import Foundation
import Testing
@testable import VPNChainCore

/// Тесты задачи 2.3: парсер os-release, uname, и логика TOFU/pinned-политик.
struct ConnectionCheckerTests {
    // MARK: Парсер /etc/os-release

    @Test func parsesUbuntuOSRelease() {
        let fixture = """
        NAME="Ubuntu"
        PRETTY_NAME="Ubuntu 22.04.3 LTS"
        VERSION_ID="22.04"
        ID=ubuntu
        HOME_URL="https://www.ubuntu.com/"
        """
        let parsed = OSReleaseParser.parse(fixture)
        #expect(parsed.name == "Ubuntu")
        #expect(parsed.version == "22.04")
    }

    @Test func parsesDebianOSRelease() {
        let fixture = """
        PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
        NAME="Debian GNU/Linux"
        VERSION_ID="12"
        VERSION="12 (bookworm)"
        ID=debian
        """
        let parsed = OSReleaseParser.parse(fixture)
        #expect(parsed.name == "Debian GNU/Linux")
        #expect(parsed.version == "12")
    }

    @Test func osReleaseWithoutQuotesAndComments() {
        let fixture = """
        # comment line
        NAME=Alpine
        VERSION_ID=3.19
        """
        let parsed = OSReleaseParser.parse(fixture)
        #expect(parsed.name == "Alpine")
        #expect(parsed.version == "3.19")
    }

    @Test func missingOSReleaseYieldsUnknown() {
        let parsed = OSReleaseParser.parse("")
        #expect(parsed.name == "Unknown")
        #expect(parsed.version == nil)
    }

    @Test func environmentDisplayText() {
        let env = ServerEnvironment(osName: "Ubuntu", osVersion: "22.04", architecture: "x86_64")
        #expect(env.displayText == "Ubuntu 22.04, x86_64")
        let noVersion = ServerEnvironment(osName: "Debian GNU/Linux", osVersion: nil, architecture: "aarch64")
        #expect(noVersion.displayText == "Debian GNU/Linux, aarch64")
    }

    // MARK: Политики host key (TOFU/pinned)

    @Test func pinnedPolicyAcceptsOnlyMatchingFingerprint() async {
        let pinned = SSHHostKeyPolicy.pinned(expectedFingerprint: "SHA256:expected")
        #expect(await SSHClient.policyAccepts(pinned, fingerprint: "SHA256:expected"))
        #expect(!(await SSHClient.policyAccepts(pinned, fingerprint: "SHA256:other")))
    }

    @Test func tofuWithStoredFingerprintRejectsMismatch() async {
        let tofu = SSHHostKeyPolicy.tofu(expectedFingerprint: "SHA256:known", confirm: { _ in true })
        // Совпадает с сохранённым — принимается, подтверждение не вызывается.
        #expect(await SSHClient.policyAccepts(tofu, fingerprint: "SHA256:known"))
        // Не совпадает — отклоняется, даже если пользователь готов подтвердить:
        // смена отпечатка = признак MITM, требует явного сброса в профиле.
        #expect(!(await SSHClient.policyAccepts(tofu, fingerprint: "SHA256:changed")))
    }

    @Test func tofuWithoutStoredFingerprintAsksUser() async {
        let asked = LockedBox<String?>(nil)
        let tofu = SSHHostKeyPolicy.tofu(expectedFingerprint: nil) { candidate in
            asked.withLock { $0 = candidate }
            return true
        }
        #expect(await SSHClient.policyAccepts(tofu, fingerprint: "SHA256:fresh"))
        #expect(asked.withLock { $0 } == "SHA256:fresh")

        let wasAsked = LockedBox<Bool>(false)
        let reject = SSHHostKeyPolicy.tofu(expectedFingerprint: nil) { _ in
            wasAsked.withLock { $0 = true }
            return false
        }
        #expect(!(await SSHClient.policyAccepts(reject, fingerprint: "SHA256:fresh")))
        #expect(wasAsked.withLock { $0 })
    }
}
