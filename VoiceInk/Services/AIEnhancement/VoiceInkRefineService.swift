import Combine
import Foundation
import OSLog

#if arch(arm64)
    import MLX
    import MLXHuggingFace
    import MLXLLM
    import MLXLMCommon
    import Tokenizers
#endif

enum VoiceInkRefineAvailability: Equatable {
    case available
    case unsupportedIntel
    case insufficientMemory
}

enum VoiceInkRefineError: LocalizedError {
    case unavailable
    case modelNotDownloaded

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return String(localized: "VoiceInk Refine requires an Apple silicon Mac with at least 16 GB of memory.")
        case .modelNotDownloaded:
            return String(localized: "VoiceInk Refine is not downloaded.")
        }
    }
}

private actor VoiceInkRefineInferenceEngine {
    #if arch(arm64)
        private var modelContainer: MLXLMCommon.ModelContainer?
        private var systemPrefixCache: [KVCache]?
        private var preparationTask: Task<Void, Error>?
        private var isWarmed = false
    #endif

    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "VoiceInkRefineInference"
    )

    func prepare(modelDirectory: URL) async throws {
        #if arch(arm64)
            if isWarmed {
                return
            }

            if let preparationTask {
                try await preparationTask.value
                return
            }

            let task = Task {
                try await prepareModel(modelDirectory: modelDirectory)
            }
            preparationTask = task

            do {
                try await task.value
                preparationTask = nil
            } catch {
                preparationTask = nil
                throw error
            }
        #else
            throw VoiceInkRefineError.unavailable
        #endif
    }

    func enhance(transcript: String, modelDirectory: URL) async throws -> String {
        #if arch(arm64)
            try await prepare(modelDirectory: modelDirectory)

            guard let modelContainer, let systemPrefixCache else {
                throw VoiceInkRefineError.modelNotDownloaded
            }

            let wordCount = transcript.split(whereSeparator: \.isWhitespace).count
            let maximumOutputTokens = min(max(wordCount * 3, 256), 4_096)
            let session = ChatSession(
                modelContainer,
                cache: copy(cache: systemPrefixCache),
                generateParameters: GenerateParameters(
                    maxTokens: maximumOutputTokens,
                    temperature: 0
                )
            )

            var output = ""
            var completionInfo: GenerateCompletionInfo?
            let startedAt = Date()

            for try await event in session.streamDetails(to: transcript) {
                switch event {
                case .chunk(let text):
                    output += text
                case .info(let info):
                    completionInfo = info
                case .toolCall:
                    break
                }
            }

            let totalDuration = Date().timeIntervalSince(startedAt)
            if let completionInfo {
                logger.info(
                    "Enhancement completed total=\(totalDuration, format: .fixed(precision: 3), privacy: .public)s promptTokens=\(completionInfo.promptTokenCount, privacy: .public) prompt=\(completionInfo.promptTime, format: .fixed(precision: 3), privacy: .public)s generatedTokens=\(completionInfo.generationTokenCount, privacy: .public) generation=\(completionInfo.generateTime, format: .fixed(precision: 3), privacy: .public)s generationRate=\(completionInfo.tokensPerSecond, format: .fixed(precision: 1), privacy: .public)t/s"
                )
            }

            return output
        #else
            throw VoiceInkRefineError.unavailable
        #endif
    }

    func unload() async {
        #if arch(arm64)
            let activePreparationTask = preparationTask
            let hadActivePreparation = activePreparationTask != nil
            activePreparationTask?.cancel()
            if let activePreparationTask {
                _ = try? await activePreparationTask.value
            }

            let hadLoadedResources =
                hadActivePreparation || modelContainer != nil || systemPrefixCache != nil || isWarmed
            preparationTask = nil
            systemPrefixCache = nil
            modelContainer = nil
            isWarmed = false

            if hadLoadedResources {
                Memory.clearCache()
                logger.info("Model unloaded from memory")
            }
        #endif
    }

    #if arch(arm64)
        private func prepareModel(modelDirectory: URL) async throws {
            let container = try await loadContainerIfNeeded(from: modelDirectory)
            let prefixCache = try await buildSystemPrefixCacheIfNeeded(using: container)

            guard !isWarmed else {
                return
            }

            let startedAt = Date()
            let warmupSession = ChatSession(
                container,
                cache: copy(cache: prefixCache),
                generateParameters: GenerateParameters(
                    maxTokens: 1,
                    temperature: 0
                )
            )
            _ = try await warmupSession.respond(to: "Speech")
            try Task.checkCancellation()

            isWarmed = true
            logger.info(
                "Model warm-up completed in \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 3), privacy: .public)s"
            )
        }

        private func loadContainerIfNeeded(from modelDirectory: URL) async throws
            -> MLXLMCommon.ModelContainer
        {
            if let modelContainer {
                return modelContainer
            }

            let startedAt = Date()
            let loadedContainer = try await loadModelContainer(
                from: modelDirectory,
                using: #huggingFaceTokenizerLoader()
            )
            try Task.checkCancellation()

            modelContainer = loadedContainer
            logger.info(
                "Model loaded in \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 3), privacy: .public)s"
            )
            return loadedContainer
        }

        private func buildSystemPrefixCacheIfNeeded(
            using container: MLXLMCommon.ModelContainer
        ) async throws -> [KVCache] {
            if let systemPrefixCache {
                return systemPrefixCache
            }

            let startedAt = Date()
            let cacheBuilder = ChatSession(
                container,
                // This model has no chat template. Its normal two-message prompt is
                // joined with two newlines, so the separator belongs in the prefix.
                instructions: VoiceInkRefineService.systemPrompt + "\n\n",
                generateParameters: GenerateParameters(
                    maxTokens: 0,
                    temperature: 0
                ),
                additionalContext: ["add_generation_prompt": false]
            )

            _ = try await cacheBuilder.respond(to: [Chat.Message]())
            try Task.checkCancellation()

            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("voiceink-refine-prefix-\(UUID().uuidString)")
                .appendingPathExtension("safetensors")
            defer {
                try? FileManager.default.removeItem(at: temporaryURL)
            }

            try await cacheBuilder.saveCache(to: temporaryURL)
            let (loadedCache, _) = try loadPromptCache(url: temporaryURL)
            try Task.checkCancellation()

            systemPrefixCache = loadedCache
            logger.info(
                "System prompt prefix prefilled in \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 3), privacy: .public)s"
            )
            return loadedCache
        }

        private func copy(cache: [KVCache]) -> [KVCache] {
            cache.map { $0.copy() }
        }
    #endif
}

final class VoiceInkRefineService: ObservableObject {
    static let shared = VoiceInkRefineService()

    static let providerName = "VoiceInk Refine"
    static let modelName = "VoiceInk Refine V1"
    static let systemPrompt = """
        Transform raw ASR input into polished text. Preserve the original meaning and tone. Handle punctuation, capitalization, and spoken formatting cues properly. Remove fillers, repetitions, false starts, and discarded self-corrections. Output only the final text.
        """
    static let repositoryID = "beingpax/voiceink-refine-v1"
    static let pinnedRevision = "5bd73a600d467da5c37bfc7c76f036dddbf280f5"
    static let minimumMemoryBytes: UInt64 = 16 * 1_024 * 1_024 * 1_024
    static let downloadSizeDescription = "1.75 GB"

    @Published private(set) var isDownloaded = false
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress = 0.0
    private(set) var downloadedBytes: Int64 = 0
    private(set) var totalDownloadBytes = VoiceInkRefineModelDownloader.totalBytes
    private(set) var downloadBytesPerSecond = 0.0
    private(set) var isFinalizingDownload = false
    @Published private(set) var downloadError: String?

    let availability: VoiceInkRefineAvailability

    var isAvailableInModes: Bool {
        availability == .available && isDownloaded
    }

    var shouldShowInCatalog: Bool {
        availability != .insufficientMemory
    }

    var unavailableDescription: String? {
        switch availability {
        case .available:
            return nil
        case .unsupportedIntel:
            return String(localized: "Available on Apple silicon Macs with at least 16 GB of memory.")
        case .insufficientMemory:
            return String(localized: "Requires at least 16 GB of memory.")
        }
    }

    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "VoiceInkRefineService"
    )
    private let modelRootDirectory: URL
    private let inferenceEngine = VoiceInkRefineInferenceEngine()
    private var downloadTask: Task<Void, Never>?

    private init(
        architectureIsAppleSilicon: Bool = SystemArchitecture.isAppleSilicon,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) {
        if !architectureIsAppleSilicon {
            availability = .unsupportedIntel
        } else if physicalMemory < Self.minimumMemoryBytes {
            availability = .insufficientMemory
        } else {
            availability = .available
        }

        let appSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        modelRootDirectory = appSupportDirectory
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
            .appendingPathComponent("VoiceInkRefine")

        refreshDownloadedState()
    }

    @MainActor
    func startDownload() {
        guard availability == .available, !isDownloaded, downloadTask == nil else {
            return
        }

        downloadTask = Task { [weak self] in
            await self?.downloadModel()
        }
    }

    @MainActor
    func cancelDownload() {
        downloadTask?.cancel()
    }

    @MainActor
    func deleteModel() async {
        cancelDownload()
        await inferenceEngine.unload()

        do {
            if FileManager.default.fileExists(atPath: modelRootDirectory.path) {
                try FileManager.default.removeItem(at: modelRootDirectory)
            }
            downloadProgress = 0
            downloadedBytes = 0
            downloadBytesPerSecond = 0
            isFinalizingDownload = false
            downloadError = nil
            refreshDownloadedState()
            NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
        } catch {
            downloadError = error.localizedDescription
            logger.error("Failed to delete VoiceInk Refine: \(error.localizedDescription, privacy: .public)")
        }
    }

    func enhance(transcript: String) async throws -> String {
        guard availability == .available else {
            throw VoiceInkRefineError.unavailable
        }
        guard isDownloaded, let snapshotURL else {
            throw VoiceInkRefineError.modelNotDownloaded
        }

        do {
            let result = try await inferenceEngine.enhance(
                transcript: transcript,
                modelDirectory: snapshotURL
            )
            await inferenceEngine.unload()
            return result
        } catch {
            await inferenceEngine.unload()
            throw error
        }
    }

    func unloadFromMemory() async {
        await inferenceEngine.unload()
    }

    func prepareForRecording() {
        guard availability == .available, isDownloaded, let snapshotURL else {
            return
        }

        let inferenceEngine = inferenceEngine
        let logger = logger
        Task.detached(priority: .utility) {
            do {
                try await inferenceEngine.prepare(modelDirectory: snapshotURL)
            } catch is CancellationError {
                logger.debug("Background model preparation was cancelled")
            } catch {
                logger.error(
                    "Background model preparation failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    @MainActor
    private func downloadModel() async {
        downloadProgress = 0
        downloadedBytes = 0
        totalDownloadBytes = VoiceInkRefineModelDownloader.totalBytes
        downloadBytesPerSecond = 0
        isFinalizingDownload = false
        downloadError = nil
        isDownloading = true

        defer {
            isDownloading = false
            downloadBytesPerSecond = 0
            isFinalizingDownload = false
            downloadTask = nil
        }

        #if arch(arm64)
            let downloader = VoiceInkRefineModelDownloader(
                repositoryID: Self.repositoryID,
                revision: Self.pinnedRevision,
                modelRootDirectory: modelRootDirectory
            )
            let progressTask = Task { @MainActor [weak self, downloader] in
                var lastSampleDate = Date()
                var lastSampleBytes = downloader.progress.transferredBytes
                var smoothedBytesPerSecond = 0.0

                while !Task.isCancelled {
                    let snapshot = downloader.progress
                    let now = Date()
                    let elapsed = now.timeIntervalSince(lastSampleDate)

                    if elapsed >= 0.25 {
                        let byteDelta = max(
                            0,
                            snapshot.transferredBytes - lastSampleBytes
                        )
                        let instantaneousSpeed = Double(byteDelta) / elapsed
                        smoothedBytesPerSecond = smoothedBytesPerSecond == 0
                            ? instantaneousSpeed
                            : (smoothedBytesPerSecond * 0.7) + (instantaneousSpeed * 0.3)
                        lastSampleDate = now
                        lastSampleBytes = snapshot.transferredBytes
                    }

                    self?.applyDownloadProgress(
                        snapshot,
                        bytesPerSecond: smoothedBytesPerSecond
                    )
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer {
                progressTask.cancel()
            }

            do {
                let downloadOperation = Task.detached(priority: .utility) {
                    try await downloader.download()
                }
                defer {
                    downloadOperation.cancel()
                }

                try await withTaskCancellationHandler {
                    try await downloadOperation.value
                } onCancel: {
                    downloadOperation.cancel()
                }
                try Task.checkCancellation()
                applyDownloadProgress(downloader.progress, bytesPerSecond: 0)
                refreshDownloadedState()
                downloadProgress = isDownloaded ? 1 : 0
                NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
            } catch is CancellationError {
                downloadError = nil
            } catch {
                downloadError = error.localizedDescription
                logger.error("Failed to download VoiceInk Refine: \(error.localizedDescription, privacy: .public)")
            }
        #else
            downloadError = VoiceInkRefineError.unavailable.localizedDescription
        #endif
    }

    private var snapshotURL: URL? {
        #if arch(arm64)
            return VoiceInkRefineModelDownloader.snapshotDirectory(
                in: modelRootDirectory,
                repositoryID: Self.repositoryID,
                revision: Self.pinnedRevision
            )
        #else
            return nil
        #endif
    }

    private func refreshDownloadedState() {
        guard let snapshotURL else {
            isDownloaded = false
            return
        }

        isDownloaded = VoiceInkRefineModelDownloader.isSnapshotComplete(
            at: snapshotURL
        )
    }

    @MainActor
    private func applyDownloadProgress(
        _ progress: VoiceInkRefineDownloadProgress,
        bytesPerSecond: Double
    ) {
        downloadedBytes = progress.downloadedBytes
        totalDownloadBytes = progress.totalBytes
        downloadBytesPerSecond = progress.isFinalizing ? 0 : bytesPerSecond
        isFinalizingDownload = progress.isFinalizing
        downloadProgress = progress.totalBytes > 0
            ? min(1, Double(progress.downloadedBytes) / Double(progress.totalBytes))
            : 0
    }
}
