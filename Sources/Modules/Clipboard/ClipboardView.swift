import SwiftUI
import AppKit

/// Экран модуля «Буфер». Всё помещается в окно без прокрутки: списки длиннее прокручиваются внутри.
struct ClipboardView: View {
    @ObservedObject private var controller = ClipboardController.shared
    @StateObject private var recorder = HotKeyRecorder()
    @State private var newName = ""
    @State private var confirmClear = false
    @State private var spaceToDelete: ClipSpace?

    var body: some View {
        DSPage(module: .clipboard, subtitle: "История буфера и цветные пространства",
               primary: DSAction("Открыть панель", icon: "rectangle.bottomthird.inset.filled") {
                   controller.togglePanel()
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
            if active { controller.refreshPermissions() } else { recorder.stop() }
        }
        .alert("Очистить историю?", isPresented: $confirmClear) {
            Button("Очистить", role: .destructive) { controller.clearHistory() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Удалятся все записи, кроме лежащих в пространствах.")
        }
        .alert("Удалить пространство?", isPresented: Binding(get: { spaceToDelete != nil },
                                                             set: { if !$0 { spaceToDelete = nil } })) {
            Button("Удалить", role: .destructive) {
                if let space = spaceToDelete { controller.deleteSpace(space.id) }
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
            DSSection("Управление", trailing: "\(controller.items.count) записей") {
                DSRow(icon: "command", title: "Клавиша панели") {
                    if recorder.isRecording {
                        DSChip("Нажми сочетание…", color: .white)
                    } else {
                        DSKeyCaps(controller.hotKeyLabel).fixedSize()
                    }
                    DSButton(recorder.isRecording ? "Отмена" : "Изменить", small: true) {
                        if recorder.isRecording { recorder.stop() } else { recorder.start(controller) }
                    }
                    .help("Кликни и нажми новое сочетание. Esc — отмена, Delete — вернуть ⌘⇧V")
                }
                if let error = controller.hotKeyError {
                    DSRow(icon: "exclamationmark.triangle.fill", title: error)
                }
                if let error = controller.storeError {
                    DSRow(icon: "key.slash", title: error)
                }
                if let notice = controller.storeNotice {
                    DSRow(icon: "exclamationmark.triangle.fill", title: notice)
                }
                DSRow(icon: "clock.arrow.circlepath", title: "Размер истории") {
                    DSSegmented(ClipboardPolicy.limits, selection: Binding(
                        get: { controller.limit }, set: { controller.setLimit($0) })) { "\($0)" }
                }
                DSRow(icon: "trash", title: "Очистить историю",
                      subtitle: "Пространства останутся") {
                    DSButton("Очистить…", small: true) { confirmClear = true }
                        .disabled(controller.historyCount == 0)
                }
            }
            if recorder.isRecording { caption("Esc — отмена, Delete — вернуть ⌘⇧V") }
        }
    }

    // MARK: Пространства

    private var spacesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DSSection("Пространства", trailing: controller.spaces.isEmpty ? nil : "\(controller.spaces.count)") {
                DSScroll(inset: 6) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(controller.spaces) { space in
                            SpaceRow(space: space,
                                     count: controller.items.filter { $0.spaceID == space.id }.count,
                                     isFirst: space.id == controller.spaces.first?.id,
                                     isLast: space.id == controller.spaces.last?.id,
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
        controller.addSpace(name: name, colorID: ClipPalette.nextID(after: controller.spaces.count))
        newName = ""
    }

    // MARK: Исключения

    private var excludedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DSSection("Не запоминать из приложений") {
                DSScroll(inset: 6) {
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
                                .frame(width: 24, height: 24)
                                Text(VoiceExcludedApps.name(id)).font(DS.rowTitle).foregroundStyle(.white.opacity(0.95))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                DSButton("Убрать", style: .plain, small: true) { controller.removeExcluded(id) }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 5)
                        }
                    }
                }
                .frame(maxHeight: 150)
                .fixedSize(horizontal: false, vertical: true)
                DSRow(title: controller.excludedApps.isEmpty ? "Список пуст" : "Ещё") {
                    DSButton("Добавить…", icon: "plus", small: true) {
                        if let id = VoiceExcludedApps.pick(message: "Выбери программу, из которой буфер не запоминать") {
                            controller.addExcluded(id)
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
            if controller.items.isEmpty {
                DSRow(title: "Пока пусто")
            }
            ForEach(controller.items.prefix(5)) { item in
                HStack(spacing: 8) {
                    if let icon = ClipSourceIcon.image(item.sourceBundleID) {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "app.dashed").frame(width: 18, height: 18).foregroundStyle(.white.opacity(0.4))
                    }
                    Text(recentTitle(item)).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(clipAgo(item.date)).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1).fixedSize()
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
            }
        }
    }

    private func recentTitle(_ item: ClipItem) -> String {
        switch item.kind {
        case .text: return (item.text ?? "").replacingOccurrences(of: "\n", with: " ")
        case .link: return item.host ?? item.text ?? ""
        case .image: return "Картинка \(item.imageWidth.map { "\($0)×\(item.imageHeight ?? 0)" } ?? "")"
        case .file: return (item.filePaths?.first.map { ($0 as NSString).lastPathComponent }) ?? "Файл"
        }
    }

    // MARK: Безопасность

    private var securityLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill").foregroundStyle(.white.opacity(0.5))
            Text("Скрытое менеджерами паролей и всё из исключений не сохраняется; остальное зашифровано, только на этом Mac")
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
            Spacer()
            if !controller.axTrusted {
                DSButton("Разрешить вставку…", small: true) { controller.requestAccessibility() }
            }
        }
        .padding(.horizontal, 6)
    }
}

/// Строка пространства: цвет, имя (правится на месте), число записей, порядок, удаление.
private struct SpaceRow: View {
    let space: ClipSpace
    let count: Int
    let isFirst: Bool
    let isLast: Bool
    let onDelete: () -> Void
    @ObservedObject private var controller = ClipboardController.shared
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
            iconButton("chevron.up", help: "Выше", disabled: isFirst) { controller.moveSpace(space.id, by: -1) }
            iconButton("chevron.down", help: "Ниже", disabled: isLast) { controller.moveSpace(space.id, by: 1) }
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
        if clean.isEmpty { name = space.name } else if clean != space.name { controller.renameSpace(space.id, to: clean) }
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
                        controller.setColor(space.id, entry.id)
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
