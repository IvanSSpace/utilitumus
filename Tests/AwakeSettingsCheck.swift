import Combine
import Foundation

// `AwakeController.start()` читает настройки заново. Запуск: Tests/run-awake-settings-check.sh
// Сборка со швом KIT_TEST_DEFAULTS: только suite стенда. Другой процесс здесь — настоящий `defaults`.

let suite = "local.utilitumus.test.kit"
var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

/// Запись другого процесса, как у утилиты или центра.
func foreignDefaults(_ arguments: String...) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    process.arguments = arguments
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
}

MainActor.assumeIsolated {
    foreignDefaults("delete", suite)
    let controller = AwakeController.shared
    check(!controller.keepDisplay && controller.duration == .forever, "настроек нет: значения по умолчанию")

    // Модуль стоит, настройки меняет другой процесс.
    controller.stop()
    foreignDefaults("write", suite, AwakeController.displayKey, "-bool", "true")
    foreignDefaults("write", suite, AwakeController.durationKey, "-int", "3600")
    controller.start()
    check(controller.keepDisplay, "start: «экран не гаснет» из настроек, не из памяти")
    check(controller.duration == .hour1, "start: длительность из настроек, не из памяти")
    controller.activate()
    check(controller.endDate != nil, "и блокировка включается уже с новым сроком")
    controller.deactivate()

    // Значение в памяти свежее не становится: оно выставлено здесь, а потом переписано снаружи.
    controller.stop()
    controller.duration = .hour2
    foreignDefaults("write", suite, AwakeController.durationKey, "-int", "14400")
    controller.start()
    check(controller.duration == .hour4, "start: своё прошлое значение не побеждает чужое новое")

    // Утилиту сняли и поставили заново, ключей больше нет.
    controller.stop()
    foreignDefaults("delete", suite)
    controller.start()
    check(!controller.keepDisplay && controller.duration == .forever, "start: ключей нет — значения по умолчанию")

    foreignDefaults("write", suite, AwakeController.durationKey, "-int", "12345")
    controller.start()
    check(controller.duration == .forever, "start: чужая длительность не принимается")

    // Ничего не изменилось — никого не будим и не пишем.
    foreignDefaults("delete", suite)
    Kit.defaults.synchronize()
    var published = 0
    let subscription = controller.objectWillChange.sink { _ in published += 1 }
    controller.start()
    subscription.cancel()
    check(published == 0, "start без изменений никого не будит (\(published))")
    check(Kit.defaults.object(forKey: AwakeController.displayKey) == nil && Kit.defaults.object(forKey: AwakeController.durationKey) == nil,
          "start без изменений не создаёт ключи")
}

print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
exit(failures == 0 ? 0 : 1)
