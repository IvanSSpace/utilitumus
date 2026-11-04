import Foundation

/// Запуск внешней программы с тайм-аутом: stdout целиком или nil (нет файла, сбой, тайм-аут).
/// Код выхода не важен: smartctl выходит с 4, когда не прочитался журнал ошибок, а остальное отдаёт.
enum Tool {
    static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }

        // Читаем параллельно: иначе полный буфер пайпа блокирует процесс до тайм-аута.
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 2)
            return nil
        }
        _ = reader.wait(timeout: .now() + 1)
        return String(decoding: box.data, as: UTF8.self)
    }
}
