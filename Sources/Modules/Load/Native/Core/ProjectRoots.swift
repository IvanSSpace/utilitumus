import Foundation

/// Корни проектов: процесс, чей рабочий каталог внутри корня, попадает в группу проекта.
/// Стандартные, как в lambscape, плюс все `~/Documents/projects*`.
///
/// Чтение ~/Documents на чистом маке вызывает системный запрос доступа и стоит, пока человек
/// не ответит, — поэтому список дочитывается в фоне, а до тех пор работают стандартные корни.
final class ProjectRoots: @unchecked Sendable {
    private let lock = NSLock()
    private var roots: [String]
    private var loaded = false

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        roots = Self.defaults(home: home)
    }

    static func defaults(home: URL) -> [String] {
        ["Developer", "Projects", "projects", "code", "Documents/projects", "Documents/GitHub"]
            .map { home.appendingPathComponent($0).path }
    }

    /// Корни без завершающего «/».
    var current: [String] {
        lock.lock()
        defer { lock.unlock() }
        return roots
    }

    /// Дочитать `~/Documents/projects*` один раз, не блокируя вызывающего.
    func loadExtraInBackground(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        lock.lock()
        let already = loaded
        loaded = true
        lock.unlock()
        guard !already else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            let documents = home.appendingPathComponent("Documents")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: documents.path)) ?? []
            var extra: [String] = []
            for name in names.sorted() where name.hasPrefix("projects") && name != "projects" {
                var isDir: ObjCBool = false
                let path = documents.appendingPathComponent(name).path
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { extra.append(path) }
            }
            lock.lock()
            roots += extra.filter { !roots.contains($0) }
            lock.unlock()
        }
    }
}
