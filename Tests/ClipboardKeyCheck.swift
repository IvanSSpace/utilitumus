import Foundation
import CryptoKit
import Security

// Порядок ключа «Буфера» и передача его центром. Только связка в памяти, каталог во временной папке и свой индекс,
// зашифрованный выдуманным ключом: настоящая Связка ключей, `index.bin` и буфер обмена не трогаются.
// Запуск: Tests/run-clipboard-key-check.sh

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

/// Связка в памяти. Записывает каждый вызов, умеет отвечать заданной ошибкой.
final class FakeKeyring: ClipboardKeyring, @unchecked Sendable {
    private let lock = NSLock()
    var items: [ClipboardKeyItem: Data] = [:]
    var readFailure: [ClipboardKeyItem: OSStatus] = [:]
    var probeFailure: [ClipboardKeyItem: OSStatus] = [:]
    var addFailure: OSStatus?
    var deleteFailure: OSStatus?
    /// Читается назад другое значение, чем записано.
    var corruptsOnAdd = false
    private(set) var adds: [ClipboardKeyItem] = []
    private(set) var deletes: [ClipboardKeyItem] = []
    private(set) var events: [String] = []

    func read(_ item: ClipboardKeyItem) -> ClipboardKeyRead {
        lock.withLock {
            events.append("read-\(item)")
            if let status = readFailure[item] { return .failure(status) }
            return items[item].map(ClipboardKeyRead.found) ?? .absent
        }
    }

    func probe(_ item: ClipboardKeyItem) -> ClipboardKeyProbe {
        lock.withLock {
            events.append("probe-\(item)")
            if let status = probeFailure[item] { return .failure(status) }
            return items[item] == nil ? .absent : .exists
        }
    }

    func add(_ item: ClipboardKeyItem, key: Data) -> OSStatus {
        lock.withLock {
            adds.append(item)
            events.append("add-\(item)")
            if let status = addFailure { return status }
            guard items[item] == nil else { return errSecDuplicateItem }
            items[item] = corruptsOnAdd ? Data(repeating: 7, count: 32) : key
            return errSecSuccess
        }
    }

    func delete(_ item: ClipboardKeyItem) -> OSStatus {
        lock.withLock {
            deletes.append(item)
            events.append("delete-\(item)")
            if let status = deleteFailure { return status }
            return items.removeValue(forKey: item) == nil ? errSecItemNotFound : errSecSuccess
        }
    }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipkeycheck-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }
var counter = 0

/// Каталог истории; `index` — с выдуманным ключом и одним пространством, чтобы файл можно было узнать.
func makeDir(index key: SymmetricKey?) -> URL {
    counter += 1
    let dir = root.appendingPathComponent("case\(counter)", isDirectory: true)
    if let key {
        let store = ClipboardStore(directory: dir, key: key)
        store.addSpace(name: "Работа", colorID: "teal")
    }
    return dir
}

func files(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
}

func indexBytes(_ dir: URL) -> Data? { try? Data(contentsOf: dir.appendingPathComponent("index.bin")) }
func keyData(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

let history = SymmetricKey(size: .bits256)
let stranger = SymmetricKey(size: .bits256)

// 1. Своя запись читается и открывает индекс
do {
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.own] = keyData(history)
    let before = indexBytes(dir)
    check(ClipboardKeyResolver(keyring: ring, directory: dir).resolve() == .ready(keyData(history)), "своя запись: ключ готов")
    check(ring.adds.isEmpty && ring.deletes.isEmpty, "своя запись: ничего не записано и не удалено")
    check(indexBytes(dir) == before && files(dir) == ["index.bin"], "своя запись: индекс на месте")
}

// 2. Своя запись есть, индекс ею не открывается: стоп, индекс не отложен
do {
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.own] = keyData(stranger)
    let before = indexBytes(dir)
    check(ClipboardKeyResolver(keyring: ring, directory: dir).resolve() == .failed(.keyDoesNotOpenIndex), "чужой ключ в своей записи: стоп")
    check(ring.adds.isEmpty && ring.deletes.isEmpty, "чужой ключ: связка не тронута")
    check(indexBytes(dir) == before && files(dir) == ["index.bin"], "чужой ключ: индекс не отложен и не тронут")
}

// 3. Своя запись повреждена по длине
do {
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.own] = Data(repeating: 1, count: 31)
    check(ClipboardKeyResolver(keyring: ring, directory: dir).resolve() == .failed(.badItem), "ключ не 32 байта: стоп")
    check(ring.adds.isEmpty && ring.deletes.isEmpty, "ключ не 32 байта: связка не тронута")
}

// 4. Своей записи нет, прежняя есть: ждём центр, нового ключа нет
do {
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.legacy] = keyData(history)
    check(ClipboardKeyResolver(keyring: ring, directory: dir).resolve() == .needsHandover, "прежняя запись есть: нужна передача")
    check(ring.adds.isEmpty && ring.deletes.isEmpty, "нужна передача: нового ключа нет, прежняя цела")
    check(!ring.events.contains("read-legacy"), "утилита прежнюю запись не читает, только проверяет")
}

// 5. Первый запуск: ни записей, ни индекса
do {
    let dir = makeDir(index: nil)
    let ring = FakeKeyring()
    let resolver = ClipboardKeyResolver(keyring: ring, directory: dir)
    let first = resolver.resolve()
    var created: Data?
    if case .ready(let data) = first { created = data }
    check(created?.count == 32 && ring.items[.own] == created && ring.adds == [.own], "первый запуск: один новый ключ в своей записи")
    check(resolver.resolve() == .ready(created ?? Data()) && ring.adds.count == 1, "второй запуск: тот же ключ, новых нет")
}

// 6. Записей нет, а индекс есть: стоп, ничего не создано, индекс цел
do {
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    let before = indexBytes(dir)
    check(ClipboardKeyResolver(keyring: ring, directory: dir).resolve() == .failed(.indexWithoutKey), "индекс без записей: стоп")
    check(ring.adds.isEmpty && ring.items.isEmpty, "индекс без записей: нового ключа нет")
    check(indexBytes(dir) == before && files(dir) == ["index.bin"], "индекс без записей: не отложен")
}

// 7. Любая ошибка Связки, кроме «нет записи»: стоп без ключа и без правок
for status: OSStatus in [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled, errSecNotAvailable, errSecInternalComponent, -1] {
    for place in ["own", "legacy"] {
        let dir = makeDir(index: nil)
        let ring = FakeKeyring()
        if place == "own" { ring.readFailure[.own] = status } else { ring.probeFailure[.legacy] = status }
        let outcome = ClipboardKeyResolver(keyring: ring, directory: dir).resolve()
        check(outcome == .failed(.keychain(status)) && ring.adds.isEmpty && ring.deletes.isEmpty && ring.items.isEmpty,
              "ошибка \(status) при чтении \(place): стоп, ключа не создано")
        check(files(dir).isEmpty, "ошибка \(status) при чтении \(place): каталог не тронут")
    }
}

// 8. Запись нового ключа не удалась
do {
    let dir = makeDir(index: nil)
    let ring = FakeKeyring()
    ring.addFailure = errSecAuthFailed
    check(ClipboardKeyResolver(keyring: ring, directory: dir).resolve() == .failed(.keychain(errSecAuthFailed)), "первый запуск, отказ записи: стоп")
}

// 9. Приём ключа от центра
do {
    // правильный
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.legacy] = keyData(history)
    let resolver = ClipboardKeyResolver(keyring: ring, directory: dir)
    check(resolver.resolve() == .needsHandover, "приём: сначала ждём")
    check(resolver.accept(keyData(history)) == nil, "приём: верный ключ принят")
    check(ring.items[.own] == keyData(history) && ring.deletes.isEmpty && ring.items[.legacy] != nil, "приём: своя запись есть, прежняя не тронута")
    check(resolver.resolve() == .ready(keyData(history)), "приём: после него обычный запуск готов")
    check(ring.events.firstIndex(of: "add-own")! < ring.events.lastIndex(of: "read-own")!, "приём: чтение назад после записи")
}
do {
    // чужой ключ: индекс не открывается, ничего не записано
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.legacy] = keyData(history)
    let before = indexBytes(dir)
    check(ClipboardKeyResolver(keyring: ring, directory: dir).accept(keyData(stranger)) == .handoverRejected, "приём: ключ, не открывающий индекс, отвергнут")
    check(ring.adds.isEmpty && ring.items[.own] == nil && indexBytes(dir) == before && files(dir) == ["index.bin"], "приём: отказ ничего не записал и не отложил")
    check(ClipboardKeyResolver(keyring: ring, directory: dir).accept(Data(repeating: 3, count: 16)) == .handoverRejected && ring.adds.isEmpty, "приём: неверная длина отвергнута")
}
do {
    // запись не читается назад: убрана
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.corruptsOnAdd = true
    check(ClipboardKeyResolver(keyring: ring, directory: dir).accept(keyData(history)) == .badItem, "приём: запись не читается назад, отказ")
    check(ring.items[.own] == nil && ring.deletes == [.own], "приём: своя битая запись убрана, прежнюю не трогали")
}
do {
    // отказ записи
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.addFailure = errSecAuthFailed
    check(ClipboardKeyResolver(keyring: ring, directory: dir).accept(keyData(history)) == .keychain(errSecAuthFailed) && ring.deletes.isEmpty, "приём: отказ записи без удалений")
}
do {
    // истории ещё нет: ключ без проверки принимается, но только от центра
    let dir = makeDir(index: nil)
    let ring = FakeKeyring()
    check(ClipboardKeyResolver(keyring: ring, directory: dir).accept(keyData(history)) == nil, "приём без индекса: принят")
}

// 10. Сообщение центра: строгий разбор, отдельный от действий экрана
do {
    let message = ClipboardKeyMessage(key: keyData(history))
    let data = LinkWire.encoded(message)
    check(data.count <= ClipboardKeyMessage.limit, "сообщение влезает в предел")
    check(LinkWire.decodeAction(ClipboardKeyMessage.self, from: data, limit: ClipboardKeyMessage.limit) == message, "сообщение туда и обратно")
    check(LinkWire.decodeAction(ClipboardAction.self, from: data, limit: 4096) == nil, "сообщение не разбирается как действие экрана")
    for action in [ClipboardAction.togglePanel, .clearHistory, .setLimit(value: 100)] {
        check(LinkWire.decodeAction(ClipboardKeyMessage.self, from: LinkWire.encoded(action), limit: 4096) == nil, "действие экрана не разбирается как передача ключа")
        check(LinkWire.decodeAction(ClipboardAction.self, from: LinkWire.encoded(action), limit: 4096) == action, "действие экрана разбирается")
    }
    let extra = Data(#"{"handoverKey":{"key":"\#(keyData(history).base64EncodedString())","x":1}}"#.utf8)
    check(LinkWire.decodeAction(ClipboardKeyMessage.self, from: extra, limit: 4096) == nil, "лишнее поле в передаче отвергнуто")
    let foreignAction = Data(#"{"togglePanel":{},"x":1}"#.utf8)
    check(LinkWire.decodeAction(ClipboardAction.self, from: foreignAction, limit: 4096) == nil, "чужой ключ в действии отвергнут сразу")
    // Состояние несёт слово о ключе, а не ключ.
    let state = ClipboardState(totalCount: 0, historyCount: 0, spaces: [], spaceCounts: [:], recent: [], hotKeyLabel: "", hotKeyError: nil,
                               storeError: ClipboardKeyFailure.keychain(-25293).message, storeNotice: nil, limit: 100, excludedApps: [],
                               axTrusted: false, keyState: .waiting)
    let json = String(decoding: LinkWire.encoded(state), as: UTF8.self)
    check(!json.contains(keyData(history).base64EncodedString()) && json.contains(#""keyState":"waiting""#), "состояние: слово о ключе, ключа нет")
    for failure in [ClipboardKeyFailure.keychain(-25293), .indexWithoutKey, .keyDoesNotOpenIndex, .indexUnknown, .badItem, .handoverRejected, .randomFailed(1)] {
        check(!failure.message.isEmpty && !failure.message.contains(keyData(history).base64EncodedString()), "сообщение об ошибке без ключа: \(failure)")
    }
}

// 11. Сторона центра: порядок и условия удаления прежней записи
func runHandover(_ ring: FakeKeyring, dir: URL, utilityReceives: Bool = true, finalState: ClipboardKeyState? = .ready,
                 failSend: Bool = false, attempts: Int = 3) async -> (ClipboardKeyHandover.Result, sent: Int) {
    let sent = Counter()
    let resolver = ClipboardKeyResolver(keyring: ring, directory: dir)
    let handover = ClipboardKeyHandover(
        keyring: ring,
        send: { data in
            sent.bump()
            if failSend { throw LinkError.timeout }
            guard utilityReceives, let message = LinkWire.decodeAction(ClipboardKeyMessage.self, from: data, limit: 256) else {
                return LinkWire.encoded(ClipboardKeyReply(received: false))
            }
            _ = resolver.accept(message.key)
            return LinkWire.encoded(ClipboardKeyReply(received: true))
        },
        readKeyState: { ring.items[.own] != nil ? finalState : .waiting },
        attempts: attempts, pause: .milliseconds(1))
    return (await handover.run(), sent.value)
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

func sync(_ body: @escaping @Sendable () async -> Void) {
    let done = DispatchSemaphore(value: 0)
    Task { await body(); done.signal() }
    done.wait()
}

sync {
    // успех
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.legacy] = keyData(history)
    let (result, sent) = await runHandover(ring, dir: dir)
    check(result == .done && sent == 1, "центр: передача прошла с одной отправкой")
    check(ring.items[.legacy] == nil && ring.items[.own] == keyData(history), "центр: прежняя удалена, своя есть")
    let addAt = ring.events.firstIndex(of: "add-own")!, delAt = ring.events.firstIndex(of: "delete-legacy")!
    check(addAt < delAt, "центр: прежняя удалена после записи своей")
    check(ring.deletes == [.legacy], "центр: удалена только прежняя")
}
sync {
    // утилита не приняла
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.legacy] = keyData(history)
    let (result, _) = await runHandover(ring, dir: dir, utilityReceives: false)
    check(result == .failed("Утилита не приняла ключ") && ring.deletes.isEmpty && ring.items[.legacy] != nil, "центр: не принято, прежняя цела")
}
sync {
    // утилита отвергла ключ
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.legacy] = keyData(stranger)
    let (result, _) = await runHandover(ring, dir: dir, finalState: .failed)
    check(ring.deletes.isEmpty && ring.items[.legacy] != nil && ring.items[.own] == nil, "центр: чужой ключ не прошёл, прежняя цела, своей нет")
    if case .failed = result {} else { check(false, "центр: чужой ключ — отказ") }
}
sync {
    // подтверждения нет
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.legacy] = keyData(history)
    let (result, _) = await runHandover(ring, dir: dir, finalState: .waiting)
    check(result == .failed("Утилита не подтвердила ключ") || ring.items[.own] != nil && ring.deletes.isEmpty, "центр: без подтверждения не удаляет")
    check(ring.deletes.isEmpty && ring.items[.legacy] != nil, "центр: без подтверждения прежняя цела")
}
sync {
    // связь оборвалась
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.legacy] = keyData(history)
    let (result, _) = await runHandover(ring, dir: dir, failSend: true)
    check(result == .failed("Утилита не ответила") && ring.deletes.isEmpty, "центр: связь оборвалась, прежняя цела")
}
sync {
    // Связка не отдала прежний ключ: ничего не отправлено
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.legacy] = keyData(history)
    ring.readFailure[.legacy] = errSecAuthFailed
    let (result, sent) = await runHandover(ring, dir: dir)
    check(sent == 0 && ring.deletes.isEmpty && result == .failed("Связка ключей не отдала прежний ключ (код \(errSecAuthFailed))"), "центр: отказ чтения, ничего не отправлено")
}
sync {
    // прежней записи нет
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    let (result, sent) = await runHandover(ring, dir: dir)
    check(result == .nothingToHand && sent == 0 && ring.deletes.isEmpty, "центр: прежней нет, отправлять нечего")
}
sync {
    // удаление не вышло: сообщаем, своя запись остаётся
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.legacy] = keyData(history)
    ring.deleteFailure = errSecAuthFailed
    let (result, _) = await runHandover(ring, dir: dir)
    check(result == .failed("Прежняя запись не удалена (код \(errSecAuthFailed))") && ring.items[.own] != nil, "центр: удаление не вышло, это видно")
}

print(failures == 0 ? "ВСЁ ПРОШЛО" : "ПРОВАЛОВ: \(failures)")
exit(failures == 0 ? 0 : 1)
