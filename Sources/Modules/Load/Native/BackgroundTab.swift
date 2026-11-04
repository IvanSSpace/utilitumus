import SwiftUI

// Вкладка «Фоновое»: сторонние агенты launchd и боты из bots.toml.
// Данные собирает `BackgroundStore` (Background/), действия и защита — `BackgroundExecutor`.
// Вкладка скрыта в `LoadScreen`, пока показывать нечего.

/// Вкладка «Фоновое». «Просто» — по строке на агента и боту с одной кнопкой; «Подробно» — всё как в lambscape.
struct BackgroundTab: View {
    @ObservedObject var background: BackgroundStore
    let mode: LoadViewMode
    var openFull: () -> Void

    var body: some View {
        Form {
            if mode == .full { full } else { simple }
        }
        .formStyle(.grouped)
        .onAppear { background.reloadJournal() }
    }

    private var data: BackgroundData { background.data }

    // MARK: Подробно

    @ViewBuilder
    private var full: some View {
        if !data.bots.isEmpty {
            Section("Боты") {
                ForEach(data.bots) { bot in
                    BotRow(bot: bot, busy: background.running) { background.request(bot, $0) }
                }
            }
        }
        Section {
            if data.agents.isEmpty {
                EmptyNote(text: "Сторонних агентов launchd нет.")
            } else {
                ForEach(data.agents) { agent in
                    AgentRow(agent: agent, busy: background.running) { background.request(agent, $0) }
                }
            }
        } header: {
            HStack {
                Text("Фоновые агенты")
                Text("\(data.agents.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Text(Fmt.mb(data.agents.filter { !$0.verbs.isEmpty }.reduce(0) { $0 + $1.memMB }))
                    .foregroundStyle(.secondary).monospacedDigit()
                    .help("Память агентов, которые можно остановить отсюда")
            }
        } footer: {
            Text("«Остановить» — до следующего входа. «Не запускать при входе» убирает автозапуск; «Вернуть» — обратно.")
                .font(.caption)
        }
        if !background.journal.isEmpty { JournalSection(entries: background.journal) }
    }

    // MARK: Просто

    @ViewBuilder
    private var simple: some View {
        Section {
            ForEach(data.bots) { bot in
                let verb: BotVerb = bot.isOn ? .stop : .start
                SimpleLine(dot: bot.isOn ? .green : .secondary, name: bot.name,
                           state: bot.isOn && bot.memMB > 0 ? Fmt.mb(bot.memMB) : bot.state.title.lowercased(),
                           button: bot.actions.contains(verb) ? (verb.title, verb == .start) : nil,
                           busy: background.running) { background.request(bot, verb) }
            }
            ForEach(data.agents) { agent in
                let verb: AgentVerb = agent.isRunning ? .stop : .enable
                SimpleLine(dot: agent.isRunning ? .green : .secondary, name: agent.title, state: agent.stateText,
                           button: agent.verbs.contains(verb) ? (agent.verbTitle(verb), verb == .enable) : nil,
                           busy: background.running) { background.request(agent, verb) }
            }
        } header: {
            HStack {
                Text("Боты и агенты")
                Text("\(data.bots.count + data.agents.count)").foregroundStyle(.secondary).monospacedDigit()
            }
        }
        Section {
            Button("Подробности: описание агентов, команды, журнал…", action: openFull).buttonStyle(.link)
        }
    }
}

/// Строка «Просто»: точка, имя, состояние и одна кнопка.
private struct SimpleLine: View {
    let dot: Color
    let name: String
    let state: String
    let button: (title: String, primary: Bool)?
    let busy: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dot.opacity(dot == .secondary ? 0.4 : 1)).frame(width: 9, height: 9)
            Text(name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(state).foregroundStyle(.secondary).monospacedDigit()
            if let button {
                if button.primary {
                    Button(button.title, action: action).buttonStyle(.borderedProminent).controlSize(.small).disabled(busy)
                } else {
                    Button(button.title, action: action).buttonStyle(.bordered).controlSize(.small).disabled(busy)
                }
            }
        }
    }
}

/// Сводка фонового в «Обзоре»: боты с кнопками и одна строка про агентов. Нечего показывать — секции нет.
struct BackgroundCompactSection: View {
    @ObservedObject var background: BackgroundStore
    var open: () -> Void

    var body: some View {
        let bots = background.data.bots, agents = background.data.agents
        if !bots.isEmpty || !agents.isEmpty {
            Section {
                ForEach(bots) { bot in
                    HStack(spacing: 8) {
                        Circle().fill(bot.isOn ? Color.green : Color.secondary.opacity(0.4)).frame(width: 9, height: 9)
                        Text(bot.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(bot.state.title).foregroundStyle(.secondary)
                        if !bot.useText.isEmpty { Text(bot.useText).foregroundStyle(.secondary).monospacedDigit() }
                        BotButtons(bot: bot, busy: background.running) { background.request(bot, $0) }
                    }
                }
                if !agents.isEmpty {
                    let live = agents.filter(\.isRunning)
                    HStack(spacing: 8) {
                        Circle().fill(live.isEmpty ? Color.secondary.opacity(0.4) : Color.green).frame(width: 9, height: 9)
                        Text("Фоновые агенты")
                        Spacer(minLength: 8)
                        Text("работают \(live.count) из \(agents.count)").foregroundStyle(.secondary).monospacedDigit()
                        Text(Fmt.mb(agents.filter { !$0.verbs.isEmpty }.reduce(0) { $0 + $1.memMB }))
                            .foregroundStyle(.secondary).monospacedDigit()
                            .help("Память агентов, которые можно остановить отсюда")
                        Button("разобрать", action: open).buttonStyle(.link)
                    }
                }
            } header: {
                HStack {
                    Text("Фоновое")
                    Text("\(bots.count + agents.count)").foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button("подробнее", action: open).buttonStyle(.link).font(.caption)
                }
            }
        }
    }
}
