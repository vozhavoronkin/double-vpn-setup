import SwiftUI
import VPNChainCore

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
        AppSection(id: "status", title: "Статус", systemImage: "gauge.with.dots.needle.67percent"),
        AppSection(id: "diagnostics", title: "Диагностика", systemImage: "stethoscope"),
        AppSection(id: "client", title: "Клиент", systemImage: "laptopcomputer"),
    ]

    static func section(id: String) -> AppSection {
        all.first { $0.id == id } ?? all[0]
    }
}

/// Корневой экран: sidebar-навигация по разделам (MVVM: view читает модели).
struct AppRootView: View {
    @SceneStorage("mainSection") private var selectionID: String = AppSections.all[0].id
    @ObservedObject private var router = AppServices.shared.commands
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var selection: AppSection {
        AppSections.section(id: selectionID)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: selectionBinding) {
                Section("Цепочка") {
                    ForEach(AppSections.all) { section in
                        Label(section.title, systemImage: section.systemImage)
                            .tag(section)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .focusedSceneValue(\.appActions, appActions)
    }

    private var selectionBinding: Binding<AppSection?> {
        Binding(
            get: { selection },
            set: { newValue in
                if let newValue {
                    selectionID = newValue.id
                }
            }
        )
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection.id {
        case "connections": ConnectionsView()
        case "install": InstallView()
        case "status": StatusView()
        case "diagnostics": DiagnosticsView()
        case "client": ClientView()
        default: Text("Неизвестный раздел")
        }
    }

    /// Действия для меню «Цепочка». Пересчитываются при изменении профилей и навигации.
    private var appActions: AppActions {
        let store = AppServices.shared.profiles
        let entryReady = store.profile(for: .entry).map { store.isReady($0) } == true
        let exitReady = store.profile(for: .exit).map { store.isReady($0) } == true
        return AppActions(
            refreshStatus: { open(.refreshStatus, section: "status") },
            startInstall: { open(.startInstall, section: "install") },
            runDiagnostics: { open(.runDiagnostics, section: "diagnostics") },
            toggleSidebar: { toggleSidebar() },
            sidebarVisible: columnVisibility != .detailOnly,
            canStartInstall: entryReady && exitReady
        )
    }

    private func open(_ command: AppCommand, section id: String) {
        selectionID = id
        router.send(command)
    }

    private func toggleSidebar() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
    }
}
// MARK: - Заглушки разделов удалены: все экраны рабочие (2.5, 5.5, 6.5, 7.1)
