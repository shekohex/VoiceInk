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
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "VoiceInk Refine requires Apple silicon."
        case .modelNotLoaded:
            return "VoiceInk Refine could not load the selected model."
        case .emptyOutput:
            return "VoiceInk Refine returned an empty response."
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
        private static let maximumGenerationTokens = 8_192

        private var modelContainer: MLXLMCommon.ModelContainer?
        private var preparationTask: Task<Void, Error>?
        private var preparationIdentity: PreparationIdentity?
        private var isWarmed = false
    #endif

    func prepare(
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
                await unload()
                throw error
            }
        #else
            throw VoiceInkRefineInferenceError.unavailable
        #endif
    }

    func enhance(
        transcript: String,
        modelDirectory: URL,
        systemPrompt: String
    ) async throws -> String {
        #if arch(arm64)
            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return transcript
            }

            try await prepare(
                modelDirectory: modelDirectory,
                systemPrompt: systemPrompt
            )

            guard let modelContainer else {
                throw VoiceInkRefineInferenceError.modelNotLoaded
            }

            let wordCount = transcript.split(whereSeparator: \.isWhitespace).count
            let maximumOutputTokens = Self.maximumOutputTokens(forWordCount: wordCount)
            let session = makeSession(
                using: modelContainer,
                systemPrompt: systemPrompt,
                maximumOutputTokens: maximumOutputTokens
            )

            var output = ""

            do {
                for try await event in session.streamDetails(to: transcript) {
                    try Task.checkCancellation()
                    switch event {
                    case .chunk(let text):
                        output.append(contentsOf: text)
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

            guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VoiceInkRefineInferenceError.emptyOutput
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
                hadActivePreparation || modelContainer != nil || isWarmed
            preparationTask = nil
            preparationIdentity = nil

            if hadLoadedResources {
                Stream.gpu.synchronize()

                Memory.cacheLimit = 0
                autoreleasepool {
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

            guard !isWarmed else { return }

            let warmupSession = makeSession(
                using: container,
                systemPrompt: systemPrompt,
                maximumOutputTokens: 1
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

        private func makeSession(
            using container: MLXLMCommon.ModelContainer,
            systemPrompt: String,
            maximumOutputTokens: Int
        ) -> ChatSession {
            ChatSession(
                container,
                instructions: systemPrompt,
                generateParameters: GenerateParameters(
                    maxTokens: maximumOutputTokens,
                    temperature: 0
                ),
                additionalContext: ["enable_thinking": false]
            )
        }

        private static func maximumOutputTokens(forWordCount wordCount: Int) -> Int {
            let scaledTokenLimit =
                wordCount > maximumGenerationTokens / 3
                ? maximumGenerationTokens
                : wordCount * 3
            return min(max(scaledTokenLimit, 256), maximumGenerationTokens)
        }
    #endif
}
