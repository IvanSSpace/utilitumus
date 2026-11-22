import SwiftUI

/// Экран модуля «Студия»: родной, без страницы внутри. Сетка утилит с мастерами, фильтры и поиск, панель выбранной утилиты,
/// задачи хаба, «Записать дела». Всё идёт через утилиту: у экрана нет токена, сети и доступа к диску. Страница Студии остаётся
/// запасной: «Открыть в браузере» просит у утилиты одноразовый код.
struct StudioView<Model: StudioModel>: View {
    @ObservedObject var model: Model
    @State private var filter = StudioFilter.all
    @State private var query = ""
    @State private var showSettings = false
    @State private var toast: StudioNotice?
    @Environment(\.dsTint) private var tint
    @Environment(\.dsTheme) private var theme
    @Environment(\.moduleControls) private var moduleControls

    init(model: Model) { self.model = model }

    var body: some View {
        let state = model.state
        DSScroll {
            VStack(alignment: .leading, spacing: 14) {
                DSHeaderLayout(title: Module.studio.title, subtitle: subtitle(state), primary: commitAction(state),
                               badge: { ModuleIconBadge(module: .studio, size: 50) },
                               controls: { headerControls(state) })
                if let board = state.board, state.phase == .running {
                    StudioBoardView(model: model, board: board, filter: $filter, query: $query)
                } else {
                    StudioIdleView(model: model)
                }
            }
            .padding(DS.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.dsTint, theme.accent(.studio))
        .preference(key: DSPageKey.self, value: true)
        .overlay(alignment: .bottom) { toastView }
        .onChange(of: state.board?.notice) {
            if let notice = state.board?.notice { show(notice) }
        }
        .onChange(of: model.actionError) {
            if let text = model.actionError { show(StudioNotice(id: -1, text: text, isError: true)) }
        }
    }

    // MARK: Шапка

    private func subtitle(_ state: StudioState) -> String {
        guard let board = state.board, state.phase == .running else { return "Утилиты, мастера и дела в одном месте" }
        let utilities = board.units.filter { $0.kind == .utility }
        let work = utilities.filter { $0.statusKey == .work }.count
        let tasks = utilities.reduce(0) { $0 + $1.openTasks }
        return "\(utilities.count) утилит · в работе \(work) · открытых задач \(tasks)"
    }

    private func commitAction(_ state: StudioState) -> DSAction? {
        guard state.phase == .running, let board = state.board else { return nil }
        return board.working.contains("commit") ? nil : DSAction("Записать дела", icon: "square.and.arrow.down") { model.send(.commitCases) }
    }

    private func headerControls(_ state: StudioState) -> some View {
        HStack(spacing: 8) {
            StudioServerPill(state: state)
            if state.phase == .running {
                DSButton("В браузере", icon: "safari", style: .plain, small: true) { model.openInBrowser() }
                    .help("Страница Студии в браузере по умолчанию: запасной путь")
            }
            Button { showSettings.toggle() } label: {
                Image(systemName: "gearshape").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    .frame(width: 26, height: 26).hoverFill(Circle(), normal: .clear, hovered: .white.opacity(0.1))
            }
            .buttonStyle(.plain).focusEffectDisabled().help("Папка Студии").accessibilityLabel("Настройки Студии")
            .popover(isPresented: $showSettings, arrowEdge: .bottom) { StudioSettingsPopover(model: model) }
            moduleControls(.studio)
        }
    }

    // MARK: Уведомление

    @ViewBuilder private var toastView: some View {
        if let toast {
            HStack(spacing: 8) {
                Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(toast.isError ? Color(red: 1.0, green: 0.7, blue: 0.25) : Color(red: 0.35, green: 0.84, blue: 0.5))
                Text(toast.text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.92)).lineLimit(3)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(Color(white: 0.12, opacity: 0.96)))
            .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.7))
            .padding(.bottom, 18)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
        }
    }

    private func show(_ notice: StudioNotice) {
        toast = notice
        Task {
            try? await Task.sleep(for: .seconds(notice.isError ? 6 : 3.5))
            if toast == notice { withAnimation(.easeOut(duration: 0.2)) { toast = nil } }
        }
    }
}

/// Состояние сервера точкой и словом в шапке.
struct StudioServerPill: View {
    let state: StudioState

    var body: some View {
        let (color, text): (Color, String) = {
            switch state.phase {
            case .running: return (Color(red: 0.35, green: 0.84, blue: 0.5), state.board?.problem == nil ? "Работает" : "Не отвечает")
            case .starting: return (Color(red: 1.0, green: 0.7, blue: 0.25), "Запускается")
            case .stopped: return (.white.opacity(0.35), "Остановлена")
            case .failed: return (Color(red: 1.0, green: 0.42, blue: 0.38), "Ошибка")
            }
        }()
        HStack(spacing: 6) {
            Circle().fill(state.phase == .running && state.board?.problem != nil ? Color(red: 1.0, green: 0.7, blue: 0.25) : color)
                .frame(width: 7, height: 7)
            Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(.white.opacity(0.08)))
        .help(state.phase == .running ? (state.ownsServer ? "Запущена этим модулем: выключишь модуль — остановится"
                                                          : "Запущена не здесь: выключишь модуль — продолжит работать") : (state.message ?? ""))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Студия: \(text)")
    }
}

/// Маленькие настройки: путь к папке и подключение заново. Не большим блоком на странице.
struct StudioSettingsPopover<Model: StudioModel>: View {
    @ObservedObject var model: Model
    @State private var folderText = ""
    @State private var edited = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ПАПКА СТУДИИ").font(DS.sectionTitle).tracking(0.8).foregroundStyle(.white.opacity(0.42))
            StudioFolderField(model: model, text: $folderText, edited: $edited)
            Text(model.state.ownsServer && model.state.phase == .running
                 ? "Сервер запущен этим модулем: выключишь модуль — остановится."
                 : "Абсолютный путь к папке, где лежит файл studio.")
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
            if model.state.phase != .stopped || !model.state.folder.isEmpty {
                DSButton("Подключиться заново", icon: "arrow.clockwise", small: true) { model.send(.reconnect) }
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { folderText = model.state.folder }
    }
}

/// Поле пути и «Сохранить»: одно и там же в поповере и на пустом экране.
struct StudioFolderField<Model: StudioModel>: View {
    @ObservedObject var model: Model
    @Binding var text: String
    @Binding var edited: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $text, prompt: Text("/путь/к/папке"))
                .textFieldStyle(.plain).font(.system(size: 12.5))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.08)))
                .onChange(of: text) { edited = text != model.state.folder }
                .onSubmit(save)
                .accessibilityLabel("Путь к папке Студии")
            DSButton("Сохранить", small: true, action: save)
        }
    }

    private func save() {
        model.setFolder(text.trimmingCharacters(in: .whitespacesAndNewlines))
        edited = false
    }
}

/// Пока сервер не работает: что случилось и что сделать. Без снимка утилит показывать нечего.
struct StudioIdleView<Model: StudioModel>: View {
    @ObservedObject var model: Model
    @State private var folderText = ""
    @State private var edited = false

    var body: some View {
        let state = model.state
        VStack(spacing: 14) {
            Image(systemName: icon(state)).font(.system(size: 30, weight: .light)).foregroundStyle(color(state))
            Text(title(state)).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
            if let message = state.message {
                Text(message).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 440)
            }
            if state.phase == .starting {
                ProgressView().controlSize(.small)
            } else {
                StudioFolderField(model: model, text: $folderText, edited: $edited).frame(maxWidth: 440)
                if state.phase == .failed {
                    DSButton("Подключиться заново", icon: "arrow.clockwise", style: .primary, small: true) { model.send(.reconnect) }
                }
            }
            if state.phase == .running {
                // Сервер работает, снимка ещё нет: первый опрос идёт.
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous).fill(.white.opacity(0.04)))
        .onAppear { if !edited { folderText = state.folder } }
        .onChange(of: state.folder) { if !edited { folderText = model.state.folder } }
    }

    private func icon(_ state: StudioState) -> String {
        switch state.phase {
        case .running: return "hourglass"
        case .starting: return "hourglass"
        case .stopped: return state.folder.isEmpty ? "folder.badge.questionmark" : "pause.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private func color(_ state: StudioState) -> Color {
        state.phase == .failed ? Color(red: 1.0, green: 0.7, blue: 0.25) : .white.opacity(0.45)
    }

    private func title(_ state: StudioState) -> String {
        switch state.phase {
        case .running: return "Читаю состояние Студии"
        case .starting: return "Студия запускается"
        case .stopped: return state.folder.isEmpty ? "Укажи папку Студии" : "Студия остановлена"
        case .failed: return "Студия не работает"
        }
    }
}
