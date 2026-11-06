import Foundation

// KitArchive.extract на составленных вручную архивах: отказ до распаковки, ничего не записано.
var failed = false
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print((ok ? "ok   " : "ПРОВАЛ ") + name + (ok ? "" : ": " + detail()))
    if !ok { failed = true }
}
let fm = FileManager.default
let dir = URL(fileURLWithPath: CommandLine.arguments[1])

func refused(_ name: String, _ zip: String, expected: String, victim: URL? = nil) {
    let destination = dir.appendingPathComponent("out-" + name)
    try? fm.removeItem(at: destination)
    do {
        try KitArchive.extract(dir.appendingPathComponent(zip), to: destination)
        check(name, false, "распаковалось")
    } catch {
        check(name, error.localizedDescription.contains(expected), error.localizedDescription)
    }
    check(name + ": ничего не распаковано", !fm.fileExists(atPath: destination.path))
    if let victim {
        check(name + ": за пределами папки пусто", ((try? fm.contentsOfDirectory(atPath: victim.path)) ?? []).isEmpty)
    }
}

let good = dir.appendingPathComponent("out-good")
do {
    try KitArchive.extract(dir.appendingPathComponent("good.zip"), to: good)
    check("обычный архив с каталогами распаковывается", fm.fileExists(atPath: good.appendingPathComponent("X.app/Contents/Info.plist").path))
} catch {
    check("обычный архив с каталогами распаковывается", false, error.localizedDescription)
}

let victim = dir.appendingPathComponent("victim")
refused("ссылка-и-файл-через-неё", "symlink-write.zip", expected: "ссылка", victim: victim)
refused("ссылка-наружу-относительная", "symlink-up.zip", expected: "ссылка")
refused("ссылка-от-ditto", "symlink-ditto.zip", expected: "ссылка")
refused("точки-в-пути", "dotdot.zip", expected: "за пределы")
refused("абсолютный-путь", "absolute.zip", expected: "за пределы")
refused("обратная-косая", "backslash.zip", expected: "за пределы")
refused("не-zip", "notzip.zip", expected: "не zip")

exit(failed ? 1 : 0)
