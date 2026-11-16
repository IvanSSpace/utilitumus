import AppKit

// «Озвучка»: прочитанный текст живёт только в памяти контроллера, пока идёт чтение. После него текста нет
// ни в контроллере, ни в состоянии для центра, ни в строке статуса, ни в настройках. Запуск: Tests/run-speak-privacy-check.sh,
// он же ищет текст в выводе этой проверки, в файлах подставного дома и в тестовом suite настроек.
// Сам текст проверка не печатает никогда: только «ok/FAIL» и названия шагов.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

/// Есть ли строка в значении и во всех его полях. Чужие объекты (подмены) не обходим: ищем то, что держит сам контроллер.
func holds(_ value: Any, _ needle: String, depth: Int = 0) -> Bool {
    if depth > 12 { return false }
    if let text = value as? String { return text.contains(needle) }
    if let text = value as? Substring { return text.contains(needle) }
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .class && depth > 0 { return false }
    return mirror.children.contains { holds($0.value, needle, depth: depth + 1) }
}

MainActor.assumeIsolated {
    let env = ProcessInfo.processInfo.environment
    let suite = env["KIT_TEST_SUITE"] ?? ""
    check(suite.hasPrefix("local.utilitumus.test.kit.speak"), "настройки только в тестовом suite «Озвучки»")
    guard let secret = env["SPEAK_SECRET"], secret.count > 20, let tail = secret.split(separator: "-", maxSplits: 1).last.map(String.init) else {
        check(false, "нет SPEAK_SECRET: запускать через Tests/run-speak-privacy-check.sh")
        return
    }
    foreignDefaults("delete", suite)
    Kit.defaults.synchronize()

    let stand = Stand()
    let c = stand.controller
    let sentence = "Пароль от банка: \(secret). Никому его не говори, даже маме."

    /// Текста нет ни в одном месте, которое уходит из памяти чтения наружу.
    @MainActor func clean(_ step: String) {
        let json = String(decoding: LinkWire.encoded(c.wireState), as: UTF8.self)
        check(!json.contains(secret) && !json.contains(tail), "\(step): состояние для центра без текста")
        let status = [c.statusLine(passiveReason: nil), c.statusLine(passiveReason: "Ведёт центр"), c.message ?? "", c.hotKeyLabel, c.hotKeyError ?? ""]
        check(!status.contains { $0.contains(secret) || $0.contains(tail) }, "\(step): строка статуса и сообщение без текста")
    }

    c.start()
    check(!holds(c, tail), "до чтения текста в контроллере нет")

    // Чтение по сочетанию.
    stand.reader.result = .text(sentence)
    stand.hotKey.press()
    check(c.phase == .speaking && stand.synth.last?.text == sentence, "чтение по сочетанию идёт")
    check(holds(c, tail), "проверка видит текст в памяти контроллера, пока он читает")
    clean("читает")

    // Перезапуск с новой скоростью: остаток тоже текст.
    let id = stand.synth.last!.id
    stand.synth.onRange?(id, (sentence as NSString).range(of: secret))
    c.setSpeed(2)
    check(stand.synth.last?.text.hasPrefix(secret) == true, "остаток с новой скоростью начинается с секрета")
    clean("сменили скорость")
    c.pause()
    clean("пауза")
    let reply = String(decoding: c.handle(LinkWire.encoded(SpeakAction.stop)), as: UTF8.self)
    check(!reply.contains(tail), "ответ на действие без текста")
    check(c.phase == .idle && !holds(c, tail), "после «стоп» текста в контроллере нет")
    clean("остановили")

    // Дочитал до конца сам.
    stand.hotKey.press()
    stand.synth.onFinish?(stand.synth.last!.id)
    check(c.phase == .idle && !holds(c, tail), "дочитал — текста в контроллере нет")

    // Повторное нажатие.
    stand.hotKey.press()
    stand.hotKey.press()
    check(c.phase == .idle && !holds(c, tail), "остановили нажатием — текста нет")

    // Службы.
    check(c.speak(text: sentence) == nil, "Службы читают")
    clean("Службы")
    c.stopSpeaking()
    check(!holds(c, tail), "после Служб текста нет")

    // Отказы: текст не задерживается и не попадает в сообщение.
    stand.reader.result = .text(sentence + String(repeating: " ещё", count: SpeakText.limit / 4))
    stand.hotKey.press()
    check(c.message == SpeakMessage.tooLong && !holds(c, tail), "длинный текст: только сообщение, текста нет")
    clean("длинный текст")
    stand.reader.result = .secureField
    stand.hotKey.press()
    check(c.message == SpeakMessage.secureField && !holds(c, tail), "поле пароля: только сообщение")

    // Модуль выключили посреди чтения.
    stand.reader.result = .text(sentence)
    stand.hotKey.press()
    c.stop()
    check(c.phase == .idle && !holds(c, tail), "stop посреди чтения — текста нет")
    clean("модуль выключен")

    // Настройки: скорость записана, текста нет.
    Kit.defaults.synchronize()
    let domain = Kit.defaults.persistentDomain(forName: suite) ?? [:]
    check(domain[SpeakKeys.speed] as? Double == 2, "в настройках есть скорость: смотрим тот самый suite")
    check(!"\(domain)".contains(tail) && !"\(Kit.defaults.dictionaryRepresentation())".contains(tail), "в настройках текста нет")
}

print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
exit(failures == 0 ? 0 : 1)
