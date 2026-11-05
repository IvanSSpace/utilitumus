import SwiftUI

// Подробности модуля: разрешения с объяснением, что скачается и куда, кнопки. Лежит поверх страницы стора.

struct StoreDetail: View {
    let module: Module
    @ObservedObject private var store = StoreModel.shared
    @Environment(\.dsTheme) private var theme

    var body: some View {
        let cat = theme.categoryColor(module.category)
        let id = StoreItemID.module(module)
        let state = store.state(id)
        let needs = StoreCatalog.needs(module)
        let download = StoreCatalog.downloads(module)
        ZStack {
            Color.black.opacity(0.5)
                .contentShape(Rectangle())
                .onTapGesture { store.close() }
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    ModuleIconBadge(module: module, size: 56)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(module.title).font(.system(size: 22, weight: .bold, design: .rounded))
                        HStack(spacing: 6) {
                            DSChip(module.category.title, color: cat, icon: module.category.icon)
                            if state == .installed {
                                DSChip(store.hasUpdate(id) ? "Есть обновление" : "Установлен",
                                       color: store.hasUpdate(id) ? .orange : .green,
                                       icon: store.hasUpdate(id) ? "arrow.down" : "checkmark")
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    DSButton("", icon: "xmark", style: .plain, small: true) { store.close() }
                        .help("Закрыть")
                }
                Text(module.summary).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)

                DSSection("Разрешения", trailing: needs.isEmpty ? "не нужны" : "спросим при установке") {
                    if needs.isEmpty {
                        DSRow(icon: "checkmark.shield.fill", title: "Ничего не просит",
                              subtitle: "Работает без особых разрешений", iconTint: .green)
                    } else {
                        ForEach(needs) { need in
                            DSRow(icon: need.permission.icon, title: need.permission.title,
                                  subtitle: need.why, iconTint: cat)
                        }
                    }
                }

                DSSection("Что скачается и куда", trailing: StoreCatalog.sizeText(module)) {
                    if let download {
                        DSRow(icon: "arrow.down.circle.fill", title: "+\(download.megabytes) МБ, \(download.kind)",
                              subtitle: download.path, iconTint: cat)
                        DSRow(icon: "checkmark.seal.fill", title: "Подпись Utilitumus",
                              subtitle: "Проверим до распаковки", iconTint: .green)
                    } else {
                        DSRow(icon: "shippingbox.fill", title: "Всё уже в приложении",
                              subtitle: "Ничего не скачивается, хранятся только настройки", iconTint: cat)
                    }
                }

                if case .installing(let stage, let p) = state {
                    StoreStages(stage: stage, progress: p, tint: cat)
                }

                HStack(spacing: 8) {
                    Text(state == .installed ? "Удаление сотрёт скачанное и настройки модуля"
                                             : "Прототип: установка имитируется")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).lineLimit(2)
                    Spacer(minLength: 8)
                    HStack(spacing: 8) { buttons(id: id, state: state) }.fixedSize()
                }
            }
            .padding(22)
            .frame(width: 520)
            .background(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                .fill(Color(hue: module.category.hue, saturation: 0.40, brightness: 0.17)))
            .overlay(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                .stroke(cat.opacity(0.45), lineWidth: 0.8))
            .environment(\.dsTint, theme.accent(module))
        }
    }

    @ViewBuilder
    private func buttons(id: StoreItemID, state: StoreState) -> some View {
        switch state {
        case .available:
            DSButton("Закрыть", style: .secondary) { store.close() }
            DSButton("Установить", icon: "arrow.down.circle.fill", style: .primary) { store.install(id) }
        case .installing:
            DSButton("Отменить", style: .secondary) { store.cancel(id) }
        case .installed:
            DSButton("Удалить", icon: "trash", style: .secondary) { store.remove(id) }
            if store.hasUpdate(id) {
                DSButton("Обновить ресурсы", icon: "arrow.triangle.2.circlepath", style: .primary) { store.update(id) }
            } else {
                DSButton("Готово", style: .primary) { store.close() }
            }
        }
    }
}

/// Три этапа установки: скачивание → проверка подписи → разрешения. Текущий с полосой.
private struct StoreStages: View {
    let stage: StoreStage
    let progress: Double
    let tint: Color
    @Environment(\.dsTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(StoreStage.allCases, id: \.rawValue) { s in
                let done = s.rawValue < stage.rawValue
                let current = s == stage
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: done ? "checkmark.circle.fill" : (current ? "circle.dotted" : "circle"))
                            .foregroundStyle(done ? Color.green : (current ? tint : .white.opacity(0.3)))
                        Text(s.title).font(.system(size: 11.5, weight: current ? .semibold : .medium))
                            .foregroundStyle(.white.opacity(done || current ? 0.95 : 0.4))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    StoreProgressBar(value: done ? 1 : (current ? progress : 0), tint: done ? .green : tint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if s != StoreStage.allCases.last {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.25)).padding(.top, 4)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous).fill(theme.group))
    }
}
