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

// 12. Затвор «только центр»: единственная защита передачи ключа. Настоящий модуль утилиты со связкой в памяти;
// сборка со швом: буфер обмена не опрашивается, горячей клавиши нет. Подпись и XPC здесь не проверяются:
// как сервер определяет центр, видно только в проверке с подписью (run-clipboard-remote-check.sh).
func spin(_ seconds: Double, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
}

@MainActor func keyState(_ module: ClipboardModule) -> ClipboardKeyState? {
    (try? JSONDecoder().decode(ClipboardState.self, from: module.state()))?.keyState
}

func received(_ reply: Data) -> Bool? { (try? JSONDecoder().decode(ClipboardKeyReply.self, from: reply))?.received }

MainActor.assumeIsolated {
    check(!LinkCaller.isHub, "затвор: вне вызова по связи центром никто не считается")
    check(LinkCaller.run(fromHub: true) { LinkCaller.isHub }, "затвор: в вызове от центра isHub истинно")
    check(!LinkCaller.run(fromHub: false) { LinkCaller.isHub }, "затвор: в вызове от не-центра isHub ложно")
    _ = LinkCaller.run(fromHub: true) { 0 }
    check(!LinkCaller.isHub, "затвор: после вызова от центра сброшен")

    for (name, caller) in [("копия утилиты или чужой", false as Bool?), ("вызов без пометки", nil)] {
        let dir = makeDir(index: history)
        let ring = FakeKeyring()
        ring.items[.legacy] = keyData(history)
        let module = ClipboardModule(keyring: ring, directory: dir)
        module.start()
        spin(5) { keyState(module) == .waiting }
        check(keyState(module) == .waiting, "затвор (\(name)): утилита ждёт ключ")
        let message = LinkWire.encoded(ClipboardKeyMessage(key: keyData(history)))
        let reply = caller.map { flag in LinkCaller.run(fromHub: flag) { module.handle(message) } } ?? module.handle(message)
        check(received(reply) == false, "затвор (\(name)): ключ не принят")
        spin(0.5) { keyState(module) == .ready }
        check(keyState(module) == .waiting && ring.adds.isEmpty && ring.items[.own] == nil, "затвор (\(name)): своей записи нет, состояние то же")
        module.stop()
    }
    do {
        let dir = makeDir(index: history)
        let ring = FakeKeyring()
        ring.items[.legacy] = keyData(history)
        let module = ClipboardModule(keyring: ring, directory: dir)
        module.start()
        spin(5) { keyState(module) == .waiting }
        let message = LinkWire.encoded(ClipboardKeyMessage(key: keyData(history)))
        let reply = LinkCaller.run(fromHub: true) { module.handle(message) }
        check(received(reply) == true, "затвор: от центра ключ принят к проверке")
        spin(5) { keyState(module) == .ready }
        check(keyState(module) == .ready && ring.items[.own] == keyData(history), "затвор: от центра своя запись появилась, состояние ready")
        check(ring.deletes.isEmpty && ring.items[.legacy] != nil, "затвор: утилита прежнюю запись не удаляет")
        let again = LinkCaller.run(fromHub: true) { module.handle(message) }
        check(received(again) == false, "затвор: готовой утилите даже центр второй раз не передаёт")
        let json = String(decoding: module.state(), as: UTF8.self) + module.statusLine(passiveReason: nil)
        check(!json.contains(keyData(history).base64EncodedString()), "затвор: ни состояние, ни статус не несут ключа")
        module.stop()
    }

}

// 13. Удаление утилиты старым центром: обработчики `returnKey` и `dropKey` остаются ради него
/// Копия отправителя из старого центра (до 0.8.0): он уже выпущен и шлёт так перед удалением утилиты. Сначала утилита
/// отдаёт ключ, центр кладёт его в прежнюю запись и проверяет чтением и индексом, и только потом утилита удаляет свою.
struct ClipboardKeyReturn: Sendable {
    enum Result: Equatable {
        case done
        /// У утилиты своей записи нет: возвращать нечего.
        case nothingToReturn
        /// Утилита не ответила: ключ остался у неё.
        case unreachable
        case failed(String)
    }

    let keyring: ClipboardKeyring
    let directory: URL
    /// Отправить байты утилите и вернуть ответ.
    let send: @Sendable (Data) async throws -> Data

    func run() async -> Result {
        let reply: ClipboardKeyReturnReply
        do {
            let answer = try await send(LinkWire.encoded(ClipboardKeyReturnMessage.returnKey))
            guard let decoded = try? JSONDecoder().decode(ClipboardKeyReturnReply.self, from: answer) else {
                return .failed("Утилита ответила непонятно")
            }
            reply = decoded
        } catch {
            return .unreachable
        }
        if let error = reply.error { return .failed(error) }
        guard let key = reply.key else { return .nothingToReturn }
        guard key.count == 32 else { return .failed("Ключ от утилиты неверной длины") }
        // Ключ, который историю не открывает, в связку центра не попадёт.
        switch ClipboardStore.indexCheck(directory: directory, key: SymmetricKey(data: key)) {
        case .noIndex, .readable: break
        case .unreadable: return .failed("Ключ утилиты не открывает историю")
        case .unknown: return .failed("Не удалось проверить файл истории")
        }
        let keyring = keyring
        let stored = await Task.detached { Self.store(key, in: keyring) }.value
        if let failure = stored { return .failed(failure) }
        do {
            let answer = try await send(LinkWire.encoded(ClipboardKeyReturnMessage.dropKey))
            guard let decoded = try? JSONDecoder().decode(ClipboardKeyReturnReply.self, from: answer) else {
                return .failed("Утилита ответила непонятно")
            }
            if let error = decoded.error { return .failed(error) }
            return .done
        } catch {
            return .failed("Утилита не ответила: ключ остался и у неё, и у Utilitumus")
        }
    }

    /// Кладёт ключ в прежнюю запись. Своё чужим не затирает: если там уже что-то лежит, это должен быть тот же ключ.
    private static func store(_ key: Data, in keyring: ClipboardKeyring) -> String? {
        switch keyring.read(.legacy) {
        case .found(let existing):
            return existing == key ? nil : "В записи Utilitumus лежит другой ключ: ничего не изменено"
        case .failure(let status):
            return "Связка ключей не отдала запись Utilitumus (код \(status))"
        case .absent:
            let status = keyring.add(.legacy, key: key)
            guard status == errSecSuccess else { return "Связка ключей не приняла ключ (код \(status))" }
            guard keyring.read(.legacy) == .found(key) else {
                _ = keyring.delete(.legacy)
                return "Ключ в Связке ключей не читается назад"
            }
            return nil
        }
    }
}

func returnRoute(_ ring: FakeKeyring, dir: URL) -> @Sendable (Data) async throws -> Data {
    { data in
        let resolver = ClipboardKeyResolver(keyring: ring, directory: dir)
        guard let message = LinkWire.decodeAction(ClipboardKeyReturnMessage.self, from: data, limit: ClipboardKeyReturnMessage.limit) else {
            return LinkWire.encoded(ClipboardKeyReturnReply(key: nil, error: "непонятно"))
        }
        switch message {
        case .returnKey: return LinkWire.encoded(resolver.keyToReturn())
        case .dropKey: return LinkWire.encoded(ClipboardKeyReturnReply(key: nil, error: resolver.dropOwn()))
        }
    }
}

func runReturn(_ ring: FakeKeyring, dir: URL, send: (@Sendable (Data) async throws -> Data)? = nil) async -> ClipboardKeyReturn.Result {
    await ClipboardKeyReturn(keyring: ring, directory: dir, send: send ?? returnRoute(ring, dir: dir)).run()
}

/// Что видит старый центр после удаления: прежняя запись из той же связки, создание нового ключа считается.
func oldHubKey(_ ring: FakeKeyring, dir: URL) -> (key: Data?, created: Bool, indexWithoutKey: Bool) {
    var created = false
    let keychain = ClipboardKeychain(
        directory: dir,
        copyItem: { _, out in
            guard case .found(let data) = ring.read(.legacy) else { return errSecItemNotFound }
            out?.pointee = data as CFData
            return errSecSuccess
        },
        addItem: { _, _ in created = true; return errSecSuccess },
        deleteItem: { _ in errSecSuccess })
    do {
        let key = try keychain.key()
        return (keyData(key), created, false)
    } catch {
        return (nil, created, (error as? ClipboardKeychainError)?.indexWithoutKey == true)
    }
}

sync {
    // Успех: ключ вернулся, своя запись удалена после записи прежней, старый центр открывает ту же историю
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.own] = keyData(history)
    let before = indexBytes(dir)
    // Без возврата старый центр нового ключа не создаёт (так было до исправления).
    let blocked = oldHubKey(ring, dir: dir)
    check(blocked.key == nil && !blocked.created && blocked.indexWithoutKey, "после передачи без возврата: старый центр ключа не создаёт")
    let result = await runReturn(ring, dir: dir)
    check(result == .done, "возврат: готово")
    check(ring.items[.legacy] == keyData(history) && ring.items[.own] == nil, "возврат: прежняя запись есть, своей нет")
    let addAt = ring.events.firstIndex(of: "add-legacy"), delAt = ring.events.firstIndex(of: "delete-own")
    check(addAt != nil && delAt != nil && addAt! < delAt!, "возврат: своя запись удалена после записи прежней")
    check(ring.deletes == [.own] && ring.adds == [.legacy], "возврат: добавлена только прежняя, удалена только своя")
    let opened = oldHubKey(ring, dir: dir)
    check(opened.key == keyData(history) && !opened.created, "после возврата: старый центр читает тот же ключ")
    check(indexBytes(dir) == before && files(dir) == ["index.bin"], "возврат: индекс не тронут")
}
sync {
    // Утилита не отвечает: ничего не тронуто
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.own] = keyData(history)
    let result = await runReturn(ring, dir: dir, send: { _ in throw LinkError.timeout })
    check(result == .unreachable && ring.adds.isEmpty && ring.deletes.isEmpty && ring.items[.own] != nil, "возврат: нет связи, связка не тронута")
}
sync {
    // У утилиты своей записи нет
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    let result = await runReturn(ring, dir: dir)
    check(result == .nothingToReturn && ring.adds.isEmpty && ring.deletes.isEmpty, "возврат: своей записи нет, возвращать нечего")
}
sync {
    // Её ключ историю не открывает: прежняя запись не создаётся
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.own] = keyData(stranger)
    let result = await runReturn(ring, dir: dir)
    if case .failed = result {} else { check(false, "возврат: чужой ключ утилиты — отказ") }
    check(ring.adds.isEmpty && ring.deletes.isEmpty && ring.items[.own] == keyData(stranger), "возврат: чужой ключ, связка не тронута")
}
sync {
    // Ответ утилиты с ключом, который историю не открывает (подмена на пути): центр его не кладёт
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.own] = keyData(history)
    let result = await runReturn(ring, dir: dir, send: { _ in
        LinkWire.encoded(ClipboardKeyReturnReply(key: keyData(stranger), error: nil))
    })
    if case .failed = result {} else { check(false, "возврат: ключ не от этой истории — отказ") }
    check(ring.adds.isEmpty && ring.deletes.isEmpty, "возврат: ключ не от этой истории не записан")
}
sync {
    // В прежней записи уже лежит другой ключ: не затираем, своя остаётся
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.own] = keyData(history)
    ring.items[.legacy] = keyData(stranger)
    let result = await runReturn(ring, dir: dir)
    if case .failed = result {} else { check(false, "возврат: другой ключ в прежней записи — отказ") }
    check(ring.adds.isEmpty && ring.deletes.isEmpty && ring.items[.own] != nil && ring.items[.legacy] == keyData(stranger), "возврат: чужое не затёрто, своя запись цела")
}
sync {
    // Прежняя уже есть с тем же ключом (прошлый возврат оборвался перед удалением): добивает удаление
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.own] = keyData(history)
    ring.items[.legacy] = keyData(history)
    let result = await runReturn(ring, dir: dir)
    check(result == .done && ring.adds.isEmpty && ring.items[.own] == nil && ring.items[.legacy] == keyData(history), "возврат: повтор после обрыва доводится до конца")
}
sync {
    // Связка не приняла ключ
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.own] = keyData(history)
    ring.addFailure = errSecAuthFailed
    let result = await runReturn(ring, dir: dir)
    if case .failed = result {} else { check(false, "возврат: отказ записи — отказ") }
    check(ring.deletes.isEmpty && ring.items[.own] != nil && ring.items[.legacy] == nil, "возврат: отказ записи, своя запись цела")
}
sync {
    // Записанное не читается назад: прежняя убирается, своя остаётся
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.own] = keyData(history)
    ring.corruptsOnAdd = true
    let result = await runReturn(ring, dir: dir)
    if case .failed = result {} else { check(false, "возврат: запись не читается назад — отказ") }
    check(ring.items[.own] == keyData(history) && ring.items[.legacy] == nil && !ring.deletes.contains(.own), "возврат: прочтение назад не сошлось, своя запись цела")
}
sync {
    // Удалить свою запись не вышло: отказ, обе записи на месте
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.own] = keyData(history)
    ring.deleteFailure = errSecAuthFailed
    let result = await runReturn(ring, dir: dir)
    if case .failed = result {} else { check(false, "возврат: не удалось удалить свою запись — отказ") }
    check(ring.items[.own] != nil && ring.items[.legacy] == keyData(history), "возврат: оба экземпляра ключа на месте")
}
sync {
    // Утилита не удаляет свою запись, пока прежней нет
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.own] = keyData(history)
    let error = ClipboardKeyResolver(keyring: ring, directory: dir).dropOwn()
    check(error != nil && ring.deletes.isEmpty && ring.items[.own] != nil, "утилита: без прежней записи своя не удаляется")
}
sync {
    // Нет связи на втором шаге: оба экземпляра остаются
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.own] = keyData(history)
    let route = returnRoute(ring, dir: dir)
    let result = await runReturn(ring, dir: dir, send: { data in
        if LinkWire.decodeAction(ClipboardKeyReturnMessage.self, from: data, limit: 64) == .dropKey { throw LinkError.timeout }
        return try await route(data)
    })
    if case .failed = result {} else { check(false, "возврат: обрыв перед удалением — отказ") }
    check(ring.items[.own] != nil && ring.items[.legacy] == keyData(history) && ring.deletes.isEmpty, "возврат: обрыв перед удалением, ключ в двух местах")
}

// 14. Нынешний центр ключ не просит: утилиту удалили и поставили снова, её запись и история на месте
do {
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.own] = keyData(history)
    let before = indexBytes(dir)
    // Новая установка: прежней записи нет, свою создавать незачем.
    let outcome = ClipboardKeyResolver(keyring: ring, directory: dir).resolve()
    check(outcome == .ready(keyData(history)), "снова поставили: тот же ключ открывает ту же историю")
    check(ring.adds.isEmpty && ring.deletes.isEmpty && ring.items[.legacy] == nil, "снова поставили: связка не менялась, ключ не возвращался центру")
    check(indexBytes(dir) == before, "снова поставили: индекс не тронут")
}
do {
    // Запись центра ещё ждёт передачи, своей нет: та же передача, что при первой установке.
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.legacy] = keyData(history)
    check(ClipboardKeyResolver(keyring: ring, directory: dir).resolve() == .needsHandover, "снова поставили, ключ у центра: ждём передачу, нового ключа нет")
    check(ring.adds.isEmpty, "снова поставили, ключ у центра: связка не менялась")
}

do {
    let message = ClipboardKeyReturnMessage.returnKey
    check(LinkWire.decodeAction(ClipboardKeyReturnMessage.self, from: LinkWire.encoded(message), limit: 64) == .returnKey, "сообщение returnKey туда и обратно")
    check(LinkWire.decodeAction(ClipboardKeyReturnMessage.self, from: LinkWire.encoded(ClipboardKeyReturnMessage.dropKey), limit: 64) == .dropKey, "сообщение dropKey туда и обратно")
    check(LinkWire.decodeAction(ClipboardAction.self, from: LinkWire.encoded(message), limit: 4096) == nil, "returnKey не разбирается как действие экрана")
    check(LinkWire.decodeAction(ClipboardKeyMessage.self, from: LinkWire.encoded(message), limit: 4096) == nil, "returnKey не разбирается как передача ключа")
    check(LinkWire.decodeAction(ClipboardKeyReturnMessage.self, from: LinkWire.encoded(ClipboardAction.clearHistory), limit: 64) == nil, "действие экрана не разбирается как returnKey")
    check(LinkWire.decodeAction(ClipboardKeyReturnMessage.self, from: Data(#"{"returnKey":{"x":1}}"#.utf8), limit: 64) == nil, "лишнее поле в returnKey отвергнуто")
}

MainActor.assumeIsolated {
    // Затвор: просьбы центра принимает только соединение центра
    let dir = makeDir(index: history)
    let ring = FakeKeyring()
    ring.items[.own] = keyData(history)
    ring.items[.legacy] = keyData(history)
    let module = ClipboardModule(keyring: ring, directory: dir)
    for message in [ClipboardKeyReturnMessage.returnKey, .dropKey] {
        let data = LinkWire.encoded(message)
        for (name, caller) in [("копия утилиты или чужой", false as Bool?), ("вызов без пометки", nil)] {
            let reply = caller.map { flag in LinkCaller.run(fromHub: flag) { module.handle(data) } } ?? module.handle(data)
            let decoded = try? JSONDecoder().decode(ClipboardKeyReturnReply.self, from: reply)
            check(decoded?.key == nil && decoded?.error != nil, "затвор возврата (\(name), \(message)): отказ")
        }
    }
    check(ring.deletes.isEmpty && ring.items[.own] == keyData(history), "затвор возврата: своя запись цела")
    let returned = try? JSONDecoder().decode(ClipboardKeyReturnReply.self, from: LinkCaller.run(fromHub: true) { module.handle(LinkWire.encoded(ClipboardKeyReturnMessage.returnKey)) })
    check(returned?.key == keyData(history) && returned?.error == nil, "затвор возврата: от центра ключ отдан")
    let dropped = try? JSONDecoder().decode(ClipboardKeyReturnReply.self, from: LinkCaller.run(fromHub: true) { module.handle(LinkWire.encoded(ClipboardKeyReturnMessage.dropKey)) })
    check(dropped?.error == nil && ring.items[.own] == nil && ring.items[.legacy] != nil, "затвор возврата: от центра своя запись удалена")
}

print(failures == 0 ? "ВСЁ ПРОШЛО" : "ПРОВАЛОВ: \(failures)")
exit(failures == 0 ? 0 : 1)
