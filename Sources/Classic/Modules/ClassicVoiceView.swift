import SwiftUI
import AppKit
import AVFoundation

/// Экран модуля «Голос».
struct ClassicVoiceView: View {
    @ObservedObject private var store = VoiceModelStore.shared
    @ObservedObject private var controller = VoiceController.shared
    @StateObject private var recorder = HotKeyRecorder()
    @State private var devices: [VoiceRecorder.InputDevice] = []
    @State private var testText = ""

    private var noneInstalled: Bool {
        !VoiceModel.allCases.contains { store.status($0) == .installed }
    }

    var body: some View {
        Form {
            if noneInstalled { hintSection }
            modelsSection
            controlSection
            excludedSection
            testSection
            permissionsSection
        }
        .formStyle(.grouped)
        .navigationTitle("Голос")
        .navigationSubtitle("Голосовой ввод в любом приложении")
        .onAppear {
            devices = VoiceRecorder.inputDevices()
            controller.refreshPermissions()
        }
        .onDisappear { recorder.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            devices = VoiceRecorder.inputDevices()
            controller.refreshPermissions()
        }
        // Выбранная модель не установлена, а другая есть — переключаемся на неё.
        .onReceive(store.$statuses) { _ in
            if store.status(store.selected) != .installed,
               let first = VoiceModel.allCases.first(where: { store.status($0) == .installed }) {
                store.selected = first
            }
        }
    }

    // MARK: - Подсказка

    private var hintSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Скачай GigaAM, чтобы начать").font(.headline)
                    Text("Без модели распознавать нечего. Скачивается один раз, дальше работает без интернета.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Скачать") { store.download(.gigaam) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy(.gigaam))
            }
            .padding(.vertical, 4)
        }
    }

    private func isBusy(_ model: VoiceModel) -> Bool {
        switch store.status(model) {
        case .downloading, .verifying: return true
        default: return false
        }
    }

    // MARK: - Модели

    private var modelsSection: some View {
        Section {
            ForEach(VoiceModel.allCases) { model in
                modelRow(model)
            }
        } header: {
            Text("Модели")
        } footer: {
            Text("Распознавание идёт на этом Mac. Звук нигде не сохраняется и никуда не уходит.")
        }
    }

    private func modelRow(_ model: VoiceModel) -> some View {
        let status = store.status(model)
        let installed = status == .installed
        return HStack(spacing: 10) {
            Button {
                store.selected = model
            } label: {
                Image(systemName: store.selected == model && installed ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(installed ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disabled(!installed)
            .help(installed ? "Использовать эту модель" : "Сначала скачай")

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                Text(model.subtitle).font(.caption).foregroundStyle(.secondary)
                if case let .failed(message) = status {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            switch status {
            case .notInstalled, .failed:
                Button(status == .notInstalled ? "Скачать" : "Повторить") { store.download(model) }
            case let .downloading(progress):
                ProgressView(value: progress).frame(width: 90)
                Text("\(Int(progress * 100)) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                Button("Отмена") { store.cancel(model) }
            case .verifying:
                ProgressView().controlSize(.small)
                Text("Проверяю…").font(.caption).foregroundStyle(.secondary)
            case .installed:
                Text("Установлена").font(.caption).foregroundStyle(.secondary)
                Button("Удалить", role: .destructive) { store.delete(model) }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Управление

    private var controlSection: some View {
        Section {
            LabeledContent("Горячая клавиша") {
                Button {
                    if recorder.isRecording { recorder.stop() } else { recorder.start(controller) }
                } label: {
                    Text(recorder.isRecording ? "Нажми сочетание…" : controller.hotKeyLabel)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .frame(minWidth: 96)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .foregroundStyle(recorder.isRecording ? Color.white : .primary)
                        .background(recorder.isRecording ? Color.accentColor : .clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(recorder.isRecording ? Color.accentColor : Color.primary.opacity(0.3), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Кликни и нажми новое сочетание. Esc — отмена, Delete — вернуть ⌃⌥Space")
            }
            if let error = controller.hotKeyError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            LabeledContent("Режим") {
                SegmentedControl(VoiceController.Mode.allCases, selection: $controller.mode, title: \.title)
                    .fixedSize()
            }
            Picker("Микрофон", selection: micBinding) {
                Text("Системный").tag("")
                ForEach(devices) { device in
                    Text(device.name).tag(device.uid)
                }
                // Выбранный микрофон сейчас отключён: оставляем его в списке, чтобы выбор не потерялся.
                if let uid = controller.micUID, !devices.contains(where: { $0.uid == uid }) {
                    Text("Отключён").tag(uid)
                }
            }
        } header: {
            Text("Управление")
        } footer: {
            Text(controller.mode == .toggle
                 ? "Нажми сочетание, скажи фразу, нажми ещё раз. Esc во время записи — отмена."
                 : "Говори, пока держишь сочетание. Отпустил — текст вставится. Esc во время записи — отмена.")
        }
    }

    private var micBinding: Binding<String> {
        Binding(get: { controller.micUID ?? "" }, set: { controller.micUID = $0.isEmpty ? nil : $0 })
    }

    // MARK: - Исключения

    private var excludedSection: some View {
        Section {
            ForEach(controller.excludedApps, id: \.self) { id in
                HStack(spacing: 10) {
                    if let icon = VoiceExcludedApps.icon(id) {
                        Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "app.dashed").frame(width: 24, height: 24).foregroundStyle(.secondary)
                    }
                    Text(VoiceExcludedApps.name(id))
                    Spacer(minLength: 8)
                    Button("Убрать", role: .destructive) { controller.removeExcluded(id) }
                }
            }
            HStack {
                if controller.excludedApps.isEmpty { Text("Список пуст").foregroundStyle(.secondary) }
                Spacer()
                Button("Добавить…") {
                    if let id = VoiceExcludedApps.pick() { controller.addExcluded(id) }
                }
            }
        } header: {
            Text("Не включать голос в этих приложениях")
        } footer: {
            Text("В этих программах сочетание голоса не срабатывает и доходит до самой программы: у неё свой ввод.")
        }
    }

    // MARK: - Проверить

    private var testSection: some View {
        Section {
            TextEditor(text: $testText)
                .font(.body)
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
        } header: {
            Text("Проверить")
        } footer: {
            Text("Кликни в поле и надиктуй: текст появится здесь.")
        }
    }

    // MARK: - Разрешения

    private var permissionsSection: some View {
        Section {
            LabeledContent("Микрофон") {
                HStack(spacing: 8) {
                    Text(micText)
                        .foregroundStyle(controller.micStatus == .authorized ? Color.green : .secondary)
                    if controller.micStatus != .authorized {
                        Button("Разрешить…") { controller.requestMic() }
                    }
                }
            }
            LabeledContent("Универсальный доступ") {
                HStack(spacing: 8) {
                    Text(controller.axTrusted ? "Разрешён" : "Не разрешён")
                        .foregroundStyle(controller.axTrusted ? Color.green : .secondary)
                    if !controller.axTrusted {
                        Button("Разрешить…") { controller.requestAccessibility() }
                    }
                }
            }
        } header: {
            Text("Разрешения")
        } footer: {
            Text("Универсальный доступ нужен, чтобы текст вставлялся сам. Без него он копируется в буфер, и остаётся нажать ⌘V.")
        }
    }

    private var micText: String {
        switch controller.micStatus {
        case .authorized: return "Разрешён"
        case .notDetermined: return "Ещё не спрашивали"
        default: return "Запрещён"
        }
    }
}

