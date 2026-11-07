import Foundation

extension LoadScreen where Model == LoadStore {
    /// Встроенный экран: модель — сам модуль.
    @MainActor init(store: LoadStore? = nil) {
        self.init(model: store ?? LoadStore.shared)
    }
}
