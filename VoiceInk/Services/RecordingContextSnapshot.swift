import AppKit
import Foundation

struct RecordingContextSnapshot {
    var capturedAt = Date()
    var selectedText: String?
    var clipboardText: String?
    var screenText: String?
}

@MainActor
final class RecordingContextSnapshotStore {
    private(set) var snapshot = RecordingContextSnapshot()

    func updateSelectedText(_ text: String?) {
        snapshot.selectedText = Self.normalized(text)
    }

    func updateClipboardText(_ text: String?) {
        snapshot.clipboardText = Self.normalized(text)
    }

    func updateScreenText(_ text: String?) {
        snapshot.screenText = Self.normalized(text)
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
enum RecordingContextCaptureService {
    static func startCapture(into store: RecordingContextSnapshotStore) -> [Task<Void, Never>] {
        [
            Task { @MainActor in
                RecordingPerformanceDiagnostics.shared.mark("context.clipboard.begin")
                let clipboardText = NSPasteboard.general.string(forType: .string)
                store.updateClipboardText(clipboardText)
                RecordingPerformanceDiagnostics.shared.mark(
                    "context.clipboard.end",
                    details: "chars=\(clipboardText?.count ?? 0)"
                )
            },
            Task { @MainActor in
                guard !Task.isCancelled else { return }
                RecordingPerformanceDiagnostics.shared.mark("context.selected_text.begin")
                let selectedText = await SelectedTextService.fetchSelectedText()
                guard !Task.isCancelled else { return }
                store.updateSelectedText(selectedText)
                RecordingPerformanceDiagnostics.shared.mark(
                    "context.selected_text.end",
                    details: "chars=\(selectedText?.count ?? 0)"
                )
            },
            Task { @MainActor in
                guard CGPreflightScreenCaptureAccess(), !Task.isCancelled else {
                    RecordingPerformanceDiagnostics.shared.mark("context.screen_capture.skipped")
                    return
                }
                RecordingPerformanceDiagnostics.shared.mark("context.screen_capture.begin")
                let screenCaptureService = ScreenCaptureService()
                let screenText = await screenCaptureService.captureAndExtractText()
                guard !Task.isCancelled else { return }
                store.updateScreenText(screenText)
                RecordingPerformanceDiagnostics.shared.mark(
                    "context.screen_capture.end",
                    details: "chars=\(screenText?.count ?? 0)"
                )
            },
        ]
    }
}
