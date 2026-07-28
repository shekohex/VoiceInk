import AppKit
import SwiftUI

@MainActor
class NotchWindowManager {
    private var windowController: NSWindowController?
    private var panel: NotchRecorderPanel?

    private let makeView: () -> AnyView

    init(
        engine: VoiceInkEngine,
        recorder: Recorder,
        assistantSession: AssistantSession,
        onRecordButtonTapped: @escaping () -> Void,
        onCloseTapped: @escaping () -> Void,
        onAssistantFollowUp: @escaping (String) -> Void
    ) {
        self.makeView = {
            AnyView(
                NotchRecorderView(
                    stateProvider: engine,
                    recorder: recorder,
                    assistantSession: assistantSession,
                    onRecordButtonTapped: onRecordButtonTapped,
                    onCloseTapped: onCloseTapped,
                    onAssistantFollowUp: onAssistantFollowUp
                )
            )
        }
    }

    func show() {
        if panel == nil {
            RecordingPerformanceDiagnostics.shared.mark("ui.notch_window.initialize.begin")
            initializeWindow()
            RecordingPerformanceDiagnostics.shared.mark("ui.notch_window.initialize.end")
        }
        RecordingPerformanceDiagnostics.shared.mark("ui.notch_window.order_front.begin")
        panel?.show()
        RecordingPerformanceDiagnostics.shared.mark("ui.notch_window.order_front.end")
    }

    func hide() {
        RecordingPerformanceDiagnostics.shared.mark("ui.notch_window.order_out.begin")
        panel?.orderOut(nil)
        RecordingPerformanceDiagnostics.shared.mark("ui.notch_window.order_out.end")
    }

    func destroyWindow() {
        deinitializeWindow()
    }

    private func initializeWindow() {
        deinitializeWindow()
        let metrics = NotchRecorderPanel.calculateWindowMetrics()
        let newPanel = NotchRecorderPanel(contentRect: metrics.frame)
        let view = makeView()
        let hostingController = NotchRecorderHostingController(rootView: view)
        newPanel.contentView = hostingController.view
        panel = newPanel
        windowController = NSWindowController(window: newPanel)
    }

    private func deinitializeWindow() {
        panel?.orderOut(nil)
        windowController?.close()
        windowController = nil
        panel = nil
    }

}
