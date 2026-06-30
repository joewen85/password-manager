import Foundation

final class EncryptedRemoteSyncClient: RemoteSyncClient, @unchecked Sendable {
    private let delegate: RemoteSyncClient
    private let crypto: VaultCryptoService
    private let vaultKey: Data
    private let masterKeyRecord: MasterKeyRecord?
    private let includeMasterKeyRecord: Bool
    private(set) var downloadedPlaintextRemote = false

    init(
        delegate: RemoteSyncClient,
        crypto: VaultCryptoService,
        vaultKey: Data,
        masterKeyRecord: MasterKeyRecord?,
        includeMasterKeyRecord: Bool
    ) {
        self.delegate = delegate
        self.crypto = crypto
        self.vaultKey = vaultKey
        self.masterKeyRecord = masterKeyRecord
        self.includeMasterKeyRecord = includeMasterKeyRecord
    }

    func metadata() async -> RemoteSyncMetadata {
        let metadata = await delegate.metadata()
        return RemoteSyncMetadata(statusCode: metadata.statusCode)
    }

    func download() async -> RemoteSyncResult {
        let download = await delegate.download()
        guard Self.isSuccessfulDownload(download.statusCode),
              let rawPayload = download.payload,
              !rawPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.containsEncryptedVault(rawPayload) else {
            markPlaintextRemoteIfNeeded(download.payload)
            return download
        }
        do {
            let payload = try decodeEncryptedPayload(rawPayload)
            return RemoteSyncResult(payload: payload, statusCode: download.statusCode)
        } catch {
            return RemoteSyncResult(payload: nil, statusCode: 422)
        }
    }

    private func markPlaintextRemoteIfNeeded(_ rawPayload: String?) {
        guard let rawPayload,
              let data = rawPayload.data(using: .utf8),
              (try? Self.makeDecoder().decode(VaultSyncPayload.self, from: data)) != nil else {
            return
        }
        downloadedPlaintextRemote = true
    }

    func upload(_ payload: String) async -> RemoteSyncResult {
        do {
            let encryptedPayload = try encodeEncryptedPayload(payload)
            return await delegate.upload(encryptedPayload)
        } catch {
            return RemoteSyncResult(payload: nil, statusCode: 422)
        }
    }

    private func encodeEncryptedPayload(_ payload: String) throws -> String {
        let decoder = Self.makeDecoder()
        let encoder = Self.makeEncoder()
        guard let data = payload.data(using: .utf8) else {
            throw VaultSyncEngineError.invalidRemotePayload
        }
        let syncPayload = try decoder.decode(VaultSyncPayload.self, from: data)
        let encryptedVault = try crypto.encrypt(try encoder.encode(syncPayload.snapshot), key: vaultKey)
        let envelope = EncryptedVaultSyncEnvelope(
            version: syncPayload.version,
            exportedAt: syncPayload.exportedAt,
            deviceId: syncPayload.deviceId,
            revision: syncPayload.revision,
            masterKeyRecord: includeMasterKeyRecord ? masterKeyRecord : nil,
            encryptedVault: encryptedVault
        )
        return String(data: try encoder.encode(envelope), encoding: .utf8) ?? "{}"
    }

    private func decodeEncryptedPayload(_ rawPayload: String) throws -> String {
        let decoder = Self.makeDecoder()
        let encoder = Self.makeEncoder()
        guard let data = rawPayload.data(using: .utf8) else {
            throw VaultSyncEngineError.invalidRemotePayload
        }
        let envelope = try decoder.decode(EncryptedVaultSyncEnvelope.self, from: data)
        let snapshot = try decoder.decode(VaultSnapshot.self, from: crypto.decrypt(envelope.encryptedVault, key: vaultKey))
        let payload = VaultSyncPayload(
            version: envelope.version,
            exportedAt: envelope.exportedAt,
            deviceId: envelope.deviceId,
            revision: envelope.revision,
            snapshot: snapshot
        )
        return String(data: try encoder.encode(payload), encoding: .utf8) ?? "{}"
    }

    private static func containsEncryptedVault(_ rawPayload: String) -> Bool {
        guard let data = rawPayload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["encryptedVault"] != nil
    }

    private static func isSuccessfulDownload(_ statusCode: Int) -> Bool {
        (statusCode >= 200 && statusCode < 300) || statusCode == 404
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct EncryptedVaultSyncEnvelope: Codable, Sendable {
    var version: Int = 1
    var exportedAt: Date
    var deviceId: String
    var revision: Int
    var masterKeyRecord: MasterKeyRecord?
    var encryptedVault: EncryptedPayloadRecord
}
