import Foundation
import os

@MainActor
final class TranscriptionDelivery {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionDelivery")

    struct Request {
        let transcription: Transcription
        let text: String?
        let output: OutputRuntimeConfiguration
        let responseConfig: EnhancementRuntimeConfiguration?
        let responseError: String?
        let isAssistantFollowUp: Bool
    }

    struct Actions {
        let setState: (RecordingState) -> Void
        let dismiss: () async -> Void
        let sendFollowUp: (String, Transcription) async -> Void
        let showResponse: (String, String?) async -> Void
        let failResponse: (String) async -> Void
    }

    func deliver(_ request: Request, actions: Actions) async {
        RecordingPerformanceDiagnostics.shared.mark(
            "delivery.entered",
            details:
                "status=\(request.transcription.transcriptionStatus) output=\(String(describing: request.output.outputMode)) chars=\(request.text?.count ?? 0)"
        )
        guard request.transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue else {
            RecordingPerformanceDiagnostics.shared.mark("delivery.route.dismiss_failed")
            await actions.dismiss()
            return
        }

        if request.isAssistantFollowUp {
            RecordingPerformanceDiagnostics.shared.mark("delivery.route.follow_up")
            await deliverFollowUp(request, actions: actions)
            return
        }

        if request.output.outputMode == .respond,
            request.responseConfig != nil || request.responseError != nil
        {
            RecordingPerformanceDiagnostics.shared.mark("delivery.route.response")
            await deliverResponse(request, actions: actions)
            return
        }

        if request.output.outputMode == .customCommand {
            RecordingPerformanceDiagnostics.shared.mark("delivery.route.custom_command")
            await deliverCustomCommand(request, actions: actions)
            return
        }

        if let text = request.text {
            RecordingPerformanceDiagnostics.shared.mark("delivery.route.paste")
            await paste(text, output: request.output, actions: actions)
        } else {
            RecordingPerformanceDiagnostics.shared.mark("delivery.route.dismiss_empty")
            await actions.dismiss()
        }
    }

    private func deliverFollowUp(_ item: Request, actions: Actions) async {
        SoundManager.shared.playStopSound()

        guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            return
        }

        actions.setState(.enhancing)
        await actions.sendFollowUp(text, item.transcription)
    }

    private func deliverResponse(_ item: Request, actions: Actions) async {
        SoundManager.shared.playStopSound()

        if let responseError = item.responseError {
            await actions.failResponse("Enhancement failed: \(responseError)")
        } else if let text = item.text,
            item.responseConfig != nil
        {
            await actions.showResponse(text, item.transcription.aiRequestSystemMessage)
        } else {
            await actions.failResponse("No response was generated.")
        }
    }

    private func deliverCustomCommand(_ item: Request, actions: Actions) async {
        guard let text = item.text else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.noTextToDeliver)
            SoundManager.shared.playStopSound()
            await actions.dismiss()
            return
        }

        guard let customCommand = item.output.customCommand,
            let command = customCommand.trimmedCommand
        else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.commandNotConfigured)
            SoundManager.shared.playStopSound()
            await actions.dismiss()
            return
        }

        let commandText = deliverableText(from: text)
        SoundManager.shared.playStopSound()
        await actions.dismiss()

        Task {
            await runCustomCommand(command: command, commandText: commandText)
        }
    }

    private func runCustomCommand(command: String, commandText: String) async {
        let startTime = Date()
        logger.notice("Custom command started")

        do {
            let result = try await CustomCommandDeliveryRunner.run(
                command: command,
                timeout: 10,
                context: CustomCommandDeliveryContext(transcript: commandText)
            )

            let duration = Date().timeIntervalSince(startTime)
            let stdoutBytes = result.stdout.utf8.count
            let stderrBytes = result.stderr.utf8.count

            if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice(
                    "Custom command stdout bytes=\(stdoutBytes, privacy: .public): \(result.stdout, privacy: .public)")
            }

            if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice(
                    "Custom command succeeded with stderr duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public): \(result.stderr, privacy: .public)"
                )
            } else {
                logger.notice(
                    "Custom command succeeded duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public)"
                )
            }
        } catch {
            notifyCustomCommandFailure(error, duration: Date().timeIntervalSince(startTime))
        }
    }

    private func notifyCustomCommandFailure(_ error: Error, duration: TimeInterval? = nil) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let duration {
            logger.error(
                "Custom command failed duration=\(Self.formattedDuration(duration), privacy: .public)s: \(message, privacy: .public)"
            )
        } else {
            logger.error("Custom command failed: \(message, privacy: .public)")
        }
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.3f", duration)
    }

    private func paste(_ text: String, output: OutputRuntimeConfiguration, actions: Actions) async {
        RecordingPerformanceDiagnostics.shared.mark("delivery.paste.prepare.begin")
        let textToPaste = deliverableText(from: text)
        let appendSpace = UserDefaults.standard.bool(forKey: "AppendTrailingSpace")
        let pastedText = textToPaste + (appendSpace ? " " : "")
        RecordingPerformanceDiagnostics.shared.mark(
            "delivery.paste.prepare.end",
            details: "chars=\(pastedText.count) append_space=\(appendSpace)"
        )
        SoundManager.shared.playStopSound()
        RecordingPerformanceDiagnostics.shared.mark("delivery.paste.dismiss.begin")
        await actions.dismiss()
        RecordingPerformanceDiagnostics.shared.mark("delivery.paste.dismiss.end")

        RecordingPerformanceDiagnostics.shared.mark("delivery.paste.task.start")
        let pasteTask = CursorPaster.startPasteAtCursor(pastedText)

        let autoSendKey = output.outputMode == .paste ? output.autoSendKey : .none
        Task { @MainActor in
            let result = await pasteTask.value
            RecordingPerformanceDiagnostics.shared.mark(
                "delivery.paste.task.completed",
                details: "command_posted=\(result.didPostPasteCommand)"
            )

            if autoSendKey.isEnabled {
                RecordingPerformanceDiagnostics.shared.mark("delivery.auto_send.delay.begin")
                try? await Task.sleep(nanoseconds: 500_000_000)
                RecordingPerformanceDiagnostics.shared.mark("delivery.auto_send.post.begin")
                CursorPaster.performAutoSend(autoSendKey)
                RecordingPerformanceDiagnostics.shared.mark("delivery.auto_send.post.end")
            }
        }
    }

    private func deliverableText(from text: String) -> String {
        var textToDeliver = text
        if let restrictionMessage = LicenseViewModel().usageRestrictionMessage {
            textToDeliver = """
                \(restrictionMessage)
                \n\(textToDeliver)
                """
        }

        return textToDeliver
    }
}
