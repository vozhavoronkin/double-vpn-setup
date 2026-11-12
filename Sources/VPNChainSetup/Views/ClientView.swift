import SwiftUI
import VPNChainCore

/// Экран «Клиент» (задача 7.1): клиентская сторона настраивается вручную
/// в приложении AmneziaVPN (раздел 8 ТЗ); текст сверен с ТЗ.
struct ClientView: View {
    private let clientSteps: [(title: String, text: String)] = [
        (
            "Подключение",
            "Обновите приложение AmneziaVPN до последней версии (поддержка актуальных поколений протокола) и подключитесь к серверу-входу по AmneziaWG. Конфиг выдаётся приложением автоматически: full tunnel 0.0.0.0/0."
        ),
        (
            "Split tunneling выключен",
            "Убедитесь, что режим «раздельного туннелирования» в AmneziaVPN выключен — по умолчанию весь трафик должен идти в туннель."
        ),
        (
            "KillSwitch и DNS",
            "Включите KillSwitch в настройках приложения. DNS берётся из конфига (AmneziaDNS/1.1.1.1) и резолвится через туннель."
        ),
        (
            "MTU (опционально)",
            "Если UDP/QUIC-приложения работают плохо — в настройках соединения снизьте MTU до 1380. Двойная инкапсуляция: TCP подстраивается сам через MSS clamp, а крупным UDP-пакетам помогает только меньший MTU клиента."
        ),
        (
            "Локальная сеть",
            "Доступ к локальной сети устройства определяется настройками AmneziaVPN и находится вне рамок этой схемы."
        ),
    ]

    private let clientChecks: [ManualCheck] = ManualChecklist.items.filter { item in
        ["client-ip", "dns-leak", "ipv6"].contains(item.id)
    }

    var body: some View {
        PageScaffold {
            Card(
                title: "Настройка вручную",
                systemImage: "hand.tap",
                subtitle: "Клиентская сторона настраивается в приложении AmneziaVPN на этом Mac — приложение показывает порядок действий"
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(clientSteps.enumerated()), id: \.offset) { index, step in
                        stepRow(index: index, title: step.title, text: step.text)
                    }
                }
            }

            Card(
                title: "Проверка после подключения",
                systemImage: "checklist",
                subtitle: "Эти пункты выполняются вручную на клиенте"
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(clientChecks) { check in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title)
                                .font(.callout)
                                .fontWeight(.semibold)
                            Text(check.instruction)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .navigationTitle("Клиент")
    }

    private func stepRow(index: Int, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20, height: 20)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .accessibilityLabel("Шаг \(index + 1)")
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout)
                    .fontWeight(.semibold)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
