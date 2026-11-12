import SwiftUI

/// Токены оформления: единая сетка отступов, радиусы, ширина контента.
/// Значения подобраны по HIG (сетка кратна 4), чтобы экраны не расходились в отступах.
enum AppTheme {
    static let pagePadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 16
    static let cardPadding: CGFloat = 16
    static let rowSpacing: CGFloat = 10
    static let cardRadius: CGFloat = 10
    static let smallRadius: CGFloat = 6
    /// Максимальная ширина колонки контента: на широких окнах текст не растягивается в строку.
    static let pageMaxWidth: CGFloat = 960
}

// MARK: - Карточка

/// Базовая карточка экрана: необязательный заголовок с иконкой, подзаголовком и аксессуаром
/// (например, статус-пилюлей), затем содержимое.
struct Card<Accessory: View, Content: View>: View {
    private let title: String?
    private let systemImage: String?
    private let subtitle: String?
    private let tint: Color
    private let accessory: Accessory
    private let content: Content

    init(
        title: String? = nil,
        systemImage: String? = nil,
        subtitle: String? = nil,
        tint: Color = .accentColor,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.tint = tint
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.rowSpacing) {
            if title != nil || subtitle != nil || systemImage != nil {
                header
            }
            content
        }
        .padding(AppTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            if let systemImage {
                IconBadge(systemImage: systemImage, tint: tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title).font(.headline)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
    }
}

extension Card where Accessory == EmptyView {
    init(
        title: String? = nil,
        systemImage: String? = nil,
        subtitle: String? = nil,
        tint: Color = .accentColor,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            subtitle: subtitle,
            tint: tint,
            accessory: { EmptyView() },
            content: content
        )
    }
}

// MARK: - Статус

/// Пять состояний элемента интерфейса: успех, внимание, ошибка, нейтрально, процесс.
enum StatusKind {
    case ok
    case warning
    case error
    case neutral
    case progress

    var tint: Color {
        switch self {
        case .ok: .green
        case .warning: .orange
        case .error: .red
        case .neutral: .secondary
        case .progress: .accentColor
        }
    }

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .neutral: "circle.dashed"
        case .progress: "arrow.triangle.2.circlepath"
        }
    }
}

/// Компактная пилюля состояния для заголовка карточки.
struct StatusPill: View {
    let kind: StatusKind
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            if kind == .progress {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: kind.symbol).font(.caption2)
            }
            Text(text).font(.caption).fontWeight(.medium)
        }
        .foregroundStyle(kind.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(kind.tint.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// Строка метрики: название, значение и иконка состояния.
struct MetricRow: View {
    enum State {
        case ok
        case warning
        case error
        case neutral

        var status: StatusKind {
            switch self {
            case .ok: .ok
            case .warning: .warning
            case .error: .error
            case .neutral: .neutral
            }
        }
    }

    let title: String
    let value: String
    var state: State = .neutral

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.status.symbol)
                .font(.caption)
                .foregroundStyle(state.status.tint)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(title).font(.callout)
            Spacer(minLength: 12)
            Text(value)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Сообщения

/// Inline-сообщение с человекочитаемым следующим шагом. Заменяет «просто красный текст».
struct Banner: View {
    enum Kind {
        case info
        case success
        case warning
        case error

        var status: StatusKind {
            switch self {
            case .info: .neutral
            case .success: .ok
            case .warning: .warning
            case .error: .error
            }
        }

        var symbol: String {
            switch self {
            case .info: "info.circle.fill"
            case .success: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            }
        }
    }

    let kind: Kind
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind.symbol)
                .font(.callout)
                .foregroundStyle(kind.status.tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            kind.status.tint.opacity(0.12),
            in: RoundedRectangle(cornerRadius: AppTheme.smallRadius, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

/// Пустое состояние: объясняет, почему данных нет, и предлагает действие.
struct EmptyState<Action: View>: View {
    private let systemImage: String
    private let title: String
    private let message: String
    private let action: Action

    init(
        systemImage: String,
        title: String,
        message: String,
        @ViewBuilder action: () -> Action
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.action = action()
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            action.padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .accessibilityElement(children: .contain)
    }
}

extension EmptyState where Action == EmptyView {
    init(systemImage: String, title: String, message: String) {
        self.init(systemImage: systemImage, title: title, message: message, action: { EmptyView() })
    }
}

// MARK: - Каркас страницы

/// Общий контейнер экрана: прокрутка, отступы по сетке и ограничение ширины колонки.
struct PageScaffold<Content: View>: View {
    private let maxWidth: CGFloat
    private let content: Content

    init(maxWidth: CGFloat = AppTheme.pageMaxWidth, @ViewBuilder content: () -> Content) {
        self.maxWidth = maxWidth
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                content
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppTheme.pagePadding)
        }
    }
}

// MARK: - Мелкие элементы

/// Иконка в тонированном квадрате со скруглением — визуальный маркер карточки или шага.
struct IconBadge: View {
    let systemImage: String
    var tint: Color = .accentColor
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemImage)
            .font(.headline)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                tint.opacity(0.14),
                in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// Поле формы с подписью над контролом: подпись не конкурирует с содержимым поля.
struct LabeledField<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
        }
    }
}
