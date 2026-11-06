import Foundation

/// Личный журнал: каталог 0700, файл 0600 (в журналах имена процессов и ботов). Права
/// ставим и на уже существующие, созданные старой версией с 0644.
enum PrivateLog {
    static func prepare(file: URL) {
        Kit.assertStandPath(file, "журнал")
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        if fm.fileExists(atPath: file.path) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } else {
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
    }
}
