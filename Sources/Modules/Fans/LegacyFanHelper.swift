import Foundation

/// Прежний setuid-помощник. Убрать вместе с поддержкой setuid, когда старых установок не останется.
///
/// Единственная причина запускать его: версия 0.5.3 упала с вентилятором в ручном режиме, а новая служба
/// ещё не поставлена, и вернуть «Авто» больше нечем. Дочерний процесс наследует разрешения приложения,
/// поэтому файл запускается только после проверки подписи.
enum LegacyFanHelper {
    static func isSetuidRoot(_ file: FanHelperInstaller.FileInfo?) -> Bool {
        guard let file else { return false }
        return file.owner == 0 && file.mode & 0o4000 != 0
    }

    /// Текст ошибки; nil — успех. Только вне главного потока: и `codesign`, и помощник — процессы.
    static func restoreAuto(fans: [Int], path: String) -> String? {
        do {
            try KitSigning.verifySignature(of: URL(fileURLWithPath: path), identifier: "local.utilitumus.fan", strict: false)
        } catch {
            return error.localizedDescription
        }
        var failure: String?
        for fan in fans {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["auto", String(fan)]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 { failure = "Прежний помощник завершился с кодом \(process.terminationStatus)" }
            } catch {
                failure = error.localizedDescription
            }
        }
        return failure
    }
}
