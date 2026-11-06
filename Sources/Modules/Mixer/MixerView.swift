import SwiftUI

/// Разделитель между строками карточки — как в `DSRow`, но строка ниже (38 вместо 50 pt),
/// чтобы микшер целиком помещался в стандартное окно.
private struct RowDivider: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12).padding(.vertical, 5)
            .frame(minHeight: 38)
            .overlay(alignment: .top) {
                Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 46)
            }
    }
}

private struct AppIcon: View {
    let image: NSImage
    var body: some View {
        Image(nsImage: image).resizable().frame(width: 26, height: 26)
    }
}

/// Строка получает значения и замыкания, а не контроллер: иначе каждая публикация
/// контроллера перерисовывала бы все строки. `Equatable` по `app` пропускает
/// пересчёт, когда у строки ничего не поменялось.
private struct MixerRow: View, Equatable {
    let app: MixerApp
    let onVolume: (Double) -> Void
    let onCommit: () -> Void
    let onToggleMute: () -> Void
    @Environment(\.dsTint) private var tint
    /// Значение под пальцем: слайдер двигается сразу, а список публикуется позже.
    @State private var dragging: Double?

    static func == (a: MixerRow, b: MixerRow) -> Bool { a.app == b.app }

    private var shownVolume: Double { dragging ?? app.volume }

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(image: app.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(DS.rowTitle).foregroundStyle(.white.opacity(0.95)).lineLimit(1)
                if app.muted {
                    Text("без звука").font(DS.rowSubtitle).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 150, alignment: .leading)

            Slider(value: Binding(
                get: { shownVolume },
                // Без step: на macOS 26 он рисует под дорожкой точечные засечки.
                set: {
                    let value = ($0 * 100).rounded() / 100
                    dragging = value
                    onVolume(value)
                }
            ), in: 0...1, onEditingChanged: { editing in
                if !editing { onCommit(); dragging = nil }
            })
            .tint(tint)
            .controlSize(.small)
            .opacity(app.muted ? 0.4 : 1)

            Text("\(Int((shownVolume * 100).rounded())) %")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 40, alignment: .trailing)

            Button {
                onToggleMute()
            } label: {
                Image(systemName: app.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(app.muted ? Color.red : .white.opacity(0.6))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(app.muted ? "Вернуть звук" : "Выключить звук")
        }
        .modifier(RowDivider())
        .onChange(of: app.volume) { dragging = nil }
    }
}

/// Приложение не запущено, но для него задана громкость: можно только сбросить.
private struct PresetRow: View, Equatable {
    let app: MixerApp
    let onReset: () -> Void

    static func == (a: PresetRow, b: PresetRow) -> Bool { a.app == b.app }

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(image: app.icon)
            Text(app.name).font(DS.rowTitle).foregroundStyle(.white.opacity(0.95)).lineLimit(1)
            Spacer(minLength: 6)
            Text(app.muted ? "без звука" : "\(Int((app.volume * 100).rounded())) %")
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            DSButton("Сбросить", small: true) { onReset() }
        }
        .modifier(RowDivider())
    }
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4)).padding(.horizontal, 6)
    }
}

/// Сворачивающая строка «Остальных»: компактная, подсказка вместо пояснения.
private struct OthersToggle: View {
    let expanded: Bool
    let count: Int
    @Environment(\.dsTint) private var tint

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.18))
                .frame(width: 26, height: 26)
                .overlay(Image(systemName: "square.stack").font(.system(size: 12, weight: .semibold)).foregroundStyle(tint))
            Text(expanded ? "Скрыть (\(count))" : "Показать (\(count))").font(DS.rowTitle).foregroundStyle(.white.opacity(0.95))
            Spacer(minLength: 6)
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
        }
        .modifier(RowDivider())
        .contentShape(Rectangle())
    }
}

struct MixerView<Model: MixerModel>: View {
    @ObservedObject var model: Model
    @State private var showOthers = false

    init(model: Model) { self.model = model }

    private func row(_ app: MixerApp) -> some View {
        let id = app.id
        return MixerRow(
            app: app,
            onVolume: { model.setVolume($0, for: id) },
            onCommit: { model.commitVolumes() },
            onToggleMute: { model.setMuted(!model.isMuted(id), for: id) }
        ).equatable()
    }

    private func idleSection() -> some View {
        DSSection("Молчат сейчас", trailing: "\(model.idleApps.count)") {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.idleApps) { app in row(app) }
            }
        }
        .help("Настрой заранее: громкость запомнится и применится, когда приложение начнёт звучать")
    }

    private func presetSection() -> some View {
        DSSection("Настроены заранее", trailing: "\(model.presetApps.count)") {
            ForEach(model.presetApps) { app in
                let id = app.id
                PresetRow(app: app, onReset: { model.reset(id) }).equatable()
            }
        }
    }

    private func othersSection() -> some View {
        DSSection("Остальные запущенные") {
            // Кликается вся строка, а не только стрелка.
            Button {
                showOthers.toggle()
            } label: {
                OthersToggle(expanded: showOthers, count: model.otherApps.count)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Звука от них обычно нет. Зазвучат — переедут наверх")
            if showOthers {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.otherApps) { app in row(app) }
                }
            }
        }
    }

    var body: some View {
        DSPage(
            module: .mixer,
            subtitle: model.apps.isEmpty ? "Сейчас ничего не играет" : "Играют: \(model.apps.count)"
        ) {
            if model.permissionProblem {
                DSSection("Нужно разрешение") {
                    DSRow(icon: "lock.shield", title: "Запись системного звука",
                          subtitle: model.runsInUtility
                              ? "Без неё громкость не меняется. Включи Микшер в «Конфиденциальность и безопасность → Запись экрана и системного звука». Если громкость не заработает, выключи модуль и включи снова."
                              : "Без неё громкость не меняется. Включи Utilitumus в «Конфиденциальность и безопасность → Запись экрана и системного звука» и перезапусти приложение.") {
                        DSButton("Открыть настройки…", small: true) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                                if !Kit.standRefuses("системные настройки") { NSWorkspace.shared.open(url) }
                            }
                        }
                    }
                    if let error = model.lastError {
                        DSRow(icon: "exclamationmark.triangle.fill", title: error)
                    }
                }
            }

            // Блоки ближе друг к другу, чем в остальных модулях: список здесь главное.
            VStack(alignment: .leading, spacing: 14) {
                DSSection("Сейчас играют", trailing: model.apps.isEmpty ? nil : "\(model.apps.count)") {
                    if model.apps.isEmpty {
                        Text("Сейчас ничего не играет").font(DS.rowTitle).foregroundStyle(.white.opacity(0.6))
                            .modifier(RowDivider())
                    }
                    ForEach(model.apps) { app in row(app) }
                }

                // Все секции на всю ширину и теми же строками: громкость молчащим ставят заранее.
                if !model.idleApps.isEmpty { idleSection() }
                if !model.presetApps.isEmpty { presetSection() }
                if !model.otherApps.isEmpty { othersSection() }

                Note(model.runsInUtility
                     ? "Выше 100 % громкость не поднять. Микшер работает и без Utilitumus. Выключи модуль или выйди из Микшера, и всё вернётся как было."
                     : "Выше 100 % громкость не поднять. При выходе из Utilitumus всё возвращается как было.")
            }
        }
        .onPageActive { model.setScreenVisible($0) }
    }
}

extension MixerView where Model == MixerController {
    /// Встроенный модуль: экран работает с контроллером в этом же процессе.
    init() { self.init(model: .shared) }
}
