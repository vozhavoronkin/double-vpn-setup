import Foundation

/// Параметры обфускации AmneziaWG relay-участка (раздел 4 ТЗ).
/// Записываются идентично в конфиги обоих серверов.
public struct ObfuscationParams: Sendable, Equatable, Codable {
    public let jc: Int
    public let jmin: Int
    public let jmax: Int
    public let s1: Int
    public let s2: Int
    public let h1: Int
    public let h2: Int
    public let h3: Int
    public let h4: Int

    public init(jc: Int, jmin: Int, jmax: Int, s1: Int, s2: Int, h1: Int, h2: Int, h3: Int, h4: Int)
    {
        self.jc = jc
        self.jmin = jmin
        self.jmax = jmax
        self.s1 = s1
        self.s2 = s2
        self.h1 = h1
        self.h2 = h2
        self.h3 = h3
        self.h4 = h4
    }

    /// Список (имя, значение) в порядке конфига — для рендера шаблонов.
    public var ordered: [(name: String, value: String)] {
        [
            ("Jc", String(jc)),
            ("Jmin", String(jmin)),
            ("Jmax", String(jmax)),
            ("S1", String(s1)),
            ("S2", String(s2)),
            ("H1", String(h1)),
            ("H2", String(h2)),
            ("H3", String(h3)),
            ("H4", String(h4)),
        ]
    }
}

/// Правила генерации и валидации параметров обфускации по разделу 4 ТЗ:
/// - `Jc` — случайное 3–12 (допустимо 1–128);
/// - `Jmin` = 8; `Jmax` = 80 (< MTU 1420, ≤ 1280);
/// - `S1` — случайное 50–120 (≤ 1132); `S2` — случайное 50–120 (≤ 1188),
///   повтор генерации при `S2 == S1 + 56`;
/// - `H1–H4` — случайные 5–2147483647, попарно различные;
///   значения 0/1/2/3/4 («обфускация выключена») запрещены.
public enum ObfuscationRules {
    public static let jcRange = 3...12
    public static let s1Range = 50...120
    public static let s2Range = 50...120
    public static let s1HardLimit = 1132
    public static let s2HardLimit = 1188
    public static let hRange = 5...2_147_483_647
    /// MTU relay-интерфейса из ТЗ (раздел 2.1).
    public static let relayMTU = 1420

    /// Генерация валидного набора параметров.
    public static func generate() -> ObfuscationParams {
        generate(
            drawJC: { Int.random(in: jcRange) },
            drawS: { Int.random(in: s1Range) },
            drawH: { Int.random(in: hRange) }
        )
    }

    /// Генерация с инъекцией источников случайности — для детерминированных тестов
    /// (включая форсированную коллизию `S2 == S1 + 56`).
    public static func generate(
        drawJC: () -> Int,
        drawS: () -> Int,
        drawH: () -> Int
    ) -> ObfuscationParams {
        let jc = drawJC()
        let s1 = drawS()
        let s2 = chooseS2(s1: s1, draw: drawS)
        let hs = chooseDistinctH(draw: drawH)
        return ObfuscationParams(
            jc: jc, jmin: 8, jmax: 80,
            s1: s1, s2: s2,
            h1: hs[0], h2: hs[1], h3: hs[2], h4: hs[3]
        )
    }

    /// Выбор S2 с повтором при коллизии `S2 == S1 + 56` (правило ТЗ).
    public static func chooseS2(s1: Int, draw: () -> Int) -> Int {
        var candidate = draw()
        var attempts = 0
        while candidate == s1 + 56, attempts < 10_000 {
            candidate = draw()
            attempts += 1
        }
        return candidate
    }

    /// Выбор четырёх попарно различных H.
    public static func chooseDistinctH(draw: () -> Int) -> [Int] {
        var values: [Int] = []
        var attempts = 0
        while values.count < 4, attempts < 100_000 {
            let candidate = draw()
            if !values.contains(candidate) {
                values.append(candidate)
            }
            attempts += 1
        }
        return values
    }

    // MARK: Валидация

    public enum Violation: Error, Equatable, Sendable {
        case jcOutOfRange(Int)
        case jminTooLarge(Int)
        case jmaxOutOfRange(Int)
        case jminNotLessThanJmax
        case s1OutOfRange(Int)
        case s2OutOfRange(Int)
        case s2CollidesWithS1(s1: Int, s2: Int)
        case hOutOfRange(Int)
        case hValuesNotDistinct
        case hDisabledValue(Int)
    }

    /// Полная валидация набора. Пустой список = набор валиден.
    public static func validate(_ params: ObfuscationParams) -> [Violation] {
        var violations: [Violation] = []
        if !(1...128).contains(params.jc) || !jcRange.contains(params.jc) {
            violations.append(.jcOutOfRange(params.jc))
        }
        if params.jmin >= params.jmax {
            violations.append(.jminNotLessThanJmax)
        }
        if params.jmax > 1280 || params.jmax >= relayMTU {
            violations.append(.jmaxOutOfRange(params.jmax))
        }
        if !s1Range.contains(params.s1) || params.s1 > s1HardLimit {
            violations.append(.s1OutOfRange(params.s1))
        }
        if !s2Range.contains(params.s2) || params.s2 > s2HardLimit {
            violations.append(.s2OutOfRange(params.s2))
        }
        if params.s2 == params.s1 + 56 {
            violations.append(.s2CollidesWithS1(s1: params.s1, s2: params.s2))
        }
        for h in [params.h1, params.h2, params.h3, params.h4] {
            if !hRange.contains(h) {
                violations.append(h < 5 ? .hDisabledValue(h) : .hOutOfRange(h))
            }
        }
        let hs = [params.h1, params.h2, params.h3, params.h4]
        if Set(hs).count != 4 {
            violations.append(.hValuesNotDistinct)
        }
        return violations
    }
}
