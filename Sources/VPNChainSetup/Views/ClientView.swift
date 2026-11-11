import SwiftUI
import VPNChainCore

/// Экран «Клиент» (задача 7.1): клиентская сторона настраивается вручную
/// в приложении AmneziaVPN (раздел 8 ТЗ); текст сверен с ТЗ.
struct ClientView: View {
    private let clientSteps: [(title: String, text: String)] = [
        (
            "1. Подключение",
            "Обновите приложение AmneziaVPN до последней версии (поддержка актуальных поколений протокола) и подключитесь к серверу-входу по AmneziaWG. Конфиг выдаётся приложением автоматически: full tunnel 0.0.0.0/0."
        ),
        (
            "2. Split tunneling выключен",
            "Убедитесь, что режим «раздельного туннелирования» в AmneziaVPN выключен — по умолчанию весь трафик должен идти в туннель."
        ),
        (
            "3. KillSwitch и DNS",
            "Включите KillSwitch в настройках приложения. DNS берётся из конфига (AmneziaDNS/1.1.1.1) и резолвится через туннель."
        ),
        (
            "4. MTU (опционально)",
            "Если UDP/QUIC-приложения работают плохо — в настройках соединения снизьте MTU до 1380. Двойная инкапсуляция: TCP подстраивается сам через MSS clamp, а крупным UDP-пакетам помогает только меньший MTU клиента."
        ),
        (
            "5. Локальная сеть",
            "Доступ к локальной сети устройства определяется настройками AmneziaVPN и находится вне рамок этой схемы."
        ),
    ]

    private let clientChecks: [ManualCheck] = ManualChecklist.items.filter { item in
        ["client-ip", "dns-leak", "ipv6"].contains(item.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Клиентская сторона настраивается вручную", systemImage: "hand.tap")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 560, alignment: .leading)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(clientSteps.enumerated()), id: \.offset) { _, step in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(step.title).font(.callout).fontWeight(.semibold)
                                Text(step.text)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 560, alignment: .leading)

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Проверка после подключения").font(.headline)
                        ForEach(clientChecks) { check in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(check.title).font(.callout).fontWeight(.semibold)
                                Text(check.instruction)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 560, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle("Клиент")
    }
}
