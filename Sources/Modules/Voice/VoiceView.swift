import SwiftUI
import AppKit
import AVFoundation

/// Экран модуля «Голос».
struct VoiceView: View {
    @Environment(\.pageActive) private var pageActive
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
            // Управление и проверка идут подряд на всю ширину, ниже в две колонки модели и исключения.
            controlSection
            testSection
            HStack(alignment: .top, spacing: 18) {
                modelsSection.frame(maxWidth: .infinity, alignment: .topLeading)
                excludedSection.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            accessibilityHint
        }
        .onPageActive { active in
            if active {
                devices = VoiceRecorder.inputDevices()
                controller.refreshPermissions()
            } else {
                recorder.stop()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard pageActive else { return }
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
                      trailing: noneInstalled ? "Скачай одну" : "Всё на этом Mac") {
                ForEach(VoiceModel.allCases) { model in
                    modelRow(model)
                }
            }
            caption("Звук не сохраняется. Модель качается один раз.")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.4))
            .padding(.horizontal, 6)
    }

    /// Короткие название и подпись для узкой колонки.
    private func shortTitle(_ model: VoiceModel) -> String {
        switch model {
        case .gigaam: return "GigaAM v3"
        case .parakeet: return "Parakeet v3"
        }
    }

    private func shortInfo(_ model: VoiceModel) -> String {
        switch model {
        case .gigaam: return "170 МБ · русский"
        case .parakeet: return "487 МБ · 25 языков"
        }
    }

    private func modelRow(_ model: VoiceModel) -> some View {
        let status = store.status(model)
        var subtitle = shortInfo(model)
        if case let .failed(message) = status { subtitle = message }
        return DSRow(icon: "cpu", title: shortTitle(model), subtitle: subtitle) {
            switch status {
            case .notInstalled:
                DSButton("Скачать", icon: "arrow.down.circle.fill", small: true) { store.download(model) }
            case .failed:
                DSButton("Повторить", icon: "arrow.clockwise", small: true) { store.download(model) }
                    .help("Ошибка загрузки: повторить")
            case let .downloading(progress):
                TintedProgress(value: progress)
                Text("\(Int(progress * 100)) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 34, alignment: .trailing)
                CircleIconButton(icon: "xmark", help: "Отменить загрузку") { store.cancel(model) }
            case .verifying:
                ProgressView().controlSize(.small)
                Text("Проверяю…").font(.caption).foregroundStyle(.white.opacity(0.5))
            case .installed:
                if store.selected == model {
                    ActiveChip()
                } else {
                    DSButton("Выбрать", small: true) { store.selected = model }
                }
                CircleIconButton(icon: "trash", help: "Удалить модель") { store.delete(model) }
            }
        }
    }

    // MARK: - Управление

    private var controlSection: some View {
        DSSection("Управление") {
            DSRow(icon: "command", title: "Клавиша", subtitle: "Esc — отмена, Delete — вернуть ⌃⌥Space") {
                if recorder.isRecording {
                    TintedChip(text: "Нажми сочетание…")
                } else {
                    DSKeyCaps(controller.hotKeyLabel).fixedSize()
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
                  subtitle: controller.mode == .toggle ? "Нажал, сказал, нажал ещё раз" : "Говорю, пока держу клавишу") {
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

    // MARK: - Исключения

    private var excludedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DSSection("Не включать в приложениях") {
                // Длинный список прокручивается внутри, чтобы не растягивать колонку.
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
                                .frame(width: 26, height: 26)
                                Text(VoiceExcludedApps.name(id)).font(DS.rowTitle).foregroundStyle(.white.opacity(0.95))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                DSButton("Убрать", style: .plain, small: true) { controller.removeExcluded(id) }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 6)
                        }
                    }
                }
                .frame(maxHeight: 130)
                .fixedSize(horizontal: false, vertical: true)
                DSRow(title: controller.excludedApps.isEmpty ? "Список пуст" : "Ещё") {
                    DSButton("Добавить…", icon: "plus", small: true) {
                        if let id = VoiceExcludedApps.pick() { controller.addExcluded(id) }
                    }
                    .fixedSize()
                }
            }
            caption("Сочетание в них доходит до программы.")
        }
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
                    Text("Кликни сюда и надиктуй.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.horizontal, 15).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 110)
        }
    }

    // MARK: - Универсальный доступ

    /// Микрофон просит экран «Осталось дать доступ»; «Универсальный доступ» желателен, и тем, кто его
    /// пропустил, здесь остаётся одна строка.
    @ViewBuilder private var accessibilityHint: some View {
        if !controller.axTrusted {
            HStack(spacing: 10) {
                Text("Без «Универсального доступа» текст только копируется, остаётся нажать ⌘V.")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                DSButton("Разрешить…", small: true) { controller.requestAccessibility() }
            }
            .padding(.horizontal, 6)
        }
    }
}

// Акцент модуля задаёт `DSPage`, поэтому читать его надо ниже страницы — в этих мелких видах.

/// Круглая кнопка-значок вместо текстовой: в узкой колонке строке не хватает места на подпись.
private struct CircleIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct TintedProgress: View {
    let value: Double
    @Environment(\.dsTint) private var tint
    var body: some View { ProgressView(value: value).tint(tint).frame(width: 70) }
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

/// То, чему назначают сочетание: «Голос» и «Буфер».
@MainActor
protocol HotKeyTarget: AnyObject {
    func setHotKey(keyCode: UInt32, modifiers: UInt32)
    func resetHotKey()
    func suspendHotKey()
    func resumeHotKey()
}

extension VoiceController: HotKeyTarget {}
extension ClipboardController: HotKeyTarget {}

/// Запись сочетания клавиш: пока идёт, следующее нажатое сочетание назначается, остальное глотается.
@MainActor
final class HotKeyRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private weak var controller: (any HotKeyTarget)?

    func start(_ controller: some HotKeyTarget) {
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
