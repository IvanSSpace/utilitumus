import SwiftUI

/// «Обновление стороннего программного обеспечения»: что изменилось в версии.
/// Тексты — в Resources/WhatsNew.json; оттуда же release.sh берёт описание релиза на GitHub.
struct WhatsNewEntry: Decodable, Identifiable {
    let version: String
    let items: [String]
    var id: String { version }
}

@MainActor
final class WhatsNew: ObservableObject {
    static let shared = WhatsNew()

    let entries: [WhatsNewEntry]
    @Published var isShown = false

    private static let seenKey = "WhatsNewSeen"
    private let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private init() {
        let url = Bundle.main.url(forResource: "WhatsNew", withExtension: "json")
        entries = url.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([WhatsNewEntry].self, from: $0) } ?? []
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

struct WhatsNewSheet: View {
    @ObservedObject var whatsNew = WhatsNew.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        Text("Обновление стороннего программного обеспечения")
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(whatsNew.entries.enumerated()), id: \.element.id) { index, entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Версия \(entry.version)")
                                .font(.headline)
                                .foregroundStyle(index == 0 ? .primary : .secondary)
                            ForEach(entry.items, id: \.self) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•").foregroundStyle(.secondary)
                                    Text(item)
                                }
                                .foregroundStyle(index == 0 ? .primary : .secondary)
                            }
                        }
                    }
                }
                .padding(24)
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
        .frame(width: 480, height: 420)
    }
}
