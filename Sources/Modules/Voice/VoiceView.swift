import SwiftUI
import AppKit
import AVFoundation

/// Экран модуля «Голос».
struct VoiceView<Model: VoiceScreenModel>: View {
    @Environment(\.pageActive) private var pageActive
    @ObservedObject var voice: Model
    @StateObject private var recorder = HotKeyRecorder()
    @State private var devices: [VoiceRecorder.InputDevice] = []
    @State private var testText = ""
    @FocusState private var testFocused: Bool

    init(voice: Model) { self.voice = voice }

    private var noneInstalled: Bool {
        !VoiceModel.allCases.contains { voice.status($0) == .installed }
    }

    /// Главная кнопка: без моделей — скачать GigaAM, иначе — перейти в поле проверки.
    private var primary: DSAction {
        if noneInstalled {
            return DSAction("Скачать GigaAM", icon: "arrow.down.circle.fill") {
                if !isBusy(.gigaam) { voice.download(.gigaam) }
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
                voice.refreshPermissions()
            } else {
                recorder.stop()
                voice.endTest()
            }
        }
        // Режим проверки у внешнего модуля: пока поле в фокусе, распознанное приходит сюда, а не в чужую программу.
        .onChange(of: testFocused) { if testFocused { voice.beginTest() } else { voice.endTest() } }
        .onChange(of: voice.test?.serial) {
            guard let phrase = voice.test?.phrase else { return }
            testText += (testText.isEmpty || testText.hasSuffix(" ") || testText.hasSuffix("\n") ? "" : " ") + phrase
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard pageActive else { return }
            devices = VoiceRecorder.inputDevices()
            voice.refreshPermissions()
        }
        // Выбранная модель не установлена, а другая есть — переключаемся на неё.
        .onReceive(voice.statusChanges) { _ in
            if voice.status(voice.selected) != .installed,
               let first = VoiceModel.allCases.first(where: { voice.status($0) == .installed }) {
                voice.selected = first
            }
        }
    }

    private func isBusy(_ model: VoiceModel) -> Bool {
        switch voice.status(model) {
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
        let status = voice.status(model)
        var subtitle = shortInfo(model)
        if case let .failed(message) = status { subtitle = message }
        return DSRow(icon: "cpu", title: shortTitle(model), subtitle: subtitle) {
            switch status {
            case .notInstalled:
                DSButton("Скачать", icon: "arrow.down.circle.fill", small: true) { voice.download(model) }
            case .failed:
                DSButton("Повторить", icon: "arrow.clockwise", small: true) { voice.download(model) }
                    .help("Ошибка загрузки: повторить")
            case let .downloading(progress):
                TintedProgress(value: progress)
                Text("\(Int(progress * 100)) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 34, alignment: .trailing)
                CircleIconButton(icon: "xmark", help: "Отменить загрузку") { voice.cancel(model) }
            case .verifying:
                ProgressView().controlSize(.small)
                Text("Проверяю…").font(.caption).foregroundStyle(.white.opacity(0.5))
            case .installed:
                if voice.selected == model {
                    ActiveChip()
                } else {
                    DSButton("Выбрать", small: true) { voice.selected = model }
                }
                CircleIconButton(icon: "trash", help: "Удалить модель") { voice.delete(model) }
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
                    DSKeyCaps(voice.hotKeyLabel).fixedSize()
                }
                DSButton(recorder.isRecording ? "Отмена" : "Изменить", small: true) {
                    if recorder.isRecording { recorder.stop() } else { recorder.start(voice) }
                }
                .help("Кликни и нажми новое сочетание. Esc — отмена, Delete — вернуть ⌃⌥Space")
            }
            if let error = voice.hotKeyError {
                DSRow(icon: "exclamationmark.triangle.fill", title: error)
            }
            DSRow(icon: "hand.tap.fill", title: "Режим",
                  subtitle: voice.mode == .toggle ? "Нажал, сказал, нажал ещё раз" : "Говорю, пока держу клавишу") {
                DSSegmented(VoiceController.Mode.allCases, selection: $voice.mode) { $0.title }
            }
            DSRow(icon: "mic.fill", title: "Микрофон", subtitle: micName) {
                micMenu
            }
        }
    }

    private var micName: String {
        guard let uid = voice.micUID else { return "Системный" }
        return devices.first(where: { $0.uid == uid })?.name ?? "Отключён"
    }

    private var micMenu: some View {
        Menu {
            Button { voice.micUID = nil } label: {
                Label("Системный", systemImage: voice.micUID == nil ? "checkmark" : "")
            }
            ForEach(devices) { device in
                Button { voice.micUID = device.uid } label: {
                    Label(device.name, systemImage: voice.micUID == device.uid ? "checkmark" : "")
                }
            }
            // Выбранный микрофон сейчас отключён: оставляем его в списке, чтобы выбор не потерялся.
            if let uid = voice.micUID, !devices.contains(where: { $0.uid == uid }) {
                Button { voice.micUID = uid } label: { Label("Отключён", systemImage: "checkmark") }
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
                        ForEach(voice.excludedApps, id: \.self) { id in
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
                                DSButton("Убрать", style: .plain, small: true) { voice.removeExcluded(id) }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 6)
                        }
                    }
                }
                .frame(maxHeight: 130)
                .fixedSize(horizontal: false, vertical: true)
                DSRow(title: voice.excludedApps.isEmpty ? "Список пуст" : "Ещё") {
                    DSButton("Добавить…", icon: "plus", small: true) {
                        if let id = VoiceExcludedApps.pick() { voice.addExcluded(id) }
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
        if !voice.axTrusted {
            HStack(spacing: 10) {
                Text("Без «Универсального доступа» текст только копируется, остаётся нажать ⌘V.")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                DSButton("Разрешить…", small: true) { voice.requestAccessibility() }
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

extension VoiceController: HotKeyTarget {}
