import SwiftUI
import AppKit

/// Экран модуля «Буфер» в классическом интерфейсе.
struct ClassicClipboardView: View {
    @ObservedObject private var controller = ClipboardController.shared
    @StateObject private var recorder = HotKeyRecorder()
    @State private var newName = ""
    @State private var confirmClear = false
    @State private var spaceToDelete: ClipSpace?

    var body: some View {
        Form {
            Section {
                LabeledContent("Клавиша панели") {
                    HStack {
                        Text(recorder.isRecording ? "Нажми сочетание…" : controller.hotKeyLabel)
                            .font(.system(.body, design: .rounded).weight(.semibold))
                        Button(recorder.isRecording ? "Отмена" : "Изменить") {
                            if recorder.isRecording { recorder.stop() } else { recorder.start(controller) }
                        }
                        Button("Открыть панель") { controller.togglePanel() }
                    }
                }
                if let error = controller.hotKeyError { Text(error).foregroundStyle(.orange) }
                if let error = controller.storeError { Text(error).foregroundStyle(.orange) }
                Picker("Размер истории", selection: Binding(get: { controller.limit },
                                                            set: { controller.setLimit($0) })) {
                    ForEach(ClipboardPolicy.limits, id: \.self) { Text("\($0)").tag($0) }
                }
                LabeledContent("Записей: \(controller.items.count)") {
                    Button("Очистить историю…") { confirmClear = true }.disabled(controller.historyCount == 0)
                }
            } footer: {
                Text("Пароли из менеджеров паролей не сохраняются, всё зашифровано и хранится только на этом Mac")
            }

            Section {
                ForEach(controller.spaces) { space in
                    HStack {
                        Circle().fill(ClipPalette.color(space.colorID)).frame(width: 12, height: 12)
                        TextField("Название", text: Binding(get: { space.name },
                                                            set: { controller.renameSpace(space.id, to: $0) }))
                        Picker("", selection: Binding(get: { space.colorID }, set: { controller.setColor(space.id, $0) })) {
                            ForEach(ClipPalette.all, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().frame(width: 130)
                        Button { controller.moveSpace(space.id, by: -1) } label: { Image(systemName: "chevron.up") }
                        Button { controller.moveSpace(space.id, by: 1) } label: { Image(systemName: "chevron.down") }
                        Button { spaceToDelete = space } label: { Image(systemName: "trash") }
                    }
                }
                HStack {
                    TextField("Новое пространство", text: $newName).onSubmit(create)
                    Button("Создать", action: create).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Пространства")
            }

            Section {
                ForEach(controller.excludedApps, id: \.self) { id in
                    HStack {
                        if let icon = VoiceExcludedApps.icon(id) { Image(nsImage: icon).resizable().frame(width: 20, height: 20) }
                        Text(VoiceExcludedApps.name(id))
                        Spacer()
                        Button("Убрать") { controller.removeExcluded(id) }
                    }
                }
                Button("Добавить программу…") {
                    if let id = VoiceExcludedApps.pick(message: "Выбери программу, из которой буфер не запоминать") {
                        controller.addExcluded(id)
                    }
                }
            } header: {
                Text("Не запоминать из приложений")
            }

            Section {
                ForEach(controller.items.prefix(5)) { item in
                    HStack {
                        Text(item.kind.title).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                        Text(item.text ?? item.filePaths?.first ?? "").lineLimit(1)
                        Spacer()
                        Text(clipAgo(item.date)).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Последние записи")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Буфер")
        .navigationSubtitle("История буфера и цветные пространства")
        .onDisappear { recorder.stop() }
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

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        controller.addSpace(name: name, colorID: ClipPalette.nextID(after: controller.spaces.count))
        newName = ""
    }
}
