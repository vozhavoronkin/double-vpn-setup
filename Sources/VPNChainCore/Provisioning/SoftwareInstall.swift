import Foundation

/// Зафиксированные состояния репозиториев AmneziaWG (ТЗ раздел 3.2: оба сервера
/// собираются из одного commit для совместимости протокола). Обновляется при release.
public enum AmneziaPins {
    /// amnezia-vpn/amneziawg-go, тег v0.2.19 (коммит 1cc9427).
    ///
    /// Регрессия приёмки 2026-11: линия v3.x (master b5928ef) на ядрах со встроенным
    /// WireGuard печатает баннер «kernel has first class support» и завершает
    /// userspace-демон после настройки интерфейса — handshake-пакеты никто не читает.
    /// v0.2.19 — последняя линия с классическим userspace-поведением (ТЗ раздел 3).
    public static let goDaemon = "1cc94272ca8e9e223a5fe76382f5880f09d3c12d"
    /// amnezia-vpn/amneziawg-tools, master (2026-08-12, v3.1.20260812).
    ///
    /// Внимание: tools 3.1 + go-daemon 0.2.x — проверенная приёмкой связка
    /// (awg-quick userspace fallback работает).
    public static let tools = "ee0f0a9aa34ff0a0da4b3433b9512781cfe02843"
}

/// Одна команда шага установки (check-then-apply, design D4).
public struct ShellAction: Sendable, Equatable {
    /// Стабильный идентификатор шага (для FSM и отчётов).
    public let id: String
    public let title: String
    /// Проверка «уже сделано?»; nil — применять всегда.
    public let check: String?
    /// Команда применения.
    public let apply: String
    /// Таймаут: сборка amneziawg-go может идти долго (design R2).
    public let timeout: TimeInterval

    public init(id: String, title: String, check: String?, apply: String, timeout: TimeInterval = 300) {
        self.id = id
        self.title = title
        self.check = check
        self.apply = apply
        self.timeout = timeout
    }

    /// Решение по результату check: применять, если check отсутствует или завершился неуспешно.
    public static func shouldApply(checkExitCode: Int?) -> Bool {
        guard let code = checkExitCode else { return true }
        return code != 0
    }
}

/// Решение по версии Go (задача 4.3, ТЗ раздел 3.2).
public enum GoDecision: Equatable, Sendable {
    /// Системного Go достаточно.
    case systemSufficient
    /// Нужен свежий Go из tarball: требуемая версия из go.mod.
    case fallbackRequired(required: String)
    /// go.mod не содержит распознаваемой директивы.
    case invalid(String)
}

/// План установки ПО amneziawg-tools + amneziawg-go (задача 4.3).
public enum SoftwareInstallPlan {
    static let toolsDir = "/tmp/amneziawg-tools"
    static let goDir = "/tmp/amneziawg-go"

    // MARK: Парсеры версий Go (чистые функции для unit-тестов)

    /// Директива `go 1.XX(.YY)` из go.mod → «1.XX.YY» (нормализация patch=0).
    public static func requiredGoVersion(goMod: String) -> String? {
        for line in goMod.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let tokens = trimmed.split(separator: " ")
            guard tokens.count >= 2, tokens[0] == "go" else { continue }
            let version = normalizeVersion(String(tokens[1]))
            return version
        }
        return nil
    }

    /// «go1.23.4» → «1.23.4»; «go1.23» → «1.23.0».
    public static func normalizeVersion(_ raw: String) -> String? {
        var value = raw
        if value.hasPrefix("go") { value.removeFirst(2) }
        let parts = value.split(separator: ".").map(String.init)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && Int($0) != nil }) else { return nil }
        var numbers = parts.map { Int($0)! }
        while numbers.count < 3 { numbers.append(0) }
        return numbers.map(String.init).joined(separator: ".")
    }

    /// Разбор вывода `go version`: «go version go1.19 linux/amd64» → (1, 19, 0).
    public static func parseInstalledGoVersion(_ output: String) -> (major: Int, minor: Int, patch: Int)? {
        guard let normalized = output.split(separator: " ").map(String.init).first(where: { $0.hasPrefix("go1") })
            .flatMap({ normalizeVersion($0) }) else {
            return nil
        }
        let numbers = normalized.split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        return (numbers[0], numbers[1], numbers[2])
    }

    /// Лексикографическое сравнение semver: «1.23.4» >= «1.23.0».
    public static func isSufficient(installed: String, required: String) -> Bool {
        let a = installed.split(separator: ".").compactMap { Int($0) }
        let b = required.split(separator: ".").compactMap { Int($0) }
        guard a.count == 3, b.count == 3 else { return false }
        for index in 0..<3 {
            if a[index] != b[index] { return a[index] > b[index] }
        }
        return true
    }

    /// Решение: хватает ли системного Go.
    public static func goBinaryDecision(goModOutput: String, goVersionOutput: String) -> GoDecision {
        guard let required = requiredGoVersion(goMod: goModOutput) else {
            return .invalid("в go.mod нет директивы go")
        }
        guard let installed = parseInstalledGoVersion(goVersionOutput) else {
            return .fallbackRequired(required: required)
        }
        let installedString = "\(installed.major).\(installed.minor).\(installed.patch)"
        return isSufficient(installed: installedString, required: required)
            ? .systemSufficient
            : .fallbackRequired(required: required)
    }

    /// Имя tarball: go1.23.0.linux-amd64.tar.gz (go.dev, архитектурозависимо).
    public static func goTarballName(required: String, arch: ServerPlatform.Arch) -> String {
        let version = normalizeVersion(required) ?? required
        let goArch = arch == .x86_64 ? "amd64" : "arm64"
        return "go\(version).linux-\(goArch).tar.gz"
    }

    // MARK: Действия

    /// Полный план для сервера. Шаг с Go-fallback движок добавляет по решению goBinaryDecision.
    public static func actions(platform: ServerPlatform) -> [ShellAction] {
        [
            ShellAction(
                id: "deps",
                title: "Установка git/make/gcc/curl",
                check: "command -v git >/dev/null 2>&1 && command -v make >/dev/null 2>&1 && command -v gcc >/dev/null 2>&1 && command -v curl >/dev/null 2>&1",
                apply: "apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y git make gcc curl ca-certificates",
                timeout: 600
            ),
            ShellAction(
                id: "tools-source",
                title: "Клон amneziawg-tools (pinned commit)",
                check: "[ -d \(toolsDir)/.git ] && [ \"$(git -C \(toolsDir) rev-parse HEAD)\" = \"\(AmneziaPins.tools)\" ]",
                apply: "rm -rf \(toolsDir) && git clone https://github.com/amnezia-vpn/amneziawg-tools \(toolsDir) && git -C \(toolsDir) checkout \(AmneziaPins.tools)",
                timeout: 300
            ),
            ShellAction(
                id: "tools-build",
                title: "Сборка и установка awg/awg-quick",
                check: "command -v awg >/dev/null 2>&1 && command -v awg-quick >/dev/null 2>&1",
                apply: "make -C \(toolsDir)/src -j\"$(nproc)\" && make -C \(toolsDir)/src install",
                timeout: 1800
            ),
            ShellAction(
                id: "go-source",
                title: "Клон amneziawg-go (pinned commit)",
                check: "[ -d \(goDir)/.git ] && [ \"$(git -C \(goDir) rev-parse HEAD)\" = \"\(AmneziaPins.goDaemon)\" ]",
                apply: "rm -rf \(goDir) && git clone https://github.com/amnezia-vpn/amneziawg-go \(goDir) && git -C \(goDir) checkout \(AmneziaPins.goDaemon)",
                timeout: 300
            ),
            ShellAction(
                id: "go-build",
                title: "Сборка и установка amneziawg-go",
                check: "command -v amneziawg-go >/dev/null 2>&1",
                apply: "PATH=/usr/local/go/bin:$PATH sh -c 'make -C \(goDir) -j\"$(nproc)\" && make -C \(goDir) install'",
                timeout: 3600
            ),
        ]
    }

    /// Условное действие Go-fallback (включается движком при `.fallbackRequired`).
    public static func goFallbackAction(required: String, arch: ServerPlatform.Arch) -> ShellAction {
        let tarball = goTarballName(required: required, arch: arch)
        return ShellAction(
            id: "go-fallback",
            title: "Установка свежего Go (\(tarball)) в /usr/local/go",
            check: nil,
            apply: """
            curl -fL https://go.dev/dl/\(tarball) -o /tmp/go.tar.gz && \
            rm -rf /usr/local/go && \
            tar -C /usr/local -xzf /tmp/go.tar.gz && \
            rm -f /tmp/go.tar.gz
            """,
            timeout: 900
        )
    }
}
