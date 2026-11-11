import Foundation
import Testing
@testable import VPNChainCore

/// Тесты задачи 4.3: версии Go, tarball, план установки.
struct SoftwareInstallTests {
    // MARK: Версии Go

    @Test func parsesGoModDirective() {
        #expect(SoftwareInstallPlan.requiredGoVersion(goMod: "module github.com/amnezia-vpn/amneziawg-go\n\ngo 1.23.0\n") == "1.23.0")
        #expect(SoftwareInstallPlan.requiredGoVersion(goMod: "go 1.23\n") == "1.23.0")
        #expect(SoftwareInstallPlan.requiredGoVersion(goMod: "module x\n") == nil)
    }

    @Test func parsesGoVersionOutput() {
        let short = SoftwareInstallPlan.parseInstalledGoVersion("go version go1.19 linux/amd64")
        #expect(short?.major == 1)
        #expect(short?.minor == 19)
        #expect(short?.patch == 0)
        let full = SoftwareInstallPlan.parseInstalledGoVersion("go version go1.23.4 linux/arm64")
        #expect(full?.major == 1)
        #expect(full?.minor == 23)
        #expect(full?.patch == 4)
        #expect(SoftwareInstallPlan.parseInstalledGoVersion("command not found") == nil)
    }

    @Test func semverComparison() {
        #expect(SoftwareInstallPlan.isSufficient(installed: "1.23.4", required: "1.23.0"))
        #expect(SoftwareInstallPlan.isSufficient(installed: "1.24.0", required: "1.23.0"))
        #expect(!SoftwareInstallPlan.isSufficient(installed: "1.19", required: "1.23.0"))
        #expect(SoftwareInstallPlan.isSufficient(installed: "1.23.0", required: "1.23.0"))
    }

    @Test func goBinaryDecisionCases() {
        #expect(
            SoftwareInstallPlan.goBinaryDecision(goModOutput: "go 1.23.0", goVersionOutput: "go version go1.19 linux/amd64")
                == .fallbackRequired(required: "1.23.0")
        )
        #expect(
            SoftwareInstallPlan.goBinaryDecision(goModOutput: "go 1.23.0", goVersionOutput: "")
                == .fallbackRequired(required: "1.23.0")
        )
        #expect(
            SoftwareInstallPlan.goBinaryDecision(goModOutput: "go 1.23.0", goVersionOutput: "go version go1.23.4 linux/amd64")
                == .systemSufficient
        )
        #expect(
            SoftwareInstallPlan.goBinaryDecision(goModOutput: "module x", goVersionOutput: "go version go1.23.4 linux/amd64")
                == .invalid("в go.mod нет директивы go")
        )
    }

    @Test func tarballNamesPerArch() {
        #expect(SoftwareInstallPlan.goTarballName(required: "1.23.0", arch: .x86_64) == "go1.23.0.linux-amd64.tar.gz")
        #expect(SoftwareInstallPlan.goTarballName(required: "1.23", arch: .aarch64) == "go1.23.0.linux-arm64.tar.gz")
    }

    // MARK: План установки

    @Test func planContainsPinnedCommitsAndTimeouts() {
        let platform = ServerPlatform(os: .debian, majorVersion: 12, arch: .x86_64)
        let actions = SoftwareInstallPlan.actions(platform: platform)
        let joined = actions.map { ($0.check ?? "") + " " + $0.apply }.joined(separator: "\n")

        #expect(joined.contains(AmneziaPins.goDaemon))
        #expect(joined.contains(AmneziaPins.tools))
        #expect(joined.contains("amneziawg-tools"))
        #expect(joined.contains("amneziawg-go"))
        #expect(joined.contains("apt-get install -y git make gcc curl ca-certificates"))

        // Долгие сборки — с щедрыми таймаутами (design R2).
        let byID = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
        #expect(byID["tools-build"]?.timeout == 1800)
        #expect(byID["go-build"]?.timeout == 3600)
        #expect(byID["deps"]?.timeout == 600)
    }

    @Test func checkThenApplySemantics() {
        #expect(ShellAction.shouldApply(checkExitCode: nil))
        #expect(ShellAction.shouldApply(checkExitCode: 1))
        #expect(!ShellAction.shouldApply(checkExitCode: 0))
    }

    @Test func goFallbackActionDownloadsFileNotPipe() {
        let action = SoftwareInstallPlan.goFallbackAction(required: "1.23.0", arch: .aarch64)
        // ТЗ раздел 5: никаких curl | bash — только скачивание в файл.
        #expect(action.apply.contains("curl -fL https://go.dev/dl/go1.23.0.linux-arm64.tar.gz -o /tmp/go.tar.gz"))
        #expect(action.apply.contains("tar -C /usr/local -xzf /tmp/go.tar.gz"))
        #expect(!action.apply.contains("curl | bash"))
        #expect(action.check == nil) // движок добавляет шаг по решению goBinaryDecision
    }

    @Test func goBuildUsesFallbackPath() {
        let actions = SoftwareInstallPlan.actions(platform: ServerPlatform(os: .ubuntu, majorVersion: 22, arch: .x86_64))
        let goBuild = actions.first { $0.id == "go-build" }
        #expect(goBuild?.apply.contains("PATH=/usr/local/go/bin:$PATH") == true)
        #expect(goBuild?.check?.contains("command -v amneziawg-go") == true)
    }
}

/// Тесты задачи 4.4: юнит awg-quick@.service.
struct SystemdUnitsTests {
    @Test func templateMatchesTZ9_4() {
        let template = SystemdUnits.awgQuickTemplate
        #expect(template.contains("Description=AmneziaWG via awg-quick for %i"))
        #expect(template.contains("After=network-online.target"))
        #expect(template.contains("Type=oneshot"))
        #expect(template.contains("RemainAfterExit=yes"))
        #expect(template.contains("Environment=WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go"))
        #expect(template.contains("ExecStart=/usr/bin/awg-quick up %i"))
        #expect(template.contains("ExecStop=/usr/bin/awg-quick down %i"))
        #expect(template.contains("WantedBy=multi-user.target"))
    }

    @Test func installCommandCreatesOnlyIfAbsent() {
        let command = SystemdUnits.installAwgQuickUnitCommand()
        #expect(command.contains("if [ ! -f /etc/systemd/system/awg-quick@.service ]; then"))
        #expect(command.contains("chmod 0644 '/etc/systemd/system/awg-quick@.service'"))
        #expect(command.contains("systemctl daemon-reload"))
        #expect(command.contains("# managed-by: amnezia-chain"))
        #expect(command.contains("<<'VPNCHAIN_EOF_"))
    }

    @Test func relayEnableCommand() {
        // Restart обязателен: enable --now для активного юнита — no-op, и новый
        // конфиг/бинарник не вступили бы в силу (регрессия приёмки).
        #expect(SystemdUnits.enableRelayCommand() == "systemctl enable awg-quick@awg-relay && systemctl restart awg-quick@awg-relay")
    }
}
