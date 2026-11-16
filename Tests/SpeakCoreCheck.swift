import AppKit
import AVFoundation
import Carbon.HIToolbox

// Ядро «Озвучки» без настоящего звука, AX и горячей клавиши: синтезатор, чтение выделения и сочетание подменены.
// Запуск: Tests/run-speak-core-check.sh. Сборка со швом KIT_TEST_DEFAULTS: настройки только в своём тестовом suite.
// Текст по нажатию берётся асинхронно: проверка ждёт его через `Stand.press()`.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

Task { @MainActor in
    await run()
    print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()

@MainActor func run() async {
    let suite = ProcessInfo.processInfo.environment["KIT_TEST_SUITE"] ?? ""
    check(suite.hasPrefix("local.utilitumus.test.kit.speak"), "настройки только в тестовом suite «Озвучки» (\(suite))")
    foreignDefaults("delete", suite)
    Kit.defaults.synchronize()

    // MARK: Скорость → rate
    let normal = SpeakRate.utteranceRate(forSpeed: 1.0)
    check(normal == AVSpeechUtteranceDefaultSpeechRate, "1× — ровно AVSpeechUtteranceDefaultSpeechRate (\(normal))")
    let slow = SpeakRate.utteranceRate(forSpeed: 0.5)
    let fast = SpeakRate.utteranceRate(forSpeed: 3.0)
    check(slow >= AVSpeechUtteranceMinimumSpeechRate && slow < normal, "0,5× в шкале и медленнее обычной (\(slow))")
    check(fast <= AVSpeechUtteranceMaximumSpeechRate && fast > normal, "3× в шкале и быстрее обычной (\(fast))")
    check(abs(fast - 0.8333) < 0.001, "3× ≈ 0,833 по замеру 1 + 6·(rate − 0,5) (\(fast))")
    check(abs(SpeakRate.utteranceRate(forSpeed: 0.75) - 0.25) < 0.0001, "ниже 1× по замеру 0,5 + rate: 0,75× → 0,25")
    var grid = Array(stride(from: 0.5, through: 3.0, by: 0.25)).map { SpeakRate.utteranceRate(forSpeed: $0) }
    check(zip(grid, grid.dropFirst()).allSatisfy { $0 < $1 }, "по отметкам 0,5…3 rate строго растёт")
    grid = [SpeakRate.utteranceRate(forSpeed: 0.1), SpeakRate.utteranceRate(forSpeed: 10), SpeakRate.utteranceRate(forSpeed: .nan)]
    check(grid == [slow, fast, normal], "за краями — край, не число — обычная скорость")

    // MARK: Шаг скорости
    check(SpeakSpeed.stepped(1.0, 1) == 1.25 && SpeakSpeed.stepped(1.0, -1) == 0.75, "шаг от 1×: 1,25 и 0,75")
    check(SpeakSpeed.stepped(1.1, 1) == 1.25 && SpeakSpeed.stepped(1.1, -1) == 1.0, "шаг с 1,1 — к соседним отметкам")
    check(SpeakSpeed.stepped(3.0, 1) == 3.0 && SpeakSpeed.stepped(0.5, -1) == 0.5, "шаг за край стоит на краю")
    check(SpeakSpeed.clamped(5) == 3 && SpeakSpeed.clamped(0.1) == 0.5 && SpeakSpeed.clamped(.infinity) == nil, "скорость в диапазоне")

    // MARK: Лимит
    check(SpeakText.fits(String(repeating: "а", count: SpeakText.limit)), "ровно 50 000 символов — читаем")
    check(!SpeakText.fits(String(repeating: "а", count: SpeakText.limit + 1)), "50 001 — нет")

    // MARK: Выбор голоса
    check(SpeakVoiceChooser.language(of: russian) == "ru" && SpeakVoiceChooser.language(of: english) == "en", "язык текста: ru и en")
    check(SpeakVoiceChooser.choose(for: russian, voices: voices, pinned: [:], preferred: ["en-US"]) == "ru.yuri.premium",
          "Авто: русский текст — лучший русский голос (premium)")
    check(SpeakVoiceChooser.choose(for: english, voices: voices, pinned: [:], preferred: ["ru-RU", "en-US"]) == "en.alex",
          "Авто: при равном качестве — регион из языков системы (en-US)")
    check(SpeakVoiceChooser.choose(for: english, voices: voices, pinned: [:], preferred: ["en-GB"]) == "en.daniel",
          "Авто: с британским в системе — британский")
    check(SpeakVoiceChooser.choose(for: english, voices: voices, pinned: ["en": "en.samantha"], preferred: ["ru-RU"]) == "en.samantha",
          "закреплённый голос побеждает Авто")
    check(SpeakVoiceChooser.choose(for: english, voices: voices, pinned: ["en": "en.gone"], preferred: ["en-US"]) == "en.alex",
          "закреплённый голос исчез — Авто")
    check(SpeakVoiceChooser.choose(for: "12345 67", voices: voices, pinned: [:], preferred: ["ru-RU"]) == "ru.yuri.premium",
          "язык не понять — язык системы")
    check(SpeakVoiceChooser.choose(for: "Bonjour à tous, il fait très beau aujourd'hui.", voices: voices, pinned: [:], preferred: ["ru-RU"]) == nil,
          "голосов языка нет — голос системы (nil)")

    // MARK: До start ничего не занято и не читается
    var stand = Stand()
    var c = stand.controller
    check(stand.hotKey.registerCalls == 0, "init не занимает сочетание")
    stand.reader.result = .text(russian)
    await stand.press()
    check(stand.reader.reads == 0 && stand.synth.spoken.isEmpty, "до start нажатие ничего не читает")
    stand.reader.result = .notTrusted
    await stand.press()
    check(stand.reader.reads == 0 && stand.screen.opens == 0 && c.message == nil, "до start нажатие без права экран модуля не открывает")
    stand.reader.result = .text(russian)
    check(c.speak(text: russian) == SpeakMessage.notRunning && stand.synth.spoken.isEmpty, "до start Службы не читают")

    c.start()
    check(stand.hotKey.registered?.keyCode == UInt32(kVK_ANSI_S)
          && stand.hotKey.registered?.modifiers == UInt32(controlKey | optionKey | shiftKey), "start занимает ⌃⌥⇧S")
    check(c.hotKeyLabel == "⌃⌥⇧S", "подпись сочетания ⌃⌥⇧S")
    check(c.voices == voices, "start берёт голоса системы")

    // MARK: Нажатие читает, повторное останавливает
    await stand.press()
    check(stand.reader.reads == 1 && stand.synth.spoken.count == 1 && c.phase == .speaking, "нажатие читает выделенное")
    check(stand.synth.last?.text == russian && stand.synth.last?.rate == AVSpeechUtteranceDefaultSpeechRate,
          "весь текст, обычная скорость")
    check(stand.synth.last?.voiceID == "ru.yuri.premium", "голос по Авто")
    check(c.message == nil, "сообщения нет")
    await stand.press()
    check(c.phase == .idle && stand.synth.calls.last == "stop" && stand.reader.reads == 1, "повторное нажатие останавливает и не читает")

    // Чтение кончилось само.
    await stand.press()
    let finishedID = stand.synth.last!.id
    stand.synth.onFinish?(finishedID)
    check(c.phase == .idle, "конец чтения — снова ждём")
    stand.synth.onFinish?(finishedID)
    check(c.phase == .idle, "лишний колбэк безвреден")

    // MARK: Пауза и продолжение
    await stand.press()
    c.pause()
    check(c.phase == .paused && stand.synth.calls.last == "pause", "пауза")
    c.pause()
    check(stand.synth.calls.filter { $0 == "pause" }.count == 1, "повторная пауза ничего не делает")
    c.resume()
    check(c.phase == .speaking && stand.synth.calls.last == "resume", "продолжить")
    await stand.press()
    check(c.phase == .idle, "нажатие на паузе тоже останавливает")
    let pausedCount = stand.synth.calls.count
    c.resume()
    c.pause()
    check(stand.synth.calls.count == pausedCount && c.phase == .idle, "пауза и продолжение без чтения — ничего")

    // MARK: Смена скорости во время чтения — остаток с текущего слова
    let text = "Раз два три четыре пять шесть"
    stand.reader.result = .text(text)
    stand.synth.finishOnStopNow = false
    await stand.press()
    let first = stand.synth.last!.id
    let tri = (text as NSString).range(of: "три")
    stand.synth.onRange?(first, tri)
    c.setSpeed(2.0)
    check(stand.synth.spoken.count >= 2 && stand.synth.last?.text == "три четыре пять шесть", "скорость сменили — остаток с «три»")
    check(stand.synth.last?.rate == SpeakRate.utteranceRate(forSpeed: 2.0), "остаток с новой скоростью")
    check(c.phase == .speaking, "и чтение продолжается")
    stand.synth.flush()
    check(c.phase == .speaking, "запоздалый «конец» старого чтения не останавливает новое")
    // Позиция в остатке считается от начала всего текста.
    let second = stand.synth.last!.id
    stand.synth.onRange?(second, NSRange(location: ("три четыре " as NSString).length, length: 4))
    stand.synth.onRange?(first, NSRange(location: 0, length: 3))
    c.stepSpeed(1)
    check(stand.synth.last?.text == "пять шесть" && c.speed == 2.25, "второй перезапуск: «пять шесть», 2,25×; позиция старого чтения отброшена")

    // На паузе: ничего не читаем до «Продолжить», потом остаток с новой скоростью.
    let pendingSpeakCount = stand.synth.spoken.count
    c.pause()
    let third = stand.synth.last!.id
    stand.synth.onRange?(third, NSRange(location: ("пять " as NSString).length, length: 5))
    c.setSpeed(1.5)
    stand.synth.flush()
    check(c.phase == .paused && stand.synth.spoken.count == pendingSpeakCount, "скорость на паузе: пауза остаётся, вслух ничего")
    let callsOnPause = stand.synth.calls.count
    c.setSpeed(1.75)
    check(stand.synth.calls.count == callsOnPause && c.phase == .paused, "вторая смена на паузе синтезатор не трогает")
    c.resume()
    check(c.phase == .speaking && stand.synth.last?.text == "шесть" && stand.synth.last?.rate == SpeakRate.utteranceRate(forSpeed: 1.75),
          "«Продолжить» читает остаток «шесть» с последней скоростью")
    c.stopSpeaking()
    stand.synth.flush()
    stand.synth.finishOnStopNow = true
    check(c.phase == .idle, "стоп")

    // Составной символ: смещение посреди эмодзи даёт начало символа.
    stand.reader.result = .text("а 👍🏽 б")
    await stand.press()
    stand.synth.onRange?(stand.synth.last!.id, NSRange(location: 3, length: 1))
    c.setSpeed(1.0)
    check(stand.synth.last?.text == "👍🏽 б", "перезапуск не режет составной символ")
    c.stopSpeaking()

    // MARK: Сообщения
    stand.reader.result = .none
    await stand.press()
    check(c.message == SpeakMessage.noSelection && c.phase == .idle, ".none — «Не вижу выделенный текст…»")
    stand.reader.result = .text("   \n ")
    await stand.press()
    check(c.message == SpeakMessage.noSelection && c.phase == .idle, "пробелы — тоже «не вижу»")
    stand.reader.result = .secureField
    await stand.press()
    check(c.message == SpeakMessage.secureField && c.phase == .idle, ".secureField — «Из поля пароля не читаю»")
    check(stand.screen.opens == 0, ".text, .none и .secureField экран модуля не открывают")
    let spokenBefore = stand.synth.spoken.count
    stand.reader.result = .notTrusted
    await stand.press()
    check(c.message == SpeakMessage.needAccess && !c.accessibilityTrusted, ".notTrusted — «Нужен Универсальный доступ…»")
    check(stand.screen.opens == 1, ".notTrusted — экран модуля открыт один раз")
    await stand.press()
    check(stand.screen.opens == 2 && c.message == SpeakMessage.needAccess, "второе нажатие без права — ещё один раз, не больше")
    stand.reader.result = .text(String(repeating: "я", count: SpeakText.limit + 1))
    await stand.press()
    check(c.message == SpeakMessage.tooLong && c.phase == .idle && c.accessibilityTrusted, "длиннее лимита — не читаем, сообщение")
    check(stand.synth.spoken.count == spokenBefore, "ни в одном из этих случаев синтезатор не звали")
    stand.reader.result = .text(String(repeating: "я", count: SpeakText.limit))
    await stand.press()
    check(c.phase == .speaking && c.message == nil, "ровно лимит — читаем, сообщение ушло")
    let readsSpeaking = stand.reader.reads
    stand.reader.result = .notTrusted
    await stand.press()
    check(c.phase == .idle && stand.reader.reads == readsSpeaking && stand.screen.opens == 2,
          "нажатие во время чтения только обрывает: выделение не читается, экран не открывается")
    c.stopSpeaking()
    stand.reader.result = .secureInput
    await stand.press()
    check(c.message == SpeakMessage.secureInput && c.phase == .idle, ".secureInput — «Включён защищённый ввод…»")
    stand.reader.result = .pasteboardDenied
    await stand.press()
    check(c.message == SpeakMessage.pasteboardDenied && c.phase == .idle, ".pasteboardDenied — сообщение про доступ к буферу")
    check(SpeakMessage.pasteboardDenied.contains("Конфиденциальность и безопасность → Вставка из других приложений"),
          "сообщение про буфер ведёт в раздел по локализации macOS")
    check(stand.synth.spoken.count == spokenBefore + 1 && stand.screen.opens == 2, "защищённый ввод и запрет буфера: не читаем, экран не открываем")

    // MARK: Копирование через ⌘C: переключатель
    check(c.copyFallback && Kit.defaults.object(forKey: SpeakKeys.copyFallback) == nil, "копирование через ⌘C по умолчанию включено, ключа нет")
    check(stand.reader.copyFallbacks.allSatisfy { $0 }, "включённое копирование доходит до чтения выделения")
    c.setCopyFallback(false)
    check(!c.copyFallback && Kit.defaults.object(forKey: SpeakKeys.copyFallback) as? Bool == false, "выключили — false в Kit.defaults")
    stand.reader.result = .none
    await stand.press()
    check(stand.reader.copyFallbacks.last == false, "выключенное копирование доходит до чтения выделения")
    check(c.message == SpeakMessage.noSelectionCopyOff, "копирование выключено и текста нет — подсказка про переключатель")
    check(SpeakMessage.noSelectionCopyOff.contains("Службы") && SpeakMessage.noSelectionCopyOff.contains("⌘C"), "подсказка: Службы и ⌘C")
    c.setCopyFallback(true)
    await stand.press()
    check(c.message == SpeakMessage.noSelection, "копирование включено и текста нет — без подсказки про переключатель")

    // MARK: Нажатие, пока текст ещё берётся
    stand.reader.hold = true
    stand.reader.result = .text(russian)
    let readsBefore = stand.reader.reads
    let spokenHeld = stand.synth.spoken.count
    stand.hotKey.press()
    await settle()
    check(stand.reader.waiting && c.reading != nil && c.phase == .idle, "текст берётся: фаза не меняется")
    stand.hotKey.press()
    await settle()
    check(stand.reader.reads == readsBefore + 1, "второе нажатие, пока текст берётся, второго чтения не начинает")
    let pending = c.reading
    stand.reader.release()
    await pending?.value
    check(c.reading == nil && c.phase == .speaking && stand.synth.spoken.count == spokenHeld + 1,
          "текст взялся — одно чтение вслух, не два")
    c.stopSpeaking()

    // Пока текст брался, начали читать из «Служб»: запоздалое выделение его не перебивает.
    stand.reader.hold = true
    stand.hotKey.press()
    await settle()
    check(c.speak(text: english) == nil && stand.synth.last?.text == english, "Службы, пока текст берётся, читают")
    let late = c.reading
    stand.reader.release()
    await late?.value
    check(stand.synth.last?.text == english && c.phase == .speaking, "запоздалое выделение не перебивает «Службы»")
    c.stopSpeaking()

    // MARK: Службы
    let reads = stand.reader.reads
    check(c.speak(text: english) == nil && c.phase == .speaking && stand.reader.reads == reads, "Службы читают без AX")
    check(stand.synth.last?.voiceID == "en.alex", "Службы: голос по языку текста")
    check(c.speak(text: russian) == nil && stand.synth.last?.text == russian, "Службы во время чтения: новое вместо старого")
    check(c.speak(text: "  ") == SpeakMessage.noSelection && c.phase == .idle, "Службы с пустым текстом — сообщение")
    c.canStart = false
    check(c.speak(text: russian) == SpeakMessage.notRunning, "canStart = false — Службы не читают")
    let readsBlocked = stand.reader.reads
    let opensBlocked = stand.screen.opens
    stand.reader.result = .notTrusted
    await stand.press()
    check(stand.reader.reads == readsBlocked && stand.screen.opens == opensBlocked, "canStart = false — нажатие не читает и экран не открывает")
    c.canStart = true

    // MARK: Голоса через контроллер
    c.pinVoice(language: "en", id: "en.samantha")
    c.speak(text: english)
    check(stand.synth.last?.voiceID == "en.samantha", "закреплённый на en голос читает английский")
    check(c.pinError(language: "en", id: "ru.milena") != nil && c.pinError(language: "en", id: "nope") != nil, "чужой язык и чужой id не закрепить")
    stand.synth.voiceList = voices.filter { $0.id != "en.samantha" }
    c.speak(text: english)
    check(stand.synth.last?.voiceID == "en.alex" && c.pinnedVoices["en"] == "en.samantha", "голос пропал — Авто, закрепление помнится")
    stand.synth.voiceList = voices
    c.unpin(language: "en")
    check(c.pinnedVoices.isEmpty && Kit.defaults.object(forKey: SpeakKeys.pinnedVoices) == nil, "открепить — ключ убран")
    c.pinVoice(language: "ru", id: "ru.milena")
    c.setVoiceAuto()
    check(c.pinnedVoices.isEmpty, "«Авто» снимает все закрепления")
    c.stopSpeaking()

    // MARK: Связь
    @MainActor func reply(_ action: String) -> LinkReply<SpeakState>? {
        try? JSONDecoder().decode(LinkReply<SpeakState>.self, from: c.handle(Data(action.utf8)))
    }
    check(reply(#"{"setSpeed":{"_0":2}}"#)?.state.speed == 2 && c.speed == 2, "связь: setSpeed")
    check(reply(#"{"stepSpeed":{"_0":-1}}"#)?.state.speed == 1.75, "связь: stepSpeed −1")
    check(reply(#"{"stepSpeed":{"_0":5}}"#)?.error != nil && c.speed == 1.75, "связь: шаг не ±1 — отказ")
    check(reply(#"{"pinVoice":{"id":"ru.katya","language":"ru"}}"#)?.state.pinnedVoices == ["ru": "ru.katya"], "связь: pinVoice")
    check(reply(#"{"pinVoice":{"id":"zzz","language":"ru"}}"#)?.error == "Такого голоса нет", "связь: чужой голос — отказ")
    check(reply(#"{"unpin":{"language":"ru"}}"#)?.state.pinnedVoices == [:], "связь: unpin")
    check(reply(#"{"pause":{}}"#)?.error != nil, "связь: пауза без чтения — отказ")
    check(reply(#"{"stop":{}}"#)?.error == nil, "связь: stop без чтения безвреден")
    check(reply(#"{"setHotKey":{"keyCode":1,"modifiers":0}}"#)?.error != nil, "связь: S без модификатора не принимается")
    check(reply(#"{"toggle":{}}"#)?.error == "Непонятная команда", "связь: чужое действие — отказ")
    check(reply(#"{"stop":{},"pause":{}}"#)?.error == "Непонятная команда", "связь: два действия разом — отказ")
    check(reply(#"{"setCopyFallback":{"_0":false}}"#)?.state.copyFallback == false && !c.copyFallback, "связь: setCopyFallback false")
    check(reply(#"{"setCopyFallback":{"_0":true}}"#)?.state.copyFallback == true && c.copyFallback, "связь: setCopyFallback true")
    check(reply(#"{"setCopyFallback":{}}"#)?.error == "Непонятная команда" && c.copyFallback, "связь: setCopyFallback без значения — отказ")
    check(reply(#"{"setCopyFallback":{"_0":"нет"}}"#)?.error == "Непонятная команда" && c.copyFallback, "связь: setCopyFallback не Bool — отказ")
    let roundTrip: [SpeakAction] = [.setSpeed(1.5), .stepSpeed(1), .setVoiceAuto, .pinVoice(language: "en", id: "en.alex"), .unpin(language: "en"),
                                    .pause, .resume, .stop, .setHotKey(keyCode: 1, modifiers: 4096), .resetHotKey, .suspendHotKey,
                                    .resumeHotKey, .refreshPermissions, .requestAccessibility, .setCopyFallback(false), .setCopyFallback(true)]
    check(roundTrip.allSatisfy { LinkWire.decodeAction(SpeakAction.self, from: LinkWire.encoded($0), limit: 512) == $0 },
          "все действия проходят связь туда и обратно")

    // MARK: Сочетание
    c.setHotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | optionKey))
    check(stand.hotKey.registered?.keyCode == UInt32(kVK_ANSI_R) && c.hotKeyLabel == "⌥⌘R", "новое сочетание занято")
    c.suspendHotKey()
    check(stand.hotKey.registered == nil, "запись сочетания: текущее отпущено")
    c.resumeHotKey()
    check(stand.hotKey.registered?.keyCode == UInt32(kVK_ANSI_R), "после записи занято снова")
    stand.hotKey.busy = true
    c.resetHotKey()
    check(c.hotKeyError == SpeakMessage.hotKeyBusy, "занятое сочетание — сообщение")
    stand.hotKey.busy = false
    c.resumeHotKey()
    check(c.hotKeyError == nil && stand.hotKey.registered?.keyCode == UInt32(kVK_ANSI_S), "освободилось — занято, сообщения нет")

    // MARK: stop снимает сочетание и обрывает речь
    stand.reader.result = .text(russian)
    await stand.press()
    c.stop()
    check(stand.hotKey.registered == nil && c.phase == .idle && stand.synth.calls.last == "stop", "stop: сочетание отпущено, чтение оборвано")
    let readsStopped = stand.reader.reads
    await stand.press()
    check(stand.reader.reads == readsStopped, "после stop нажатие ничего не читает")
    c.stop()
    check(stand.hotKey.registered == nil, "повторный stop безвреден")

    // stop, пока текст берётся: выделение не читается, даже если модуль сразу включили снова.
    c.start()
    stand.reader.hold = true
    stand.reader.result = .text(russian)
    let spokenBeforeStop = stand.synth.spoken.count
    stand.hotKey.press()
    await settle()
    let cancelled = c.reading
    c.stop()
    c.start()
    stand.reader.release()
    await cancelled?.value
    check(c.reading == nil && c.phase == .idle && stand.synth.spoken.count == spokenBeforeStop,
          "stop, пока текст берётся: взятый текст не читается и после нового start")
    await stand.press()
    check(c.phase == .speaking, "после такого stop нажатие снова читает")
    c.stop()

    // MARK: Настройки помнятся между экземплярами и перечитываются в start
    c.setSpeed(1.25)
    c.pinVoice(language: "en", id: "en.daniel")
    stand = Stand()
    c = stand.controller
    check(c.speed == 1.25 && c.pinnedVoices == ["en": "en.daniel"], "новый экземпляр: скорость и голос из настроек")
    check(c.hotKeyLabel == "⌃⌥⇧S", "новый экземпляр: сочетание из настроек")
    foreignDefaults("write", suite, SpeakKeys.speed, "-float", "2.5")
    foreignDefaults("write", suite, SpeakKeys.keyCode, "-int", String(kVK_ANSI_T))
    foreignDefaults("write", suite, SpeakKeys.copyFallback, "-bool", "false")
    c.start()
    check(c.speed == 2.5, "start: скорость, записанная другим процессом")
    check(!c.copyFallback && !c.wireState.copyFallback, "start: выключенное другим процессом копирование через ⌘C")
    foreignDefaults("delete", suite, SpeakKeys.copyFallback)
    check(stand.hotKey.registered?.keyCode == UInt32(kVK_ANSI_T), "start: сочетание, записанное другим процессом")
    foreignDefaults("write", suite, SpeakKeys.speed, "-float", "99")
    c.start()
    check(c.speed == 3.0, "start: чужая скорость приводится в диапазон")
    c.stop()

    foreignDefaults("delete", suite)
    Kit.defaults.synchronize()
    stand = Stand()
    c = stand.controller
    var published = 0
    let subscription = c.objectWillChange.sink { _ in published += 1 }
    c.start()
    c.stop()
    subscription.cancel()
    check(c.speed == SpeakSpeed.normal && c.pinnedVoices.isEmpty, "настроек нет — значения по умолчанию")
    check(Kit.defaults.object(forKey: SpeakKeys.speed) == nil && Kit.defaults.object(forKey: SpeakKeys.keyCode) == nil,
          "start без изменений не создаёт ключи")
    check(published <= 1, "start без изменений будит не больше раза: только голоса (\(published))")
    check(c.copyFallback && Kit.defaults.object(forKey: SpeakKeys.copyFallback) == nil, "start без изменений: копирование включено, ключа нет")
}
