import Foundation

struct VoiceInkRefineDownloadProgress: Sendable {
    let downloadedBytes: Int64
    let totalBytes: Int64
    let transferredBytes: Int64
    let isFinalizing: Bool
}

enum VoiceInkRefineDownloadError: LocalizedError {
    case invalidDownloadURL(String)
    case invalidResponse(String)
    case unexpectedStatusCode(Int, String)
    case invalidContentRange(String)
    case invalidFileSize(String, expected: Int64, actual: Int64)

    var errorDescription: String? {
        switch self {
        case let .invalidDownloadURL(path):
            return String(localized: "Could not create the download URL for \(path).")
        case let .invalidResponse(path):
            return String(localized: "The model server returned an invalid response for \(path).")
        case let .unexpectedStatusCode(statusCode, path):
            return String(localized: "The model server returned status \(statusCode) for \(path).")
        case let .invalidContentRange(path):
            return String(localized: "The model server returned an invalid byte range for \(path).")
        case let .invalidFileSize(path, expected, actual):
            return String(
                localized: "The downloaded size for \(path) was \(actual) bytes instead of \(expected) bytes."
            )
        }
    }
}

final class VoiceInkRefineModelDownloader: @unchecked Sendable {
    struct ModelFile: Sendable {
        let path: String
        let size: Int64
    }

    static let files: [ModelFile] = [
        ModelFile(path: ".gitattributes", size: 1_570),
        ModelFile(path: "LICENSE.md", size: 275),
        ModelFile(path: "README.md", size: 1_087),
        ModelFile(path: "chat_template.jinja", size: 7_650),
        ModelFile(path: "config.json", size: 3_113),
        ModelFile(path: "model.safetensors", size: 1_722_271_785),
        ModelFile(path: "model.safetensors.index.json", size: 81_722),
        ModelFile(path: "preprocessor_config.json", size: 390),
        ModelFile(path: "processor_config.json", size: 991),
        ModelFile(path: "tokenizer.json", size: 19_989_325),
        ModelFile(path: "tokenizer_config.json", size: 1_165),
        ModelFile(path: "video_preprocessor_config.json", size: 385),
        ModelFile(path: "vocab.json", size: 6_722_759),
    ]

    static let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }

    static func snapshotDirectory(
        in modelRootDirectory: URL,
        repositoryID: String,
        revision: String
    ) -> URL {
        modelRootDirectory
            .appendingPathComponent("models--\(repositoryID.replacingOccurrences(of: "/", with: "--"))")
            .appendingPathComponent("snapshots")
            .appendingPathComponent(revision)
    }

    static func isSnapshotComplete(at snapshotDirectory: URL) -> Bool {
        files.allSatisfy { file in
            fileSize(at: snapshotDirectory.appendingPathComponent(file.path)) == file.size
        }
    }

    private struct DownloadJob: Sendable {
        let file: ModelFile
        let partIndex: Int
        let startByte: Int64
        let endByte: Int64
        let destination: URL

        var identifier: String {
            "\(file.path)#\(partIndex)"
        }

        var expectedSize: Int64 {
            endByte - startByte + 1
        }

        var isWholeFile: Bool {
            startByte == 0 && expectedSize == file.size
        }
    }

    private let repositoryID: String
    private let revision: String
    private let snapshotDirectory: URL
    private let partsDirectory: URL
    private let progressTracker = ProgressTracker(totalBytes: totalBytes)
    private let maximumConcurrentDownloads = 8
    private let parallelDownloadThreshold: Int64 = 64 * 1_024 * 1_024

    init(repositoryID: String, revision: String, modelRootDirectory: URL) {
        self.repositoryID = repositoryID
        self.revision = revision
        snapshotDirectory = Self.snapshotDirectory(
            in: modelRootDirectory,
            repositoryID: repositoryID,
            revision: revision
        )
        partsDirectory = modelRootDirectory
            .appendingPathComponent(".voiceink-downloads")
            .appendingPathComponent(revision)
    }

    var progress: VoiceInkRefineDownloadProgress {
        progressTracker.snapshot()
    }

    func download() async throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(
            at: snapshotDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: partsDirectory,
            withIntermediateDirectories: true
        )

        let jobs = try prepareDownloadJobs()
        if !jobs.isEmpty {
            let configuration = URLSessionConfiguration.default
            configuration.httpMaximumConnectionsPerHost = maximumConcurrentDownloads
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 24 * 60 * 60
            configuration.waitsForConnectivity = true

            let delegateQueue = OperationQueue()
            delegateQueue.name = "com.prakashjoshipax.voiceink.refine-download"
            delegateQueue.qualityOfService = .utility
            delegateQueue.maxConcurrentOperationCount = 1

            let delegate = DownloadSessionDelegate(progressTracker: progressTracker)
            let session = URLSession(
                configuration: configuration,
                delegate: delegate,
                delegateQueue: delegateQueue
            )
            defer {
                session.invalidateAndCancel()
            }

            try await download(jobs, using: session, delegate: delegate)
        }

        try Task.checkCancellation()
        progressTracker.beginFinalizing()
        try assembleDownloadedFiles()
        try validateSnapshot()

        if FileManager.default.fileExists(atPath: partsDirectory.path) {
            try FileManager.default.removeItem(at: partsDirectory)
        }
    }

    private func prepareDownloadJobs() throws -> [DownloadJob] {
        var jobs: [DownloadJob] = []

        for file in Self.files {
            try Task.checkCancellation()

            let finalURL = snapshotDirectory.appendingPathComponent(file.path)
            if Self.fileSize(at: finalURL) == file.size {
                progressTracker.addPersistedBytes(file.size)
                continue
            }

            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }

            let partCount = file.size >= parallelDownloadThreshold ? maximumConcurrentDownloads : 1
            for partIndex in 0..<partCount {
                let range = byteRange(partIndex: partIndex, partCount: partCount, fileSize: file.size)
                let destination = partURL(for: file, partIndex: partIndex)
                let expectedSize = range.end - range.start + 1

                if Self.fileSize(at: destination) == expectedSize {
                    progressTracker.addPersistedBytes(expectedSize)
                    continue
                }

                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }

                jobs.append(
                    DownloadJob(
                        file: file,
                        partIndex: partIndex,
                        startByte: range.start,
                        endByte: range.end,
                        destination: destination
                    )
                )
            }
        }

        return jobs
    }

    private func download(
        _ jobs: [DownloadJob],
        using session: URLSession,
        delegate: DownloadSessionDelegate
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = jobs.makeIterator()
            let initialJobCount = min(maximumConcurrentDownloads, jobs.count)

            for _ in 0..<initialJobCount {
                if let job = iterator.next() {
                    group.addTask { [self] in
                        try await download(job, using: session, delegate: delegate)
                    }
                }
            }

            while try await group.next() != nil {
                try Task.checkCancellation()
                if let job = iterator.next() {
                    group.addTask { [self] in
                        try await download(job, using: session, delegate: delegate)
                    }
                }
            }
        }
    }

    private func download(
        _ job: DownloadJob,
        using session: URLSession,
        delegate: DownloadSessionDelegate
    ) async throws {
        try Task.checkCancellation()

        guard let url = URL(
            string: "https://huggingface.co/\(repositoryID)/resolve/\(revision)/\(job.file.path)"
        ) else {
            throw VoiceInkRefineDownloadError.invalidDownloadURL(job.file.path)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 24 * 60 * 60
        request.setValue(
            "bytes=\(job.startByte)-\(job.endByte)",
            forHTTPHeaderField: "Range"
        )
        request.setValue("VoiceInk", forHTTPHeaderField: "User-Agent")

        let task = session.downloadTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.register(
                    task: task,
                    job: job,
                    continuation: continuation
                )
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func assembleDownloadedFiles() throws {
        for file in Self.files {
            try Task.checkCancellation()

            let finalURL = snapshotDirectory.appendingPathComponent(file.path)
            if Self.fileSize(at: finalURL) == file.size {
                continue
            }

            let partCount = file.size >= parallelDownloadThreshold ? maximumConcurrentDownloads : 1
            try FileManager.default.createDirectory(
                at: finalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }

            if partCount == 1 {
                try FileManager.default.moveItem(
                    at: partURL(for: file, partIndex: 0),
                    to: finalURL
                )
            } else {
                FileManager.default.createFile(atPath: finalURL.path, contents: nil)
                let output = try FileHandle(forWritingTo: finalURL)
                defer {
                    try? output.close()
                }

                for partIndex in 0..<partCount {
                    try Task.checkCancellation()
                    let input = try FileHandle(
                        forReadingFrom: partURL(for: file, partIndex: partIndex)
                    )
                    defer {
                        try? input.close()
                    }

                    while let data = try input.read(upToCount: 1_024 * 1_024), !data.isEmpty {
                        try Task.checkCancellation()
                        try output.write(contentsOf: data)
                    }
                }
            }

            let actualSize = Self.fileSize(at: finalURL) ?? 0
            guard actualSize == file.size else {
                throw VoiceInkRefineDownloadError.invalidFileSize(
                    file.path,
                    expected: file.size,
                    actual: actualSize
                )
            }
        }
    }

    private func validateSnapshot() throws {
        for file in Self.files {
            let actualSize = Self.fileSize(
                at: snapshotDirectory.appendingPathComponent(file.path)
            ) ?? 0
            guard actualSize == file.size else {
                throw VoiceInkRefineDownloadError.invalidFileSize(
                    file.path,
                    expected: file.size,
                    actual: actualSize
                )
            }
        }
    }

    private func byteRange(
        partIndex: Int,
        partCount: Int,
        fileSize: Int64
    ) -> (start: Int64, end: Int64) {
        let baseSize = fileSize / Int64(partCount)
        let remainder = fileSize % Int64(partCount)
        let extraByteCount = min(Int64(partIndex), remainder)
        let start = Int64(partIndex) * baseSize + extraByteCount
        let currentSize = baseSize + (Int64(partIndex) < remainder ? 1 : 0)
        return (start, start + currentSize - 1)
    }

    private func partURL(for file: ModelFile, partIndex: Int) -> URL {
        partsDirectory
            .appendingPathComponent(file.path, isDirectory: true)
            .appendingPathComponent("\(partIndex).part")
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url)
        else {
            return nil
        }
        defer {
            try? handle.close()
        }
        return try? Int64(handle.seekToEnd())
    }

    private final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private final class Context: @unchecked Sendable {
            let job: DownloadJob
            let continuation: CheckedContinuation<Void, Error>
            var completionError: Error?
            var didPersistDownload = false

            init(
                job: DownloadJob,
                continuation: CheckedContinuation<Void, Error>
            ) {
                self.job = job
                self.continuation = continuation
            }
        }

        private let lock = NSLock()
        private let progressTracker: ProgressTracker
        private var contexts: [Int: Context] = [:]

        init(progressTracker: ProgressTracker) {
            self.progressTracker = progressTracker
        }

        func register(
            task: URLSessionDownloadTask,
            job: DownloadJob,
            continuation: CheckedContinuation<Void, Error>
        ) {
            lock.lock()
            contexts[task.taskIdentifier] = Context(
                job: job,
                continuation: continuation
            )
            lock.unlock()
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let context = context(for: task) else {
                completionHandler(request)
                return
            }

            var redirectedRequest = request
            redirectedRequest.setValue(
                "bytes=\(context.job.startByte)-\(context.job.endByte)",
                forHTTPHeaderField: "Range"
            )
            redirectedRequest.setValue("VoiceInk", forHTTPHeaderField: "User-Agent")
            completionHandler(redirectedRequest)
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard let context = context(for: downloadTask) else {
                return
            }
            progressTracker.update(
                identifier: context.job.identifier,
                downloadedBytes: min(totalBytesWritten, context.job.expectedSize)
            )
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            guard let context = context(for: downloadTask) else {
                return
            }

            do {
                try validateResponse(for: downloadTask, job: context.job)

                let actualSize = VoiceInkRefineModelDownloader.fileSize(at: location) ?? 0
                guard actualSize == context.job.expectedSize else {
                    throw VoiceInkRefineDownloadError.invalidFileSize(
                        context.job.file.path,
                        expected: context.job.expectedSize,
                        actual: actualSize
                    )
                }

                try FileManager.default.createDirectory(
                    at: context.job.destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: context.job.destination.path) {
                    try FileManager.default.removeItem(at: context.job.destination)
                }
                try FileManager.default.moveItem(
                    at: location,
                    to: context.job.destination
                )
                progressTracker.finish(
                    identifier: context.job.identifier,
                    persistedBytes: context.job.expectedSize
                )
                context.didPersistDownload = true
            } catch {
                context.completionError = error
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            guard let context = removeContext(for: task) else {
                return
            }

            if let error {
                if (error as? URLError)?.code == .cancelled {
                    context.continuation.resume(throwing: CancellationError())
                } else {
                    context.continuation.resume(throwing: error)
                }
            } else if let completionError = context.completionError {
                context.continuation.resume(throwing: completionError)
            } else if context.didPersistDownload {
                context.continuation.resume()
            } else {
                context.continuation.resume(
                    throwing: VoiceInkRefineDownloadError.invalidResponse(
                        context.job.file.path
                    )
                )
            }
        }

        private func validateResponse(
            for downloadTask: URLSessionDownloadTask,
            job: DownloadJob
        ) throws {
            guard let response = downloadTask.response as? HTTPURLResponse else {
                throw VoiceInkRefineDownloadError.invalidResponse(job.file.path)
            }

            if response.statusCode == 206 {
                let expectedPrefix = "bytes \(job.startByte)-\(job.endByte)/"
                guard let contentRange = response.value(
                    forHTTPHeaderField: "Content-Range"
                ),
                    contentRange.lowercased().hasPrefix(expectedPrefix)
                else {
                    throw VoiceInkRefineDownloadError.invalidContentRange(
                        job.file.path
                    )
                }
            } else if response.statusCode != 200 || !job.isWholeFile {
                throw VoiceInkRefineDownloadError.unexpectedStatusCode(
                    response.statusCode,
                    job.file.path
                )
            }
        }

        private func context(for task: URLSessionTask) -> Context? {
            lock.lock()
            let context = contexts[task.taskIdentifier]
            lock.unlock()
            return context
        }

        private func removeContext(for task: URLSessionTask) -> Context? {
            lock.lock()
            let context = contexts.removeValue(forKey: task.taskIdentifier)
            lock.unlock()
            return context
        }
    }
}

private final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let totalBytes: Int64
    private var persistedBytes: Int64 = 0
    private var transferredBytes: Int64 = 0
    private var activeBytes: [String: Int64] = [:]
    private var isFinalizing = false

    init(totalBytes: Int64) {
        self.totalBytes = totalBytes
    }

    func addPersistedBytes(_ byteCount: Int64) {
        lock.lock()
        persistedBytes += byteCount
        lock.unlock()
    }

    func update(identifier: String, downloadedBytes: Int64) {
        lock.lock()
        activeBytes[identifier] = downloadedBytes
        lock.unlock()
    }

    func finish(identifier: String, persistedBytes byteCount: Int64) {
        lock.lock()
        activeBytes.removeValue(forKey: identifier)
        persistedBytes += byteCount
        transferredBytes += byteCount
        lock.unlock()
    }

    func beginFinalizing() {
        lock.lock()
        isFinalizing = true
        lock.unlock()
    }

    func snapshot() -> VoiceInkRefineDownloadProgress {
        lock.lock()
        let downloadedBytes = min(
            totalBytes,
            persistedBytes + activeBytes.values.reduce(Int64(0), +)
        )
        let currentTransferredBytes = min(
            totalBytes,
            transferredBytes + activeBytes.values.reduce(Int64(0), +)
        )
        let snapshot = VoiceInkRefineDownloadProgress(
            downloadedBytes: downloadedBytes,
            totalBytes: totalBytes,
            transferredBytes: currentTransferredBytes,
            isFinalizing: isFinalizing
        )
        lock.unlock()
        return snapshot
    }
}
