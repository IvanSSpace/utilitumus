import SwiftUI

// Плавающая панель подробностей («новое / уже выдано» по живой проверке доступов): лежит справа поверх страницы стора,
// раскладка под ней не меняется. Закрытие: крестик, клик по затемнению или Esc.

struct StoreDetail: View {
    let module: Module
    @ObservedObject private var store = StoreModel.shared
    @Environment(\.dsTheme) private var theme

    var body: some View {
        let cat = theme.categoryColor(module.category)
        let state = store.state(module)
        let steps = module.setupSteps
        let app = store.satellites.catalogApp(module)
        let download = app.map {
            StoreDownload(megabytes: $0.sizeMB, kind: "приложение", path: "/Applications/Utilitumus/",
                          name: SatelliteRegistry.bundleName(module) + " " + $0.version)
        } ?? StoreCatalog.downloads(module)
        let isSatellite = store.satellites.hasBundle(module)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ModuleIconBadge(module: module, size: 42)
                VStack(alignment: .leading, spacing: 5) {
                    Text(module.title).font(.system(size: 18, weight: .bold, design: .rounded)).lineLimit(1)
                    HStack(spacing: 5) {
                        // Рядом с пометкой состояния категория не влезает в узкую панель.
                        if state == .installed {
                            DSChip(store.hasUpdate(module) ? (isSatellite ? "Есть обновление" : "Нет модели") : "Установлен",
                                   color: store.hasUpdate(module) ? .orange : .green)
                            if store.isHidden(module) { DSChip("скрыт из панели", color: .gray, icon: "eye.slash") }
                        } else {
                            DSChip(module.category.title, color: cat)
                        }
                    }
                    .fixedSize()
                }
                Spacer(minLength: 4)
                DSButton("", icon: "xmark", style: .plain, small: true) { store.close() }
                    .help("Закрыть (Esc)")
            }

            DSScroll(inset: DS.groupRadius) {
                VStack(alignment: .leading, spacing: 14) {
                    if let failure = store.failure, failure.module == module {
                        VStack(spacing: 0) {
                            noteRow(icon: "exclamationmark.triangle.fill", tint: .orange, title: "Не получилось",
                                    subtitle: failure.message, button: "Закрыть") { store.dismissFailure() }
                            if failure.offersBuiltIn {
                                noteRow(icon: "shippingbox.fill", tint: .white.opacity(0.7), title: "Можно встроенный",
                                        subtitle: "Работает прямо в Utilitumus, скачивать не нужно",
                                        button: "Поставить") { store.installBuiltIn(module) }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous).fill(theme.group))
                    }
                    if case .installing(let stage, let p) = state {
                        StoreStages(stage: stage, progress: p, tint: cat)
                    }
                    if state == .installed { installedNotes }
                    DSSection("Что делает") {
                        Text(module.summary).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14).padding(.vertical, 11)
                    }

                    DSSection(steps.allSatisfy { $0.kind == .permission } ? "Разрешения" : "Разрешения и настройка",
                              trailing: steps.isEmpty ? "не нужны" : nil) {
                        if steps.isEmpty {
                            DSRow(icon: "checkmark.shield.fill", title: "Ничего не просит",
                                  subtitle: "Работает без особых разрешений", iconTint: .green)
                        } else {
                            ForEach(steps) { StoreNeedRow(step: $0, status: $0.status) }
                        }
                    }

                    DSSection("Что скачается", trailing: download == nil ? "без загрузки" : "хэш сверим") {
                        if let download {
                            DSRow(icon: "arrow.down.circle.fill", title: "+\(download.megabytes) МБ, \(download.kind)",
                                  subtitle: "\(download.name)\n\(download.path)", iconTint: cat)
                            if let optional = download.optional {
                                DSRow(icon: "plus.circle", title: "Другая модель", subtitle: optional, iconTint: cat)
                            }
                        } else {
                            DSRow(icon: "shippingbox.fill", title: "Всё уже в приложении",
                                  subtitle: "Ничего не скачивается", iconTint: cat)
                        }
                    }

                    DSSection("Что удалится", trailing: "настройки сохранятся") {
                        ForEach(StoreCatalog.removal(module), id: \.self) { DSRow(icon: "trash.fill", title: $0, iconTint: cat) }
                    }
                }
            }

            HStack(spacing: 8) { buttons(state: state) }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        // Стеклянный фон поверх затемнённой витрины.
        .background(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous).fill(.regularMaterial))
        .background(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous).fill(.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
            .stroke(.white.opacity(0.12), lineWidth: 0.8))
        .environment(\.dsTint, theme.accent(module))
        // Esc закрывает панель.
        .background(Button("") { store.close() }.keyboardShortcut(.escape, modifiers: []).opacity(0).frame(width: 0, height: 0))
    }

    /// Что сделать с уже установленным: дойти до конца настройки, вернуть строку в панель.
    @ViewBuilder
    private var installedNotes: some View {
        let progress = store.pendingSetup(module)
        let hidden = store.isHidden(module)
        if progress != nil || hidden {
            VStack(spacing: 0) {
                if let progress {
                    noteRow(icon: "exclamationmark.circle.fill", tint: .orange,
                            title: "Настройка: \(progress.done) из \(progress.total)",
                            subtitle: "Без этого «\(module.title)» работает не полностью", button: "Настроить") { store.configure(module) }
                }
                if hidden {
                    noteRow(icon: "eye.slash", tint: .gray, title: "Скрыт из панели",
                            subtitle: "Работает в фоне, строка в «Скрытых»", button: "Показать в панели") { store.showInPanel(module) }
                }
            }
            .background(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous).fill(theme.group))
        }
    }

    private func noteRow(icon: String, tint: Color, title: String, subtitle: String, button: String,
                         action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.95))
                Text(subtitle).font(DS.rowSubtitle).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            DSButton(button, style: .secondary, small: true, action: action).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder
    private func buttons(state: StoreState) -> some View {
        switch state {
        case .available:
            DSButton("Установить", icon: "arrow.down.circle.fill", style: .primary) { store.install(module) }
        case .installing:
            DSButton("Отменить", style: .secondary) { store.cancel(module) }
        case .installed:
            DSButton("Удалить", icon: "trash", style: .secondary, small: true) { store.requestRemoval(module) }
            if store.hasUpdate(module) {
                DSButton(store.satellites.hasBundle(module) ? "Обновить" : "Обновить ресурсы",
                         icon: "arrow.triangle.2.circlepath", style: .secondary, small: true) {
                    store.downloadResources(module)
                }
            }
            DSButton("Открыть", icon: "arrow.right", style: .primary, small: true) { store.openInApp(module) }
        }
    }
}

/// Этапы скачивания столбиком: скачивание, проверка хэша. У текущего — полоса.
private struct StoreStages: View {
    let stage: StoreStage
    let progress: Double
    let tint: Color
    @Environment(\.dsTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(StoreStage.allCases, id: \.rawValue) { s in
                let done = s.rawValue < stage.rawValue
                let current = s == stage
                HStack(spacing: 8) {
                    Image(systemName: done ? "checkmark.circle.fill" : (current ? "circle.dotted" : "circle"))
                        .foregroundStyle(done ? Color.green : (current ? tint : .white.opacity(0.3)))
                    Text(s.title).font(.system(size: 12, weight: current ? .semibold : .medium))
                        .foregroundStyle(.white.opacity(done || current ? 0.95 : 0.4))
                        .frame(width: 118, alignment: .leading)
                    StoreProgressBar(value: done ? 1 : (current ? progress : 0), tint: done ? .green : tint)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous).fill(theme.group))
    }
}

/// Шаг настройки: название и пометка («новое», «сделаем сами», «уже выдано») в одной строке, пояснение под ними.
private struct StoreNeedRow: View {
    let step: SetupStep
    let status: SetupStep.Status

    private var chip: (text: String, color: Color) {
        switch status {
        case .done: return ("уже выдано", .green)
        case .onDemand: return ("спросит сама", .gray)
        case .optional: return ("необязательно", .gray)
        case .needed: return (step.isAutomatic ? "сделаем сами" : "новое", .orange)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(step.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                DSChip(chip.text, color: chip.color).fixedSize()
            }
            Text(step.why).font(DS.rowSubtitle).foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 14)
        }
    }
}
