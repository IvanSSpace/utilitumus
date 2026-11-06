import SwiftUI

/// Мини-окошко темы 92×60: боковая панель, фон и карточка.
/// Рисуется теми же функциями темы, что и настоящее окно, поэтому не врёт.
struct ThemePreview: View {
    let theme: DSTheme
    var selected = false

    /// Модуль для образца: из средней категории, чтобы акцент был «обычным».
    private let sample = Module.voice

    var body: some View {
        let bg = theme.background(sample)
        let accent = theme.accent(sample)
        VStack(spacing: 5) {
            HStack(spacing: 0) {
                sidebar
                content(accent: accent)
            }
            .frame(width: 92, height: 60)
            .background(LinearGradient(colors: bg, startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 0.7))
            .padding(3)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(accent, lineWidth: selected ? 2 : 0))
            Text(theme.title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(.white.opacity(selected ? 0.95 : 0.6))
        }
        .contentShape(Rectangle())
    }

    /// Полоска панели: по точке на цвет категории, у средней — подсветка выбранной строки.
    private var sidebar: some View {
        VStack(spacing: 7) {
            ForEach(Array(ModuleCategory.all.enumerated()), id: \.element.id) { index, category in
                Circle().fill(theme.categoryColor(category)).frame(width: 7, height: 7)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(index == 1 ? theme.selection(sample) : .clear))
            }
        }
        .frame(width: 22)
        .frame(maxHeight: .infinity)
        .background(theme.sidebar)
    }

    /// Карточка страницы: заголовок, строка и кнопка акцентом.
    private func content(accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Capsule().fill(.white.opacity(0.75)).frame(width: 26, height: 3)
            Capsule().fill(.white.opacity(0.28)).frame(width: 38, height: 2.5)
            Spacer(minLength: 0)
            Capsule().fill(accent).frame(width: 20, height: 7)
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.card))
        .padding(6)
    }
}
