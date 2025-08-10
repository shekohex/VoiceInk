import SwiftUI

struct ExperimentalFeaturesSection: View {
    @AppStorage("isExperimentalFeaturesEnabled") private var isExperimentalFeaturesEnabled = false
    @ObservedObject private var playbackController = PlaybackController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "flask")
                    .font(.system(size: 20))
                    .foregroundColor(.accentColor)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Experimental Features")
                        .font(.headline)
                    Text("Experimental features that might be unstable & bit buggy.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Toggle("Experimental Features", isOn: $isExperimentalFeaturesEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: isExperimentalFeaturesEnabled) { _, newValue in
                        if !newValue {
                            playbackController.isPauseMediaEnabled = false
                        }
                    }
            }

            Divider()
                .padding(.vertical, 4)

            if isExperimentalFeaturesEnabled {
                Toggle(isOn: $playbackController.isPauseMediaEnabled) {
                    Text("Pause Media on Playback")
                }
                .toggleStyle(.switch)
                .help("Automatically pause active media playback during recordings and resume afterward.")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground(isSelected: false, useAccentGradientWhenSelected: true))
    }
}


