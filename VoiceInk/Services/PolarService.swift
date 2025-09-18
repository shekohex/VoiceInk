import Foundation
import IOKit

class PolarService {
    private let organizationId = "Org"
    private let apiToken = "Token"
    private let baseURL = "https://api.polar.sh"
    
    struct LicenseValidationResponse: Codable {
        let status: String
        let limit_activations: Int?
        let id: String?
        let activation: ActivationResponse?
    }
    
    struct ActivationResponse: Codable {
        let id: String
    }
    
    struct ActivationRequest: Codable {
        let key: String
        let organization_id: String
        let label: String
        let meta: [String: String]
    }
    
    struct ActivationResult: Codable {
        let id: String
        let license_key: LicenseKeyInfo
    }
    
    struct LicenseKeyInfo: Codable {
        let limit_activations: Int
        let status: String
    }
    
    // Generate a unique device identifier
    private func getDeviceIdentifier() -> String {
        // Use the macOS serial number or a generated UUID that persists
        if let serialNumber = getMacSerialNumber() {
            return serialNumber
        }
        
        // Fallback to a stored UUID if we can't get the serial number
        let defaults = UserDefaults.standard
        if let storedId = defaults.string(forKey: "VoiceInkDeviceIdentifier") {
            return storedId
        }
        
        // Create and store a new UUID if none exists
        let newId = UUID().uuidString
        defaults.set(newId, forKey: "VoiceInkDeviceIdentifier")
        return newId
    }
    
    // Try to get the Mac serial number
    private func getMacSerialNumber() -> String? {
        let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if platformExpert == 0 { return nil }
        
        defer { IOObjectRelease(platformExpert) }
        
        if let serialNumber = IORegistryEntryCreateCFProperty(platformExpert, "IOPlatformSerialNumber" as CFString, kCFAllocatorDefault, 0) {
            return (serialNumber.takeRetainedValue() as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return nil
    }
    
    // Check if a license key requires activation
    func checkLicenseRequiresActivation(_ key: String) async throws -> (isValid: Bool, requiresActivation: Bool, activationsLimit: Int?) {
        // Always return valid license that doesn't require activation
        return (isValid: true, requiresActivation: false, activationsLimit: nil)
    }
    
    // Activate a license key on this device
    func activateLicenseKey(_ key: String) async throws -> (activationId: String, activationsLimit: Int) {
        // Always return successful activation
        return (activationId: "fake-activation-id", activationsLimit: 0)
    }
    
    // Validate a license key with an activation ID
    func validateLicenseKeyWithActivation(_ key: String, activationId: String) async throws -> Bool {
        // Always return valid
        return true
    }
}

enum LicenseError: Error, LocalizedError {
    case activationFailed(String)
    case validationFailed(String)
    case activationLimitReached(String)
    case activationNotRequired
    
    var errorDescription: String? {
        switch self {
        case .activationFailed(let details):
            return "Failed to activate license: \(details)"
        case .validationFailed(let details):
            return "License validation failed: \(details)"
        case .activationLimitReached(let details):
            return "Activation limit reached: \(details)"
        case .activationNotRequired:
            return "This license does not require activation."
        }
    }
}
