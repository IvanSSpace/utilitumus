import AppKit
import SwiftUI

// Строки вкладки «Фоновое»: агент, бот, журнал и подтверждение действия. Только системные цвета и шрифты.

/// Точка состояния: запущен — зелёная, выключен — пустое кольцо, остальное — серая.
private struct StateDot: View {
    enum Kind { case on, warn, off, hollow }
    let kind: Kind

    var body: some View {
        Group {
            switch kind {
            case .on: Circle().fill(.green)
            case .warn: Circle().fill(.orange)
            case .off: Circle().fill(Color.white.opacity(0.18))
            case .hollow: Circle().strokeBorder(.secondary, lineWidth: 1.2)
            }
        }
        .frame(width: 9, height: 9)
    }
}

/// Маленькая метка рядом с именем («автозапуск», «KeepAlive», «root»).
private struct TagLabel: View {
    let text: String
    let help: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color.white.opacity(0.1), in: Capsule())
            .help(help)
    }
}

extension AgentItem {
    fileprivate var dotKind: StateDot.Kind { disabled ? .hollow : isRunning ? .on : .off }

    /// Что стоит справа: память, если запущен, иначе состояние.
    var stateText: String {
        isRunning ? Fmt.mb(memMB) : disabled ? "выключен" : "не запущен"
    }

    func verbTitle(_ v: AgentVerb) -> String {
        switch v {
        case .stop: return "Остановить"
        case .disable: return "Не запускать при входе"
        case .enable: return "Вернуть"
        }
    }
}

extension BotItem {
    fileprivate var dotKind: StateDot.Kind {
        switch state {
        case .running: return .on
        case .partial: return .warn
        case .stopped: return .off
        case .noConfig: return .hollow
        }
    }

    /// «292 MB · 2 д» — память и аптайм работающего бота.
    var useText: String {
        guard isOn else { return "" }
        return [memMB > 0 || !pids.isEmpty ? Fmt.mb(memMB) : "", uptime > 0 ? Fmt.duration(uptime) : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: Агент

struct AgentRow: View {
    let agent: AgentItem
    let busy: Bool
    let onAction: (AgentVerb) -> Void

    var body: some View {
        LoadLine { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                StateDot(kind: agent.dotKind).help(agent.disabled ? "выключен" : agent.isRunning ? "работает" : "не запущен")
                Text(agent.title).font(DS.rowTitle).lineLimit(1).truncationMode(.middle)
                if agent.domain == "system" { TagLabel(text: "root", help: "Системный демон: нужен sudo") }
                if agent.runAtLoad, !agent.disabled { TagLabel(text: "автозапуск", help: "Запускается при входе") }
                if agent.keepalive, !agent.disabled {
                    TagLabel(text: "KeepAlive", help: "launchd поднимет его снова, если просто убить процесс")
                }
                Spacer(minLength: 8)
                Text(agent.stateText).foregroundStyle(.secondary).monospacedDigit()
                    .help(agent.refusal != nil && agent.isRunning ? "Не входит в итог: отсюда не остановить" : "")
            }
            if !agent.note.isEmpty {
                Text(agent.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let place = agent.place { PlaceLabel(place: place, showHome: false) }
            HStack(spacing: 8) {
                Text(agent.label).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(agent.plist ?? agent.label)
                Spacer(minLength: 8)
                ForEach(agent.verbs, id: \.self) { verb in
                    DSButton(agent.verbTitle(verb), small: true) { onAction(verb) }
                }
            }
            .disabled(busy)
            if let hint = agent.sudoHint {
                HStack(spacing: 6) {
                    Text(hint).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Spacer(minLength: 8)
                    DSButton("", icon: "doc.on.doc", style: .plain, small: true) {
                        Kit.pasteboard.clearContents()
                        Kit.pasteboard.setString(hint, forType: .string)
                    }
                    .help("Скопировать команду").accessibilityLabel("Скопировать команду")
                }
            }
        }
    }
}

// MARK: Бот

/// Кнопки бота: «Включить» / «Выключить» / «Перезапустить» — только те, что есть в bots.toml и подходят состоянию.
struct BotButtons: View {
    let bot: BotItem
    let busy: Bool
    let onAction: (BotVerb) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if bot.actions.contains(.start) { DSButton(BotVerb.start.title, small: true) { onAction(.start) } }
            if bot.actions.contains(.stop) { DSButton(BotVerb.stop.title, small: true) { onAction(.stop) } }
            if bot.actions.contains(.restart) {
                DSButton("", icon: "arrow.clockwise", small: true) { onAction(.restart) }
                    .help("Перезапустить").accessibilityLabel("Перезапустить")
            }
        }
        .disabled(busy)
    }
}

struct BotRow: View {
    let bot: BotItem
    let busy: Bool
    let onAction: (BotVerb) -> Void

    private var link: URL? {
        guard let s = bot.url, let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased()) else { return nil }
        return u
    }

    var body: some View {
        LoadLine { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                StateDot(kind: bot.dotKind)
                Text(bot.name).font(DS.rowTitle).lineLimit(1).truncationMode(.middle)
                if let link {
                    Link(destination: link) {
                        Label(link.absoluteString.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""),
                              systemImage: "arrow.up.right.square")
                    }
                    .font(.caption).help("Панель бота — в браузере")
                }
                Spacer(minLength: 8)
                Text(bot.state.title).foregroundStyle(.secondary)
                if !bot.useText.isEmpty { Text(bot.useText).foregroundStyle(.secondary).monospacedDigit().help("память · аптайм") }
            }
            if bot.state == .noConfig {
                Label(bot.note, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !bot.note.isEmpty {
                Text(bot.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if bot.state != .noConfig {
                    Text(facts).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 8)
                BotButtons(bot: bot, busy: busy, onAction: onAction)
            }
        }
    }

    /// «порт 8765 · PID 27252 32086 +1»
    private var facts: String {
        let ports = bot.ports.isEmpty ? "—" : bot.ports.joined(separator: ", ")
        let shown = bot.pids.prefix(2).map(String.init).joined(separator: " ")
        let pids = bot.pids.isEmpty ? "—" : shown + (bot.pids.count > 2 ? " +\(bot.pids.count - 2)" : "")
        return "порт \(ports) · PID \(pids)"
    }
}

// MARK: Журнал

struct JournalSection: View {
    let entries: [ActionLog.Entry]

    var body: some View {
        DSSection("Журнал действий") {
            ForEach(entries) { e in
                LoadLine {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: e.ok ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(e.ok ? Color.green : Color.orange)
                        Text(e.message).lineLimit(2).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(e.time, format: .dateTime.day().month().hour().minute())
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
            LoadNote(text: "Полный журнал — файл ~/Library/Logs/Utilitumus/actions.log")
        }
    }
}

// MARK: Подтверждение

/// Подтверждение действия над агентом или ботом: что именно будет сделано, какие процессы остановятся
/// и какая команда запустится.
struct BackgroundConfirmSheet<Background: LoadBackgroundModel>: View {
    @ObservedObject var background: Background
    let plan: LoadBackgroundPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: plan.destructive ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                    .foregroundStyle(plan.destructive ? Color.orange : Color.blue)
                Text(plan.title).font(.title3.weight(.semibold)).lineLimit(2)
                Spacer()
                if !plan.targets.isEmpty {
                    Text("\(Fmt.plural(plan.targets.count, "процесс", "процесса", "процессов")) · ≈\(Fmt.mb(plan.totalMB))")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text(plan.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if !plan.targets.isEmpty {
                Text("Остановится:").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(plan.targets) { t in
                            HStack {
                                Text(t.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(String(t.pid)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                Text(Fmt.mb(t.memMB)).monospacedDigit().frame(width: 80, alignment: .trailing)
                            }
                            .padding(.vertical, 3)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

            if !plan.command.isEmpty {
                Text("Команда:").font(.caption).foregroundStyle(.secondary)
                Text(plan.command).font(.caption.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if background.running {
                    ProgressView().controlSize(.small)
                    Text("Выполняю…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                // Enter по умолчанию отменяет: случайное нажатие ничего не изменит.
                Button("Отмена") { background.cancel() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(background.running)
                Button(plan.confirmTitle, role: plan.destructive ? .destructive : nil) { background.confirm(plan.id) }
                    .disabled(background.running)
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(background.running)
    }
}
