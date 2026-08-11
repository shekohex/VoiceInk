import Foundation

extension VoiceInkEngine {
    @MainActor
    func recordingAudioFailure(
        for error: Error
    ) -> (title: String, actionLabel: String, action: () -> Void)? {
        guard let recorderError = error as? Recorder.RecorderError,
            case .noUsableMicrophone = recorderError
        else {
            return nil
        }

        return (
            String(localized: "No usable microphone is available. Choose a microphone in Audio Settings."),
            String(localized: "Audio Settings"),
            AudioSetupNavigator.openAudioSettings
        )
    }
}
