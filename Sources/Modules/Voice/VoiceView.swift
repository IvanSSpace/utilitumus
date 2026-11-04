import SwiftUI
import AppKit
import AVFoundation

/// Экран модуля «Голос».
struct VoiceView: View {
    @ObservedObject private var store = VoiceModelStore.shared
    @ObservedObject private var controller = VoiceController.shared
    @StateObject private var recorder = HotKeyRecorder()
    @State private var devices: [VoiceRecorder.InputDevice] = []
    @State private var testText = ""
    @FocusState private var testFocused: Bool

    private var noneInstalled: Bool {
        !VoiceModel.allCases.contains { store.status($0) == .installed }
    }

    /// Главная кнопка: без моделей — скачать GigaAM, иначе — перейти в поле проверки.
    private var primary: DSAction {
        if noneInstalled {
            return DSAction("Скачать GigaAM", icon: "arrow.down.circle.fill") {
                if !isBusy(.gigaam) { store.download(.gigaam) }
            }
        }
        return DSAction("Проверить", icon: "mic.fill") { testFocused = true }
    }

    var body: some View {
        DSPage(module: .voice, subtitle: "Голосовой ввод в любом приложении", primary: primary) {
            modelsSection
            controlSection
            HStack(alignment: .top, spacing: DS.blockSpacing) {
                testSection.frame(maxWidth: .infinity)
                permissionsSection.frame(maxWidth: .infinity)
            }
        }
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

    private func isBusy(_ model: VoiceModel) -> Bool {
        switch store.status(model) {
        case .downloading, .verifying: return true
        default: return false
        }
    }

    // MARK: - Модели

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DSSection("Модели распознавания",
                      trailing: noneInstalled ? "Скачай одну, чтобы начать" : "Всё считается на этом Mac") {
                ForEach(VoiceModel.allCases) { model in
                    modelRow(model)
                }
            }
            Text("Звук нигде не сохраняется и никуда не уходит. Модель скачивается один раз, дальше интернет не нужен.")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 6)
        }
    }

    private func modelRow(_ model: VoiceModel) -> some View {
        let status = store.status(model)
        var subtitle = model.subtitle
        if case let .failed(message) = status { subtitle = message }
        return DSRow(icon: "cpu", title: model.title, subtitle: subtitle) {
            switch status {
            case .notInstalled:
                DSButton("Скачать", icon: "arrow.down.circle.fill", small: true) { store.download(model) }
            case .failed:
                DSChip("Ошибка", color: .red, icon: "exclamationmark.triangle.fill")
                DSButton("Повторить", icon: "arrow.clockwise", small: true) { store.download(model) }
            case let .downloading(progress):
                TintedProgress(value: progress)
                Text("\(Int(progress * 100)) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 36, alignment: .trailing)
                DSButton("Отмена", small: true) { store.cancel(model) }
            case .verifying:
                ProgressView().controlSize(.small)
                Text("Проверяю…").font(.caption).foregroundStyle(.white.opacity(0.5))
            case .installed:
                if store.selected == model {
                    ActiveChip()
                } else {
                    DSButton("Выбрать", small: true) { store.selected = model }
                }
                DSButton("Удалить", style: .plain, small: true) { store.delete(model) }
            }
        }
    }

    // MARK: - Управление

    private var controlSection: some View {
        DSSection("Управление") {
            DSRow(icon: "command", title: "Горячая клавиша",
                  subtitle: recorder.isRecording ? "Esc — отмена, Delete — вернуть ⌃⌥Space" : nil) {
                if recorder.isRecording {
                    TintedChip(text: "Нажми сочетание…")
                } else {
                    DSKeyCaps(controller.hotKeyLabel)
                }
                DSButton(recorder.isRecording ? "Отмена" : "Изменить", small: true) {
                    if recorder.isRecording { recorder.stop() } else { recorder.start(controller) }
                }
                .help("Кликни и нажми новое сочетание. Esc — отмена, Delete — вернуть ⌃⌥Space")
            }
            if let error = controller.hotKeyError {
                DSRow(icon: "exclamationmark.triangle.fill", title: error)
            }
            DSRow(icon: "hand.tap.fill", title: "Режим",
                  subtitle: controller.mode == .toggle
                      ? "Нажал, сказал, нажал ещё раз. Esc — отмена"
                      : "Говори, пока держишь. Отпустил — текст вставится. Esc — отмена") {
                DSSegmented(VoiceController.Mode.allCases, selection: $controller.mode) { $0.title }
            }
            DSRow(icon: "mic.fill", title: "Микрофон", subtitle: micName) {
                micMenu
            }
        }
    }

    private var micName: String {
        guard let uid = controller.micUID else { return "Системный" }
        return devices.first(where: { $0.uid == uid })?.name ?? "Отключён"
    }

    private var micMenu: some View {
        Menu {
            Button { controller.micUID = nil } label: {
                Label("Системный", systemImage: controller.micUID == nil ? "checkmark" : "")
            }
            ForEach(devices) { device in
                Button { controller.micUID = device.uid } label: {
                    Label(device.name, systemImage: controller.micUID == device.uid ? "checkmark" : "")
                }
            }
            // Выбранный микрофон сейчас отключён: оставляем его в списке, чтобы выбор не потерялся.
            if let uid = controller.micUID, !devices.contains(where: { $0.uid == uid }) {
                Button { controller.micUID = uid } label: { Label("Отключён", systemImage: "checkmark") }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .bold))
                Text("Сменить").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 11).frame(height: 26)
            .background(Capsule().fill(.white.opacity(0.1)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Проверить

    private var testSection: some View {
        DSSection("Проверить") {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $testText)
                    .font(.system(size: 13.5))
                    .scrollContentBackground(.hidden)
                    .focused($testFocused)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                if testText.isEmpty {
                    Text("Кликни сюда и надиктуй: текст появится здесь.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.horizontal, 15).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 100)
        }
    }

    // MARK: - Разрешения

    private var permissionsSection: some View {
        DSSection("Разрешения") {
            DSRow(title: "Микрофон", subtitle: controller.micStatus == .authorized ? nil : micText) {
                if controller.micStatus == .authorized {
                    DSChip("Разрешён", color: .green, icon: "checkmark")
                } else {
                    DSButton("Разрешить…", small: true) { controller.requestMic() }
                }
            }
            DSRow(title: "Универсальный доступ",
                  subtitle: controller.axTrusted ? nil : "Без него текст копируется, остаётся нажать ⌘V") {
                if controller.axTrusted {
                    DSChip("Разрешён", color: .green, icon: "checkmark")
                } else {
                    DSButton("Разрешить…", small: true) { controller.requestAccessibility() }
                }
            }
            .help("Нужен, чтобы текст вставлялся сам")
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

// Акцент модуля задаёт `DSPage`, поэтому читать его надо ниже страницы — в этих мелких видах.

private struct TintedProgress: View {
    let value: Double
    @Environment(\.dsTint) private var tint
    var body: some View { ProgressView(value: value).tint(tint).frame(width: 90) }
}

private struct ActiveChip: View {
    @Environment(\.dsTint) private var tint
    var body: some View { DSChip("Активна", color: tint, icon: "checkmark") }
}

private struct TintedChip: View {
    let text: String
    @Environment(\.dsTint) private var tint
    var body: some View { DSChip(text, color: tint) }
}

/// Запись сочетания клавиш: пока идёт, следующее нажатое сочетание назначается, остальное глотается.
@MainActor
final class HotKeyRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private weak var controller: VoiceController?

    func start(_ controller: VoiceController) {
        stop()
        self.controller = controller
        isRecording = true
        // Текущее сочетание не должно срабатывать, пока ждём новое.
        controller.suspendHotKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = UInt32(event.keyCode)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            MainActor.assumeIsolated { self?.handle(keyCode: keyCode, flags: flags) }
            return nil
        }
        // Клик мимо отменяет; клик по самой кнопке сразу запустит запись заново.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.stop() }
            return event
        }
    }

    private func handle(keyCode: UInt32, flags: NSEvent.ModifierFlags) {
        guard let controller else { return stop() }
        let modifiers = VoiceHotKey.carbonModifiers(flags)
        switch keyCode {
        case 53 where modifiers == 0:
            stop()
        case 51 where modifiers == 0, 117 where modifiers == 0:
            controller.resetHotKey()
            stop()
        default:
            if VoiceHotKey.isAcceptable(keyCode: keyCode, modifiers: modifiers) {
                controller.setHotKey(keyCode: keyCode, modifiers: modifiers)
                stop()
            }
        }
    }

    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyMonitor = nil
        mouseMonitor = nil
        if isRecording { controller?.resumeHotKey() }
        isRecording = false
    }
}
