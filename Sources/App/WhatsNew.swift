import SwiftUI

/// «Обновление стороннего программного обеспечения»: что изменилось в версии.
/// Тексты — в Resources/WhatsNew.json; оттуда же release.sh берёт описание релиза на GitHub.
struct WhatsNewEntry: Decodable, Identifiable {
    let version: String
    let items: [Item]
    var id: String { version }

    /// Пункт — строка или `{ "icon": SF Symbol, "text": … }`.
    struct Item: Decodable, Hashable {
        let icon: String
        let text: String

        init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                self.icon = "sparkle"
                self.text = text
                return
            }
            let c = try decoder.container(keyedBy: Keys.self)
            icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "sparkle"
            text = try c.decode(String.self, forKey: .text)
        }

        private enum Keys: String, CodingKey { case icon, text }
    }
}

@MainActor
final class WhatsNew: ObservableObject {
    static let shared = WhatsNew()

    /// Версии не новее установленной: запись следующего релиза пишется заранее и не должна светиться.
    let entries: [WhatsNewEntry]
    @Published var isShown = false

    private static let seenKey = "WhatsNewSeen"
    private let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    /// Готовый список без чтения ресурса: так окно собирает проверка.
    init(entries: [WhatsNewEntry]) {
        self.entries = entries
    }

    private init() {
        let url = Bundle.main.url(forResource: "WhatsNew", withExtension: "json")
        let all = url.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([WhatsNewEntry].self, from: $0) } ?? []
        let current = self.current
        entries = all.filter { $0.version.compare(current, options: .numeric) != .orderedDescending }
    }

    /// После обновления показываем один раз. На новой установке — нет: там всё «новое».
    func showIfUpdated() {
        let defaults = UserDefaults.standard
        let seen = defaults.string(forKey: Self.seenKey)
        defaults.set(current, forKey: Self.seenKey)
        // Ключа ещё нет, но приложение уже стояло (0.4.0 и раньше его не писали) — это обновление.
        let updated = seen.map { $0 != current } ?? (defaults.object(forKey: "ModulesV2") != nil)
        if updated, entries.contains(where: { $0.version == current }) { isShown = true }
    }
}

// MARK: - Окно

struct WhatsNewSheet: View {
    @ObservedObject var whatsNew: WhatsNew
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dsTheme) private var theme
    @State private var selected: String?

    init(whatsNew: WhatsNew = .shared) {
        self.whatsNew = whatsNew
    }

    private var entry: WhatsNewEntry? {
        whatsNew.entries.first { $0.version == selected } ?? whatsNew.entries.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if whatsNew.entries.count > 1 { versionPicker }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let entry {
                        let tints = Self.tints(for: theme)
                        ForEach(Array(entry.items.enumerated()), id: \.offset) { index, item in
                            ItemRow(item: item, tint: tints[index % tints.count])
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Понятно") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 500, height: 560)
        .onAppear {
            selected = whatsNew.entries.first?.version
        }
    }

    // Шапка: статичный градиент. У «Графита» серый, в цвет темы: цветной ему не подходит.
    private var headerColors: [Color] {
        if theme == .graphite { return [Color(white: 0.30), Color(white: 0.20)] }
        return [Color(hue: 0.62, saturation: 0.55, brightness: 0.9),
                Color(hue: 0.80, saturation: 0.6, brightness: 0.75),
                Color(hue: 0.95, saturation: 0.55, brightness: 0.85)]
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: headerColors, startPoint: .top, endPoint: .bottom)
            HStack(spacing: 14) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Обновление стороннего программного обеспечения")
                        .font(.title3.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let entry {
                        Text("Версия \(entry.version)")
                            .font(.callout.weight(.medium))
                            .opacity(0.85)
                    }
                }
                .foregroundStyle(.white)
            }
            .padding(20)
        }
        .frame(height: 118)
        .clipped()
    }

    private var versionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(whatsNew.entries) { e in
                    let isOn = e.version == entry?.version
                    Button {
                        guard !isOn else { return }
                        selected = e.version
                    } label: {
                        Text(e.version)
                            .font(.callout.weight(isOn ? .semibold : .regular).monospacedDigit())
                            .foregroundStyle(isOn ? Color.white : Color.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background {
                                if isOn {
                                    Capsule()
                                        .fill(Color.accentColor.gradient)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
        }
        .scrollClipDisabled()
    }

    /// Плитки значков пунктов. У «Графита» одна приглушённая серая, как шапка: белый значок на ней читается, пестрота не нужна.
    static func tints(for theme: DSTheme) -> [Color] {
        if theme == .graphite { return [Color(white: 0.38)] }
        return [.pink, .orange, .yellow, .green, .teal, .blue, .indigo, .purple]
    }
}

private struct ItemRow: View {
    let item: WhatsNewEntry.Item
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(item.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
