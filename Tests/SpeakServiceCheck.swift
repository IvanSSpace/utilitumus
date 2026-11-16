import AppKit

// «Озвучка»: служба «Прочитать вслух», проводка модуля и мини-плеер. Синтезатор, чтение выделения и сочетание подменены
// (Tests/SpeakCheckStubs.swift), провайдер служб у системы не регистрируется, панель стенд не показывает, AX не трогается.
// Запуск: Tests/run-speak-service-check.sh. Сборка со швом KIT_TEST_DEFAULTS.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

/// Буфер, который система передала бы службе: данные отдаются лениво, и каждое чтение видно.
final class PasteboardSpy: NSObject {
    var text: String?
    var reads = 0
    @objc func pasteboard(_ sender: NSPasteboard, provideDataForType type: NSPasteboard.PasteboardType) {
        reads += 1
        if let text { sender.setString(text, forType: type) }
    }
}

/// Своё имя у каждого буфера: общий буфер обмена проверка не читает и не пишет.
@MainActor func servicePasteboard(_ spy: PasteboardSpy, _ text: String?) -> NSPasteboard {
    let board = NSPasteboard.withUniqueName()
    spy.text = text
    spy.reads = 0
    board.declareTypes([.string], owner: spy)
    return board
}

@MainActor func callService(_ provider: AnyObject?, _ board: NSPasteboard) -> String {
    guard let service = provider as? SpeakService else { return "провайдера нет" }
    var error: NSString = ""
    service.readAloud(board, userData: nil, error: &error)
    return error as String
}

MainActor.assumeIsolated {
    let suite = ProcessInfo.processInfo.environment["KIT_TEST_SUITE"] ?? ""
    check(suite.hasPrefix("local.utilitumus.test.kit.speak"), "настройки только в тестовом suite «Озвучки» (\(suite))")
    let secret = ProcessInfo.processInfo.environment["SPEAK_SECRET"] ?? "Тайна-\(UUID().uuidString)"
    var boards: [NSPasteboard] = []
    defer { for board in boards { board.releaseGlobally() } }

    // MARK: Селектор и провайдер
    let selector = NSSelectorFromString("readAloud:userData:error:")
    let stand = Stand()
    var installed: [AnyObject?] = []
    let module = SpeakModule(controller: stand.controller, installServices: { installed.append($0) })
    check(module.service.responds(to: selector), "у провайдера есть readAloud:userData:error: — NSMessage readAloud из Info.plist")

    // MARK: init ничего не запускает
    check(!stand.controller.canStart, "после init читать нельзя (canStart = false)")
    check(installed.isEmpty, "init не ставит провайдера служб")
    check(stand.hotKey.registered == nil && stand.hotKey.registerCalls == 0, "init не занимает сочетание")
    check(!module.player.visible, "init не показывает панель")

    let spy = PasteboardSpy()
    var board = servicePasteboard(spy, "Прочитай меня \(secret)")
    boards.append(board)
    check(module.service.read(board) == SpeakMessage.notRunning, "до start служба отказывает текстом «\(SpeakMessage.notRunning)»")
    check(spy.reads == 0, "до start переданный буфер даже не открыт")
    check(stand.synth.spoken.isEmpty, "до start ничего не прочитано")

    // MARK: start
    module.start()
    check(stand.controller.canStart, "start: читать можно")
    check(installed.count == 1 && installed.last.flatMap { $0 } === module.service, "start ставит провайдером службу модуля")
    check(stand.hotKey.registered != nil, "start занимает сочетание")

    // MARK: Чтение из переданного буфера
    let text = "Прочитай меня вслух, это из меню Службы. \(secret)"
    board = servicePasteboard(spy, text)
    boards.append(board)
    var error = callService(installed.last ?? nil, board)
    check(error.isEmpty, "служба читает без отказа (\(error.isEmpty ? "пусто" : "есть отказ"))")
    check(spy.reads >= 1, "текст взят из переданного системой буфера")
    check(stand.synth.spoken.count == 1 && stand.synth.last?.text == text,
          "синтезатор получил ровно текст этого буфера: общий буфер обмена с ним не совпал бы")
    check(stand.reader.reads == 0, "чтение выделения через AX не вызывалось")
    check(stand.controller.phase == .speaking, "фаза «читаю»")
    check(module.player.visible, "мини-плеер показан на время чтения")
    check(!module.mayRestart, "пока читает, перезапуск ради обновления нельзя")

    let wire = String(decoding: LinkWire.encoded(stand.controller.wireState), as: UTF8.self)
    let status = module.statusLine(passiveReason: nil)
    check(!wire.contains(secret) && !wire.contains("Прочитай"), "текста службы нет в состоянии для центра")
    check(!status.contains(secret) && !status.contains("Прочитай"), "текста службы нет в строке статуса (\(status))")
    check(!String(decoding: module.state(), as: UTF8.self).contains(secret), "текста службы нет в state() модуля")

    // MARK: Панель идёт за фазой
    stand.controller.pause()
    check(stand.controller.phase == .paused && module.player.visible, "пауза: панель остаётся")
    stand.controller.resume()
    check(stand.controller.phase == .speaking && module.player.visible, "продолжили: панель на месте")
    stand.controller.stopSpeaking()
    check(stand.controller.phase == .idle && !module.player.visible, "стоп: панель убрана")
    check(module.mayRestart, "без чтения перезапуск можно")

    // Повторный вызов службы обрывает текущее чтение и начинает новое.
    board = servicePasteboard(spy, "Первый")
    boards.append(board)
    _ = callService(installed.last ?? nil, board)
    board = servicePasteboard(spy, "Второй")
    boards.append(board)
    _ = callService(installed.last ?? nil, board)
    check(stand.synth.last?.text == "Второй" && stand.controller.phase == .speaking, "новый вызов службы читает новый текст")
    stand.synth.onFinish?(stand.synth.last?.id ?? 0)
    check(stand.controller.phase == .idle && !module.player.visible, "дочитал: фаза idle, панель убрана")

    // MARK: Отказы
    var before = stand.synth.spoken.count
    board = servicePasteboard(spy, "   \n\t ")
    boards.append(board)
    error = callService(installed.last ?? nil, board)
    check(error == SpeakService.noText && stand.synth.spoken.count == before, "пустой текст: отказ «\(SpeakService.noText)», ничего не прочитано")

    let images = NSPasteboard.withUniqueName()
    boards.append(images)
    images.declareTypes([NSPasteboard.PasteboardType("public.png")], owner: nil)
    error = callService(installed.last ?? nil, images)
    check(error == SpeakService.noText && stand.synth.spoken.count == before, "в буфере нет текста: тот же отказ")

    board = servicePasteboard(spy, String(repeating: "а", count: SpeakText.limit + 1))
    boards.append(board)
    error = callService(installed.last ?? nil, board)
    check(error == SpeakMessage.tooLong && stand.synth.spoken.count == before, "слишком длинный текст: отказ «\(SpeakMessage.tooLong)»")

    // MARK: stop
    module.stop()
    check(!stand.controller.canStart, "stop: читать нельзя")
    check(installed.count == 2 && installed.last! == nil, "stop снимает провайдера служб")
    check(stand.hotKey.registered == nil, "stop отпускает сочетание")
    check(!module.player.visible, "stop: панели нет")
    module.stop()
    check(installed.count == 2, "повторный stop ничего не трогает")

    before = stand.synth.spoken.count
    board = servicePasteboard(spy, "После остановки \(secret)")
    boards.append(board)
    check(module.service.read(board) == SpeakMessage.notRunning, "после stop служба отказывает")
    check(spy.reads == 0 && stand.synth.spoken.count == before, "после stop буфер не открыт и ничего не прочитано")

    // Модуль выключен, а провайдер ещё стоит (вызов успел прийти): canStart всё равно не даёт читать.
    stand.controller.canStart = false
    let late = SpeakService(controller: stand.controller, install: { _ in })
    board = servicePasteboard(spy, "Опоздавший вызов")
    boards.append(board)
    error = callService(late, board)
    check(error == SpeakMessage.notRunning && spy.reads == 0 && stand.synth.spoken.count == before,
          "canStart = false: отказ, буфер не открыт, ничего не прочитано")

    // MARK: Шаг настройки
    // Право стенда задаёт ключ шва: настоящий AX не спрашивается.
    Kit.defaults.set(false, forKey: "Test.AXTrusted")
    let axStep = module.setupSteps.first { $0.id == "speak.ax" }
    check(axStep?.required == false && axStep?.done == false,
          "«Универсальный доступ» — необязательный шаг: без права работают «Службы», центр не пишет «нужен доступ»")
    Kit.defaults.removeObject(forKey: "Test.AXTrusted")

    // MARK: Запуск снова
    module.start()
    check(installed.count == 3 && installed.last.flatMap { $0 } === module.service, "снова start: провайдер снова стоит")

    // Текст по сочетанию ещё берётся: перезапуск между ⌘C и возвратом буфера оставил бы в нём чужое выделение.
    stand.reader.hold = true
    stand.reader.result = .text("Берётся")
    stand.hotKey.press()
    check(stand.controller.reading != nil && stand.controller.phase == .idle && !module.mayRestart,
          "пока текст по сочетанию берётся, перезапуск ради обновления нельзя")
    module.stop()

    // MARK: Место панели
    let screen = (frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visible: CGRect(x: 0, y: 0, width: 1440, height: 875))
    let size = SpeakPlayerView<SpeakController>.size
    let middle = SpeakPlayer.origin(size: size, cursor: CGPoint(x: 700, y: 500), screens: [screen], main: screen.visible)
    check(middle == CGPoint(x: 714, y: 500 - 14 - size.height), "у курсора: справа снизу (\(middle))")
    let corner = SpeakPlayer.origin(size: size, cursor: CGPoint(x: 1435, y: 20), screens: [screen], main: screen.visible)
    let cornerRect = CGRect(origin: corner, size: size)
    check(screen.visible.insetBy(dx: 7.9, dy: 7.9).contains(cornerRect), "у края экрана панель целиком на экране (\(cornerRect))")
    check(corner.y > 20, "у нижнего края — над курсором, а не под ним")
    let second = (frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), visible: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
    let onSecond = SpeakPlayer.origin(size: size, cursor: CGPoint(x: 2000, y: 600), screens: [screen, second], main: screen.visible)
    check(second.visible.contains(CGRect(origin: onSecond, size: size)), "на втором экране — на нём (\(onSecond))")
    let lost = SpeakPlayer.origin(size: size, cursor: CGPoint(x: -500, y: -500), screens: [screen], main: screen.visible)
    check(lost == CGPoint(x: 1440 - size.width - 16, y: 875 - size.height - 16), "курсор вне экранов — правый верхний угол (\(lost))")
    check(SpeakPlayer.origin(size: size, cursor: .zero, screens: [], main: nil) == .zero, "экранов нет — начало координат")
}

print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
exit(failures == 0 ? 0 : 1)
