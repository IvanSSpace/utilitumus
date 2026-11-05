import Foundation
import CryptoKit
import Security

/// Ключ шифрования: случайный, лежит в Keychain (generic password). Больше нигде не хранится.
struct ClipboardKeychain {
    var service = "local.utilitumus.clipboard"
    var account = "history-key"

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func key() -> SymmetricKey? {
        var out: CFTypeRef?
        let read = base.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        if SecItemCopyMatching(read as CFDictionary, &out) == errSecSuccess, let data = out as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        // Ключа нет (первый запуск) — создаём. Старую историю без ключа всё равно не прочитать.
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &bytes) == errSecSuccess else { return nil }
        let data = Data(bytes)
        delete()
        // Только на этом Mac и только пока он разблокирован: в iCloud-связку ключ не уходит.
        let add = base.merging([kSecValueData as String: data,
                                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { $1 }
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        return SymmetricKey(data: data)
    }

    func delete() {
        SecItemDelete(base as CFDictionary)
    }
}

/// История буфера и пространства. Всё на диске зашифровано AES-GCM; без ключа из Keychain это шум.
///
/// Индекс (`index.bin`) — JSON со всеми записями, картинки — отдельные файлы `img-<id>.bin`.
/// Не привязан к главному потоку и к AppKit, чтобы проверяться отдельным тестом.
final class ClipboardStore {
    private(set) var items: [ClipItem] = []
    private(set) var spaces: [ClipSpace] = []
    /// Лимит записей без пространства. Закреплённое в него не входит.
    private(set) var limit: Int
    /// nil — ключ получить не удалось: ничего не пишем и не запоминаем.
    private let key: SymmetricKey?
    private let directory: URL
    private let fm = FileManager.default

    private struct Index: Codable {
        var items: [ClipItem]
        var spaces: [ClipSpace]
    }

    init(directory: URL, key: SymmetricKey?, limit: Int = ClipboardPolicy.defaultLimit) {
        self.directory = directory
        self.key = key
        self.limit = limit
        guard key != nil else { return }
        prepareDirectory()
        load()
    }

    var isAvailable: Bool { key != nil }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Utilitumus/Clipboard", isDirectory: true)
    }

    // MARK: Запись из буфера

    /// Запоминает снимок буфера. Возвращает false, если запись пропущена (скрытый тип, пусто, слишком большое).
    @discardableResult
    func ingest(_ snap: ClipSnapshot, now: Date = Date()) -> Bool {
        guard key != nil, !ClipboardPolicy.shouldSkip(types: snap.types) else { return false }
        var item = ClipItem(id: UUID(), hash: "", kind: .text, sourceBundleID: snap.sourceBundleID,
                            sourceName: snap.sourceName, date: now)
        var png: Data?
        if !snap.filePaths.isEmpty {
            item.kind = .file
            item.filePaths = snap.filePaths
            item.hash = Self.hash("file", Data(snap.filePaths.joined(separator: "\n").utf8))
        } else if let data = snap.imagePNG, snap.text?.isEmpty != false {
            guard data.count <= ClipboardPolicy.maxImageBytes else { return false }
            item.kind = .image
            png = data
            item.hash = Self.hash("image", data)
        } else if var text = snap.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if text.count > ClipboardPolicy.maxTextLength { text = String(text.prefix(ClipboardPolicy.maxTextLength)) }
            item.kind = ClipboardPolicy.isLink(text) ? .link : .text
            item.text = item.kind == .link ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
            item.hash = Self.hash("text", Data(text.utf8))
        } else {
            return false
        }

        // Повтор: прежняя запись поднимается наверх, пространство у неё остаётся.
        if let index = items.firstIndex(where: { $0.hash == item.hash }) {
            var existing = items.remove(at: index)
            existing.date = now
            existing.sourceBundleID = item.sourceBundleID ?? existing.sourceBundleID
            existing.sourceName = item.sourceName ?? existing.sourceName
            items.insert(existing, at: 0)
            save()
            return true
        }
        if let png {
            let file = "img-\(item.id.uuidString).bin"
            guard writeEncrypted(png, name: file) else { return false }
            item.imageFile = file
            (item.imageWidth, item.imageHeight) = Self.pngSize(png)
        }
        items.insert(item, at: 0)
        trim()
        save()
        return true
    }

    /// Поднять запись наверх (после вставки).
    func touch(_ id: UUID, now: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.date = now
        items.insert(item, at: 0)
        save()
    }

    /// Лишние записи без пространства (старые) удаляются; закреплённые остаются всегда.
    private func trim() {
        var kept = 0
        var drop: [ClipItem] = []
        for item in items where item.spaceID == nil {
            kept += 1
            if kept > limit { drop.append(item) }
        }
        guard !drop.isEmpty else { return }
        let ids = Set(drop.map(\.id))
        items.removeAll { ids.contains($0.id) }
        drop.forEach(removeFiles)
    }

    func setLimit(_ value: Int) {
        limit = max(10, value)
        trim()
        save()
    }

    // MARK: Правка истории

    func delete(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        removeFiles(item)
        save()
    }

    /// «Очистить историю»: записи в пространствах остаются.
    func clearHistory() {
        let drop = items.filter { $0.spaceID == nil }
        items.removeAll { $0.spaceID == nil }
        drop.forEach(removeFiles)
        save()
    }

    func pin(_ id: UUID, to space: UUID?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let space, !spaces.contains(where: { $0.id == space }) { return }
        items[index].spaceID = space
        // Открепили — запись снова под лимитом истории.
        if space == nil { trim() }
        save()
    }

    // MARK: Пространства

    @discardableResult
    func addSpace(name: String, colorID: String) -> ClipSpace {
        let space = ClipSpace(id: UUID(), name: name, colorID: colorID)
        spaces.append(space)
        save()
        return space
    }

    func renameSpace(_ id: UUID, to name: String) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].name = name
        save()
    }

    func setColor(_ id: UUID, _ colorID: String) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].colorID = colorID
        save()
    }

    func moveSpace(_ id: UUID, by offset: Int) {
        guard let from = spaces.firstIndex(where: { $0.id == id }) else { return }
        let to = from + offset
        guard spaces.indices.contains(to) else { return }
        spaces.insert(spaces.remove(at: from), at: to)
        save()
    }

    /// Записи удалённого пространства возвращаются в историю и дальше живут по её лимиту.
    func deleteSpace(_ id: UUID) {
        spaces.removeAll { $0.id == id }
        for index in items.indices where items[index].spaceID == id { items[index].spaceID = nil }
        trim()
        save()
    }

    // MARK: Поиск

    func items(in space: UUID?, query: String) -> [ClipItem] {
        Self.filter(items, space: space, query: query)
    }

    static func filter(_ items: [ClipItem], space: UUID?, query: String) -> [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            if let space, item.spaceID != space { return false }
            guard !q.isEmpty else { return true }
            let names = item.filePaths?.map { ($0 as NSString).lastPathComponent }.joined(separator: " ")
            let haystack = [item.text, item.host, item.sourceName, item.kind.title, names]
            return haystack.contains { $0?.lowercased().contains(q) == true }
        }
    }

    func imageData(_ item: ClipItem) -> Data? {
        guard let file = item.imageFile else { return nil }
        return readEncrypted(name: file)
    }

    // MARK: Диск

    private func prepareDirectory() {
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        // Каталог мог появиться раньше с другими правами.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private var indexURL: URL { directory.appendingPathComponent("index.bin") }

    private func load() {
        guard let sealed = try? Data(contentsOf: indexURL), let plain = open(sealed),
              let index = try? JSONDecoder().decode(Index.self, from: plain) else { return }
        items = index.items
        spaces = index.spaces
    }

    private func save() {
        guard key != nil, let plain = try? JSONEncoder().encode(Index(items: items, spaces: spaces)),
              let sealed = seal(plain) else { return }
        write(sealed, to: indexURL)
    }

    private func seal(_ data: Data) -> Data? {
        guard let key else { return nil }
        return try? AES.GCM.seal(data, using: key).combined
    }

    private func open(_ data: Data) -> Data? {
        guard let key, let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    private func write(_ data: Data, to url: URL) {
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func writeEncrypted(_ data: Data, name: String) -> Bool {
        guard let sealed = seal(data) else { return false }
        write(sealed, to: directory.appendingPathComponent(name))
        return true
    }

    private func readEncrypted(name: String) -> Data? {
        guard let sealed = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return open(sealed)
    }

    private func removeFiles(_ item: ClipItem) {
        if let file = item.imageFile { try? fm.removeItem(at: directory.appendingPathComponent(file)) }
    }

    // MARK: Мелочи

    private static func hash(_ tag: String, _ data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(tag.utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Размер PNG из заголовка IHDR, без декодирования картинки.
    private static func pngSize(_ data: Data) -> (Int?, Int?) {
        guard data.count > 24 else { return (nil, nil) }
        func be(_ at: Int) -> Int { data[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } }
        return (be(16), be(20))
    }
}
