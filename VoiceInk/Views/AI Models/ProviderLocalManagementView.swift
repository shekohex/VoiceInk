import AppKit
import SwiftUI

struct LocalEnhancementProviderManagementView: View {
    @EnvironmentObject private var aiService: AIService
    @ObservedObject private var voiceInkRefineService = VoiceInkRefineService.shared

    @State private var isVoiceInkRefineExpanded = false
    @State private var isOllamaExpanded = false
    @State private var isLocalCLIExpanded = false
    @State private var isShowingVoiceInkRefineDeleteConfirmation = false
    @State private var ollamaBaseURL = UserDefaults.standard.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434"
    @State private var selectedOllamaModel = UserDefaults.standard.string(forKey: "ollamaSelectedModel") ?? "mistral"
    @State private var ollamaUserRefreshError: String?
    @State private var localCLICommandTemplate = ""
    @State private var localCLITimeoutSeconds = LocalCLIService.defaultTimeoutSeconds
    @State private var isSyncingLocalCLIState = false

    private var isLocalCLIConfigured: Bool {
        !localCLICommandTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProviderSectionHeader(
                title: "Local & CLI Providers",
                subtitle: "Clean up transcripts on this Mac, connect to Ollama, or use any CLI command."
            )
            .padding(.top, 8)

            VStack(spacing: 0) {
                if voiceInkRefineService.shouldShowInCatalog {
                    LocalProviderDisclosureRow(
                        title: Text(VoiceInkRefineService.providerName),
                        subtitle: Text("On-device transcript cleanup"),
                        systemImage: "sparkles",
                        statusTitle: voiceInkRefineStatusTitle,
                        isExpanded: $isVoiceInkRefineExpanded
                    ) {
                        voiceInkRefineConfiguration
                    }

                    Divider()
                        .padding(.leading, 58)
                }

                LocalProviderDisclosureRow(
                    title: Text(verbatim: "Ollama"),
                    subtitle: ollamaModelNames.isEmpty ? Text("Local server") : Text(localModelCountLabel),
                    systemImage: "server.rack",
                    statusTitle: ollamaStatusTitle,
                    isExpanded: $isOllamaExpanded
                ) {
                    ollamaConfiguration
                }

                Divider()
                    .padding(.leading, 58)

                LocalProviderDisclosureRow(
                    title: Text("Local CLI"),
                    subtitle: Text("Claude, Codex, scripts, or any command"),
                    systemImage: "terminal",
                    statusTitle: isLocalCLIConfigured ? Text("Configured") : Text("Not configured"),
                    isExpanded: $isLocalCLIExpanded
                ) {
                    localCLIConfiguration
                }
            }
            .background(AppMaterialCardBackground(cornerRadius: 11))
        }
        .onAppear {
            selectedOllamaModel = aiService.selectedModel(for: .ollama)
            syncLocalCLIStateFromService()
        }
        .confirmationDialog(
            "Delete VoiceInk Refine?",
            isPresented: $isShowingVoiceInkRefineDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Model", role: .destructive) {
                Task {
                    await voiceInkRefineService.deleteModel()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The model will need to be downloaded again before a Mode can use it.")
        }
    }

    private var voiceInkRefineStatusTitle: Text {
        switch voiceInkRefineService.availability {
        case .unsupportedIntel:
            return Text("Unavailable")
        case .insufficientMemory:
            return Text("Unavailable")
        case .available:
            if voiceInkRefineService.isDownloading {
                return Text("Downloading")
            }
            return voiceInkRefineService.isDownloaded ? Text("Ready") : Text("Not downloaded")
        }
    }

    @ViewBuilder
    private var voiceInkRefineConfiguration: some View {
        LocalProviderExpandedContent {
            if let unavailableDescription = voiceInkRefineService.unavailableDescription {
                Text(unavailableDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LocalProviderFormRow(title: "Model") {
                    Text(VoiceInkRefineService.modelName)
                        .font(.system(size: 12, weight: .medium))
                }

                Divider()
                    .padding(.leading, LocalProviderMetrics.labelWidth + 12)

                LocalProviderFormRow(title: "Download") {
                    Text(VoiceInkRefineService.downloadSizeDescription)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                if voiceInkRefineService.isDownloading {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            ProgressView(value: voiceInkRefineService.downloadProgress)
                                .frame(maxWidth: 280)
                                .accessibilityLabel("Model download progress")
                                .accessibilityValue(
                                    Text(verbatim: voiceInkRefineDownloadAccessibilityValue)
                                )

                            Text(
                                voiceInkRefineService.downloadProgress,
                                format: .percent.precision(.fractionLength(0))
                            )
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)

                            Button("Cancel") {
                                voiceInkRefineService.cancelDownload()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Text(verbatim: voiceInkRefineDownloadDetail)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else if voiceInkRefineService.isDownloaded {
                    HStack(spacing: 10) {
                        Button("Delete Model", role: .destructive) {
                            isShowingVoiceInkRefineDeleteConfirmation = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Text("Select VoiceInk Refine as the AI provider in a Mode to use it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Button("Download Model") {
                        voiceInkRefineService.startDownload()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if let downloadError = voiceInkRefineService.downloadError {
                    Text(downloadError)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Status.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var voiceInkRefineDownloadDetail: String {
        if voiceInkRefineService.isFinalizingDownload {
            return String(localized: "Finalizing model files…")
        }

        let downloaded = ByteCountFormatter.string(
            fromByteCount: voiceInkRefineService.downloadedBytes,
            countStyle: .file
        )
        let total = ByteCountFormatter.string(
            fromByteCount: voiceInkRefineService.totalDownloadBytes,
            countStyle: .file
        )

        if voiceInkRefineService.downloadBytesPerSecond >= 1 {
            let speed = ByteCountFormatter.string(
                fromByteCount: Int64(voiceInkRefineService.downloadBytesPerSecond),
                countStyle: .file
            )
            return String(
                format: String(localized: "%@ of %@ • %@/s"),
                downloaded,
                total,
                speed
            )
        }

        return String(
            format: String(localized: "%@ of %@"),
            downloaded,
            total
        )
    }

    private var voiceInkRefineDownloadAccessibilityValue: String {
        let percentage = Int((voiceInkRefineService.downloadProgress * 100).rounded())
        return "\(percentage)%. \(voiceInkRefineDownloadDetail)"
    }

    private var ollamaModelNames: [String] {
        aiService.availableModels(for: .ollama)
    }

    private var localModelCountLabel: String {
        let count = ollamaModelNames.count
        return String(localized: "\(count) models")
    }

    private var ollamaStatusTitle: Text {
        if aiService.isOllamaRefreshing {
            return Text("Checking")
        }

        if !aiService.connectedProviders.contains(.ollama) {
            return Text("Disconnected")
        }

        return ollamaModelNames.isEmpty ? Text("No models") : Text(localModelCountLabel)
    }

    private var ollamaActionTitle: LocalizedStringKey {
        aiService.connectedProviders.contains(.ollama) ? "Refresh" : "Connect"
    }

    private var ollamaConfiguration: some View {
        LocalProviderExpandedContent {
            LocalProviderFormRow(title: "Server") {
                HStack(spacing: 8) {
                    TextField("", text: $ollamaBaseURL, prompt: Text(verbatim: "http://localhost:11434"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .disabled(aiService.isOllamaRefreshing)
                        .onChange(of: ollamaBaseURL) { _, _ in
                            ollamaUserRefreshError = nil
                        }

                    Button {
                        ollamaUserRefreshError = nil
                        aiService.updateOllamaBaseURL(ollamaBaseURL)
                        checkOllamaConnectionFromUserAction()
                    } label: {
                        if aiService.isOllamaRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(ollamaActionTitle)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(aiService.isOllamaRefreshing)
                }
            }

            if let ollamaUserRefreshError {
                Text(ollamaUserRefreshError)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Status.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, LocalProviderMetrics.labelWidth + 12)
            }

            if !ollamaModelNames.isEmpty {
                Divider()
                    .padding(.leading, LocalProviderMetrics.labelWidth + 12)

                LocalProviderFormRow(title: "Model") {
                    Picker("Model", selection: $selectedOllamaModel) {
                        ForEach(ollamaModelNames, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                    .onChange(of: selectedOllamaModel) { _, newValue in
                        aiService.updateSelectedOllamaModel(newValue)
                        aiService.selectModel(newValue, for: .ollama)
                    }
                }
            }
        }
    }

    private var localCLIConfiguration: some View {
        LocalProviderExpandedContent {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Command")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Menu {
                        ForEach(LocalCLITemplate.allCases) { template in
                            Button(template.displayName) {
                                aiService.loadLocalCLITemplate(template)
                                syncLocalCLIStateFromService()
                            }
                        }
                    } label: {
                        Label("Template", systemImage: "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                TextEditor(text: $localCLICommandTemplate)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 88)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(AppTheme.Border.control.opacity(0.4), lineWidth: 1)
                    )
                    .onChange(of: localCLICommandTemplate) { _, newValue in
                        guard !isSyncingLocalCLIState else { return }
                        aiService.updateLocalCLICommandTemplate(newValue)
                    }
            }

            Divider()
                .padding(.leading, LocalProviderMetrics.labelWidth + 12)

            LocalProviderFormRow(title: "Timeout") {
                Picker("Timeout", selection: $localCLITimeoutSeconds) {
                    Text("15s").tag(15.0)
                    Text("30s").tag(30.0)
                    Text("45s").tag(45.0)
                    Text("60s").tag(60.0)
                    Text("90s").tag(90.0)
                    Text("120s").tag(120.0)
                    Text("180s").tag(180.0)
                    Text("300s").tag(300.0)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 110, alignment: .leading)
                .onChange(of: localCLITimeoutSeconds) { _, newValue in
                    aiService.updateLocalCLITimeoutSeconds(newValue)
                }
            }

            Text("Variables: VOICEINK_SYSTEM_PROMPT, VOICEINK_USER_PROMPT, VOICEINK_FULL_PROMPT")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private func checkOllamaConnectionFromUserAction() {
        Task { @MainActor in
            let result = await aiService.refreshOllamaAvailability()
            let models = result.models.map(\.name)

            ollamaUserRefreshError = result.errorMessage

            if !models.contains(selectedOllamaModel), let firstModel = models.first {
                selectedOllamaModel = firstModel
                aiService.selectModel(firstModel, for: .ollama)
            }
        }
    }

    private func syncLocalCLIStateFromService() {
        isSyncingLocalCLIState = true
        localCLICommandTemplate = aiService.localCLICommandTemplate
        localCLITimeoutSeconds = aiService.localCLITimeoutSeconds
        DispatchQueue.main.async {
            isSyncingLocalCLIState = false
        }
    }
}

private enum LocalProviderMetrics {
    static let labelWidth: CGFloat = 72
}

private struct LocalProviderDisclosureRow<Content: View>: View {
    let title: Text
    let subtitle: Text
    let systemImage: String
    let statusTitle: Text
    @Binding var isExpanded: Bool
    let content: () -> Content

    init(
        title: Text,
        subtitle: Text,
        systemImage: String,
        statusTitle: Text,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.statusTitle = statusTitle
        self._isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.smooth(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(AppTheme.Surface.control)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(AppTheme.Border.control.opacity(0.3), lineWidth: 1)
                                )
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        title
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)

                        subtitle
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    statusTitle
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .padding(.leading, 58)

                content()
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
    }
}

private struct LocalProviderExpandedContent<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LocalProviderFormRow<Content: View>: View {
    let title: LocalizedStringKey
    let content: () -> Content

    init(title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: LocalProviderMetrics.labelWidth, alignment: .leading)

            content()

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
