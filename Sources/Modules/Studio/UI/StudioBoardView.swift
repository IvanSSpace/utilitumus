import SwiftUI

/// Рабочая часть экрана (макет A): фильтры со счётчиками и поиск, сверху Хаб и Лаунчер, ниже сетка утилит («Выпущены»,
/// «В разработке»), справа панель выбранной.
struct StudioBoardView<Model: StudioModel>: View {
    @ObservedObject var model: Model
    let board: StudioBoard
    @Binding var filter: StudioFilter
    @Binding var query: String
    @Environment(\.dsTint) private var tint

    private var visible: [StudioUnit] { board.units.filter { filter.matches($0, query: query) } }
    private var selected: StudioUnit? { board.selected.flatMap(board.unit) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let problem = board.problem { banner(problem, retry: true) }
            if let orca = board.orcaError { banner(orca, retry: false) }
            toolbar
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    topRow
                    grid
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                if let selected {
                    StudioDetailPanel(model: model, unit: selected, board: board) { model.send(.deselect) }
                        .frame(width: 340)
                }
            }
        }
    }

    // MARK: Панель инструментов

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(StudioFilter.allCases, id: \.self) { item in filterChip(item) }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                TextField("", text: $query, prompt: Text("Поиск утилиты"))
                    .textFieldStyle(.plain).font(.system(size: 12.5))
                    .accessibilityLabel("Поиск утилиты")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.4)) }
                        .buttonStyle(.plain).accessibilityLabel("Очистить поиск")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(width: 190)
            .background(Capsule().fill(.white.opacity(0.08)))
        }
    }

    private func filterChip(_ item: StudioFilter) -> some View {
        let on = filter == item
        let count = board.units.filter { item.matches($0, query: "") }.count
        return Button { filter = item } label: {
            HStack(spacing: 5) {
                Text(item.title).font(.system(size: 11.5, weight: .semibold))
                Text("\(count)").font(.system(size: 11, weight: .medium)).opacity(0.6)
            }
            .foregroundStyle(on ? Color.black.opacity(0.8) : .white.opacity(0.7))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(on ? tint : .white.opacity(0.07)))
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func banner(_ text: String, retry: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(red: 1.0, green: 0.7, blue: 0.25))
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if retry { DSButton("Подключиться заново", small: true) { model.send(.reconnect) } }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(red: 1.0, green: 0.7, blue: 0.25).opacity(0.13)))
    }

    // MARK: Сетка

    private var grid: some View {
        let released = visible.filter(\.released)
        let inDevelopment = visible.filter { !$0.released }
        return VStack(alignment: .leading, spacing: 14) {
            if released.isEmpty && inDevelopment.isEmpty {
                Text("Ничего не нашлось").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 40)
            }
            section("Выпущены", released)
            section("В разработке", inDevelopment)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func section(_ title: String, _ units: [StudioUnit]) -> some View {
        if !units.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title.uppercased()).font(DS.sectionTitle).tracking(0.8).foregroundStyle(.white.opacity(0.42))
                    Spacer()
                    Text("\(units.count)").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                }
                .padding(.horizontal, 4)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 142, maximum: 190), spacing: 10)], spacing: 10) {
                    ForEach(units) { unit in
                        StudioUnitCard(unit: unit, png: board.icons[unit.id], selected: board.selected == unit.id,
                                       busy: board.working.contains(unit.id)) { model.send(.select(unit.id)) }
                    }
                }
            }
        }
    }

    // MARK: Хаб и Лаунчер

    /// Хаб шире, Лаунчер рядом: сквозное над сеткой утилит. Поиск и фильтры их не прячут.
    private var topRow: some View {
        HStack(alignment: .top, spacing: 10) {
            if let hub = board.unit("orchestrator") { hubCard(hub).frame(maxWidth: .infinity) }
            if let launcher = board.unit("launcher") { launcherCard(launcher).frame(width: 210) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func hubCard(_ hub: StudioUnit) -> some View {
        Button { model.send(.select(hub.id)) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    StudioMasterDot(state: hub.master)
                    Text("Хаб · оркестратор").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.95))
                }
                Text("\(hub.master.label) · сквозное, проверки и выпуски").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                if board.hubTasks.isEmpty {
                    Text("Задач у хаба нет").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4))
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(board.hubTasks.enumerated()), id: \.offset) { _, task in
                            HStack(spacing: 6) {
                                Text(task.name).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                                Spacer(minLength: 4)
                                DSChip(task.label, color: taskColor(task.status))
                            }
                            .help(task.comment)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: DS.rowRadius + 3, style: .continuous).fill(.white.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: DS.rowRadius + 3, style: .continuous).stroke(board.selected == hub.id ? tint.opacity(0.8) : .white.opacity(0.07), lineWidth: board.selected == hub.id ? 1.2 : 0.7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusEffectDisabled()
    }

    private func taskColor(_ status: String) -> Color {
        switch status {
        case "in-progress": return StudioStatusKey.work.color
        case "in-review": return StudioStatusKey.ready.color
        default: return .white.opacity(0.55)
        }
    }

    private func launcherCard(_ launcher: StudioUnit) -> some View {
        Button { model.send(.select(launcher.id)) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    StudioIcon(unit: launcher, png: board.icons[launcher.id], side: 24)
                    Text("Лаунчер \(launcher.version ?? "")").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.95))
                    Spacer(minLength: 4)
                    StudioMasterDot(state: launcher.master)
                }
                Text("Свой мастер: окно центра, Стор, обновления, экраны утилит").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                StudioStatusPill(key: launcher.statusKey)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: DS.rowRadius + 3, style: .continuous).fill(.white.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: DS.rowRadius + 3, style: .continuous).stroke(board.selected == launcher.id ? tint.opacity(0.8) : .white.opacity(0.07), lineWidth: board.selected == launcher.id ? 1.2 : 0.7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusEffectDisabled()
    }
}
