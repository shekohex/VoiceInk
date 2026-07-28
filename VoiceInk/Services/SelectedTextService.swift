import ApplicationServices
import Foundation
import SelectedTextKit
import os

@MainActor
final class SelectedTextService {
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SelectedTextService")
    private static let textManager = SelectedTextManager.shared
    private static let selectedTextStrategies: [TextStrategy] = [
        .accessibility,
        .menuAction,
        .appleScript,
    ]

    static func fetchSelectedText() async -> String? {
        guard AXIsProcessTrusted() else {
            RecordingPerformanceDiagnostics.shared.mark("selected_text.permission_denied")
            logger.debug("Accessibility is not trusted; selected text capture skipped")
            return nil
        }

        RecordingPerformanceDiagnostics.shared.mark(
            "selected_text.capture.begin",
            details: "main_thread=\(Thread.isMainThread)"
        )
        for strategy in selectedTextStrategies {
            guard !Task.isCancelled else {
                RecordingPerformanceDiagnostics.shared.mark("selected_text.capture.canceled")
                return nil
            }

            let strategyName = strategy.description.replacingOccurrences(of: " ", with: "_").lowercased()
            RecordingPerformanceDiagnostics.shared.mark(
                "selected_text.strategy.begin",
                details: "strategy=\(strategyName) main_thread=\(Thread.isMainThread)"
            )
            do {
                let text = normalized(try await textManager.getSelectedText(strategy: strategy))
                RecordingPerformanceDiagnostics.shared.mark(
                    "selected_text.strategy.end",
                    details:
                        "strategy=\(strategyName) chars=\(text?.count ?? 0) main_thread=\(Thread.isMainThread)"
                )
                if let text {
                    RecordingPerformanceDiagnostics.shared.mark(
                        "selected_text.capture.end",
                        details: "strategy=\(strategyName) chars=\(text.count)"
                    )
                    return text
                }
            } catch {
                RecordingPerformanceDiagnostics.shared.mark(
                    "selected_text.strategy.failed",
                    details: "strategy=\(strategyName) error=\(error.localizedDescription)"
                )
                logger.debug(
                    "SelectedTextKit \(strategy.description, privacy: .public) failed: \(error, privacy: .public)"
                )
            }
        }

        RecordingPerformanceDiagnostics.shared.mark("selected_text.capture.end", details: "strategy=none chars=0")
        return nil
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
