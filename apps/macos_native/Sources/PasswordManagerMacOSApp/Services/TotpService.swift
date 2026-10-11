import CryptoKit
import Foundation

struct TotpService {
    var period: TimeInterval = 30
    var digits = 6
    var skewWindows = 1

    func generateCode(secret: String, date: Date = Date()) throws -> String {
        let key = try decodeBase32(secret)
        let counter = UInt64(floor(date.timeIntervalSince1970 / period))
        return code(for: counter, key: key)
    }

    func verifyCode(secret: String, code submittedCode: String, date: Date = Date()) -> Bool {
        let normalizedCode = submittedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedCode.count == digits,
              normalizedCode.allSatisfy(\.isNumber),
              let key = try? decodeBase32(secret) else {
            return false
        }
        let counter = Int64(floor(date.timeIntervalSince1970 / period))
        for offset in -skewWindows...skewWindows {
            let expected = code(for: UInt64(counter + Int64(offset)), key: key)
            if constantTimeEquals(expected, normalizedCode) {
                return true
            }
        }
        return false
    }

    private func code(for counter: UInt64, key: Data) -> String {
        var movingFactor = counter.bigEndian
        let counterData = Data(bytes: &movingFactor, count: MemoryLayout<UInt64>.size)
        let signature = HMAC<Insecure.SHA1>.authenticationCode(
            for: counterData,
            using: SymmetricKey(data: key)
        )
        let hash = Array(signature)
        let offset = Int(hash[hash.count - 1] & 0x0f)
        let binary = (UInt32(hash[offset] & 0x7f) << 24)
            | (UInt32(hash[offset + 1]) << 16)
            | (UInt32(hash[offset + 2]) << 8)
            | UInt32(hash[offset + 3])
        let divisor = UInt32(pow(10.0, Double(digits)))
        return String(format: "%0*u", digits, binary % divisor)
    }

    private func decodeBase32(_ secret: String) throws -> Data {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        let lookup = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($0.element, UInt8($0.offset)) })
        let normalized = secret
            .uppercased()
            .filter { !$0.isWhitespace && $0 != "=" }
        guard !normalized.isEmpty else {
            throw TotpError.invalidSecret
        }

        var buffer = 0
        var bitsLeft = 0
        var bytes: [UInt8] = []
        for character in normalized {
            guard let value = lookup[character] else {
                throw TotpError.invalidSecret
            }
            buffer = (buffer << 5) | Int(value)
            bitsLeft += 5
            if bitsLeft >= 8 {
                bytes.append(UInt8((buffer >> (bitsLeft - 8)) & 0xff))
                bitsLeft -= 8
            }
        }
        return Data(bytes)
    }

    private func constantTimeEquals(_ left: String, _ right: String) -> Bool {
        let leftBytes = Array(left.utf8)
        let rightBytes = Array(right.utf8)
        var diff = leftBytes.count ^ rightBytes.count
        let maxLength = max(leftBytes.count, rightBytes.count)
        for index in 0..<maxLength {
            let leftByte = index < leftBytes.count ? leftBytes[index] : 0
            let rightByte = index < rightBytes.count ? rightBytes[index] : 0
            diff |= Int(leftByte ^ rightByte)
        }
        return diff == 0
    }
}

enum TotpError: Error {
    case invalidSecret
}
