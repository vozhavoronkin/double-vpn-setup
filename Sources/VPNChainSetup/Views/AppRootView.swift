import SwiftUI

/// Разделы главного окна приложения.
struct AppSection: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
}

enum AppSections {
    static let all: [AppSection] = [
        AppSection(id: "connections", title: "Подключения", systemImage: "server.rack"),
        AppSection(id: "install", title: "Установка", systemImage: "arrow.down.circle"),
        AppSection(id: "status", title: "Статус", systemImage: "gauge"),
        AppSection(id: "diagnostics", title: "Диагностика", systemImage: "stethoscope"),
        AppSection(id: "client", title: "Клиент", systemImage: "laptopcomputer"),
    ]
}

/// Корневой экран: sidebar-навигация по разделам (MVVM: view читает модели).
struct AppRootView: View {
    @State private var selection: AppSection = AppSections.all[0]

    var body: some View {
        NavigationSplitView {
            List(AppSections.all, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            detailView(for: selection)
        }
    }

    @ViewBuilder
    private func detailView(for section: AppSection) -> some View {
        switch section.id {
        case "connections": ConnectionsView()
        case "install": InstallView()
        case "status": StatusView()
        case "diagnostics": DiagnosticsView()
        case "client": ClientView()
        default: Text("Неизвестный раздел")
        }
    }
}
// MARK: - Заглушки разделов удалены: все экраны рабочие (2.5, 5.5, 6.5, 7.1)
