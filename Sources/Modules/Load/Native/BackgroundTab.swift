import SwiftUI

// Вкладка «Фоновое»: сторонние агенты launchd и боты из bots.toml.
// Данные собирает `BackgroundStore` (Background/), действия и защита — `BackgroundExecutor`.
// Вкладка скрыта в `LoadScreen`, пока показывать нечего.

/// Вкладка «Фоновое». «Просто» — по строке на агента и боту с одной кнопкой; «Подробно» — всё как в lambscape.
struct BackgroundTab<Background: LoadBackgroundModel>: View {
    @ObservedObject var background: Background
    let mode: LoadViewMode
    var openFull: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.blockSpacing) {
            if mode == .full { full } else { simple }
        }
        .onAppear { background.reloadJournal() }
    }

    private var data: BackgroundData { background.data }

    // MARK: Подробно

    @ViewBuilder
    private var full: some View {
        if !data.bots.isEmpty {
            DSSection("Боты") {
                ForEach(data.bots) { bot in
                    BotRow(bot: bot, busy: background.running) { background.request(bot, $0) }
                }
            }
        }
        DSSection("Фоновые агенты",
                  trailing: "\(data.agents.count) · " + Fmt.mb(data.agents.filter { !$0.verbs.isEmpty }.reduce(0) { $0 + $1.memMB })) {
            if data.agents.isEmpty {
                LoadEmpty(text: "Сторонних агентов launchd нет.")
            } else {
                ForEach(data.agents) { agent in
                    AgentRow(agent: agent, busy: background.running) { background.request(agent, $0) }
                }
                LoadNote(text: "«Остановить» — до следующего входа. «Не запускать при входе» убирает автозапуск; «Вернуть» — обратно. Память в итоге — только у агентов, которые можно остановить отсюда.")
            }
        }
        if !background.journal.isEmpty { JournalSection(entries: background.journal) }
    }

    // MARK: Просто

    @ViewBuilder
    private var simple: some View {
        DSSection("Боты и агенты", trailing: String(data.bots.count + data.agents.count)) {
            ForEach(data.bots) { bot in
                let verb: BotVerb = bot.isOn ? .stop : .start
                SimpleLine(dot: bot.isOn ? .green : .secondary, name: bot.name,
                           state: bot.isOn && bot.memMB > 0 ? Fmt.mb(bot.memMB) : bot.state.title.lowercased(),
                           button: bot.actions.contains(verb) ? verb.title : nil,
                           busy: background.running) { background.request(bot, verb) }
            }
            ForEach(data.agents) { agent in
                let verb: AgentVerb = agent.isRunning ? .stop : .enable
                SimpleLine(dot: agent.isRunning ? .green : .secondary, name: agent.title, state: agent.stateText,
                           button: agent.verbs.contains(verb) ? agent.verbTitle(verb) : nil,
                           busy: background.running) { background.request(agent, verb) }
            }
        }
        HStack {
            DSButton("Подробности: описание агентов, команды, журнал", icon: "chevron.right", style: .plain, small: true, action: openFull)
            Spacer()
        }
    }
}

/// Строка «Просто»: точка, имя, состояние и одна кнопка.
private struct SimpleLine: View {
    let dot: Color
    let name: String
    let state: String
    let button: String?
    let busy: Bool
    let action: () -> Void

    var body: some View {
        LoadLine {
            HStack(spacing: 8) {
                Circle().fill(dot.opacity(dot == .secondary ? 0.4 : 1)).frame(width: 9, height: 9)
                Text(name).font(DS.rowTitle).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(state).foregroundStyle(.secondary).monospacedDigit()
                if let button {
                    DSButton(button, small: true, action: action).disabled(busy)
                }
            }
        }
    }
}

/// Сводка фонового в «Обзоре»: боты с кнопками и одна строка про агентов. Нечего показывать — секции нет.
struct BackgroundCompactSection<Background: LoadBackgroundModel>: View {
    @ObservedObject var background: Background
    var open: () -> Void

    var body: some View {
        let bots = background.data.bots, agents = background.data.agents
        if !bots.isEmpty || !agents.isEmpty {
            DSSection("Фоновое", trailing: String(bots.count + agents.count)) {
                ForEach(bots) { bot in
                    LoadLine {
                        HStack(spacing: 8) {
                            Circle().fill(bot.isOn ? Color.green : Color.secondary.opacity(0.4)).frame(width: 9, height: 9)
                            Text(bot.name).font(DS.rowTitle).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(bot.state.title).foregroundStyle(.secondary)
                            if !bot.useText.isEmpty { Text(bot.useText).foregroundStyle(.secondary).monospacedDigit() }
                            BotButtons(bot: bot, busy: background.running) { background.request(bot, $0) }
                        }
                    }
                }
                if !agents.isEmpty {
                    let live = agents.filter(\.isRunning)
                    LoadLine {
                        HStack(spacing: 8) {
                            Circle().fill(live.isEmpty ? Color.secondary.opacity(0.4) : Color.green).frame(width: 9, height: 9)
                            Text("Фоновые агенты").font(DS.rowTitle)
                            Spacer(minLength: 8)
                            Text("работают \(live.count) из \(agents.count)").foregroundStyle(.secondary).monospacedDigit()
                            Text(Fmt.mb(agents.filter { !$0.verbs.isEmpty }.reduce(0) { $0 + $1.memMB }))
                                .foregroundStyle(.secondary).monospacedDigit()
                                .help("Память агентов, которые можно остановить отсюда")
                            DSButton("Разобрать", small: true, action: open)
                        }
                    }
                } else {
                    LoadLine { DSButton("Подробнее", icon: "chevron.right", style: .plain, small: true, action: open) }
                }
            }
        }
    }
}
