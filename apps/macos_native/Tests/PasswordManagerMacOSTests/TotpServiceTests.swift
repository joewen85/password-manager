import Foundation
import Testing
@testable import PasswordManagerMacOSApp

@Suite("TOTP service")
struct TotpServiceTests {
    private let service = TotpService(skewWindows: 1)
    private let fixtureDate = Date(timeIntervalSince1970: 59)

    @Test("Generates the RFC 6238 SHA1 fixture code")
    func generatesRfcFixture() throws {
        let code = try service.generateCode(
            secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",
            date: fixtureDate
        )

        #expect(code == "287082")
    }

    @Test("Verifies current and skew-window codes")
    func verifiesSkewWindow() throws {
        let previousWindowCode = try service.generateCode(
            secret: "JBSWY3DPEHPK3PXP",
            date: fixtureDate.addingTimeInterval(-30)
        )

        #expect(service.verifyCode(secret: "JBSWY3DPEHPK3PXP", code: previousWindowCode, date: fixtureDate))
    }

    @Test("Rejects malformed or incorrect codes")
    func rejectsInvalidCodes() {
        #expect(!service.verifyCode(secret: "JBSWY3DPEHPK3PXP", code: "12345", date: fixtureDate))
        #expect(!service.verifyCode(secret: "JBSWY3DPEHPK3PXP", code: "000000", date: fixtureDate))
        #expect(!service.verifyCode(secret: "not-base32", code: "000000", date: fixtureDate))
    }
}
