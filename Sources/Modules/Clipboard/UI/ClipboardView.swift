import SwiftUI
import AppKit

/// Экран модуля «Буфер». Всё помещается в окно без прокрутки: списки длиннее прокручиваются внутри.
struct ClipboardView<Model: ClipboardModel>: View {
    @ObservedObject var model: Model
    @StateObject private var recorder = HotKeyRecorder()
    @State private var newName = ""
    @State private var confirmClear = false
    @State private var spaceToDelete: ClipSpace?

    init(model: Model) { self.model = model }

    var body: some View {
        DSPage(module: .clipboard, subtitle: "История буфера и цветные пространства",
               primary: DSAction("Открыть панель", icon: "rectangle.bottomthird.inset.filled") {
                   model.togglePanel()
               }) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 16) {
                    controlSection
                    spacesSection
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 16) {
                    excludedSection
                    recentSection
                }
                .frame(width: 270, alignment: .topLeading)
            }
            securityLine
        }
        .onPageActive { active in
            if active { model.refreshPermissions() } else { recorder.stop() }
        }
        .alert("Очистить историю?", isPresented: $confirmClear) {
            Button("Очистить", role: .destructive) { model.clearHistory() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Удалятся все записи, кроме лежащих в пространствах.")
        }
        .alert("Удалить пространство?", isPresented: Binding(get: { spaceToDelete != nil },
                                                             set: { if !$0 { spaceToDelete = nil } })) {
            Button("Удалить", role: .destructive) {
                if let space = spaceToDelete { model.deleteSpace(space.id) }
                spaceToDelete = nil
            }
            Button("Отмена", role: .cancel) { spaceToDelete = nil }
        } message: {
            Text("«\(spaceToDelete?.name ?? "")» исчезнет, а его записи вернутся в историю.")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4)).padding(.horizontal, 6)
    }

    // MARK: Управление

    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DSSection("Управление", trailing: "\(model.totalCount) записей") {
                DSRow(icon: "command", title: "Клавиша панели") {
                    if recorder.isRecording {
                        DSChip("Нажми сочетание…", color: .white)
                    } else {
                        DSKeyCaps(model.hotKeyLabel).fixedSize()
                    }
                    DSButton(recorder.isRecording ? "Отмена" : "Изменить", small: true) {
                        if recorder.isRecording { recorder.stop() } else { recorder.start(model) }
                    }
                    .help("Кликни и нажми новое сочетание. Esc — отмена, Delete — вернуть ⌘⇧V")
                }
                if let error = model.hotKeyError {
                    DSRow(icon: "exclamationmark.triangle.fill", title: error)
                }
                if let error = model.storeError {
                    DSRow(icon: "key.slash", title: error)
                }
                if let notice = model.storeNotice {
                    DSRow(icon: "exclamationmark.triangle.fill", title: notice)
                }
                DSRow(icon: "clock.arrow.circlepath", title: "Размер истории") {
                    DSSegmented(ClipboardPolicy.limits, selection: Binding(
                        get: { model.limit }, set: { model.setLimit($0) })) { "\($0)" }
                }
                DSRow(icon: "trash", title: "Очистить историю",
                      subtitle: "Пространства останутся") {
                    DSButton("Очистить…", small: true) { confirmClear = true }
                        .disabled(model.historyCount == 0)
                }
            }
            if recorder.isRecording { caption("Esc — отмена, Delete — вернуть ⌘⇧V") }
        }
    }

    // MARK: Пространства

    private var spacesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DSSection("Пространства", trailing: model.spaces.isEmpty ? nil : "\(model.spaces.count)") {
                DSScroll(inset: 6) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.spaces) { space in
                            SpaceRow(model: model, space: space,
                                     count: model.count(inSpace: space.id),
                                     isFirst: space.id == model.spaces.first?.id,
                                     isLast: space.id == model.spaces.last?.id,
                                     onDelete: { spaceToDelete = space })
                        }
                    }
                }
                .frame(maxHeight: 170)
                .fixedSize(horizontal: false, vertical: true)
                DSRow(icon: "plus", title: "") {
                    TextField("Новое пространство", text: $newName)
                        .textFieldStyle(.plain).font(DS.rowTitle)
                        .onSubmit(createSpace)
                    DSButton("Создать", small: true, action: createSpace)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            caption("Записи в пространствах не вытесняются лимитом истории. Закрепляй правым кликом по карточке.")
        }
    }

    private func createSpace() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.addSpace(name: name, colorID: ClipPalette.nextID(after: model.spaces.count))
        newName = ""
    }

    // MARK: Исключения

    private var excludedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DSSection("Не запоминать из приложений") {
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
                                .frame(width: 24, height: 24)
                                Text(VoiceExcludedApps.name(id)).font(DS.rowTitle).foregroundStyle(.white.opacity(0.95))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                DSButton("Убрать", style: .plain, small: true) { model.removeExcluded(id) }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 5)
                        }
                    }
                }
                .frame(maxHeight: 150)
                .fixedSize(horizontal: false, vertical: true)
                DSRow(title: model.excludedApps.isEmpty ? "Список пуст" : "Ещё") {
                    DSButton("Добавить…", icon: "plus", small: true) {
                        if let id = VoiceExcludedApps.pick(message: "Выбери программу, из которой буфер не запоминать") {
                            model.addExcluded(id)
                        }
                    }
                    .fixedSize()
                }
            }
        }
    }

    // MARK: Последние

    private var recentSection: some View {
        DSSection("Последние записи") {
            if model.recent.isEmpty {
                DSRow(title: "Пока пусто")
            }
            ForEach(Array(model.recent.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 8) {
                    if let icon = ClipSourceIcon.image(item.sourceBundleID) {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "app.dashed").frame(width: 18, height: 18).foregroundStyle(.white.opacity(0.4))
                    }
                    Text(item.title).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(clipAgo(item.date)).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1).fixedSize()
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
            }
        }
    }

    // MARK: Безопасность

    private var securityLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill").foregroundStyle(.white.opacity(0.5))
            Text("Скрытое менеджерами паролей и всё из исключений не сохраняется; остальное зашифровано, только на этом Mac")
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
            Spacer()
            if !model.axTrusted {
                DSButton("Разрешить вставку…", small: true) { model.requestAccessibility() }
            }
        }
        .padding(.horizontal, 6)
    }
}

/// Строка пространства: цвет, имя (правится на месте), число записей, порядок, удаление.
private struct SpaceRow<Model: ClipboardModel>: View {
    @ObservedObject var model: Model
    let space: ClipSpace
    let count: Int
    let isFirst: Bool
    let isLast: Bool
    let onDelete: () -> Void
    @State private var name = ""
    @State private var picking = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            colorMenu
            TextField("Название", text: $name)
                .textFieldStyle(.plain).font(DS.rowTitle)
                .focused($focused)
                .onSubmit(commit)
            Text("\(count)").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.4))
            iconButton("chevron.up", help: "Выше", disabled: isFirst) { model.moveSpace(space.id, by: -1) }
            iconButton("chevron.down", help: "Ниже", disabled: isLast) { model.moveSpace(space.id, by: 1) }
            iconButton("trash", help: "Удалить пространство", disabled: false, action: onDelete)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(minHeight: 40)
        .onAppear { name = space.name }
        .onChange(of: space.name) { name = space.name }
        .onChange(of: focused) { if !focused { commit() } }
    }

    private func commit() {
        let clean = name.trimmingCharacters(in: .whitespaces)
        if clean.isEmpty { name = space.name } else if clean != space.name { model.renameSpace(space.id, to: clean) }
    }

    private var colorMenu: some View {
        Button { picking = true } label: {
            Circle().fill(ClipPalette.color(space.colorID)).frame(width: 16, height: 16)
                .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
                .padding(4)
        }
        .buttonStyle(.plain)
        .help("Цвет пространства")
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            HStack(spacing: 8) {
                ForEach(ClipPalette.all, id: \.id) { entry in
                    Button {
                        model.setColor(space.id, entry.id)
                        picking = false
                    } label: {
                        Circle().fill(entry.color).frame(width: 20, height: 20)
                            .overlay(Circle().stroke(.white.opacity(entry.id == space.colorID ? 0.95 : 0.15),
                                                     lineWidth: entry.id == space.colorID ? 2 : 1))
                    }
                    .buttonStyle(.plain).help(entry.name)
                }
            }
            .padding(12)
        }
    }

    private func iconButton(_ icon: String, help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(disabled ? 0.2 : 0.7))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(0.07)))
        }
        .buttonStyle(.plain).disabled(disabled).help(help).accessibilityLabel(help)
    }
}
