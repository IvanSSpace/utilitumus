import SwiftUI

/// Экран модуля «Озвучка». Работает только с `SpeakModel`: права, звук и выделение — забота утилиты, экран их не трогает.
/// Текста чтения здесь нет: модель отдаёт только фазу, числа и готовые строки.
struct SpeakView<Model: SpeakModel>: View {
    @ObservedObject var model: Model
    @StateObject private var recorder = HotKeyRecorder()
    /// Значение ползунка, пока его тянут: скорость уходит модели одним действием, когда ползунок отпустили.
    @State private var draggedSpeed: Double?
    @State private var dragging = false

    init(model: Model) { self.model = model }

    var body: some View {
        DSPage(module: .speak, subtitle: "Читает вслух выделенный текст по сочетанию клавиш") {
            nowSection
            speedSection
            voiceSection
            hotKeySection
            accessSection
            servicesSection
        }
        .onPageActive { active in
            if active { model.refreshPermissions() } else { recorder.stop() }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
    }

    private var defaultHotKeyLabel: String {
        VoiceHotKey.label(keyCode: SpeakKeys.defaultKeyCode, modifiers: SpeakKeys.defaultModifiers)
    }

    // MARK: - Сейчас

    private var nowSection: some View {
        DSSection("Сейчас") {
            switch model.phase {
            case .idle:
                DSRow(icon: "speaker.wave.2.fill", title: "Ничего не читаю",
                      subtitle: model.canStart ? "Выдели текст и нажми \(model.hotKeyLabel), ещё раз — остановить"
                                               : SpeakMessage.notRunning)
            case .speaking:
                DSRow(icon: "waveform", title: "Читаю вслух", subtitle: "Скорость \(SpeakSpeed.label(model.speed))") {
                    DSButton("Пауза", icon: "pause.fill", small: true) { model.pause() }
                    DSButton("Стоп", icon: "stop.fill", small: true) { model.stopSpeaking() }
                }
            case .paused:
                DSRow(icon: "pause.circle.fill", title: "Пауза", subtitle: "Скорость \(SpeakSpeed.label(model.speed))") {
                    DSButton("Продолжить", icon: "play.fill", small: true) { model.resume() }
                    DSButton("Стоп", icon: "stop.fill", small: true) { model.stopSpeaking() }
                }
            }
            if let message = model.message {
                DSRow(icon: "exclamationmark.triangle.fill", title: message)
            }
        }
    }

    // MARK: - Скорость

    private var shownSpeed: Double { draggedSpeed ?? model.speed }

    private var speedSection: some View {
        DSSection("Скорость") {
            DSRow(icon: "gauge.with.needle", title: "Скорость чтения", subtitle: "Меняется и во время чтения") {
                Text(SpeakSpeed.label(shownSpeed))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 46, alignment: .trailing)
                DSButton("1×", small: true) { model.setSpeed(SpeakSpeed.normal) }
                    .disabled(shownSpeed == SpeakSpeed.normal)
                    .help("Обычная скорость")
            }
            HStack(spacing: 10) {
                Text(SpeakSpeed.label(SpeakSpeed.range.lowerBound)).modifier(SpeedMark())
                SpeakSpeedSlider(value: Binding(get: { shownSpeed }, set: dragged), editing: editing)
                Text(SpeakSpeed.label(SpeakSpeed.range.upperBound)).modifier(SpeedMark())
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 14) }
        }
    }

    /// Мышью — запомнить до отпускания; с клавиатуры и VoiceOver ползунок не «тянут» — сразу модели.
    private func dragged(_ value: Double) {
        if dragging { draggedSpeed = value } else { model.setSpeed(value) }
    }

    private func editing(_ on: Bool) {
        dragging = on
        guard !on, let value = draggedSpeed else { return }
        draggedSpeed = nil
        model.setSpeed(value)
    }

    // MARK: - Голос

    /// Языки установленных голосов и закреплённые без голоса: русский, английский, дальше по названию.
    private var languages: [String] {
        let keys = Set(model.voices.map(\.languageKey)).union(model.pinnedVoices.keys)
        let first = ["ru", "en"]
        return keys.sorted { a, b in
            let ia = first.firstIndex(of: a) ?? first.count, ib = first.firstIndex(of: b) ?? first.count
            if ia != ib { return ia < ib }
            return SpeakVoiceNames.language(a) < SpeakVoiceNames.language(b)
        }
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DSSection("Голос", trailing: model.pinnedVoices.isEmpty ? "Авто" : "Закреплено: \(model.pinnedVoices.count)") {
                DSRow(icon: "person.wave.2.fill", title: "Авто",
                      subtitle: "Язык текста определяется сам, читает лучший установленный голос этого языка") {
                    if model.pinnedVoices.isEmpty {
                        TintedChip(text: "Включено", icon: "checkmark")
                    } else {
                        DSButton("Всё на «Авто»", small: true) { model.setVoiceAuto() }
                    }
                }
                if model.voices.isEmpty {
                    DSRow(title: "Список голосов ещё не пришёл", subtitle: "Его знает утилита: откроется, когда она ответит")
                } else {
                    DSScroll(inset: 6) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(languages, id: \.self) { language in languageRow(language) }
                        }
                    }
                    .frame(maxHeight: 260)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            caption("Голос лучше качеством скачивается в системе: Системные настройки → Универсальный доступ → Устный контент → "
                    + "Голос системы. Выбери русский голос и скачай улучшенное или премиум-качество.")
        }
    }

    private func languageRow(_ language: String) -> some View {
        let voices = model.voices.filter { $0.languageKey == language }
            .sorted { a, b in a.quality != b.quality ? a.quality > b.quality : (a.name, a.id) < (b.name, b.id) }
        let pinnedID = model.pinnedVoices[language]
        let pinned = pinnedID.flatMap { id in voices.first { $0.id == id } }
        let subtitle: String
        if let pinned {
            subtitle = "Закреплён: " + SpeakVoiceNames.title(pinned, among: voices)
        } else if pinnedID != nil {
            subtitle = "Закреплённого голоса нет в системе, читает «Авто»"
        } else {
            subtitle = "Авто"
        }
        return DSRow(title: SpeakVoiceNames.language(language), subtitle: subtitle) {
            Menu {
                Button { model.unpin(language: language) } label: {
                    Label("Авто", systemImage: pinnedID == nil ? "checkmark" : "")
                }
                Divider()
                ForEach(voices, id: \.id) { voice in
                    Button { model.pinVoice(language: language, id: voice.id) } label: {
                        Label(SpeakVoiceNames.title(voice, among: voices), systemImage: pinnedID == voice.id ? "checkmark" : "")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .bold))
                    Text(pinned?.name ?? "Авто").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 11).frame(height: 26)
                .background(Capsule().fill(.white.opacity(0.1)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Голос для этого языка")
        }
    }

    // MARK: - Сочетание

    private var hotKeySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DSSection("Сочетание") {
                DSRow(icon: "command", title: "Прочитать выделенное", subtitle: "Нажми ещё раз, чтобы остановить") {
                    if recorder.isRecording {
                        TintedChip(text: "Нажми сочетание…")
                    } else {
                        DSKeyCaps(model.hotKeyLabel).fixedSize()
                    }
                    DSButton(recorder.isRecording ? "Отмена" : "Изменить", small: true) {
                        if recorder.isRecording { recorder.stop() } else { recorder.start(model) }
                    }
                    .help("Кликни и нажми новое сочетание. Esc — отмена, Delete — вернуть \(defaultHotKeyLabel)")
                }
                if let error = model.hotKeyError {
                    DSRow(icon: "exclamationmark.triangle.fill", title: error)
                }
            }
            if recorder.isRecording { caption("Esc — отмена, Delete — вернуть \(defaultHotKeyLabel)") }
        }
    }

    // MARK: - Универсальный доступ

    private var accessSection: some View {
        DSSection("Универсальный доступ") {
            if model.accessibilityTrusted {
                DSRow(icon: "hand.raised.fill", title: "Доступ есть",
                      subtitle: "По сочетанию выделенный текст берётся прямо из программы") {
                    TintedChip(text: "Есть", icon: "checkmark")
                }
            } else {
                DSRow(icon: "hand.raised.fill", title: "Нужен, чтобы читать по сочетанию",
                      subtitle: "Без него сочетание не видит выделенный текст. Меню «Службы» работает и так") {
                    DSButton("Дать доступ", icon: "hand.raised.fill", style: .primary, small: true) { model.requestAccessibility() }
                        .fixedSize()
                }
            }
        }
    }

    // MARK: - Службы

    private var servicesSection: some View {
        DSSection("Меню «Службы»") {
            DSRow(icon: "filemenu.and.selection", title: "Прочитать вслух",
                  subtitle: "Выдели текст → меню приложения → Службы → Прочитать вслух. Универсальный доступ не нужен")
            DSRow(icon: "keyboard", title: "Своё сочетание для службы",
                  subtitle: "Системные настройки → Клавиатура → Сочетания клавиш… → Службы → Текст")
        }
    }
}

extension SpeakSpeed {
    /// «1×», «1.5×», «0.75×»: без лишних нулей.
    static func label(_ value: Double) -> String { String(format: "%g×", value) }
}

/// Подписи голосов и языков по-русски, как в остальном интерфейсе.
enum SpeakVoiceNames {
    private static let russian = Locale(identifier: "ru")

    /// «Русский», «Английский». Неизвестный код — сам код.
    static func language(_ key: String) -> String {
        guard let name = russian.localizedString(forLanguageCode: key), !name.isEmpty else { return key }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    static func quality(_ quality: SpeakVoiceQuality) -> String? {
        switch quality {
        case .premium: return "премиум"
        case .enhanced: return "улучшенный"
        case .regular: return nil
        }
    }

    /// «Daniel, Великобритания · улучшенный». Страна — только если у языка голоса разных стран.
    static func title(_ voice: SpeakVoiceRow, among voices: [SpeakVoiceRow]) -> String {
        var text = voice.name
        if Set(voices.map(\.language)).count > 1, let region = region(voice.language) { text += ", " + region }
        if let quality = quality(voice.quality) { text += " · " + quality }
        return text
    }

    private static func region(_ tag: String) -> String? {
        let parts = tag.split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard parts.count > 1 else { return nil }
        return russian.localizedString(forRegionCode: String(parts[parts.count - 1]))
    }
}

/// Подписи краёв ползунка.
private struct SpeedMark: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
    }
}

// Акцент модуля задаёт `DSPage`, поэтому читать его надо ниже страницы — в этих мелких видах.

private struct SpeakSpeedSlider: View {
    @Binding var value: Double
    let editing: (Bool) -> Void
    @Environment(\.dsTint) private var tint
    var body: some View {
        Slider(value: $value, in: SpeakSpeed.range, step: SpeakSpeed.step, onEditingChanged: editing).tint(tint)
    }
}

private struct TintedChip: View {
    let text: String
    var icon: String?
    @Environment(\.dsTint) private var tint
    var body: some View { DSChip(text, color: tint, icon: icon) }
}
