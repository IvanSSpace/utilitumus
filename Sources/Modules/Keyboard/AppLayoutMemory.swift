import Foundation

/// Память «раскладка для каждого приложения». Чистая логика без AppKit: id приложений и раскладок — строки.
struct AppLayoutMemory: Equatable {
    /// bundle id → id раскладки, которая была включена в приложении последней.
    private(set) var saved: [String: String]
    /// Приложения, где раскладку не трогаем: ни запоминаем, ни возвращаем.
    var excluded: Set<String>
    /// С чего начинать приложение, которого ещё не видели; nil — «как было», оставить текущую.
    var newAppLayout: String?

    init(saved: [String: String] = [:], excluded: Set<String> = [], newAppLayout: String? = nil) {
        self.saved = saved
        self.excluded = excluded
        self.newAppLayout = newAppLayout
    }

    /// В приложении включена раскладка: запоминаем. Исключённые не трогаем. true — запись изменилась.
    @discardableResult
    mutating func remember(layout: String, in app: String) -> Bool {
        guard !excluded.contains(app), saved[app] != layout else { return false }
        saved[app] = layout
        return true
    }

    /// Какую раскладку включить при входе в приложение; nil — ничего не менять.
    /// Сохранённая раскладка, которую выключили в системе, не годится: берём правило для новых приложений.
    func layout(for app: String, enabled: [String]) -> String? {
        guard !excluded.contains(app) else { return nil }
        if let id = saved[app], enabled.contains(id) { return id }
        if let id = newAppLayout, enabled.contains(id) { return id }
        return nil
    }
}
