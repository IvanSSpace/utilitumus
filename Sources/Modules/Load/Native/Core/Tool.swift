import Darwin
import Foundation

/// Запуск внешней программы с тайм-аутом: stdout целиком или nil (нет файла, сбой, тайм-аут).
/// Код выхода не важен: smartctl выходит с 4, когда не прочитался журнал ошибок, а остальное отдаёт.
///
/// Каталог Homebrew доступен на запись любой программе пользователя, а macOS считает родителя ответственным
/// за дочерний процесс. Поэтому ответственность снимаем при запуске: подменённый smartctl или tmux
/// не получит разрешений Utilitumus (Универсальный доступ, Мониторинг ввода, микрофон).
enum Tool {
    /// Принимает указатель на атрибуты, как `posix_spawnattr_setflags`.
    typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    /// Функция не документирована, поэтому ищем её при запуске, а не связываемся с ней при сборке.
    static let systemDisclaim: Disclaim? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), // RTLD_DEFAULT
                                                 "responsibility_spawnattrs_setdisclaim")
        .map { unsafeBitCast($0, to: Disclaim.self) }

    /// Файлы под защитой системы (SIP): без root их не подменить. Без функции выше запускаем только их:
    /// launchctl, top и ioreg нужны экранам «Нагрузки», а разрешениями им пользоваться незачем.
    static func isSealed(_ path: String) -> Bool {
        ["/usr/", "/bin/", "/sbin/"].contains { path.hasPrefix($0) } && !path.hasPrefix("/usr/local/") && !path.contains("/../")
    }

    /// `environment` — строки «ИМЯ=значение»; nil — окружение приложения.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval, environment: [String]? = nil,
                    disclaim: Disclaim? = systemDisclaim) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path), disclaim != nil || isSealed(path) else { return nil }

        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(0x4000)) // POSIX_SPAWN_CLOEXEC_DEFAULT: чужие дескрипторы не наследуются
        if let disclaim, disclaim(&attr, 1) != 0 { return nil }

        let pipe = Pipe()
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        let env = environment ?? ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        let cArgv = ([path] + args).map { strdup($0) } + [nil]
        let cEnv = env.map { strdup($0) } + [nil]
        defer { (cArgv + cEnv).forEach { free($0) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, path, &actions, &attr, cArgv, cEnv)
        // Свой конец записи закрываем сразу: иначе чтение не дождётся конца файла.
        try? pipe.fileHandleForWriting.close()
        guard spawned == 0 else { return nil }

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
            done.signal()
        }

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
            kill(pid, SIGTERM)
            if done.wait(timeout: .now() + 2) == .timedOut { kill(pid, SIGKILL) }
            return nil
        }
        _ = reader.wait(timeout: .now() + 1)
        return String(decoding: box.data, as: UTF8.self)
    }
}
