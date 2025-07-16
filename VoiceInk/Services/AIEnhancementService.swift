import Foundation
import SwiftData
import AppKit

enum EnhancementPrompt {
    case transcriptionEnhancement
    case aiAssistant
}

class AIEnhancementService: ObservableObject {
    @Published var isEnhancementEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnhancementEnabled, forKey: "isAIEnhancementEnabled")
            if isEnhancementEnabled && selectedPromptId == nil {
                selectedPromptId = customPrompts.first?.id
            }
        }
    }
    
    @Published var useClipboardContext: Bool {
        didSet {
            UserDefaults.standard.set(useClipboardContext, forKey: "useClipboardContext")
        }
    }
    
    @Published var useScreenCaptureContext: Bool {
        didSet {
            UserDefaults.standard.set(useScreenCaptureContext, forKey: "useScreenCaptureContext")
        }
    }
    
    @Published var customPrompts: [CustomPrompt] {
        didSet {
            if let encoded = try? JSONEncoder().encode(customPrompts) {
                UserDefaults.standard.set(encoded, forKey: "customPrompts")
            }
        }
    }
    
    @Published var selectedPromptId: UUID? {
        didSet {
            UserDefaults.standard.set(selectedPromptId?.uuidString, forKey: "selectedPromptId")
        }
    }
    
    var activePrompt: CustomPrompt? {
        allPrompts.first { $0.id == selectedPromptId }
    }
    
    var allPrompts: [CustomPrompt] {
        return customPrompts
    }
    
    private let aiService: AIService
    private let screenCaptureService: ScreenCaptureService
    private let maxRetries = 3
    private let baseTimeout: TimeInterval = 10
    private let rateLimitInterval: TimeInterval = 1.0
    private var lastRequestTime: Date?
    private let modelContext: ModelContext
    
    init(aiService: AIService = AIService(), modelContext: ModelContext) {
        self.aiService = aiService
        self.modelContext = modelContext
        self.screenCaptureService = ScreenCaptureService()
        
        self.isEnhancementEnabled = UserDefaults.standard.bool(forKey: "isAIEnhancementEnabled")
        self.useClipboardContext = UserDefaults.standard.bool(forKey: "useClipboardContext")
        self.useScreenCaptureContext = UserDefaults.standard.bool(forKey: "useScreenCaptureContext")
        
        self.customPrompts = PromptMigrationService.migratePromptsIfNeeded()
        
        if let savedPromptId = UserDefaults.standard.string(forKey: "selectedPromptId") {
            self.selectedPromptId = UUID(uuidString: savedPromptId)
        }
        
        if isEnhancementEnabled && (selectedPromptId == nil || !allPrompts.contains(where: { $0.id == selectedPromptId })) {
            self.selectedPromptId = allPrompts.first?.id
        }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAPIKeyChange),
            name: .aiProviderKeyChanged,
            object: nil
        )
        
        initializePredefinedPrompts()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func handleAPIKeyChange() {
        DispatchQueue.main.async {
            self.objectWillChange.send()
            if !self.aiService.isAPIKeyValid {
                self.isEnhancementEnabled = false
            }
        }
    }
    
    func getAIService() -> AIService? {
        return aiService
    }
    
    var isConfigured: Bool {
        aiService.isAPIKeyValid
    }
    
    private func waitForRateLimit() async throws {
        if let lastRequest = lastRequestTime {
            let timeSinceLastRequest = Date().timeIntervalSince(lastRequest)
            if timeSinceLastRequest < rateLimitInterval {
                try await Task.sleep(nanoseconds: UInt64((rateLimitInterval - timeSinceLastRequest) * 1_000_000_000))
            }
        }
        lastRequestTime = Date()
    }
    
    private func getSystemMessage(for mode: EnhancementPrompt) -> String {
        let selectedText = SelectedTextService.fetchSelectedText()
        
        if let activePrompt = activePrompt,
           activePrompt.id == PredefinedPrompts.assistantPromptId,
           let selectedText = selectedText, !selectedText.isEmpty {
            
            let selectedTextContext = "\n\nSelected Text: \(selectedText)"
            let contextSection = "\n\n\(AIPrompts.contextInstructions)\n\n<CONTEXT_INFORMATION>\(selectedTextContext)\n</CONTEXT_INFORMATION>"
            return activePrompt.promptText + contextSection
        }
        
        let clipboardContext = if useClipboardContext,
                              let clipboardText = NSPasteboard.general.string(forType: .string),
                              !clipboardText.isEmpty {
            "\n\nAvailable Clipboard Context: \(clipboardText)"
        } else {
            ""
        }
        
        let screenCaptureContext = if useScreenCaptureContext,
                                   let capturedText = screenCaptureService.lastCapturedText,
                                   !capturedText.isEmpty {
            "\n\nActive Window Context: \(capturedText)"
        } else {
            ""
        }
        
        let contextSection = if !clipboardContext.isEmpty || !screenCaptureContext.isEmpty {
            "\n\n\(AIPrompts.contextInstructions)\n\n<CONTEXT_INFORMATION>\(clipboardContext)\(screenCaptureContext)\n</CONTEXT_INFORMATION>"
        } else {
            ""
        }
        
        guard let activePrompt = activePrompt else {
            return AIPrompts.assistantMode + contextSection
        }
        
        if activePrompt.id == PredefinedPrompts.assistantPromptId {
            return activePrompt.promptText + contextSection
        }
        
        var systemMessage = String(format: AIPrompts.customPromptTemplate, activePrompt.promptText)
        systemMessage += contextSection
        return systemMessage
    }
    
    private func makeRequest(text: String, mode: EnhancementPrompt, retryCount: Int = 0) async throws -> String {
        guard isConfigured else {
            throw EnhancementError.notConfigured
        }
        
        guard !text.isEmpty else {
            throw EnhancementError.emptyText
        }
        
        let formattedText = "\n<TRANSCRIPT>\n\(text)\n</TRANSCRIPT>"
        let systemMessage = getSystemMessage(for: mode)
        
        if aiService.selectedProvider == .ollama {
            do {
                let result = try await aiService.enhanceWithOllama(text: formattedText, systemPrompt: systemMessage)
                let filteredResult = AIEnhancementOutputFilter.filter(result)
                return filteredResult
            } catch let error as LocalAIError {
                switch error {
                case .serviceUnavailable:
                    throw EnhancementError.notConfigured
                case .modelNotFound:
                    throw EnhancementError.enhancementFailed
                case .serverError:
                    throw EnhancementError.serverError
                default:
                    throw EnhancementError.enhancementFailed
                }
            }
        }
        
        try await waitForRateLimit()
        
        switch aiService.selectedProvider {
        case .gemini:
            let baseEndpoint = "https://generativelanguage.googleapis.com/v1beta/models"
            let model = aiService.currentModel
            let fullURL = "\(baseEndpoint)/\(model):generateContent"
            
            var urlComponents = URLComponents(string: fullURL)!
            urlComponents.queryItems = [URLQueryItem(name: "key", value: aiService.apiKey)]
            
            guard let url = urlComponents.url else {
                throw EnhancementError.invalidResponse
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = baseTimeout * pow(2.0, Double(retryCount))
            
            let requestBody: [String: Any] = [
                "contents": [
                    [
                        "parts": [
                            ["text": systemMessage],
                            ["text": formattedText]
                        ]
                    ]
                ],
                "generationConfig": [
                    "temperature": 0.3,
                ]
            ]
            
            request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw EnhancementError.invalidResponse
                }
                
                switch httpResponse.statusCode {
                case 200:
                    guard let jsonResponse = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let candidates = jsonResponse["candidates"] as? [[String: Any]],
                          let firstCandidate = candidates.first,
                          let content = firstCandidate["content"] as? [String: Any],
                          let parts = content["parts"] as? [[String: Any]],
                          let firstPart = parts.first,
                          let enhancedText = firstPart["text"] as? String else {
                        throw EnhancementError.enhancementFailed
                    }
                    
                    let filteredText = AIEnhancementOutputFilter.filter(enhancedText.trimmingCharacters(in: .whitespacesAndNewlines))
                    return filteredText
                    
                case 401:
                    throw EnhancementError.authenticationFailed
                case 429:
                    throw EnhancementError.rateLimitExceeded
                case 500...599:
                    throw EnhancementError.serverError
                default:
                    throw EnhancementError.apiError
                }
            } catch let error as EnhancementError {
                throw error
            } catch {
                if retryCount < maxRetries {
                    try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(retryCount)) * 1_000_000_000))
                    return try await makeRequest(text: text, mode: mode, retryCount: retryCount + 1)
                }
                throw EnhancementError.networkError
            }
            
        case .anthropic:
            let requestBody: [String: Any] = [
                "model": aiService.currentModel,
                "max_tokens": 1024,
                "system": systemMessage,
                "messages": [
                    ["role": "user", "content": formattedText]
                ]
            ]
            
            var request = URLRequest(url: URL(string: aiService.selectedProvider.baseURL)!)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue(aiService.apiKey, forHTTPHeaderField: "x-api-key")
            request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.timeoutInterval = baseTimeout * pow(2.0, Double(retryCount))
            request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw EnhancementError.invalidResponse
                }
                
                switch httpResponse.statusCode {
                case 200:
                    guard let jsonResponse = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let content = jsonResponse["content"] as? [[String: Any]],
                          let firstContent = content.first,
                          let enhancedText = firstContent["text"] as? String else {
                        throw EnhancementError.enhancementFailed
                    }
                    
                    let filteredText = AIEnhancementOutputFilter.filter(enhancedText.trimmingCharacters(in: .whitespacesAndNewlines))
                    return filteredText
                    
                case 401:
                    throw EnhancementError.authenticationFailed
                case 429:
                    throw EnhancementError.rateLimitExceeded
                case 500...599:
                    throw EnhancementError.serverError
                default:
                    throw EnhancementError.apiError
                }
            } catch let error as EnhancementError {
                throw error
            } catch {
                if retryCount < maxRetries {
                    try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(retryCount)) * 1_000_000_000))
                    return try await makeRequest(text: text, mode: mode, retryCount: retryCount + 1)
                }
                throw EnhancementError.networkError
            }
            
        default:
            let url = URL(string: aiService.selectedProvider.baseURL)!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("Bearer \(aiService.apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = baseTimeout * pow(2.0, Double(retryCount))
            
            let messages: [[String: Any]] = [
                ["role": "system", "content": systemMessage],
                ["role": "user", "content": formattedText]
            ]
            
            let requestBody: [String: Any] = [
                "model": aiService.currentModel,
                "messages": messages,
                "temperature": 0.3,
                "frequency_penalty": 0.0,
                "presence_penalty": 0.0,
                "stream": false
            ]
            
            request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw EnhancementError.invalidResponse
                }
                
                switch httpResponse.statusCode {
                case 200:
                    guard let jsonResponse = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = jsonResponse["choices"] as? [[String: Any]],
                          let firstChoice = choices.first,
                          let message = firstChoice["message"] as? [String: Any],
                          let enhancedText = message["content"] as? String else {
                        throw EnhancementError.enhancementFailed
                    }
                    
                    let filteredText = AIEnhancementOutputFilter.filter(enhancedText.trimmingCharacters(in: .whitespacesAndNewlines))
                    return filteredText
                    
                case 401:
                    throw EnhancementError.authenticationFailed
                case 429:
                    throw EnhancementError.rateLimitExceeded
                case 500...599:
                    throw EnhancementError.serverError
                default:
                    throw EnhancementError.apiError
                }
                
            } catch let error as EnhancementError {
                throw error
            } catch {
                if retryCount < maxRetries {
                    try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(retryCount)) * 1_000_000_000))
                    return try await makeRequest(text: text, mode: mode, retryCount: retryCount + 1)
                }
                throw EnhancementError.networkError
            }
        }
    }
    
    func enhance(_ text: String) async throws -> (String, TimeInterval) {
        let startTime = Date()
        let enhancementPrompt: EnhancementPrompt = .transcriptionEnhancement
        
        var retryCount = 0
        while retryCount < maxRetries {
            do {
                let result = try await makeRequest(text: text, mode: enhancementPrompt, retryCount: retryCount)
                let duration = Date().timeIntervalSince(startTime)
                return (result, duration)
            } catch let error as EnhancementError {
                if shouldRetry(error: error, retryCount: retryCount) {
                    retryCount += 1
                    let delaySeconds = getRetryDelay(for: retryCount)
                    try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                    continue
                } else {
                    throw error
                }
            } catch {
                throw error
            }
        }
        throw EnhancementError.maxRetriesExceeded
    }
    
    func captureScreenContext() async {
        guard useScreenCaptureContext else { return }
        
        if let capturedText = await screenCaptureService.captureAndExtractText() {
            await MainActor.run {
                self.objectWillChange.send()
            }
        }
    }
    
    func addPrompt(title: String, promptText: String, icon: PromptIcon = .documentFill, description: String? = nil, triggerWords: [String] = []) {
        let newPrompt = CustomPrompt(title: title, promptText: promptText, icon: icon, description: description, isPredefined: false, triggerWords: triggerWords)
        customPrompts.append(newPrompt)
        if customPrompts.count == 1 {
            selectedPromptId = newPrompt.id
        }
    }
    
    func updatePrompt(_ prompt: CustomPrompt) {
        if let index = customPrompts.firstIndex(where: { $0.id == prompt.id }) {
            customPrompts[index] = prompt
        }
    }
    
    func deletePrompt(_ prompt: CustomPrompt) {
        customPrompts.removeAll { $0.id == prompt.id }
        if selectedPromptId == prompt.id {
            selectedPromptId = allPrompts.first?.id
        }
    }
    
    func setActivePrompt(_ prompt: CustomPrompt) {
        selectedPromptId = prompt.id
    }
    
    private func shouldRetry(error: EnhancementError, retryCount: Int) -> Bool {
        guard retryCount < maxRetries - 1 else { return false }
        
        switch error {
        case .rateLimitExceeded, .serverError:
            return true
        default:
            return false
        }
    }
    
    private func getRetryDelay(for retryCount: Int) -> TimeInterval {
        return retryCount == 1 ? 1.0 : 2.0
    }
    
    private func initializePredefinedPrompts() {
        let predefinedTemplates = PredefinedPrompts.createDefaultPrompts()
        
        for template in predefinedTemplates {
            if let existingIndex = customPrompts.firstIndex(where: { $0.id == template.id }) {
                var updatedPrompt = customPrompts[existingIndex]
                updatedPrompt = CustomPrompt(
                    id: updatedPrompt.id,
                    title: template.title,
                    promptText: template.promptText,
                    isActive: updatedPrompt.isActive,
                    icon: template.icon,
                    description: template.description,
                    isPredefined: true,
                    triggerWords: updatedPrompt.triggerWords
                )
                customPrompts[existingIndex] = updatedPrompt
            } else {
                customPrompts.append(template)
            }
        }
    }
}

enum EnhancementError: Error {
    case notConfigured
    case emptyText
    case invalidResponse
    case enhancementFailed
    case authenticationFailed
    case rateLimitExceeded
    case serverError
    case apiError
    case networkError
    case maxRetriesExceeded
}

extension EnhancementError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "AI provider not configured. Please check your API key."
        case .emptyText:
            return "No text to enhance."
        case .invalidResponse:
            return "Invalid response from AI provider."
        case .enhancementFailed:
            return "AI enhancement failed to process the text."
        case .authenticationFailed:
            return "API key is invalid. Please check your credentials."
        case .rateLimitExceeded:
            return "Rate limit exceeded. Please try again later."
        case .serverError:
            return "AI provider server error. Please try again."
        case .apiError:
            return "AI provider API error. Please try again."
        case .networkError:
            return "Network connection failed. Check your internet."
        case .maxRetriesExceeded:
            return "Enhancement failed after multiple attempts."
        }
    }
}