import Foundation
import Testing
@testable import VPNChainCore

/// Тесты задачи 3.1: генерация ключей WireGuard на CryptoKit.
struct WireGuardKeysTests {
    @Test func keyFormatIsWireGuardBase64() throws {
        let pair = try WireGuardKeys.generateKeyPair(name: "s1-relay")
        guard let privateKeyData = Data(base64Encoded: pair.privateKey),
              let publicKeyData = Data(base64Encoded: pair.publicKey) else {
            Issue.record("Ключи не декодируются как base64")
            return
        }
        #expect(privateKeyData.count == 32)
        #expect(publicKeyData.count == 32)
        // Формат `awg genkey`: 44 символа base64, завершаются '='.
        #expect(pair.privateKey.hasSuffix("="))
        #expect(pair.privateKey.count == 44)
    }

    @Test func clampingBitsApplied() throws {
        let pair = try WireGuardKeys.generateKeyPair(name: "s2-relay")
        let raw = [UInt8](Data(base64Encoded: pair.privateKey)!)
        #expect(raw[0] & 7 == 0) // &= 248
        #expect(raw[31] & 128 == 0) // &= 127
        #expect(raw[31] & 64 == 64) // |= 64
    }

    @Test func publicKeyIsDerivedFromPrivateKey() throws {
        let pair = try WireGuardKeys.generateKeyPair(name: "s1-relay")
        let restored = try WireGuardKeys.keyPair(name: "s1-relay", privateKeyBase64: pair.privateKey)
        #expect(restored.publicKey == pair.publicKey)
        #expect(restored.privateKey == pair.privateKey)
    }

    @Test func keyPairRestoresFromSavedPrivate() throws {
        let original = try WireGuardKeys.generateKeyPair(name: "s2-relay")
        let restored = try WireGuardKeys.keyPair(name: "s2-relay", privateKeyBase64: original.privateKey)
        #expect(restored == original)
    }

    @Test func invalidKeyFormatRejected() {
        #expect(throws: SecretError.invalidKeyFormat("приватный ключ s1-relay: не base64 длиной 32 байта")) {
            try WireGuardKeys.keyPair(name: "s1-relay", privateKeyBase64: "не-ключ")
        }
    }

    @Test func keysDifferBetweenGenerations() throws {
        let a = try WireGuardKeys.generateKeyPair(name: "s1-relay")
        let b = try WireGuardKeys.generateKeyPair(name: "s1-relay")
        #expect(a.privateKey != b.privateKey)
        #expect(a.publicKey != b.publicKey)
    }
}

/// Тесты задачи 3.2: правила параметров обфускации раздела 4 ТЗ.
struct ObfuscationRulesTests {
    @Test func generatedParamsSatisfyAllRules() {
        for _ in 0..<200 {
            let params = ObfuscationRules.generate()
            #expect(ObfuscationRules.validate(params).isEmpty, "нарушения: \(ObfuscationRules.validate(params)) для \(params)")
        }
    }

    @Test func s2CollisionRegenerated() {
        // Форсированная коллизия: первый вызов drawS после S1 возвращает S1+56,
        // второй — валидное значение. Достаточно 3 попытки, лимит 10_000.
        final class DrawState: @unchecked Sendable {
            var step = 0
            var hCounter = 4
        }
        let state = DrawState()
        let params = ObfuscationRules.generate(
            drawJC: { 5 },
            drawS: {
                state.step += 1
                switch state.step {
                case 1: return 100 // S1 = 100 (запрещённый S2 = 156)
                case 2: return 156 // коллизия → перегенерация
                default: return 77 // валидное S2
                }
            },
            drawH: {
                state.hCounter += 1
                return state.hCounter
            }
        )
        #expect(params.s1 == 100)
        #expect(params.s2 == 77)
        #expect(params.s2 != params.s1 + 56)
    }

    @Test func hValuesArePairwiseDistinct() {
        var counter = 9
        let hs = ObfuscationRules.chooseDistinctH {
            counter += 1
            return counter % 11 + 5 // значения из маленького набора → будут повторы
        }
        #expect(hs.count == 4)
        #expect(Set(hs).count == 4)
    }

    @Test func validationRejectsOutOfRangeS1S2() {
        let params = ObfuscationParams(jc: 5, jmin: 8, jmax: 80, s1: 1133, s2: 50, h1: 5, h2: 6, h3: 7, h4: 8)
        #expect(ObfuscationRules.validate(params).contains(.s1OutOfRange(1133)))
        let params2 = ObfuscationParams(jc: 5, jmin: 8, jmax: 80, s1: 49, s2: 1189, h1: 5, h2: 6, h3: 7, h4: 8)
        #expect(ObfuscationRules.validate(params2).contains(.s2OutOfRange(1189)))
    }

    @Test func validationRejectsDisabledHValues() {
        let params = ObfuscationParams(jc: 5, jmin: 8, jmax: 80, s1: 100, s2: 77, h1: 4, h2: 6, h3: 7, h4: 8)
        #expect(ObfuscationRules.validate(params).contains(.hDisabledValue(4)))
        let zero = ObfuscationParams(jc: 5, jmin: 8, jmax: 80, s1: 100, s2: 77, h1: 0, h2: 6, h3: 7, h4: 8)
        #expect(ObfuscationRules.validate(zero).contains(.hDisabledValue(0)))
    }

    @Test func validationRejectsDuplicateH() {
        let params = ObfuscationParams(jc: 5, jmin: 8, jmax: 80, s1: 100, s2: 77, h1: 9, h2: 9, h3: 10, h4: 11)
        #expect(ObfuscationRules.validate(params).contains(.hValuesNotDistinct))
    }

    @Test func validationRejectsS2Collision() {
        let params = ObfuscationParams(jc: 5, jmin: 8, jmax: 80, s1: 100, s2: 156, h1: 9, h2: 10, h3: 11, h4: 12)
        #expect(ObfuscationRules.validate(params).contains(.s2CollidesWithS1(s1: 100, s2: 156)))
    }

    @Test func validationRejectsBadJ() {
        let jc = ObfuscationParams(jc: 200, jmin: 8, jmax: 80, s1: 100, s2: 77, h1: 9, h2: 10, h3: 11, h4: 12)
        #expect(ObfuscationRules.validate(jc).contains(.jcOutOfRange(200)))
        let jmin = ObfuscationParams(jc: 5, jmin: 90, jmax: 80, s1: 100, s2: 77, h1: 9, h2: 10, h3: 11, h4: 12)
        #expect(ObfuscationRules.validate(jmin).contains(.jminNotLessThanJmax))
        let jmax = ObfuscationParams(jc: 5, jmin: 8, jmax: 1300, s1: 100, s2: 77, h1: 9, h2: 10, h3: 11, h4: 12)
        #expect(ObfuscationRules.validate(jmax).contains(.jmaxOutOfRange(1300)))
    }

    @Test func validSetPassesValidation() {
        let params = ObfuscationParams(jc: 5, jmin: 8, jmax: 80, s1: 100, s2: 77, h1: 9, h2: 10, h3: 11, h4: 12)
        #expect(ObfuscationRules.validate(params).isEmpty)
    }
}
