import Foundation

/// Кто сейчас вызывает модуль по связи. Действия принимает только служба центра (`KitLink.machService`), чей слушатель
/// пускает одну подпись центра; здесь это остаётся вторым замком: действие вроде передачи ключа проверяет `isHub`.
/// Значение живёт на главном потоке ровно на время одного вызова `moduleAction`. Процесс по pid больше не определяется:
/// pid переиспользуется, а требование слушателя привязано к токену соединения.
@MainActor enum LinkCaller {
    static private(set) var isHub = false

    static func run<T>(fromHub: Bool, _ body: () -> T) -> T {
        isHub = fromHub
        defer { isHub = false }
        return body()
    }
}
