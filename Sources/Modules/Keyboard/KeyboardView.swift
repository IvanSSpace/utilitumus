import SwiftUI

/// Экран модуля «Клавиатура»: список фишек со своими переключателями, у раскрытой видны её настройки.
/// Внизу общий блок «Починить» и «Журнал».
struct KeyboardView: View {
    @ObservedObject var controller = KeyboardController.shared
    /// Аккордеон: раскрыта одна фишка. Сначала — первая из включённых, чтобы настройки были под рукой.
    @State private var expanded: KeyboardFeature? = KeyboardFeature.enabled.first
    @State private var logShown = false

    var body: some View {
        DSPage(module: .keyboard, subtitle: "Фишки для клавиатуры: язык, раскладки, клавиши") {
            if controller.isOn(.fnLanguage), controller.secureInputApp != nil { warnings }

            DSSection("Фишки") {
                ForEach(KeyboardFeature.allCases) { feature in
                    featureRow(feature)
                    if expanded == feature, feature.isAvailable { settings(feature) }
                }
            }

            commonSection
        }
        .onPageActive { if $0 { controller.refreshAccess(); controller.refreshSystem() } }
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
                    DSToggle(feature.title, isOn: Binding(get: { controller.isOn(feature) },
                                                          set: { controller.setFeature(feature, on: $0) }))
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
        Group {
            DSRow(title: "Когда менять язык",
                  subtitle: "«При нажатии» быстрее, но сработает и при Fn+другая клавиша") {
                DSSegmented(FnTrigger.allCases, selection: $controller.trigger) { $0.title }
            }
            DSRow(title: "Какой язык следующий", subtitle: "Порядок раскладок — как в системе") {
                DSSegmented(LayoutMode.allCases, selection: $controller.mode) { $0.title }
            }
            DSRow(title: status.text, subtitle: "Сейчас включена: \(controller.currentName)") {
                Image(systemName: status.icon).foregroundStyle(status.color)
            }
            // Отключить действие можно в чек-листе настройки (плашка сверху).
            DSRow(title: "Системное действие 🌐",
                  subtitle: controller.systemUsage == 0 ? "Отключено, второго переключения не будет"
                      : "macOS тоже переключит язык, и он сменится дважды. Отключается в настройке модуля") {
                DSChip(FnSystemAction.title(for: controller.systemUsage),
                       color: controller.systemUsage == 0 ? .green : .orange,
                       icon: controller.systemUsage == 0 ? "checkmark" : "exclamationmark.triangle.fill")
            }
        }
        .background(.white.opacity(0.03))
    }

    private var status: (text: String, icon: String, color: Color) {
        if !controller.inputAccess {
            return ("Нет доступа «Мониторинг ввода», клавиша не слышна", "exclamationmark.triangle", .orange)
        }
        return controller.tapActive
            ? ("Слушаю клавишу Fn, тап переключает язык сразу", "checkmark.circle.fill", .green)
            : ("Запускаю прослушивание…", "hourglass", .secondary)
    }

    /// Защищённый ввод: пока он включён, macOS не отдаёт нажатия. Остальные конфликты решает чек-лист настройки.
    private var warnings: some View {
        DSSection("Конфликты с системой") {
            if let app = controller.secureInputApp {
                DSRow(icon: "lock.fill", title: "Сейчас Fn не слышно",
                      subtitle: "Защищённый ввод в «\(app)»: пока он включён, macOS не отдаёт нажатия. Выйди из поля пароля или отключи Secure Keyboard Entry.",
                      iconTint: .orange) { EmptyView() }
            }
        }
    }

    // MARK: Раскладка для каждого приложения

    private var perAppSettings: some View {
        Group {
            DSRow(title: "Новые приложения начинают с:",
                  subtitle: "Для приложения, где ещё не меняли язык") {
                newAppMenu
            }
            DSRow(title: "Не трогать в этих приложениях",
                  subtitle: controller.excludedApps.isEmpty ? "Список пуст" : nil) {
                DSButton("Добавить…", icon: "plus", small: true) {
                    if let id = VoiceExcludedApps.pick(message: "Выбери программу, где раскладку не менять") {
                        controller.addExcluded(id)
                    }
                }
                .fixedSize()
            }
            if !controller.excludedApps.isEmpty { excludedList }
        }
        .background(.white.opacity(0.03))
    }

    private var newAppMenu: some View {
        Menu {
            Button { controller.newAppLayout = nil } label: {
                Label("Как было", systemImage: controller.newAppLayout == nil ? "checkmark" : "")
            }
            ForEach(controller.layouts) { layout in
                Button { controller.newAppLayout = layout.id } label: {
                    Label(layout.name, systemImage: controller.newAppLayout == layout.id ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .bold))
                Text(controller.newAppLayout.map(controller.layoutName) ?? "Как было")
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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(controller.excludedApps, id: \.self) { id in
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
                        DSButton("Убрать", style: .plain, small: true) { controller.removeExcluded(id) }
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
                  subtitle: controller.repairResult ?? "Если «Язык по Fn» не работает: сбросит системное действие, пересоздаст прослушивание и сверит раскладку") {
                DSButton("Починить", small: true) { controller.repair() }
            }
            DSRow(icon: "doc.text", title: "Журнал (\(controller.logCount))",
                  subtitle: "Пришли его, если что-то перестало работать") {
                HStack(spacing: 8) {
                    DSButton("Скопировать журнал", icon: "doc.on.doc", small: true) { controller.copyLog() }
                    DSButton(logShown ? "Скрыть" : "Показать", small: true) { logShown.toggle() }
                }
            }
            if logShown {
                ForEach(Array(controller.logTail.enumerated()), id: \.offset) { _, entry in
                    DSRow(title: "\(KeyboardLog.shortTime(entry.date))  \(entry.text)") { EmptyView() }
                }
            }
        }
    }
}
