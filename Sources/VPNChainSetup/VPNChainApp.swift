import SwiftUI

@main
struct VPNChainApp: App {
    var body: some Scene {
        WindowGroup {
            AppRootView()
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1040, height: 700)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            VPNChainCommands()
        }
    }
}

/// Действия, которые меню и toolbar передают активному окну.
struct AppActions {
    let refreshStatus: () -> Void
    let startInstall: () -> Void
    let runDiagnostics: () -> Void
    let toggleSidebar: () -> Void
    let sidebarVisible: Bool
    let canStartInstall: Bool
}

private struct AppActionsKey: FocusedValueKey {
    typealias Value = AppActions
}

extension FocusedValues {
    var appActions: AppActions? {
        get { self[AppActionsKey.self] }
        set { self[AppActionsKey.self] = newValue }
    }
}

/// Меню приложения: стандартные меню macOS + «Цепочка» с командами, доступными из любого раздела.
struct VPNChainCommands: Commands {
    @FocusedValue(\.appActions) private var actions

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button(actions?.sidebarVisible == false ? "Показать боковую панель" : "Скрыть боковую панель") {
                actions?.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(actions == nil)
        }
        CommandMenu("Цепочка") {
            Button("Обновить статус") {
                actions?.refreshStatus()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(actions == nil)

            Button("Начать установку") {
                actions?.startInstall()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(actions?.canStartInstall != true)

            Button("Диагностировать") {
                actions?.runDiagnostics()
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(actions == nil)
        }
    }
}
