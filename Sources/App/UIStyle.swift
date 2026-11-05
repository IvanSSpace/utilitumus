import AppKit
import SwiftUI

/// Какой интерфейс показывать: прежний («Классический») или переработанный («Новый»).
/// Выбор лежит в настройках (`UI.Style`), по умолчанию — новый; классический остаётся на выбор.
enum UIStyle: String, CaseIterable, Identifiable {
    case classic, new

    static let storageKey = "UI.Style"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "Классический"
        case .new: return "Новый"
        }
    }

    /// Выбранный в настройках.
    static var stored: UIStyle {
        UIStyle(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .new
    }

    /// Интерфейс, с которым запущено окно. Читается один раз при старте: стиль заголовка окна задаётся
    /// сценой `App` и на лету не меняется, поэтому новый выбор вступает в силу после перезапуска.
    static let launched = stored
}

/// Под переключателем: если выбран не тот интерфейс, с которым запущено окно, предлагаем перезапуск.
struct UIStyleRestartNote: View {
    let style: UIStyle

    var body: some View {
        if style != UIStyle.launched {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                Text("Интерфейс «\(style.title)» включится после перезапуска.")
                Spacer(minLength: 8)
                Button("Перезапустить сейчас") { Updater.relaunch(Bundle.main.bundleURL) }
                    .controlSize(.small)
            }
            .font(.caption)
        }
    }
}
