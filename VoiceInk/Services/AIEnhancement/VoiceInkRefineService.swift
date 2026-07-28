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
                RecordingPerformanceDiagnostics.shared.mark(
                    "refine.prepare.reused",
                    details: mlxMemoryDetails()
                )
                return
            }

            if let preparationTask {
                RecordingPerformanceDiagnostics.shared.mark(
                    "refine.prepare.join_existing",
                    details: mlxMemoryDetails()
                )
                try await preparationTask.value
                return
            }

            RecordingPerformanceDiagnostics.shared.mark(
                "refine.prepare.begin",
                details: mlxMemoryDetails()
            )
            let task = Task {
                try await prepareModel(modelDirectory: modelDirectory)
            }
            preparationTask = task

            do {
                try await task.value
                preparationTask = nil
                RecordingPerformanceDiagnostics.shared.mark(
                    "refine.prepare.end",
                    details: mlxMemoryDetails()
                )
            } catch {
                preparationTask = nil
                RecordingPerformanceDiagnostics.shared.mark(
                    "refine.prepare.failed",
                    details: "\(mlxMemoryDetails()) error=\(error.localizedDescription)"
                )
                throw error
            }
        #else
            throw VoiceInkRefineError.unavailable
        #endif
    }

    func enhance(transcript: String, modelDirectory: URL) async throws -> String {
        #if arch(arm64)
            RecordingPerformanceDiagnostics.shared.mark(
                "refine.enhance.begin",
                details: "\(mlxMemoryDetails()) words=\(transcript.split(whereSeparator: \.isWhitespace).count)"
            )
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
            RecordingPerformanceDiagnostics.shared.mark(
                "refine.enhance.end",
                details: String(
                    format: "%@ duration_ms=%.2f",
                    mlxMemoryDetails(),
                    totalDuration * 1_000
                )
            )

            return output
        #else
            throw VoiceInkRefineError.unavailable
        #endif
    }

    func unload() async {
        #if arch(arm64)
            RecordingPerformanceDiagnostics.shared.mark(
                "refine.unload.begin",
                details: mlxMemoryDetails()
            )
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
            RecordingPerformanceDiagnostics.shared.mark(
                "refine.unload.end",
                details: mlxMemoryDetails()
            )
        #endif
    }

    func unloadIfNeeded() async {
        #if arch(arm64)
            guard preparationTask != nil || modelContainer != nil || systemPrefixCache != nil || isWarmed else {
                return
            }
            await unload()
        #endif
    }

    #if arch(arm64)
        private func prepareModel(modelDirectory: URL) async throws {
            RecordingPerformanceDiagnostics.shared.mark(
                "refine.model_prepare.begin",
                details: mlxMemoryDetails()
            )
            let container = try await loadContainerIfNeeded(from: modelDirectory)
            let prefixCache = try await buildSystemPrefixCacheIfNeeded(using: container)

            guard !isWarmed else {
                return
            }

            let startedAt = Date()
            RecordingPerformanceDiagnostics.shared.mark(
                "refine.warmup.begin",
                details: mlxMemoryDetails()
            )
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
            RecordingPerformanceDiagnostics.shared.mark(
                "refine.warmup.end",
                details: String(
                    format: "%@ duration_ms=%.2f",
                    mlxMemoryDetails(),
                    Date().timeIntervalSince(startedAt) * 1_000
                )
            )
            logger.info(
                "Model warm-up completed in \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 3), privacy: .public)s"
            )
        }

        private func loadContainerIfNeeded(from modelDirectory: URL) async throws
            -> MLXLMCommon.ModelContainer
        {
            if let modelContainer {
                RecordingPerformanceDiagnostics.shared.mark(
                    "refine.model_load.reused",
                    details: mlxMemoryDetails()
                )
                return modelContainer
            }

            let startedAt = Date()
            RecordingPerformanceDiagnostics.shared.mark(
                "refine.model_load.begin",
                details: mlxMemoryDetails()
            )
            let loadedContainer = try await loadModelContainer(
                from: modelDirectory,
                using: #huggingFaceTokenizerLoader()
            )
            try Task.checkCancellation()

            modelContainer = loadedContainer
            RecordingPerformanceDiagnostics.shared.mark(
                "refine.model_load.end",
                details: String(
                    format: "%@ duration_ms=%.2f",
                    mlxMemoryDetails(),
                    Date().timeIntervalSince(startedAt) * 1_000
                )
            )
            logger.info(
                "Model loaded in \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 3), privacy: .public)s"
            )
            return loadedContainer
        }

        private func buildSystemPrefixCacheIfNeeded(
            using container: MLXLMCommon.ModelContainer
        ) async throws -> [KVCache] {
            if let systemPrefixCache {
                RecordingPerformanceDiagnostics.shared.mark(
                    "refine.prefix_cache.reused",
                    details: mlxMemoryDetails()
                )
                return systemPrefixCache
            }

            let startedAt = Date()
            RecordingPerformanceDiagnostics.shared.mark(
                "refine.prefix_cache.begin",
                details: mlxMemoryDetails()
            )
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
            RecordingPerformanceDiagnostics.shared.mark(
                "refine.prefix_cache.end",
                details: String(
                    format: "%@ duration_ms=%.2f",
                    mlxMemoryDetails(),
                    Date().timeIntervalSince(startedAt) * 1_000
                )
            )
            logger.info(
                "System prompt prefix prefilled in \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 3), privacy: .public)s"
            )
            return loadedCache
        }

        private func copy(cache: [KVCache]) -> [KVCache] {
            cache.map { $0.copy() }
        }

        private func mlxMemoryDetails() -> String {
            let snapshot = Memory.snapshot()
            return String(
                format: "mlx_active_mb=%.1f mlx_cache_mb=%.1f mlx_peak_mb=%.1f",
                Double(snapshot.activeMemory) / 1_048_576,
                Double(snapshot.cacheMemory) / 1_048_576,
                Double(snapshot.peakMemory) / 1_048_576
            )
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

    func unloadPreparedModelIfNeeded() async {
        await inferenceEngine.unloadIfNeeded()
    }

    func prepareForRecording() {
        guard availability == .available, isDownloaded, let snapshotURL else {
            RecordingPerformanceDiagnostics.shared.mark(
                "refine.background_prepare.skipped",
                details:
                    "availability=\(String(describing: availability)) downloaded=\(isDownloaded)"
            )
            return
        }

        let inferenceEngine = inferenceEngine
        let logger = logger
        RecordingPerformanceDiagnostics.shared.mark("refine.background_prepare.scheduled")
        Task.detached(priority: .utility) {
            RecordingPerformanceDiagnostics.shared.mark(
                "refine.background_prepare.started",
                details: "priority=utility"
            )
            do {
                try await inferenceEngine.prepare(modelDirectory: snapshotURL)
                RecordingPerformanceDiagnostics.shared.mark("refine.background_prepare.completed")
            } catch is CancellationError {
                RecordingPerformanceDiagnostics.shared.mark("refine.background_prepare.cancelled")
                logger.debug("Background model preparation was cancelled")
            } catch {
                RecordingPerformanceDiagnostics.shared.mark(
                    "refine.background_prepare.failed",
                    details: "error=\(error.localizedDescription)"
                )
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
