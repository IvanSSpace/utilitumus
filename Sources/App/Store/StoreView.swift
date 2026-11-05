import SwiftUI

// Страница «Стор», направление V1 «Витрина»: крупная рекомендация, ниже ряды плиток по категориям.
// Клик по плитке открывает подробности поверх страницы. Переходы — 0,2 с, без пружин.

struct StoreView: View {
    @ObservedObject private var store = StoreModel.shared
    @Environment(\.dsTheme) private var theme

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 14) {
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
            }
            .padding(DS.pagePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let module = store.detail {
                StoreDetail(module: module)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
    }
}

// MARK: - Витрина

private struct StoreShowcase: View {
    @Environment(\.dsTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StoreFeatured(module: StoreModel.featured)
            ForEach(ModuleCategory.all) { category in
                StoreShelf(category: category)
            }
        }
    }
}

/// Крупная рекомендация сверху.
private struct StoreFeatured: View {
    let module: Module
    @ObservedObject private var store = StoreModel.shared
    @Environment(\.dsTheme) private var theme

    var body: some View {
        let cat = theme.categoryColor(module.category)
        HStack(spacing: 16) {
            ModuleIconBadge(module: module, size: 68)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    DSChip("Рекомендуем", color: cat, icon: "star.fill")
                    DSChip(module.category.title, color: .white.opacity(0.7))
                }
                Text(module.title).font(.system(size: 21, weight: .bold, design: .rounded))
                Text(module.info.tagline).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                StoreMeta(module: module)
            }
            Spacer(minLength: 12)
            VStack(spacing: 6) {
                StoreActionButton(id: .module(module), small: false)
                DSButton("Подробнее", style: .plain, small: true) { store.open(module) }
            }
            .fixedSize()
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(height: 112)
        .background(
            RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous)
                .fill(LinearGradient(colors: [cat.opacity(0.34), cat.opacity(0.10)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous)
            .stroke(cat.opacity(0.4), lineWidth: 0.8))
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
        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
    }
}

/// Ряд категории: заголовок с цветной меткой и плитки по три в строке.
private struct StoreShelf: View {
    let category: ModuleCategory
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
        let rows = stride(from: 0, to: items.count, by: 3).map { Array(items[$0..<min($0 + 3, items.count)]) }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Capsule().fill(theme.categoryColor(category)).frame(width: 3, height: 12)
                Text(category.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                Text(category.subtitle).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.42))
            }
            .padding(.horizontal, 4)
            VStack(spacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        ForEach(row) { item in
                            switch item {
                            case .module(let m): StoreTile(module: m)
                            case .soon(let s): StoreSoonTile(soon: s, category: category)
                            }
                        }
                        if row.count < 3 { ForEach(0..<(3 - row.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) } }
                    }
                }
            }
        }
    }
}

/// Плитка модуля: значок, имя, строка «что делает», размер и разрешения, справа состояние.
private struct StoreTile: View {
    let module: Module
    @ObservedObject private var store = StoreModel.shared
    @Environment(\.dsTheme) private var theme

    var body: some View {
        let cat = theme.categoryColor(module.category)
        let state = store.state(module)
        let installed = state == .installed
        HStack(spacing: 10) {
            ModuleIconBadge(module: module, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(module.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(module.info.tagline).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                StoreMeta(module: module, short: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StoreGlyph(state: state, update: store.hasUpdate(.module(module)), tint: cat)
        }
        .padding(.horizontal, 11)
        .frame(height: 62)
        .hoverFill(RoundedRectangle(cornerRadius: 12, style: .continuous),
                   normal: cat.opacity(installed ? 0.16 : 0.08), hovered: cat.opacity(0.22))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(cat.opacity(installed ? 0.38 : 0.16), lineWidth: 0.7))
        .onTapGesture { store.open(module) }
        .accessibilityAddTraits(.isButton)
    }
}

/// Плитка «Скоро»: серая, не открывается.
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
            VStack(alignment: .leading, spacing: 1) {
                Text(soon.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(soon.tagline).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            DSChip("Скоро", color: cat)
        }
        .padding(.horizontal, 11)
        .frame(height: 62)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(.white.opacity(0.12), style: StrokeStyle(lineWidth: 0.7, dash: [4, 3])))
        .opacity(0.8)
    }
}

/// Значок состояния справа в плитке: установлен, можно поставить, идёт установка.
struct StoreGlyph: View {
    let state: StoreState
    let update: Bool
    let tint: Color

    var body: some View {
        Group {
            switch state {
            case .installed:
                Image(systemName: update ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(update ? Color.orange : Color.green)
            case .available:
                Image(systemName: "plus.circle").foregroundStyle(.white.opacity(0.55))
            case .installing(let stage, let p):
                let done = (Double(stage.rawValue) + p) / Double(StoreStage.allCases.count)
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 2.5)
                    Circle().trim(from: 0, to: done).stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 17, height: 17)
            }
        }
        .font(.system(size: 19))
        .frame(width: 22)
    }
}

/// Главная кнопка по состоянию: Установить / Обновить ресурсы / «Установлен» / процент.
struct StoreActionButton: View {
    let id: StoreItemID
    var small = true
    @ObservedObject private var store = StoreModel.shared

    var body: some View {
        switch store.state(id) {
        case .available:
            DSButton("Установить", icon: "arrow.down.circle.fill", style: .primary, small: small) { store.install(id) }
        case .installing(let stage, let p):
            let done = (Double(stage.rawValue) + p) / Double(StoreStage.allCases.count)
            DSButton("\(Int(done * 100))% · \(stage.title)", style: .secondary, small: small) { store.cancel(id) }
                .help("Отменить установку")
        case .installed:
            if store.hasUpdate(id) {
                DSButton("Обновить ресурсы", icon: "arrow.triangle.2.circlepath", style: .primary, small: small) {
                    store.update(id)
                }
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
                    Text("Наборы подписаны ключом Utilitumus").font(.system(size: 13, weight: .semibold))
                    Text("Перед установкой приложение сверяет подпись: чужие или изменённые данные не примет")
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 8)
                DSChip("Ключ v1", color: .green)
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
    @ObservedObject private var store = StoreModel.shared
    @Environment(\.dsTheme) private var theme

    var body: some View {
        let packs = StorePack.all.filter { $0.group == group }
        let tint = theme.tone(group.module)
        let have = packs.filter { store.state(.pack($0.id)) == .installed }.count
        DSSection(group.title, trailing: "\(have) из \(packs.count)", mark: theme.categoryColor(group.module.category)) {
            ForEach(packs) { pack in
                DSRow(icon: group.icon, title: pack.title, subtitle: "\(pack.sizeText) · \(pack.detail)", iconTint: tint) {
                    PackAction(id: .pack(pack.id))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PackAction: View {
    let id: StoreItemID
    @ObservedObject private var store = StoreModel.shared

    var body: some View {
        switch store.state(id) {
        case .available:
            DSButton("Скачать", icon: "arrow.down", style: .secondary, small: true) { store.install(id) }
        case .installing(let stage, let p):
            HStack(spacing: 7) {
                StoreProgressBar(value: (Double(stage.rawValue) + p) / Double(StoreStage.allCases.count))
                    .frame(width: 54)
                Text(stage == .download ? "качаю" : "проверяю").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
        case .installed:
            HStack(spacing: 4) {
                DSChip("Есть", color: .green, icon: "checkmark")
                DSButton("", icon: "trash", style: .plain, small: true) { store.remove(id) }
                    .help("Удалить набор")
            }
        }
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
