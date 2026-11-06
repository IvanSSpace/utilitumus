import SwiftUI

// Страница «Стор»: витрина V1 (рекомендация и ряды плиток по категориям), подробности как в V3 —
// плавающая панель справа поверх страницы, снизу полоса «Твоя сборка» из V2. Переходы 0,2 с, без пружин.
// Цвет страницы нейтральный (см. `DSTheme.storeTint`): модуль красит только свою плитку и карточку.

struct StoreView: View {
    @ObservedObject private var store = StoreModel.shared
    @Environment(\.dsTheme) private var theme

    var body: some View {
        // Панель живёт только на «Витрине» и лежит поверх неё: раскладка страницы не меняется.
        let detail = store.tab == .showcase ? store.detail : nil
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 12) {
                DSHeaderLayout(title: "Стор", subtitle: "Ресурсы и доступы видно до установки",
                               primary: nil, badge: { DSBadge(icon: "bag.fill") },
                               controls: {
                    DSSegmented(StoreTab.allCases, selection: $store.tab) { $0.title }
                })
                switch store.tab {
                case .showcase: StoreShowcase()
                case .packs: StorePacksTab()
                }
                Spacer(minLength: 0)
                StoreBar()
            }
            .overlay(alignment: .bottom) {
                if let failure = store.failure {
                    StoreFailureToast(failure: failure).padding(.bottom, 1).transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let module = store.justInstalled {
                    StoreToast(module: module).padding(.bottom, 1).transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(DS.pagePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let detail {
                Color.black.opacity(0.25)
                    .contentShape(Rectangle())
                    .onTapGesture { store.close() }
                    .transition(.opacity)
                StoreDetail(module: detail)
                    .frame(width: 380)
                    .padding(12)
                    .shadow(color: .black.opacity(0.4), radius: 18, x: -4, y: 4)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(.easeInOut(duration: 0.2), value: detail)
    }
}

/// Подтверждение удаления: общее для Стора и боковой панели, висит на главном окне.
struct StoreRemovalAlert: ViewModifier {
    @ObservedObject private var store = StoreModel.shared

    func body(content: Content) -> some View {
        content.alert("Удалить «\(store.pendingRemoval?.title ?? "")»?", isPresented: shown, presenting: store.pendingRemoval) { module in
            Button("Удалить", role: .destructive) { store.remove(module) }
            Button("Отмена", role: .cancel) {}
        } message: { module in
            Text((StoreCatalog.removal(module).map { "• " + $0 } + ["Настройки сохранятся, если поставишь снова."]).joined(separator: "\n"))
        }
    }

    private var shown: Binding<Bool> {
        Binding(get: { store.pendingRemoval != nil }, set: { if !$0 { store.pendingRemoval = nil } })
    }
}

// MARK: - Витрина

private struct StoreShowcase: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StoreFeatured(module: StoreModel.featured)
            ForEach(ModuleCategory.all) { StoreShelf(category: $0) }
        }
    }
}

/// Крупная рекомендация: свой цвет только внутри карточки.
private struct StoreFeatured: View {
    let module: Module
    @ObservedObject private var store = StoreModel.shared
    @Environment(\.dsTheme) private var theme

    var body: some View {
        let cat = theme.categoryColor(module.category)
        HStack(spacing: 16) {
            ModuleIconBadge(module: module, size: 58)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    DSChip("Рекомендуем", color: cat, icon: "star.fill")
                    StoreMeta(module: module)
                }
                Text(module.title).font(.system(size: 20, weight: .bold, design: .rounded))
                if let note = store.updateNotes(module).first {
                    StoreUpdateTeaser(note: note)
                } else {
                    Text(module.info.tagline).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            VStack(spacing: 4) {
                StoreActionButton(module: module, small: false)
                DSButton("Подробнее", style: .plain, small: true) { store.open(module) }
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(height: 92)
        .background(
            RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous)
                .fill(LinearGradient(colors: [cat.opacity(0.30), cat.opacity(0.08)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous)
            .stroke(cat.opacity(0.4), lineWidth: 0.8))
        .environment(\.dsTint, theme.accent(module))
        .contentShape(Rectangle())
        .onTapGesture { store.open(module) }
    }
}

/// Размер скачиваемого и значки разрешений — одной строкой.
private struct StoreMeta: View {
    let module: Module
    var short = false

    var body: some View {
        let needs = StoreCatalog.needs(module)
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: StoreCatalog.downloads(module) == nil ? "checkmark.circle" : "arrow.down.circle")
                Text(StoreCatalog.sizeText(module, short: short))
            }
            if !needs.isEmpty {
                HStack(spacing: 5) {
                    ForEach(needs) { Image(systemName: $0.permission.icon) }
                }
            }
        }
        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1).fixedSize()
    }
}

/// Ряд категории: заголовок с цветной меткой и плитки по `columns` в строке.
private struct StoreShelf: View {
    let category: ModuleCategory
    private let columns = 3
    @ObservedObject private var store = StoreModel.shared
    @Environment(\.dsTheme) private var theme

    private enum Item: Identifiable {
        case module(Module), soon(StoreSoon)
        var id: String {
            switch self {
            case .module(let m): return m.rawValue
            case .soon(let s): return s.id
            }
        }
    }

    var body: some View {
        let items = category.modules.map(Item.module) + StoreSoon.all.filter { $0.categoryID == category.id }.map(Item.soon)
        let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Capsule().fill(theme.categoryColor(category)).frame(width: 3, height: 12)
                Text(category.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                Text(category.subtitle).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.42)).lineLimit(1)
            }
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.categoryColor(category).opacity(store.highlighted == category ? 0.22 : 0))
                .padding(.vertical, -3))
            VStack(spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        ForEach(row) { item in
                            switch item {
                            case .module(let m): StoreTile(module: m)
                            case .soon(let s): StoreSoonTile(soon: s, category: category)
                            }
                        }
                        if row.count < columns {
                            ForEach(0..<(columns - row.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                        }
                    }
                }
            }
        }
    }
}

/// Плитка модуля: значок с состоянием, имя целиком, одна строка описания, размер и разрешения; сбоку (i).
private struct StoreTile: View {
    let module: Module
    @ObservedObject private var store = StoreModel.shared
    @Environment(\.dsTheme) private var theme

    var body: some View {
        let cat = theme.categoryColor(module.category)
        let state = store.state(module)
        let installed = state == .installed
        let selected = store.detail == module
        HStack(spacing: 10) {
            ModuleIconBadge(module: module, size: 36)
                .overlay(alignment: .bottomTrailing) {
                    StoreGlyph(state: state, update: store.hasUpdate(module), tint: cat).offset(x: 5, y: 5)
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(module.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .fixedSize().layoutPriority(2)
                    Spacer(minLength: 2)
                    StoreInfoButton(module: module)
                }
                Text(StoreCatalog.line(module)).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                if installed {
                    if let progress = store.pendingSetup(module) {
                        StoreSetupChip(module: module, progress: progress)
                    } else if let note = store.updateNotes(module).first {
                        StoreUpdateTeaser(note: note)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                            Text(store.isHidden(module) ? "Установлен · скрыт" : "Установлен")
                        }
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.green).lineLimit(1)
                    }
                } else if state == .available {
                    // Кнопка прямо на плитке: без неё не было понятно, как ставить (только через (i)).
                    HStack(spacing: 6) {
                        StoreMeta(module: module, short: true).layoutPriority(0)
                        Spacer(minLength: 4)
                        StoreTileInstall(module: module).layoutPriority(1)
                    }
                } else {
                    StoreMeta(module: module, short: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 11)
        .frame(height: 62)
        .hoverFill(RoundedRectangle(cornerRadius: 12, style: .continuous),
                   normal: cat.opacity(installed ? 0.15 : 0.08), hovered: cat.opacity(0.22))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(selected ? Color.white.opacity(0.6) : cat.opacity(installed ? 0.36 : 0.16),
                    lineWidth: selected ? 1.2 : 0.7))
        .contentShape(Rectangle())
        .onTapGesture { store.open(module) }
        .accessibilityAddTraits(.isButton)
    }
}

/// Первая заметка к обновлению там, где места на одну строку; все заметки в подробностях.
struct StoreUpdateTeaser: View {
    let note: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkle")
            Text(verbatim: note)
        }
        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange).lineLimit(1)
    }
}

/// Кнопка «＋» на плитке Стора: ставит модуль сразу.
private struct StoreTileInstall: View {
    let module: Module
    @ObservedObject private var store = StoreModel.shared

    var body: some View {
        Button { store.install(module) } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("Установить модуль")
    }
}

/// Мелкая плашка на плитке: «Настройка 1 из 3 · Настроить». Нажатие открывает чек-лист модуля.
struct StoreSetupChip: View {
    let module: Module
    let progress: SetupProgress
    @ObservedObject private var store = StoreModel.shared

    var body: some View {
        Button { store.configure(module) } label: {
            Text("Настройка \(progress.done) из \(progress.total) · Настроить")
                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.orange)
                .lineLimit(1).minimumScaleFactor(0.75)
                .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("Открыть чек-лист настройки модуля")
    }
}

/// Подтверждение внизу Стора после установки: без перехода, исчезает само.
private struct StoreToast: View {
    let module: Module
    @ObservedObject private var store = StoreModel.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Установлен: \(module.title)").fontWeight(.medium)
            Text("·").foregroundStyle(.white.opacity(0.4))
            DSButton("Открыть", style: .plain, small: true) { store.openInApp(module) }
        }
        .font(.system(size: 12.5))
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 6)
        .background(Capsule().fill(.regularMaterial))
        .background(Capsule().fill(.black.opacity(0.4)))
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
    }
}

/// Установка сорвалась: сама не исчезает, иначе причину можно не успеть прочитать.
private struct StoreFailureToast: View {
    let failure: StoreFailure
    @ObservedObject private var store = StoreModel.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("\(failure.module.title): \(failure.message)").fontWeight(.medium).lineLimit(2)
            if failure.offersBuiltIn {
                DSButton("Поставить встроенный", style: .secondary, small: true) { store.installBuiltIn(failure.module) }
                    .fixedSize()
            }
            DSButton("", icon: "xmark", style: .plain, small: true) { store.dismissFailure() }
                .help("Закрыть")
        }
        .font(.system(size: 12.5))
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 6)
        .background(Capsule().fill(.regularMaterial))
        .background(Capsule().fill(.black.opacity(0.4)))
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
    }
}

/// Кнопка (i): открывает боковую панель с подробностями.
private struct StoreInfoButton: View {
    let module: Module
    @ObservedObject private var store = StoreModel.shared
    @State private var hover = false

    var body: some View {
        Button { store.open(module) } label: {
            Image(systemName: store.detail == module ? "info.circle.fill" : "info.circle")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(hover || store.detail == module ? 0.95 : 0.5))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hover = $0 }
        .help("Что скачается и какие нужны доступы")
    }
}

/// Плитка «Скоро»: пунктир, нормальная плашка в третьей строке, не открывается.
private struct StoreSoonTile: View {
    let soon: StoreSoon
    let category: ModuleCategory
    @Environment(\.dsTheme) private var theme

    var body: some View {
        let cat = theme.categoryColor(category)
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(cat.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: 36, height: 36)
                .overlay(Image(systemName: soon.icon).font(.system(size: 16)).foregroundStyle(cat))
            VStack(alignment: .leading, spacing: 2) {
                Text(soon.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
                Text(soon.tagline).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                DSChip("Скоро", color: cat).fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 11)
        .frame(height: 62)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(.white.opacity(0.14), style: StrokeStyle(lineWidth: 0.7, dash: [4, 3])))
    }
}

/// Нижняя полоса: что получится в сборке и какие доступы придётся выдать.
private struct StoreBar: View {
    @ObservedObject private var store = StoreModel.shared

    var body: some View {
        let count = store.buildModules.count
        let new = store.newPermissions
        HStack(spacing: 8) {
            Image(systemName: "shippingbox.fill").foregroundStyle(.white.opacity(0.6))
            if count > 0 { Text("Установлено:").fontWeight(.semibold) }
            if count == 0 {
                Text("Пока ничего не установлено").foregroundStyle(.white.opacity(0.7))
            } else {
                Text("\(count) \(Self.plural(count)) · скачано \(store.buildMegabytes) МБ · ждут доступа:")
                    .foregroundStyle(.white.opacity(0.7))
                if new.isEmpty {
                    Text("нет").foregroundStyle(.white.opacity(0.7))
                } else {
                    ForEach(new, id: \.rawValue) { DSChip($0.title, color: .orange, icon: $0.icon) }
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12)).lineLimit(1)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
    }

    static func plural(_ n: Int) -> String {
        let last = n % 10, tens = n % 100
        if tens >= 11 && tens <= 14 { return "модулей" }
        return last == 1 ? "модуль" : (2...4).contains(last) ? "модуля" : "модулей"
    }
}

/// Значок состояния на углу иконки плитки: установлен, обновить, идёт установка. «Не стоит» — без значка.
struct StoreGlyph: View {
    let state: StoreState
    let update: Bool
    let tint: Color

    var body: some View {
        Group {
            switch state {
            case .installed:
                Image(systemName: update ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, update ? Color.orange : Color.green)
            case .available:
                EmptyView()
            case .installing(let stage, let p):
                let done = (Double(stage.rawValue) + p) / Double(StoreStage.allCases.count)
                ZStack {
                    Circle().fill(.black.opacity(0.6))
                    Circle().stroke(.white.opacity(0.2), lineWidth: 2)
                    Circle().trim(from: 0, to: done).stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
        }
        .font(.system(size: 15))
        .frame(width: 15, height: 15)
        .background(Circle().fill(.black.opacity(state == .installed ? 0.35 : 0)))
    }
}

/// Главная кнопка по состоянию: Установить / Докачать модель / «Установлен» / процент.
struct StoreActionButton: View {
    let module: Module
    var small = true
    @ObservedObject private var store = StoreModel.shared

    var body: some View {
        switch store.state(module) {
        case .available:
            DSButton("Установить", icon: "arrow.down.circle.fill", style: .primary, small: small) { store.install(module) }
        case .installing(let stage, let p):
            let done = (Double(stage.rawValue) + p) / Double(StoreStage.allCases.count)
            DSButton("\(Int(done * 100))% · \(stage.title)", style: .secondary, small: small) { store.cancel(module) }
                .help("Отменить скачивание")
        case .installed:
            if store.hasUpdate(module) {
                DSButton(store.satellites.hasBundle(module) ? "Обновить" : "Обновить ресурсы",
                         icon: "arrow.triangle.2.circlepath", style: .primary, small: small) {
                    store.downloadResources(module)
                }
            } else if let progress = store.pendingSetup(module) {
                StoreSetupChip(module: module, progress: progress)
            } else {
                DSChip("Установлен", color: .green, icon: "checkmark")
            }
        }
    }
}

// MARK: - Наборы контента

private struct StorePacksTab: View {
    @Environment(\.dsTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 20)).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Наборы контента появятся позже").font(.system(size: 13, weight: .semibold))
                    Text("Сейчас в сторе ставятся только модули; наборы будут подписаны ключом Utilitumus")
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 8)
                DSChip("Скоро", color: .green)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous).fill(.green.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous).stroke(.green.opacity(0.28), lineWidth: 0.7))

            let groups = PackGroup.allCases
            VStack(spacing: 16) {
                ForEach([Array(groups[0..<2]), Array(groups[2..<4])], id: \.first) { pair in
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(pair) { PackSection(group: $0) }
                    }
                }
            }
        }
    }
}

private struct PackSection: View {
    let group: PackGroup
    @Environment(\.dsTheme) private var theme

    var body: some View {
        let packs = StorePack.all.filter { $0.group == group }
        let tint = theme.tone(group.module)
        DSSection(group.title, trailing: "скоро", mark: theme.categoryColor(group.module.category)) {
            ForEach(packs) { pack in
                DSRow(icon: group.icon, title: pack.title, subtitle: "\(pack.sizeText) · \(pack.detail)", iconTint: tint) {
                    DSChip("Скоро", color: tint).fixedSize()
                }
                .opacity(0.6)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Полоса прогресса: без анимации пружиной, значение приходит мелкими шагами.
struct StoreProgressBar: View {
    let value: Double
    var tint: Color?
    @Environment(\.dsTint) private var envTint

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule().fill(tint ?? envTint).frame(width: max(4, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 5)
    }
}
