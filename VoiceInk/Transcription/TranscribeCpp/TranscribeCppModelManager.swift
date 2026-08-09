import AppKit
import CryptoKit
import Foundation
import os

struct TranscribeCppDownloadStatus: Sendable {
    let fractionCompleted: Double
    let message: String
    let isIndeterminate: Bool
}

private final class TranscribeCppDownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destinationURL: URL
    private let expectedByteCount: Int64
    private let progressHandler: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var isCancelled = false
    private var isCompleted = false

    init(
        destinationURL: URL,
        expectedByteCount: Int64,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) {
        self.destinationURL = destinationURL
        self.expectedByteCount = expectedByteCount
        self.progressHandler = progressHandler
    }

    func start(from sourceURL: URL) async throws -> HTTPURLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: sourceURL)

                let shouldStart = lock.withLock {
                    guard !isCancelled, !isCompleted else { return false }
                    self.session = session
                    self.task = task
                    self.continuation = continuation
                    return true
                }

                if shouldStart {
                    task.resume()
                } else {
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = expectedByteCount > 0 ? expectedByteCount : totalBytesExpectedToWrite
        guard total > 0 else { return }

        let fraction = Double(totalBytesWritten) / Double(total)
        progressHandler(min(max(fraction, 0), 1))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo temporaryURL: URL
    ) {
        let result: Result<HTTPURLResponse, Error>

        if let httpResponse = downloadTask.response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        {
            do {
                try? FileManager.default.removeItem(at: destinationURL)
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
                result = .success(httpResponse)
            } catch {
                result = .failure(error)
            }
        } else {
            result = .failure(URLError(.badServerResponse))
        }

        finish(with: result)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(with: .failure(error))
        }
    }

    private func finish(with result: Result<HTTPURLResponse, Error>) {
        let resolution = lock.withLock {
            guard !isCompleted else {
                return (nil as CheckedContinuation<HTTPURLResponse, Error>?, nil as URLSession?)
            }

            isCompleted = true
            let continuation = self.continuation
            let session = self.session
            self.continuation = nil
            self.session = nil
            task = nil
            return (continuation, session)
        }

        resolution.1?.finishTasksAndInvalidate()
        resolution.0?.resume(with: result)
    }

    private func cancel() {
        let session = lock.withLock {
            isCancelled = true
            return self.session
        }
        session?.invalidateAndCancel()
    }
}

@MainActor
final class TranscribeCppModelManager: ObservableObject {
    static let shared = TranscribeCppModelManager()

    @Published private var downloadStatuses: [String: TranscribeCppDownloadStatus] = [:]
    @Published private var modelStateRevision = 0

    var onModelDeleted: ((String) -> Void)?
    var onModelsChanged: (() -> Void)?

    private var activeDownloadIDs: [String: UUID] = [:]
    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "TranscribeCppModelManager"
    )

    private init() {}

    func isModelDownloaded(_ model: TranscribeCppModel) -> Bool {
        isModelDownloaded(named: model.name)
    }

    func isModelDownloaded(named modelName: String) -> Bool {
        TranscribeCppModelCatalog.artifact(for: modelName)?.installedModelFileURL != nil
    }

    func isModelDownloading(_ model: TranscribeCppModel) -> Bool {
        activeDownloadIDs[model.name] != nil
    }

    func downloadStatus(for model: TranscribeCppModel) -> TranscribeCppDownloadStatus? {
        downloadStatuses[model.name]
    }

    func downloadModel(_ model: TranscribeCppModel) async {
        guard
            let artifact = TranscribeCppModelCatalog.artifact(for: model.name),
            activeDownloadIDs[model.name] == nil,
            !isModelDownloaded(model)
        else {
            return
        }

        let downloadID = UUID()
        activeDownloadIDs[model.name] = downloadID
        downloadStatuses[model.name] = TranscribeCppDownloadStatus(
            fractionCompleted: 0,
            message: String(localized: "Downloading..."),
            isIndeterminate: false
        )

        defer {
            if activeDownloadIDs[model.name] == downloadID {
                activeDownloadIDs[model.name] = nil
                downloadStatuses[model.name] = nil
                onModelsChanged?()
            }
        }

        let partialURL = artifact.modelDirectory.appendingPathComponent("\(artifact.fileName).partial")
        let modelName = model.name

        do {
            try FileManager.default.createDirectory(at: artifact.modelDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: partialURL)

            let operation = TranscribeCppDownloadOperation(
                destinationURL: partialURL,
                expectedByteCount: artifact.expectedFileSize
            ) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.updateDownloadProgress(fraction, for: modelName, downloadID: downloadID)
                }
            }
            _ = try await operation.start(from: artifact.downloadURL)
            try Task.checkCancellation()

            downloadStatuses[model.name] = TranscribeCppDownloadStatus(
                fractionCompleted: 1,
                message: String(localized: "Verifying..."),
                isIndeterminate: true
            )

            let values = try partialURL.resourceValues(forKeys: [.fileSizeKey])
            guard Int64(values.fileSize ?? 0) == artifact.expectedFileSize else {
                throw CocoaError(.fileReadCorruptFile)
            }

            let checksum = try await Task.detached(priority: .utility) {
                try Self.sha256(of: partialURL)
            }.value
            guard checksum == artifact.expectedSHA256 else {
                throw CocoaError(.fileReadCorruptFile)
            }

            try? FileManager.default.removeItem(at: artifact.modelFileURL)
            try FileManager.default.moveItem(at: partialURL, to: artifact.modelFileURL)
            try artifact.expectedSHA256.write(
                to: artifact.checksumFileURL,
                atomically: true,
                encoding: .utf8
            )

            guard artifact.installedModelFileURL != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }

            logger.notice("\(model.displayName, privacy: .public) installed successfully")
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: partialURL)
            logger.notice("\(model.displayName, privacy: .public) download cancelled")
        } catch {
            try? FileManager.default.removeItem(at: partialURL)
            if !artifact.modelFileIsValid(in: artifact.modelDirectory) {
                try? FileManager.default.removeItem(at: artifact.modelFileURL)
                try? FileManager.default.removeItem(at: artifact.checksumFileURL)
            }
            logger.error("\(model.displayName, privacy: .public) download failed: \(error, privacy: .public)")
            NotificationManager.shared.showNotification(
                title: "\(model.displayName) download failed",
                type: .error
            )
        }
    }

    func deleteModel(_ model: TranscribeCppModel) {
        guard let artifact = TranscribeCppModelCatalog.artifact(for: model.name) else { return }
        artifact.removeInstalledFiles()
        modelStateRevision += 1
        NotificationCenter.default.post(
            name: .transcribeCppModelDeleted,
            object: nil,
            userInfo: ["modelName": model.name]
        )
        onModelDeleted?(model.name)
        onModelsChanged?()
    }

    func showModelInFinder(_ model: TranscribeCppModel) {
        guard
            let artifact = TranscribeCppModelCatalog.artifact(for: model.name),
            let modelFileURL = artifact.installedModelFileURL
        else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([modelFileURL])
    }

    private func updateDownloadProgress(_ fraction: Double, for modelName: String, downloadID: UUID) {
        guard activeDownloadIDs[modelName] == downloadID, fraction.isFinite else { return }
        let currentFraction = downloadStatuses[modelName]?.fractionCompleted ?? 0
        guard fraction > currentFraction else { return }
        guard fraction == 1 || fraction - currentFraction >= 0.005 else { return }

        downloadStatuses[modelName] = TranscribeCppDownloadStatus(
            fractionCompleted: fraction,
            message: String(localized: "Downloading..."),
            isIndeterminate: false
        )
    }

    nonisolated private static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 8 * 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
