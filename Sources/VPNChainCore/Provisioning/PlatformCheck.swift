import Foundation

/// Проверка ОС и архитектуры сервера (задача 4.2).
/// Поддерживаются: Debian 11/12/13, Ubuntu 20.04/22.04/24.04, x86_64/aarch64 (ТЗ раздел 5).
public struct ServerPlatform: Sendable, Equatable {
    public enum OSKind: String, Sendable {
        case debian
        case ubuntu
    }

    public enum Arch: String, Sendable, CaseIterable {
        case x86_64
        case aarch64
    }

    public let os: OSKind
    public let majorVersion: Int
    public let arch: Arch

    public init(os: OSKind, majorVersion: Int, arch: Arch) {
        self.os = os
        self.majorVersion = majorVersion
        self.arch = arch
    }

    public var displayName: String {
        "\(os.rawValue.capitalized) \(majorVersion), \(arch.rawValue)"
    }

    public static func isSupported(os: OSKind, majorVersion: Int) -> Bool {
        switch os {
        case .debian: [11, 12, 13].contains(majorVersion)
        case .ubuntu: [20, 22, 24].contains(majorVersion)
        }
    }
}

/// Чистые парсеры платформы — покрываются unit-тестами на фиксчунах.
public enum PlatformParser {
    public enum PlatformError: Error, Equatable {
        case unknownOS(String)
        case unknownArch(String)
        case badVersion(String)
    }

    /// osRelease — содержимое /etc/os-release, uname — вывод `uname -m`.
    public static func parsePlatform(osRelease: String, uname: String) throws -> ServerPlatform {
        let parsed = OSReleaseParser.parse(osRelease)
        let name = parsed.name.lowercased()
        let os: ServerPlatform.OSKind
        if name.contains("ubuntu") {
            os = .ubuntu
        } else if name.contains("debian") {
            os = .debian
        } else {
            throw PlatformError.unknownOS(parsed.name)
        }
        guard let versionID = parsed.version else {
            throw PlatformError.badVersion("VERSION_ID отсутствует в os-release")
        }
        let majorString = versionID.split(separator: ".").first.map(String.init) ?? versionID
        guard let major = Int(majorString) else {
            throw PlatformError.badVersion("VERSION_ID не число: \(versionID)")
        }

        let trimmedUname = uname.trimmingCharacters(in: .whitespacesAndNewlines)
        let arch: ServerPlatform.Arch
        switch trimmedUname {
        case "x86_64", "amd64":
            arch = .x86_64
        case "aarch64", "arm64":
            arch = .aarch64
        default:
            throw PlatformError.unknownArch(trimmedUname)
        }
        return ServerPlatform(os: os, majorVersion: major, arch: arch)
    }

    /// Полная проверка поддержки: бросает `ProvisioningError.unsupportedPlatform` для неподдерживаемых комбинаций.
    public static func ensureSupported(_ platform: ServerPlatform) throws {
        guard ServerPlatform.isSupported(os: platform.os, majorVersion: platform.majorVersion),
            ServerPlatform.Arch.allCases.contains(platform.arch)
        else {
            throw ProvisioningError.unsupportedPlatform(platform.displayName)
        }
    }

    /// Контрольная команда для сбора платформы одной строкой.
    public static let probeCommand =
        "cat /etc/os-release 2>/dev/null; echo '---VPNCHAIN---'; uname -m"

    /// Разбор вывода probeCommand.
    public static func parseProbeOutput(_ output: String) throws -> ServerPlatform {
        let parts = output.components(separatedBy: "---VPNCHAIN---")
        let osRelease = parts.first ?? ""
        let uname =
            parts.dropFirst().first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard !uname.isEmpty else {
            throw PlatformError.unknownArch("")
        }
        return try parsePlatform(osRelease: osRelease, uname: uname)
    }
}
