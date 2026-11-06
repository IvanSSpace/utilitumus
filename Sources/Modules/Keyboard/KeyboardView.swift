import SwiftUI

/// Экран модуля «Клавиатура»: список фишек со своими переключателями, у раскрытой видны её настройки.
/// Внизу общий блок «Починить» и «Журнал».
struct KeyboardView<Model: KeyboardModel>: View {
    @ObservedObject var model: Model
    /// Аккордеон: раскрыта одна фишка. Сначала — первая из включённых, чтобы настройки были под рукой.
    @State private var expanded: KeyboardFeature?
    @State private var logShown = false

    init(model: Model) {
        self.model = model
        _expanded = State(initialValue: KeyboardFeature.allCases.first { model.isOn($0) })
    }

    var body: some View {
        DSPage(module: .keyboard, subtitle: "Фишки для клавиатуры: язык, раскладки, клавиши") {
            if model.isOn(.fnLanguage), model.secureInputApp != nil { warnings }

            DSSection("Фишки") {
                ForEach(KeyboardFeature.allCases) { feature in
                    featureRow(feature)
                    if expanded == feature, feature.isAvailable { settings(feature) }
                }
            }

            commonSection
        }
        .onPageActive { if $0 { model.refreshAccess(); model.refreshSystem() } }
    }

    // MARK: Строка фишки

    private func featureRow(_ feature: KeyboardFeature) -> some View {
        let open = expanded == feature
        return DSRow(icon: feature.icon, title: feature.title, subtitle: feature.tagline) {
            if feature.isAvailable {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    DSToggle(feature.title, isOn: Binding(get: { model.isOn(feature) },
                                                          set: { model.setFeature(feature, on: $0) }))
                }
            } else {
                DSChip("Скоро")
            }
        }
        .opacity(feature.isAvailable ? 1 : 0.6)
        .contentShape(Rectangle())
        .onTapGesture {
            guard feature.isAvailable else { return }
            withAnimation(.easeOut(duration: 0.15)) { expanded = open ? nil : feature }
        }
    }

    @ViewBuilder private func settings(_ feature: KeyboardFeature) -> some View {
        switch feature {
        case .fnLanguage: fnSettings
        case .perAppLayout: perAppSettings
        case .capsLock: EmptyView()
        }
    }

    // MARK: Язык по Fn

    private var fnSettings: some View {
        FeatureSettings {
            DSRow(title: "Когда менять язык",
                  subtitle: "«При нажатии» быстрее, но сработает и при Fn+клавиша") {
                DSSegmented(FnTrigger.allCases, selection: $model.trigger) { $0.title }
            }
            DSRow(title: "Какой язык следующий", subtitle: "Порядок раскладок — как в системе") {
                DSSegmented(LayoutMode.allCases, selection: $model.mode) { $0.title }
            }
            DSRow(title: status.text, subtitle: "Сейчас включена: \(model.currentName)") {
                Image(systemName: status.icon).foregroundStyle(status.color)
            }
            // Отключить действие можно в чек-листе настройки (плашка сверху).
            DSRow(title: "Системное действие 🌐",
                  subtitle: model.systemUsage == 0 ? "Отключено, второго переключения не будет"
                      : "macOS тоже переключит язык, и он сменится дважды. Отключается в настройке модуля") {
                DSChip(FnSystemAction.title(for: model.systemUsage),
                       color: model.systemUsage == 0 ? .green : .orange,
                       icon: model.systemUsage == 0 ? "checkmark" : "exclamationmark.triangle.fill")
            }
        }
    }

    private var status: (text: String, icon: String, color: Color) {
        if !model.inputAccess {
            return ("Нет доступа «Мониторинг ввода», клавиша не слышна", "exclamationmark.triangle", .orange)
        }
        return model.tapActive
            ? ("Слушаю клавишу Fn, тап переключает язык сразу", "checkmark.circle.fill", .green)
            : ("Запускаю прослушивание…", "hourglass", .secondary)
    }

    /// Защищённый ввод: пока он включён, macOS не отдаёт нажатия. Остальные конфликты решает чек-лист настройки.
    private var warnings: some View {
        DSSection("Конфликты с системой") {
            if let app = model.secureInputApp {
                DSRow(icon: "lock.fill", title: "Сейчас Fn не слышно",
                      subtitle: "Защищённый ввод в «\(app)»: пока он включён, macOS не отдаёт нажатия. Выйди из поля пароля или отключи Secure Keyboard Entry.",
                      iconTint: .orange) { EmptyView() }
            }
        }
    }

    // MARK: Раскладка для каждого приложения

    private var perAppSettings: some View {
        FeatureSettings {
            DSRow(title: "Новые приложения начинают с:",
                  subtitle: "Для приложения, где ещё не меняли язык") {
                newAppMenu
            }
            DSRow(title: "Не трогать в этих приложениях",
                  subtitle: model.excludedApps.isEmpty ? "Список пуст" : nil) {
                DSButton("Добавить…", icon: "plus", small: true) {
                    if let id = VoiceExcludedApps.pick(message: "Выбери программу, где раскладку не менять") {
                        model.addExcluded(id)
                    }
                }
                .fixedSize()
            }
            if !model.excludedApps.isEmpty { excludedList }
        }
    }

    private var newAppMenu: some View {
        Menu {
            Button { model.newAppLayout = nil } label: {
                Label("Как было", systemImage: model.newAppLayout == nil ? "checkmark" : "")
            }
            ForEach(model.layouts) { layout in
                Button { model.newAppLayout = layout.id } label: {
                    Label(layout.name, systemImage: model.newAppLayout == layout.id ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .bold))
                Text(model.newAppLayout.map(model.layoutName) ?? "Как было")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 11).frame(height: 26)
            .background(Capsule().fill(.white.opacity(0.1)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var excludedList: some View {
        DSScroll(inset: 6) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.excludedApps, id: \.self) { id in
                    HStack(spacing: 10) {
                        Group {
                            if let icon = VoiceExcludedApps.icon(id) {
                                Image(nsImage: icon).resizable()
                            } else {
                                Image(systemName: "app.dashed").foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        .frame(width: 22, height: 22)
                        Text(VoiceExcludedApps.name(id)).font(DS.rowTitle).foregroundStyle(.white.opacity(0.95))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        DSButton("Убрать", style: .plain, small: true) { model.removeExcluded(id) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 4)
                }
            }
        }
        .frame(maxHeight: 100)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Общее

    private var commonSection: some View {
        DSSection("Общее") {
            DSRow(icon: "wrench.and.screwdriver.fill", title: "Починить",
                  subtitle: model.repairResult ?? "Если «Язык по Fn» не работает: сбросит системное действие и пересоздаст прослушивание") {
                DSButton("Починить", small: true) { model.repair() }
            }
            DSRow(icon: "doc.text", title: "Журнал (\(model.logCount))",
                  subtitle: "Пришли его, если что-то перестало работать") {
                HStack(spacing: 8) {
                    DSButton("Скопировать журнал", icon: "doc.on.doc", small: true) { model.copyLog() }
                    DSButton(logShown ? "Скрыть" : "Показать", small: true) { logShown.toggle() }
                }
            }
            if logShown {
                ForEach(Array(model.logTail.enumerated()), id: \.offset) { _, entry in
                    DSRow(title: "\(KeyboardLog.shortTime(entry.date))  \(entry.text)") { EmptyView() }
                }
            }
        }
    }
}

extension KeyboardView where Model == KeyboardController {
    init() { self.init(model: .shared) }
}

/// Настройки раскрытой фишки: чуть правее строк фишек и с цветной полосой слева, чтобы было видно, чьи они.
private struct FeatureSettings<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.dsTint) private var tint

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.leading, 18)
            .background(.white.opacity(0.03))
            .overlay(alignment: .leading) { Rectangle().fill(tint.opacity(0.7)).frame(width: 3) }
    }
}
