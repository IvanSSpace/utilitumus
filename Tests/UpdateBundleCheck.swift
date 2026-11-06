import Foundation

// Установка обновления центра: режимы файлов и повторная проверка копии перед заменой.
// Всё в папке стенда; настоящий /Applications не упоминается.

var failed = false
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print((ok ? "ok   " : "ПРОВАЛ ") + name + (ok ? "" : ": " + detail()))
    if !ok { failed = true }
}

let fm = FileManager.default
let good = URL(fileURLWithPath: CommandLine.arguments[1])
let root = URL(fileURLWithPath: CommandLine.arguments[2])
let version = "9.9.9"
let staged = root.appendingPathComponent("Utilitumus.app.new")
let target = root.appendingPathComponent("Utilitumus.app")
let data = "Contents/Resources/data.txt"

func freshTarget() {
    try? fm.removeItem(at: target)
    try! fm.createDirectory(at: target, withIntermediateDirectories: true)
    try! "старая".write(to: target.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
}
func targetIntact() -> Bool { fm.fileExists(atPath: target.appendingPathComponent("old.txt").path) }

/// Отказ: сообщение содержит `expected`, цель цела, копии рядом не осталось.
func refused(_ name: String, _ app: URL, version v: String = version, expected: String, afterCopy: (URL) throws -> Void = { _ in }) {
    freshTarget()
    do {
        try UpdateBundle.install(app, expectedVersion: v, target: target, afterCopy: afterCopy)
        check(name, false, "установка прошла")
    } catch {
        check(name, error.localizedDescription.contains(expected), error.localizedDescription)
    }
    check(name + ": цель цела", targetIntact())
    check(name + ": копии не осталось", !fm.fileExists(atPath: staged.path))
}

func copyOfGood(_ name: String) -> URL {
    let dir = root.appendingPathComponent(name)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let app = dir.appendingPathComponent("Utilitumus.app")
    try! fm.copyItem(at: good, to: app)
    return app
}

// MARK: Настоящая подпись проходит

freshTarget()
do {
    try UpdateBundle.install(copyOfGood("ok"), expectedVersion: version, target: target)
    let info = NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist"))
    check("подписанная сборка ставится", info?["CFBundleShortVersionString"] as? String == version)
    check("цель заменена целиком", !targetIntact())
    check("копии не осталось", !fm.fileExists(atPath: staged.path))
} catch {
    check("подписанная сборка ставится", false, error.localizedDescription)
}

// MARK: Режимы

let wide = copyOfGood("wide")
try! fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: wide.appendingPathComponent(data).path)
do {
    try KitSigning.verifySignature(of: wide, identifier: "local.utilitumus", strict: true)
    check("подпись режимы не запечатывает (ради этого и проверка)", true)
} catch {
    check("подпись режимы не запечатывает (ради этого и проверка)", false, error.localizedDescription)
}
refused("файл 0777", wide, expected: "запись разрешена")

let group = copyOfGood("group")
try! fm.setAttributes([.posixPermissions: 0o775], ofItemAtPath: group.appendingPathComponent("Contents/Resources").path)
refused("каталог с записью для группы", group, expected: "запись разрешена")

let top = copyOfGood("top")
try! fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: top.path)
refused("сам бандл 0777", top, expected: "запись разрешена")

// MARK: Остальные отказы как раньше

refused("не та версия", copyOfGood("version"), version: "1.0.0", expected: "не та версия")
let edited = copyOfGood("edited")
try! "подмена".write(to: edited.appendingPathComponent(data), atomically: false, encoding: .utf8)
refused("изменённый файл до копирования", edited, expected: "не от автора")

// MARK: Подмена копии между копированием и заменой

refused("подмена копии", copyOfGood("swap"), expected: "не от автора") { copy in
    try "подмена".write(to: copy.appendingPathComponent(data), atomically: false, encoding: .utf8)
}
refused("права копии", copyOfGood("chmod"), expected: "запись разрешена") { copy in
    try fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: copy.appendingPathComponent(data).path)
}

exit(failed ? 1 : 0)
