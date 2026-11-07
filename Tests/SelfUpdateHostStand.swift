import Foundation

// Стенд пути самообновления. Запуск: Tests/run-satellite-role-check.sh
// В обычной сборке этот код есть, а в сборке со швом его нет (`#if !KIT_TEST_DEFAULTS`), и утилита на стенде не обновляется.
// Поэтому настоящий текст `scheduleUpdateChecks` и `checkForUpdate` скрипт вырезает из SatelliteHost.swift и вставляет
// в `HostStand`. Подставные здесь только сеть и хозяйство вокруг.

/// Перекрывает настоящий URLSession во всей сборке стенда: выйти в сеть ей не на чем.
/// На главном актёре: чтение каталога считается сразу, а не когда до него дойдёт очередь.
@MainActor final class StandSession {
    var catalog = Data()
    var reads = 0
    var downloads = 0

    func data(from url: URL) async throws -> (Data, Foundation.URLResponse) {
        reads += 1
        return (catalog, Foundation.URLResponse())
    }

    /// Установка дальше не идёт: бандл стенда заменять незачем, важно, что до скачивания дошло.
    func download(from url: URL) async throws -> (URL, Foundation.URLResponse) {
        downloads += 1
        throw KitSigning.Failure("стенд не качает")
    }
}

enum URLSession {
    @MainActor static let shared = StandSession()
}

struct StandModule {
    let mayRestart = true
    func stopForUpdate() {}
}

struct StandHello {
    let version: String
}

@MainActor final class HostStand {
    let module = StandModule()
    let id: String
    let version: String
    let title = "Стенд"
    var working = true
    var restartPending = false

    init(id: String, version: String) {
        self.id = id
        self.version = version
    }

    func linkHello() -> StandHello { StandHello(version: version) }
    func syncScreen() {}
    func applyRole() {}
    /// Настоящий `restart` здесь не нужен: он зовёт launchctl.
    func restart() {}
}

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

func catalogData(_ id: String, version: String, manual: Bool = false) -> Data {
    let manualField = manual ? #","manualUpdate":true"# : ""
    let entry = #"{"id":"\#(id)","version":"\#(version)","minHub":"0.6.0","url":"https://example.invalid/a.zip","sha256":"ab","sizeMB":1\#(manualField)}"#
    return Data(#"{"schema":1,"apps":[\#(entry)]}"#.utf8)
}

/// Один запуск утилиты: что она успела спросить у сети. Ждём не дольше 5 с и ещё немного на лишнее.
@MainActor func run(_ id: String, catalog: Data, expecting expected: Int) async -> (reads: Int, downloads: Int) {
    Kit.defaults.removeObject(forKey: "App.\(id).LastUpdateCheck")
    let session = URLSession.shared
    session.catalog = catalog
    session.reads = 0
    session.downloads = 0
    let host = HostStand(id: id, version: "1.0.0")
    host.scheduleUpdateChecks()
    let deadline = Date().addingTimeInterval(5)
    while session.reads + session.downloads < expected, Date() < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    try? await Task.sleep(for: .milliseconds(150))
    return (session.reads, session.downloads)
}

@MainActor func scenarios() async {
    for id in ["fans", "clipboard"] {
        let result = await run(id, catalog: catalogData(id, version: "2.0.0"), expecting: 0)
        check(result.reads == 0, "\(id): каталог не читается, есть новее или нет (чтений \(result.reads))")
        check(result.downloads == 0, "\(id): новая версия не скачивается (скачиваний \(result.downloads))")
    }

    let plain = await run("awake", catalog: catalogData("awake", version: "2.0.0"), expecting: 2)
    check(plain.reads == 1, "awake: другие утилиты читают каталог (чтений \(plain.reads))")
    check(plain.downloads == 1, "awake: другие утилиты ставят новую версию сами (скачиваний \(plain.downloads))")

    let marked = await run("awake", catalog: catalogData("awake", version: "2.0.0", manual: true), expecting: 1)
    check(marked.reads == 1, "awake с отметкой: каталог прочитан, отметка только в нём (чтений \(marked.reads))")
    check(marked.downloads == 0, "awake с отметкой manualUpdate: не скачивается (скачиваний \(marked.downloads))")

    let same = await run("awake", catalog: catalogData("awake", version: "1.0.0"), expecting: 1)
    check(same.reads == 1 && same.downloads == 0, "awake: та же версия не скачивается (\(same.reads), \(same.downloads))")
}

Task { @MainActor in
    await scenarios()
    print(failures == 0 ? "ВСЁ ОК" : "ПРОВАЛОВ: \(failures)")
    exit(failures == 0 ? 0 : 1)
}
dispatchMain()
