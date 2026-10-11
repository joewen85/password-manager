import CommonCrypto
import CryptoKit
import Foundation
import Security

enum VaultCryptoError: LocalizedError {
    case randomFailed(OSStatus)
    case derivationFailed(Int32)
    case invalidPayload
    case invalidUtf8
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .randomFailed(let status):
            "Secure random generation failed with status \(status)."
        case .derivationFailed(let status):
            "PBKDF2 key derivation failed with status \(status)."
        case .invalidPayload:
            "Encrypted vault payload is invalid."
        case .invalidUtf8:
            "Decrypted vault payload is not valid UTF-8."
        case .authenticationFailed:
            "Vault authentication failed."
        }
    }
}

struct VaultCryptoService {
    static let defaultIterations = 600_000

    func makeMasterKeyRecord(password: String) throws -> MasterKeyRecord {
        let salt = try randomBytes(count: 16)
        let verifier = try deriveKey(password: password, salt: salt, iterations: Self.defaultIterations)
        let metadataSalt = try randomBytes(count: 16)
        return MasterKeyRecord(
            saltBase64: salt.base64EncodedString(),
            iterations: Self.defaultIterations,
            verifierBase64: verifier.base64EncodedString(),
            metadataSaltBase64: metadataSalt.base64EncodedString(),
            metadataIterations: Self.defaultIterations
        )
    }

    func makeMasterKeyRecord(
        password: String,
        salt: Data,
        metadataSalt: Data,
        iterations: Int = Self.defaultIterations
    ) throws -> MasterKeyRecord {
        let verifier = try deriveKey(password: password, salt: salt, iterations: iterations)
        return MasterKeyRecord(
            saltBase64: salt.base64EncodedString(),
            iterations: iterations,
            verifierBase64: verifier.base64EncodedString(),
            metadataSaltBase64: metadataSalt.base64EncodedString(),
            metadataIterations: iterations
        )
    }

    func verify(password: String, record: MasterKeyRecord) throws -> Data {
        guard let salt = Data(base64Encoded: record.saltBase64),
              let verifier = Data(base64Encoded: record.verifierBase64) else {
            throw VaultCryptoError.invalidPayload
        }
        let derived = try deriveKey(password: password, salt: salt, iterations: record.iterations)
        guard constantTimeEquals(derived, verifier) else {
            throw VaultCryptoError.authenticationFailed
        }
        return derived
    }

    func encrypt(_ plaintext: Data, key: Data) throws -> EncryptedPayloadRecord {
        let nonceBytes = try randomBytes(count: 12)
        return try encrypt(plaintext, key: key, nonceBytes: nonceBytes)
    }

    func encrypt(_ plaintext: Data, key: Data, nonceBytes: Data) throws -> EncryptedPayloadRecord {
        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce)
        return EncryptedPayloadRecord(
            ciphertext: sealed.ciphertext.base64EncodedString(),
            nonce: nonceBytes.base64EncodedString(),
            mac: sealed.tag.base64EncodedString(),
            version: 1
        )
    }

    func deriveKeyForTesting(password: String, salt: Data, iterations: Int) throws -> Data {
        try deriveKey(password: password, salt: salt, iterations: iterations)
    }

    func decrypt(_ payload: EncryptedPayloadRecord, key: Data) throws -> Data {
        guard let ciphertext = Data(base64Encoded: payload.ciphertext),
              let nonceBytes = Data(base64Encoded: payload.nonce),
              let tag = Data(base64Encoded: payload.mac) else {
            throw VaultCryptoError.invalidPayload
        }
        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: SymmetricKey(data: key))
    }

    private func deriveKey(password: String, salt: Data, iterations: Int) throws -> Data {
        let passwordBytes = Array(password.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBuffer in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes,
                passwordBytes.count,
                saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(iterations),
                &derived,
                derived.count
            )
        }
        guard status == kCCSuccess else {
            throw VaultCryptoError.derivationFailed(status)
        }
        return Data(derived)
    }

    private func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw VaultCryptoError.randomFailed(status)
        }
        return Data(bytes)
    }

    private func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for index in lhs.indices {
            diff |= lhs[index] ^ rhs[index]
        }
        return diff == 0
    }
}
