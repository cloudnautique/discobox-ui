import CryptoKit
import Foundation
import Security
import DiscoboxCore

/// An app-specific enrollment identity, never the CLI's key or a server key.
/// Only its public ID is shown or saved in preferences.
enum IrohIdentity {
    /// Keychain calls block (and can wait on an access prompt), so they run on
    /// a thread of their own, never the main actor or the cooperative pool.
    static func seed() async throws -> Data {
        try await BlockingThread.run(name: "Discobox Keychain identity", priority: .userInitiated) { try IrohIdentity.storedSeed() }
    }
    private static func storedSeed() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ai.discobox.desktop.iroh",
            kSecAttrAccount as String: "client-identity-v1"
        ]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            guard data.count == 32 else { throw DiscoboxError("The saved Iroh identity is invalid. It has not been replaced.") }
            return data
        }
        guard status == errSecItemNotFound else { throw keychainError(status) }
        let seed = Curve25519.Signing.PrivateKey().rawRepresentation
        var item = query
        item[kSecValueData as String] = seed
        item[kSecAttrLabel as String] = "Discobox remote connection identity"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        if added == errSecDuplicateItem { return try storedSeed() }
        guard added == errSecSuccess else { throw keychainError(added) }
        return seed
    }
    private static func keychainError(_ status: OSStatus) -> DiscoboxError {
        DiscoboxError("Could not access the Discobox identity in Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))")
    }
}
