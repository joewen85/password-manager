import Foundation
import Testing
@testable import PasswordManagerMacOSApp

@Suite("VaultCryptoService")
struct VaultCryptoServiceTests {
    private let crypto = VaultCryptoService()

    @Test("PBKDF2 verifier is deterministic for fixed salt and iterations")
    func deterministicVerifier() throws {
        let password = "correct horse battery staple"
        let salt = Data((0..<16).map(UInt8.init))
        let metadataSalt = Data((16..<32).map(UInt8.init))

        let record = try crypto.makeMasterKeyRecord(
            password: password,
            salt: salt,
            metadataSalt: metadataSalt,
            iterations: 120_000
        )
        let expectedKey = try crypto.deriveKeyForTesting(
            password: password,
            salt: salt,
            iterations: 120_000
        )

        #expect(record.saltBase64 == salt.base64EncodedString())
        #expect(record.metadataSaltBase64 == metadataSalt.base64EncodedString())
        #expect(record.iterations == 120_000)
        #expect(record.verifierBase64 == expectedKey.base64EncodedString())
        #expect(try crypto.verify(password: password, record: record) == expectedKey)
        #expect(throws: (any Error).self) {
            _ = try crypto.verify(password: "wrong password", record: record)
        }
    }

    @Test("AES-GCM encrypted payload round trips and does not expose plaintext")
    func aesGcmRoundTrip() throws {
        let plaintext = Data(#"{"label":"Email","password":"secret"}"#.utf8)
        let key = Data((0..<32).map(UInt8.init))
        let nonce = Data((0..<12).map { UInt8($0 + 32) })

        let payload = try crypto.encrypt(plaintext, key: key, nonceBytes: nonce)
        let decrypted = try crypto.decrypt(payload, key: key)

        #expect(decrypted == plaintext)
        #expect(payload.version == 1)
        #expect(payload.nonce == nonce.base64EncodedString())
        #expect(!payload.ciphertext.contains("Email"))
        #expect(!payload.ciphertext.contains("secret"))
        #expect(!payload.mac.isEmpty)
    }

    @Test("AES-GCM rejects tampered authentication tag")
    func tamperedPayloadFails() throws {
        let plaintext = Data("vault".utf8)
        let key = Data((0..<32).map(UInt8.init))
        let nonce = Data((0..<12).map(UInt8.init))
        var payload = try crypto.encrypt(plaintext, key: key, nonceBytes: nonce)
        payload.mac = Data(repeating: 0, count: 16).base64EncodedString()

        #expect(throws: (any Error).self) {
            _ = try crypto.decrypt(payload, key: key)
        }
    }
}
