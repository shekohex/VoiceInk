import Foundation

#if arch(arm64)
    import MLX
    import MLXHuggingFace
    import MLXLLM
    import MLXLMCommon
    import Tokenizers
#endif

enum VoiceInkRefineInferenceError: LocalizedError {
    case unavailable
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "VoiceInk Refine requires Apple silicon."
        case .modelNotLoaded:
            return "VoiceInk Refine could not load the selected model."
        }
    }
}

actor VoiceInkRefineInferenceEngine {
    #if arch(arm64)
        private struct PreparationIdentity: Equatable {
            let modelDirectoryPath: String
            let systemPrompt: String
        }

        private static let activeCacheLimitBytes = 64 * 1_024 * 1_024

        private var modelContainer: MLXLMCommon.ModelContainer?
        private var systemPrefixCache: [KVCache]?
        private var preparationTask: Task<Void, Error>?
        private var preparationIdentity: PreparationIdentity?
        private var isWarmed = false
    #endif

    func prepare(
        requestID _: UUID,
        modelDirectory: URL,
        systemPrompt: String
    ) async throws {
        #if arch(arm64)
            let requestedIdentity = PreparationIdentity(
                modelDirectoryPath: modelDirectory.path,
                systemPrompt: systemPrompt
            )

            if isWarmed, preparationIdentity == requestedIdentity {
                return
            }

            if let preparationTask, preparationIdentity == requestedIdentity {
                try await preparationTask.value
                return
            }

            if preparationTask != nil || preparationIdentity != nil {
                await unload()
            }

            Memory.cacheLimit = Self.activeCacheLimitBytes
            preparationIdentity = requestedIdentity
            let task = Task {
                try await prepareModel(
                    modelDirectory: modelDirectory,
                    systemPrompt: systemPrompt
                )
            }
            preparationTask = task

            do {
                try await task.value
                preparationTask = nil
            } catch {
                preparationTask = nil
                preparationIdentity = nil
                throw error
            }
        #else
            throw VoiceInkRefineInferenceError.unavailable
        #endif
    }

    func enhance(
        requestID: UUID,
        transcript: String,
        modelDirectory: URL,
        systemPrompt: String
    ) async throws -> String {
        #if arch(arm64)
            try await prepare(
                requestID: requestID,
                modelDirectory: modelDirectory,
                systemPrompt: systemPrompt
            )

            guard let modelContainer, let systemPrefixCache else {
                throw VoiceInkRefineInferenceError.modelNotLoaded
            }

            let wordCount = transcript.split(whereSeparator: \.isWhitespace).count
            let maximumOutputTokens = min(max(wordCount * 3, 256), 8_192)
            let session = ChatSession(
                modelContainer,
                cache: copy(cache: systemPrefixCache),
                generateParameters: GenerateParameters(
                    maxTokens: maximumOutputTokens,
                    temperature: 0
                )
            )

            var output = ""

            do {
                for try await event in session.streamDetails(to: transcript) {
                    try Task.checkCancellation()
                    switch event {
                    case .chunk(let text):
                        output += text
                    case .info:
                        break
                    case .toolCall:
                        break
                    }
                }
                await session.clear()
            } catch {
                await session.clear()
                throw error
            }

            return output
        #else
            throw VoiceInkRefineInferenceError.unavailable
        #endif
    }

    func unload() async {
        #if arch(arm64)
            var activePreparationTask = preparationTask
            let hadActivePreparation = activePreparationTask != nil
            activePreparationTask?.cancel()
            if let activePreparationTask {
                _ = try? await activePreparationTask.value
            }
            activePreparationTask = nil

            let hadLoadedResources =
                hadActivePreparation || modelContainer != nil || systemPrefixCache != nil || isWarmed
            preparationTask = nil
            preparationIdentity = nil

            if hadLoadedResources {
                Stream.gpu.synchronize()

                Memory.cacheLimit = 0
                autoreleasepool {
                    systemPrefixCache = nil
                    modelContainer = nil
                    isWarmed = false
                }

                Stream.gpu.synchronize()
                Memory.clearCache()
                Stream.gpu.synchronize()
            } else {
                Memory.cacheLimit = 0
                isWarmed = false
            }
        #endif
    }

    #if arch(arm64)
        private func prepareModel(
            modelDirectory: URL,
            systemPrompt: String
        ) async throws {
            let container = try await loadContainerIfNeeded(from: modelDirectory)
            let prefixCache = try await buildSystemPrefixCacheIfNeeded(
                using: container,
                systemPrompt: systemPrompt
            )

            guard !isWarmed else { return }

            let warmupSession = ChatSession(
                container,
                cache: copy(cache: prefixCache),
                generateParameters: GenerateParameters(
                    maxTokens: 1,
                    temperature: 0
                )
            )
            do {
                _ = try await warmupSession.respond(to: "Speech")
                await warmupSession.clear()
            } catch {
                await warmupSession.clear()
                throw error
            }
            try Task.checkCancellation()

            isWarmed = true
        }

        private func loadContainerIfNeeded(
            from modelDirectory: URL
        ) async throws -> MLXLMCommon.ModelContainer {
            if let modelContainer {
                return modelContainer
            }

            let loadedContainer = try await loadModelContainer(
                from: modelDirectory,
                using: #huggingFaceTokenizerLoader()
            )
            try Task.checkCancellation()

            modelContainer = loadedContainer
            return loadedContainer
        }

        private func buildSystemPrefixCacheIfNeeded(
            using container: MLXLMCommon.ModelContainer,
            systemPrompt: String
        ) async throws -> [KVCache] {
            if let systemPrefixCache {
                return systemPrefixCache
            }

            let cacheBuilder = ChatSession(
                container,
                // This model has no chat template. Its normal two-message prompt is
                // joined with two newlines, so the separator belongs in the prefix.
                instructions: systemPrompt + "\n\n",
                generateParameters: GenerateParameters(
                    maxTokens: 0,
                    temperature: 0
                ),
                additionalContext: ["add_generation_prompt": false]
            )

            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("voiceink-refine-prefix-\(UUID().uuidString)")
                .appendingPathExtension("safetensors")
            defer {
                try? FileManager.default.removeItem(at: temporaryURL)
            }

            let loadedCache: [KVCache]
            do {
                _ = try await cacheBuilder.respond(to: [Chat.Message]())
                try Task.checkCancellation()
                try await cacheBuilder.saveCache(to: temporaryURL)
                (loadedCache, _) = try loadPromptCache(url: temporaryURL)
                await cacheBuilder.clear()
                try Task.checkCancellation()
            } catch {
                await cacheBuilder.clear()
                throw error
            }

            systemPrefixCache = loadedCache
            return loadedCache
        }

        private func copy(cache: [KVCache]) -> [KVCache] {
            cache.map { $0.copy() }
        }
    #endif
}
