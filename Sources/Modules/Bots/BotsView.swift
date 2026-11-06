import SwiftUI

/// Экран «Боты»: карточка на бота, подтверждение действия, подсказка про bots.toml, когда ботов нет.
/// Системные цвета и шрифты `DS`: один вид у центра и у утилиты.
struct BotsView<Model: BotsModel>: View {
    @ObservedObject var model: Model
    @Environment(\.dsTheme) private var theme

    var body: some View {
        DSPage(module: .bots, subtitle: BotsText.summary(model.state),
               primary: DSAction("Обновить", icon: "arrow.clockwise") { model.refreshNow() }) {
            if let notice = model.state.notice { noticeBanner(notice) }
            if model.state.file.kind == .unsafe { unsafeBanner }
            if model.state.bots.isEmpty {
                emptyState
            } else {
                VStack(spacing: DS.blockSpacing) {
                    ForEach(model.state.bots) { bot in
                        BotCardView(bot: bot, busy: model.state.running) { model.request(bot, $0) }
                    }
                }
            }
        }
        .defaultScrollAnchor(.top)
        .onPageActive { open in open ? model.screenAppeared() : model.screenDisappeared() }
        .sheet(item: Binding(get: { model.state.prompt }, set: { if $0 == nil { model.cancel() } })) { prompt in
            BotsConfirmSheet(model: model, prompt: prompt).dsThemed()
        }
    }

    private func noticeBanner(_ n: BotsNotice) -> some View {
        HStack(spacing: 10) {
            Label(n.text, systemImage: n.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(n.isError ? Color.orange : Color.green)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            DSButton("Закрыть", style: .plain, small: true) { model.dismissNotice() }
        }
        .font(.callout)
    }

    private var unsafeBanner: some View {
        Label("Кнопки отключены: \(model.state.file.detail). Пока права не исправлены, команды из файла не запускаются.",
              systemImage: "lock.trianglebadge.exclamationmark.fill")
            .font(.callout).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var emptyState: some View {
        DSSection("Как добавить бота") {
            VStack(alignment: .leading, spacing: 10) {
                Text(emptyLead).font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("Файл: ~/Library/Application Support/Utilitumus/bots.toml. Команды запускаются как есть, без shell; кнопка появляется только у тех, что описаны. Токены в файл не пиши: «requires_env» проверяет лишь, что переменная задана.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(BotsText.example).font(.caption.monospaced()).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.18)))
            }
            .padding(14)
        }
    }

    private var emptyLead: String {
        switch model.state.file.kind {
        case .unsafe: return "Файл найден, но ему нельзя доверять: \(model.state.file.detail)."
        case .invalid: return "Файл найден, но не разобрался. Проверь кавычки и скобки: каждый бот начинается с [[bot]]."
        case .ok: return "В файле нет ни одного бота с id, name и project."
        case .missing: return "Ботов пока нет. Опиши их в файле, и они появятся здесь: статус, память, кнопки включить и выключить."
        }
    }
}

// MARK: Карточка

private struct StatusDot: View {
    let state: BotState

    var body: some View {
        Group {
            switch state {
            case .running: Circle().fill(.green)
            case .partial: Circle().fill(.orange)
            case .stopped: Circle().fill(Color.white.opacity(0.18))
            case .noConfig: Circle().strokeBorder(.secondary, lineWidth: 1.2)
            }
        }
        .frame(width: 9, height: 9)
    }
}

struct BotCardView: View {
    let bot: BotCard
    let busy: Bool
    let onAction: (BotVerb) -> Void
    @Environment(\.dsTheme) private var theme

    private var link: URL? { bot.url.flatMap { BotsMonitor.safeURL($0) }.flatMap(URL.init(string:)) }
    private var on: Bool { bot.state == .running || bot.state == .partial }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusDot(state: bot.state)
                Text(bot.name).font(DS.rowTitle).lineLimit(1).truncationMode(.middle)
                Text(bot.project).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Text(bot.state.title).foregroundStyle(.secondary)
            }
            if bot.state == .noConfig {
                Label(bot.note, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 14) {
                    fact("память", on ? Fmt.mb(bot.memMB) : "—")
                    fact("аптайм", on && bot.uptime > 0 ? Fmt.duration(Double(bot.uptime)) : "—")
                    fact("порт", bot.ports.isEmpty ? "—" : bot.ports.joined(separator: ", "))
                    Spacer(minLength: 8)
                    if let link {
                        Link(destination: link) {
                            Label(link.absoluteString.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""),
                                  systemImage: "arrow.up.right.square")
                        }
                        .font(.caption).help("Панель бота — в браузере")
                    }
                }
                if !bot.note.isEmpty {
                    Text(bot.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !bot.verbs.isEmpty {
                HStack(spacing: 8) {
                    ForEach(bot.verbs, id: \.self) { verb in
                        DSButton(verb.title, icon: verb == .restart ? "arrow.clockwise" : nil, small: true) { onAction(verb) }
                    }
                    Spacer()
                }
                .disabled(busy)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous).fill(theme.group))
        .overlay(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous).stroke(.white.opacity(0.06), lineWidth: 0.7))
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).monospacedDigit()
        }
    }
}

// MARK: Подтверждение

/// Что именно запустится. Enter по умолчанию отменяет: случайное нажатие ничего не изменит.
struct BotsConfirmSheet<Model: BotsModel>: View {
    @ObservedObject var model: Model
    let prompt: BotsPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: prompt.destructive ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                    .foregroundStyle(prompt.destructive ? Color.orange : Color.blue)
                Text(prompt.title).font(.title3.weight(.semibold)).lineLimit(2)
                Spacer()
            }
            Text(prompt.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !prompt.command.isEmpty {
                Text("Команда:").font(.caption).foregroundStyle(.secondary)
                Text(prompt.command).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.state.running {
                    ProgressView().controlSize(.small)
                    Text("Выполняю…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Отмена") { model.cancel() }.keyboardShortcut(.defaultAction).disabled(model.state.running)
                Button(prompt.confirmTitle, role: prompt.destructive ? .destructive : nil) { model.confirm(prompt.id) }
                    .disabled(model.state.running)
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(model.state.running)
    }
}
