import Foundation
import CryptoKit

/// Модели распознавания речи для sherpa-onnx. Скачиваются по кнопке (сотни мегабайт
/// в приложение не вшиваются); хэш каждого архива вшит сюда и сверяется после загрузки.
enum VoiceModel: String, CaseIterable, Identifiable {
    case gigaam
    case parakeet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gigaam: return "GigaAM v3 — русский"
        case .parakeet: return "Parakeet v3 — многоязычный"
        }
    }

    /// Короткая подпись под названием: размер и сильные стороны.
    var subtitle: String {
        switch self {
        case .gigaam: return "170 МБ · лучший для русского, сам ставит знаки препинания"
        case .parakeet: return "487 МБ · 25 европейских языков, включая русский и английский"
        }
    }

    var license: String {
        switch self {
        case .gigaam: return "MIT"
        case .parakeet: return "CC-BY-4.0"
        }
    }

    /// Архив с моделью в релизах sherpa-onnx.
    var url: URL {
        URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(folderName).tar.bz2")!
    }

    var sha256: String {
        switch self {
        case .gigaam: return "f9620a0099019c6afcee26525ef9ed3297fa50dd5691c1902af0c948fc1a470b"
        case .parakeet: return "5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf"
        }
    }

    /// Размер архива в байтах — для прогресса, когда сервер не прислал Content-Length.
    var sizeBytes: Int64 {
        switch self {
        case .gigaam: return 170_197_019
        case .parakeet: return 487_170_055
        }
    }

    /// Имя папки: оно же имя корневой папки внутри архива.
    var folderName: String {
        switch self {
        case .gigaam: return "sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16"
        case .parakeet: return "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"
        }
    }

    /// Файлы, без которых модель не работает.
    var requiredFiles: [String] {
        switch self {
        case .gigaam: return ["encoder.int8.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"]
        case .parakeet: return ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"]
        }
    }
}

/// Скачанные модели: статус, загрузка, удаление, выбранная модель.
@MainActor
final class VoiceModelStore: ObservableObject {
    static let shared = VoiceModelStore()

    enum Status: Equatable, Codable {
        case notInstalled
        case downloading(progress: Double)
        case verifying
        case installed
        case failed(String)
    }

    @Published private(set) var statuses: [VoiceModel: Status] = [:]

    /// Выбранная модель: UserDefaults "Voice.Model", по умолчанию GigaAM.
    @Published var selected: VoiceModel {
        didSet { UserDefaults.standard.set(selected.rawValue, forKey: Self.selectedKey) }
    }

    nonisolated static let selectedKey = "Voice.Model"

    private var tasks: [VoiceModel: Task<Void, Never>] = [:]

    /// Application Support/Utilitumus/Voice/Models.
    nonisolated static var modelsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Utilitumus/Voice/Models", isDirectory: true)
    }

    private init() {
        selected = UserDefaults.standard.string(forKey: Self.selectedKey)
            .flatMap(VoiceModel.init(rawValue:)) ?? .gigaam
        cleanLeftovers()
        for model in VoiceModel.allCases {
            statuses[model] = Self.isInstalled(model) ? .installed : .notInstalled
        }
    }

    func status(_ model: VoiceModel) -> Status { statuses[model] ?? .notInstalled }

    /// Папка модели — только для установленной.
    func modelDirectory(_ model: VoiceModel) -> URL? {
        status(model) == .installed ? Self.folder(of: model) : nil
    }

    // MARK: - Действия

    func download(_ model: VoiceModel) {
        switch status(model) {
        case .downloading, .verifying, .installed: return
        case .notInstalled, .failed: break
        }
        statuses[model] = .downloading(progress: 0)
        tasks[model] = Task { [weak self] in
            do {
                try await Self.install(model) { progress in
                    Task { @MainActor in
                        guard let self, case .downloading = self.status(model) else { return }
                        self.statuses[model] = .downloading(progress: progress)
                    }
                } onVerifying: {
                    Task { @MainActor in
                        guard let self, case .downloading = self.status(model) else { return }
                        self.statuses[model] = .verifying
                    }
                }
                self?.statuses[model] = .installed
            } catch is CancellationError {
                self?.statuses[model] = .notInstalled
            } catch {
                self?.statuses[model] = .failed(error.localizedDescription)
            }
            self?.tasks[model] = nil
        }
    }

    func cancel(_ model: VoiceModel) {
        tasks[model]?.cancel()
    }

    func delete(_ model: VoiceModel) {
        tasks[model]?.cancel()
        try? FileManager.default.removeItem(at: Self.folder(of: model))
        statuses[model] = .notInstalled
    }

    // MARK: - Диск

    nonisolated static func folder(of model: VoiceModel) -> URL {
        modelsRoot.appendingPathComponent(model.folderName, isDirectory: true)
    }

    nonisolated static func isInstalled(_ model: VoiceModel) -> Bool {
        let dir = folder(of: model)
        return model.requiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    /// Хвосты прерванных загрузок (недокачанные архивы, недораспакованные папки).
    private func cleanLeftovers() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: Self.modelsRoot.path)) ?? []
        for name in names where name.hasPrefix(".download-") || name.hasPrefix(".staging-") {
            try? fm.removeItem(at: Self.modelsRoot.appendingPathComponent(name))
        }
    }

    /// Каталог 0700, вне Time Machine и Spotlight.
    nonisolated private static func prepareRoot() throws {
        let fm = FileManager.default
        var dir = modelsRoot
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Voice/ и Utilitumus/ создал createDirectory с обычными правами — подтягиваем и их.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.deletingLastPathComponent().path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try dir.setResourceValues(values)
        let marker = dir.appendingPathComponent(".metadata_never_index")
        if !fm.fileExists(atPath: marker.path) {
            fm.createFile(atPath: marker.path, contents: nil)
        }
    }

    // MARK: - Установка (вне главного потока)

    nonisolated private static func install(
        _ model: VoiceModel,
        onProgress: @escaping @Sendable (Double) -> Void,
        onVerifying: @escaping @Sendable () -> Void
    ) async throws {
        let fm = FileManager.default
        try prepareRoot()
        let root = modelsRoot
        let archive = root.appendingPathComponent(".download-\(model.folderName).tar.bz2")
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fm.removeItem(at: archive)
            try? fm.removeItem(at: staging)
        }
        try? fm.removeItem(at: archive)

        try await ModelDownloader.download(model.url, to: archive, expectedBytes: model.sizeBytes, onProgress: onProgress)
        try Task.checkCancellation()

        onVerifying()
        let digest = try await Task.detached(priority: .utility) { try sha256Hex(of: archive) }.value
        guard digest == model.sha256 else {
            try? fm.removeItem(at: archive)
            throw VoiceModelError("Файл повреждён или подменён")
        }
        try Task.checkCancellation()

        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try await Task.detached(priority: .utility) {
            try runTar(["-xjf", archive.path, "-C", staging.path])
        }.value
        try Task.checkCancellation()

        let unpacked = staging.appendingPathComponent(model.folderName, isDirectory: true)
        for file in model.requiredFiles
        where !fm.fileExists(atPath: unpacked.appendingPathComponent(file).path) {
            throw VoiceModelError("В архиве нет файла \(file)")
        }
        let target = folder(of: model)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: unpacked, to: target)
    }

    /// SHA-256 файла потоково: 500 МБ в память не грузим.
    nonisolated static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func runTar(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = args
        let err = Pipe()
        process.standardError = err
        try process.run()
        // stderr tar'а мал; читаем до конца, чтобы не заблокировать процесс.
        let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VoiceModelError("Не удалось распаковать: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}

struct VoiceModelError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Загрузка одного файла с прогрессом и отменой через отмену задачи.
private final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedBytes: Int64
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?
    private var status = 0

    private init(destination: URL, expectedBytes: Int64, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.onProgress = onProgress
    }

    static func download(_ url: URL, to destination: URL, expectedBytes: Int64,
                         onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let worker = ModelDownloader(destination: destination, expectedBytes: expectedBytes, onProgress: onProgress)
        let session = URLSession(configuration: .ephemeral, delegate: worker, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                worker.continuation = c
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        onProgress(min(1, Double(totalBytesWritten) / Double(max(total, 1))))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { return }
        // Файл во временной папке удаляется сразу после возврата из метода — переносим здесь.
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let c = continuation
        continuation = nil
        if let error {
            // Отмена приходит как NSURLErrorCancelled — превращаем в отмену задачи.
            if (error as? URLError)?.code == .cancelled { c?.resume(throwing: CancellationError()) }
            else { c?.resume(throwing: error) }
        } else if status != 200 {
            c?.resume(throwing: VoiceModelError("Сервер ответил \(status)"))
        } else if let moveError {
            c?.resume(throwing: moveError)
        } else {
            c?.resume()
        }
    }
}
