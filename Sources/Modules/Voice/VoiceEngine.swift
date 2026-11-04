import Foundation
import Security

/// Распознавание речи через процесс-помощник `utilitumus-voice` (sherpa-onnx влинкован
/// в него статически). Протокол — в Sources/VoiceHelper/main.c.
///
/// Помощник запускается при первом запросе, держит модель в памяти и через
/// `idleTimeout` без запросов получает `quit` — оперативку не занимаем зря.
actor VoiceEngine {
    static let shared = VoiceEngine()

    nonisolated static let helperIdentifier = "local.utilitumus.voice"
    nonisolated static let idleTimeout: TimeInterval = 180
    /// Должно совпадать с лимитом в main.c (16000 * 600).
    nonisolated static let maxSamples = 16_000 * 600

    private var helper: HelperProcess?
    private var signatureChecked = false
    private var lastUse = Date()
    private var inFlight = 0
    private var idleTask: Task<Void, Never>?

    /// `samples` — 16 кГц, моно, float32 в диапазоне -1...1.
    func transcribe(_ samples: [Float], model: VoiceModel) async throws -> String {
        guard !samples.isEmpty else { return "" }
        guard samples.count <= Self.maxSamples else { throw VoiceEngineError("Запись длиннее 10 минут") }
        guard let dir = await VoiceModelStore.shared.modelDirectory(model) else {
            throw VoiceEngineError("Модель «\(model.title)» не скачана")
        }

        let process = try ensureHelper()
        inFlight += 1
        lastUse = Date()
        defer {
            inFlight -= 1
            lastUse = Date()
            scheduleIdleCheck()
        }
        do {
            return try await process.transcribe(samples, modelDirectory: dir.path)
        } catch {
            // Помощник умер или ответил мусором — забываем, следующий запрос поднимет новый.
            if helper === process {
                process.terminate()
                helper = nil
            }
            throw error
        }
    }

    /// Остановить помощника сейчас (выход из приложения, выключение модуля).
    func shutdown() {
        idleTask?.cancel()
        idleTask = nil
        helper?.quit()
        helper = nil
    }

    // MARK: - Помощник

    private func ensureHelper() throws -> HelperProcess {
        if let helper, helper.isRunning { return helper }
        helper = nil
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/utilitumus-voice")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw VoiceEngineError("В приложении нет помощника распознавания (utilitumus-voice)")
        }
        if !signatureChecked {
            try Self.verifyHelper(url)
            signatureChecked = true
        }
        let process = try HelperProcess(executable: url)
        helper = process
        return process
    }

    /// Та же проверка, что у Updater: свой identifier и листовой сертификат автора.
    /// Если приложение подписано ad-hoc (локальная сборка без сертификата), проверять
    /// не с чем — подпись помощника тоже ad-hoc.
    nonisolated static func verifyHelper(_ url: URL) throws {
        guard !Self.isSelfAdHoc() else { return }
        do {
            try Updater.verifySignature(of: url, identifier: helperIdentifier, strict: false)
        } catch {
            throw VoiceEngineError("Подпись помощника распознавания не прошла проверку: \(error.localizedDescription)")
        }
    }

    nonisolated static func isSelfAdHoc() -> Bool {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return true }
        let certs = dict[kSecCodeInfoCertificates as String] as? [Any] ?? []
        return certs.isEmpty
    }

    // MARK: - Автовыгрузка

    private func scheduleIdleCheck() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleTimeout))
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        guard inFlight == 0, Date().timeIntervalSince(lastUse) >= Self.idleTimeout - 1 else { return }
        shutdown()
    }
}

struct VoiceEngineError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Один запущенный помощник. Весь ввод-вывод блокирующий и идёт на своей последовательной
/// очереди: так запросы не перемешиваются, а пул потоков Swift не простаивает в read().
private final class HelperProcess: @unchecked Sendable {
    private let process = Process()
    private let toHelper = Pipe()
    private let fromHelper = Pipe()
    private let queue = DispatchQueue(label: "local.utilitumus.voice.io", qos: .userInitiated)
    private var loadedDirectory: String?
    private var buffer = [UInt8]()

    var isRunning: Bool { process.isRunning }

    init(executable: URL) throws {
        process.executableURL = executable
        process.environment = [:]
        process.standardInput = toHelper
        process.standardOutput = fromHelper
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Запись в закрытую трубу должна дать ошибку, а не SIGPIPE на всё приложение.
        _ = fcntl(toHelper.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func transcribe(_ samples: [Float], modelDirectory: String) async throws -> String {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            queue.async { [self] in
                do { c.resume(returning: try transcribeBlocking(samples, modelDirectory: modelDirectory)) }
                catch { c.resume(throwing: error) }
            }
        }
    }

    /// Просьба выйти; если не вышел сам — завершаем.
    func quit() {
        queue.async { [self] in
            _ = try? send(["cmd": "quit"])
            try? toHelper.fileHandleForWriting.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
                if process.isRunning { process.terminate() }
            }
        }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    // MARK: - Блокирующая часть (только на queue)

    private func transcribeBlocking(_ samples: [Float], modelDirectory: String) throws -> String {
        if loadedDirectory != modelDirectory {
            try send(["cmd": "load", "dir": modelDirectory, "kind": "transducer"])
            let reply = try readReply()
            guard reply["ok"] as? Bool == true else {
                throw VoiceEngineError("Не удалось загрузить модель: \(reply["error"] as? String ?? "неизвестная ошибка")")
            }
            loadedDirectory = modelDirectory
        }
        try send(["cmd": "transcribe", "samples": samples.count, "rate": 16000],
                 payload: samples.withUnsafeBytes { Data($0) })
        let reply = try readReply()
        guard reply["ok"] as? Bool == true, let text = reply["text"] as? String else {
            throw VoiceEngineError("Ошибка распознавания: \(reply["error"] as? String ?? "неизвестная ошибка")")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func send(_ command: [String: Any], payload: Data? = nil) throws -> Bool {
        var line = try JSONSerialization.data(withJSONObject: command)
        line.append(0x0A)
        try write(line)
        if let payload { try write(payload) }
        return true
    }

    private func write(_ data: Data) throws {
        let fd = toHelper.fileHandleForWriting.fileDescriptor
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw VoiceEngineError("Помощник распознавания не отвечает")
                }
                offset += n
            }
        }
    }

    /// Читает одну строку JSON-ответа.
    private func readReply() throws -> [String: Any] {
        let fd = fromHelper.fileHandleForReading.fileDescriptor
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<nl])
                buffer.removeSubrange(...nl)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw VoiceEngineError("Помощник распознавания ответил непонятно")
                }
                return object
            }
            guard buffer.count < 1 << 24 else { throw VoiceEngineError("Ответ помощника слишком большой") }
            var chunk = [UInt8](repeating: 0, count: 1 << 16)
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw VoiceEngineError("Помощник распознавания завершился") }
            buffer.append(contentsOf: chunk[..<n])
        }
    }
}
