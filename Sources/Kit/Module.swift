import SwiftUI

/// Модули в боковой панели. Новый модуль = новый case + экран в `ModuleDetail`.
enum Module: String, CaseIterable, Identifiable {
    case sound, load, stash, fans, mixer, mouse, browser, voice, clipboard
    case keyboard
    case awake

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sound: return "Звук"
        case .load: return "Нагрузка"
        case .stash: return "Стеш программ"
        case .fans: return "Вентиляторы"
        case .mixer: return "Микшер"
        case .mouse: return "Мышь"
        case .browser: return "Браузер"
        case .voice: return "Голос"
        case .clipboard: return "Буфер"
        case .keyboard: return "Клавиатура"
        case .awake: return "Не спать"
        }
    }

    var icon: String {
        switch self {
        case .sound: return "mic.fill"
        case .load: return "gauge.with.dots.needle.67percent"
        case .stash: return "square.stack.3d.down.right.fill"
        case .fans: return "fan.fill"
        case .mixer: return "slider.vertical.3"
        case .mouse: return "computermouse"
        case .browser: return "globe"
        case .voice: return "waveform"
        case .clipboard: return "doc.on.clipboard.fill"
        case .keyboard: return "keyboard"
        case .awake: return "cup.and.saucer.fill"
        }
    }

    /// Цвет плашки значка: у каждого модуля свой, как в Системных настройках.
    /// Системные цвета адаптируются к светлой и тёмной теме.
    var tint: Color {
        switch self {
        case .sound: return .blue
        case .load: return .orange
        case .stash: return .purple
        case .fans: return .teal
        case .mixer: return .pink
        case .mouse: return Color(nsColor: .systemGray)
        case .browser: return .indigo
        case .voice: return .green
        case .clipboard: return .mint
        case .keyboard: return .cyan
        case .awake: return .brown
        }
    }

    /// Одна строка о модуле — для витрины Стора.
    var summary: String {
        switch self {
        case .sound: return "Держит основной микрофон по приоритету, не даёт Bluetooth-наушникам стать входом"
        case .load: return "Куда уходит память, сессии Claude Code, фоновые агенты"
        case .stash: return "Закрывает отмеченные программы перед игрой и возвращает их с окнами на места"
        case .fans: return "Режимы Авто, Константа и По датчику, температура процессора и видеокарты"
        case .mixer: return "Громкость каждого приложения отдельно"
        case .mouse: return "Своё направление прокрутки для мыши и плавная прокрутка колеса"
        case .browser: return "Панель выбора браузера у курсора для каждой ссылки и правила «сайт или приложение — браузер»"
        case .voice: return "Голосовой ввод по горячей клавише: надиктовал — текст вставился туда, где курсор. Всё распознаётся на этом Mac"
        case .clipboard: return "История буфера обмена и цветные пространства для ссылок и текстов. Панель по горячей клавише, всё зашифровано на этом Mac"
        case .keyboard: return "Фишки для клавиатуры: мгновенная смена языка по Fn, раскладка для каждого приложения"
        case .awake: return "Mac не засыпает, пока ты работаешь: на час, на несколько или пока не выключишь"
        }
    }
}

/// Белый значок на цветной скруглённой плашке — один вид везде, где показан модуль.
struct ModuleIconBadge: View {
    let module: Module
    var size: CGFloat = 22
    @Environment(\.dsTheme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(theme.badge(module).gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: module.icon)
                    .font(.system(size: size * 0.55, weight: .medium))
                    .foregroundStyle(.white)
            }
    }
}
