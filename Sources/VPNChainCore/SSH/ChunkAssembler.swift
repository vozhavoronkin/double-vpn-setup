import Foundation

/// Накапливает байты потока и выдаёт из них безопасные строки,
/// не разрезая многобайтовые последовательности UTF-8 посреди символа.
///
/// Выделен в отдельный тип, чтобы покрываться unit-тестами (задача 2.1):
/// реальный SSH-канал приносит произвольные куски байтов, и граница
/// символа может прийти в следующем куске.
public final class ChunkAssembler {
    private var pending: [UInt8] = []

    public init() {}

    /// Добавить новые байты и вернуть всю декодированную часть,
    /// не включая «висящий» неполный префикс многобайтового символа.
    @discardableResult
    public func append(_ bytes: [UInt8]) -> String {
        pending.append(contentsOf: bytes)
        let safeCount = Self.safeUTF8PrefixLength(pending)
        guard safeCount > 0 else { return "" }
        let safeBytes = Array(pending[..<safeCount])
        pending.removeFirst(safeCount)
        return String(decoding: safeBytes, as: UTF8.self)
    }

    /// Поток завершён: вернуть остаток (включая возможный битый префикс как replacement-символы).
    public func finalize() -> String {
        let rest = String(decoding: pending, as: UTF8.self)
        pending = []
        return rest
    }

    public var hasPendingBytes: Bool { !pending.isEmpty }

    /// Сколько байт из начала массива можно декодировать как завершённые UTF-8 символы.
    static func safeUTF8PrefixLength(_ bytes: [UInt8]) -> Int {
        var index = 0
        var safe = 0
        while index < bytes.count {
            let byte = bytes[index]
            let sequenceLength: Int
            if byte & 0b1000_0000 == 0 {
                sequenceLength = 1
            } else if byte & 0b1110_0000 == 0b1100_0000 {
                sequenceLength = 2
            } else if byte & 0b1111_0000 == 0b1110_0000 {
                sequenceLength = 3
            } else if byte & 0b1111_1000 == 0b1111_0000 {
                sequenceLength = 4
            } else {
                // Байт-продолжение без начала последовательности: мусор, декодируем как есть.
                sequenceLength = 1
            }
            guard index + sequenceLength <= bytes.count else { break }
            safe += sequenceLength
            index += sequenceLength
        }
        return safe
    }
}
