import SwiftUI

extension FansView where Model == BuiltInFansModel {
    /// Встроенный модуль: экран рисуется из настоящих контроллеров этого же процесса.
    init() { self.init(model: BuiltInFansModel.shared) }
}
