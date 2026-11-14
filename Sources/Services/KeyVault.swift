//
//  KeyVault.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 24.10.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import CryptoKit
import Foundation
import LocalAuthentication
import Security

// MARK: - KeyVault

/// Protects key store secrets at rest. Opening a secret requires user authentication.
protocol KeyVault: Sendable {
    /// Removes the key protecting `sealed`, if any.
    func discard(_ sealed: Data)
    /// Decrypts `sealed`, asking the user to authenticate with `reason`.
    func open(_ sealed: Data, reason: String) async throws -> Data
    /// Encrypts `secret` with a new key.
    func seal(_ secret: Data) throws -> Data
}

// MARK: - KeychainKeyVault

/// AES-GCM with a random per-secret key stored in the keychain behind
/// `.userPresence` (Face ID, Touch ID or device password). Blob layout:
/// `version (1) | key id (16) | AES-GCM combined (nonce, ciphertext, tag)`.
struct KeychainKeyVault: KeyVault {
    private static let service = "xyz.reefr.wallet.keystore"
    private static let version: UInt8 = 1
    private static let keyIdLength = 16

    func discard(_ sealed: Data) {
        guard let keyId = Self.keyId(of: sealed) else {
            return
        }

        SecItemDelete(Self.query(keyId: keyId) as CFDictionary)
    }

    func open(_ sealed: Data, reason: String) async throws -> Data {
        guard let keyId = Self.keyId(of: sealed) else {
            throw ReefrError.invalidData
        }

        let combined = sealed.dropFirst(1 + Self.keyIdLength)

        return try await Task.detached {
            let context = LAContext()
            context.localizedReason = reason

            // Prompt explicitly: the keychain would also prompt for `.userPresence`
            // on a device, but the simulator doesn't enforce it. The evaluated
            // context is reused for the read below, so there is one prompt.
            do {
                try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            } catch {
                throw ReefrError.authenticationFailed
            }

            var query = Self.query(keyId: keyId)
            query[kSecReturnData as String] = true
            query[kSecUseAuthenticationContext as String] = context

            var item: CFTypeRef?

            switch SecItemCopyMatching(query as CFDictionary, &item) {
            case errSecSuccess:
                break
            case errSecAuthFailed, errSecUserCanceled:
                throw ReefrError.authenticationFailed
            case errSecItemNotFound:
                throw ReefrError.notFound
            default:
                throw ReefrError.internalError
            }

            guard let keyData = item as? Data else {
                throw ReefrError.internalError
            }

            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: SymmetricKey(data: keyData))
        }.value
    }

    func seal(_ secret: Data) throws -> Data {
        var error: Unmanaged<CFError>?

        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .userPresence,
            &error
        ) else {
            throw error?.takeRetainedValue() ?? ReefrError.internalError
        }

        let key = SymmetricKey(size: .bits256)
        let keyId = UUID()

        var query = Self.query(keyId: keyId.uuidString)
        query[kSecAttrAccessControl as String] = access
        query[kSecValueData as String] = key.withUnsafeBytes { Data($0) }

        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw ReefrError.internalError
        }

        guard let combined = try AES.GCM.seal(secret, using: key).combined else {
            throw ReefrError.internalError
        }

        return Data([Self.version]) + withUnsafeBytes(of: keyId.uuid) { Data($0) } + combined
    }
}

private extension KeychainKeyVault {
    static func keyId(of sealed: Data) -> String? {
        guard sealed.count > 1 + keyIdLength, sealed[sealed.startIndex] == version else {
            return nil
        }

        let bytes = sealed.dropFirst().prefix(keyIdLength)
        return UUID(uuid: bytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }).uuidString
    }

    static func query(keyId: String) -> [String: Any] {
        [
            kSecAttrAccount as String: keyId,
            kSecAttrService as String: service,
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}

// MARK: - PassthroughKeyVault

/// Stores secrets as is, for tests and previews.
struct PassthroughKeyVault: KeyVault {
    func discard(_ sealed: Data) {}

    func open(_ sealed: Data, reason: String) async throws -> Data {
        sealed
    }

    func seal(_ secret: Data) throws -> Data {
        secret
    }
}
