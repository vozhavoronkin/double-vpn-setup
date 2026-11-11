/// Роль сервера в цепочке «Клиент → С1 → С2 → Интернет».
public enum ServerRole: String, Codable, Sendable, CaseIterable {
    /// С1 — входной сервер с AmneziaVPN (Docker-контейнер amnezia-awg).
    case entry
    /// С2 — выходной сервер (чистый Debian/Ubuntu).
    case exit
}
