import SwiftUI

/// Панель выбранной утилиты: мастер, задача, очередь, дело, действия. Всё, что умеет панель страницы Студии.
struct StudioDetailPanel<Model: StudioModel>: View {
    @ObservedObject var model: Model
    let unit: StudioUnit
    let board: StudioBoard
    let close: () -> Void

    @State private var draft = ""
    /// Смена мастера необратима: подтверждение показано в самой панели, не скрытым вторым нажатием.
    @State private var confirmRotate = false
    @Environment(\.dsTint) private var tint

    private var isHub: Bool { unit.kind == .orchestrator }
    private var busy: Bool { board.working.contains(unit.id) }
    private var detail: StudioDetail? { board.detail?.id == unit.id ? board.detail : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            masterBox
            taskBox
            queueBox
            caseBox
            if !isHub { actionsBox }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous).fill(.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: DS.groupRadius, style: .continuous).stroke(.white.opacity(0.07), lineWidth: 0.7))
        .onChange(of: unit.id) { draft = ""; lastSent = nil; confirmRotate = false }
        .onChange(of: board.notice) {
            guard lastSent != nil else { return }
            if board.notice?.isError == true { restoreDraft() } else { lastSent = nil }
        }
        .onChange(of: model.actionError) { if model.actionError != nil, lastSent != nil { restoreDraft() } }
    }

    // MARK: Части

    private var header: some View {
        HStack(spacing: 10) {
            if !isHub { StudioIcon(unit: unit, png: board.icons[unit.id], side: 34) }
            VStack(alignment: .leading, spacing: 2) {
                Text(isHub ? "Хаб · оркестратор" : unit.title).font(.system(size: 15, weight: .bold, design: .rounded))
                Text(isHub ? "hub-utilitumus · основная копия"
                           : "\(unit.id) · \(unit.released ? "v\(unit.version ?? "")" : "не выпущена")")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
            }
            if !isHub { StudioStatusPill(key: unit.statusKey) }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                    .frame(width: 24, height: 24).hoverFill(Circle(), normal: .clear, hovered: .white.opacity(0.1))
            }
            .buttonStyle(.plain).focusEffectDisabled().help("Закрыть панель").accessibilityLabel("Закрыть панель")
        }
    }

    private func box<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(DS.sectionTitle).tracking(0.8).foregroundStyle(.white.opacity(0.42))
            content()
        }
    }

    private var masterBox: some View {
        box("Мастер") {
            HStack(spacing: 7) {
                StudioMasterDot(state: unit.master)
                Text(unit.lastActive == nil ? unit.master.label : "\(unit.master.label) · \(StudioAgo.text(unit.lastActive))").font(.system(size: 12)).foregroundStyle(.white.opacity(0.78))
                Spacer(minLength: 6)
                Text(branchText).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            StudioContextBar(pct: unit.contextPct, height: 4)
            Text(contextText).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(unit.contextHot && !isHub ? Color(red: 1.0, green: 0.7, blue: 0.25) : .white.opacity(0.5))
            if let rotation = unit.rotation {
                Text("Смена мастера: \(rotation.message)").font(.system(size: 11.5))
                    .foregroundStyle(rotation.failed ? Color(red: 1.0, green: 0.7, blue: 0.25) : .white.opacity(0.6))
            }
            HStack(spacing: 8) {
                DSButton("Открыть сессию", style: .primary, small: true) { model.send(.openSession(unit.id)) }
                    .help(isHub ? "Терминал хаба в Orca" : "Терминал мастера в Orca; спит — поднимется с делом")
                if !isHub, !confirmRotate {
                    DSButton("Сменить мастера", small: true) { confirmRotate = true }
                        .disabled(unit.rotation?.running == true)
                        .help("Мастер запишет дело, терминал закроется, новый поднимется с делом")
                }
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(busy)
            if confirmRotate {
                HStack(spacing: 8) {
                    Text("Мастер запишет дело, терминал закроется, новый поднимется.").font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    DSButton("Сменить", small: true) { confirmRotate = false; model.send(.rotate(unit.id)) }
                    DSButton("Отмена", style: .plain, small: true) { confirmRotate = false }
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.06)))
            }
        }
    }

    private var branchText: String {
        guard let branch = unit.branch else { return "папки ещё нет" }
        return branch + ((unit.ahead ?? 0) > 0 ? " +\(unit.ahead ?? 0)" : "")
    }

    private var contextText: String {
        guard let pct = unit.contextPct else { return "контекст —" }
        return "контекст \(pct)%" + (unit.contextHot && !isHub ? " — пора сменить мастера" : "")
    }

    private var taskBox: some View {
        box(isHub ? "Дать задачу хабу" : "Дать задачу") {
            TextField("", text: $draft, prompt: Text(isHub ? "Например: «выпусти иконки общим выпуском»" : "Например: «превью скриншотов с Рабочего стола»"),
                      axis: .vertical)
                .textFieldStyle(.plain).lineLimit(2...5).font(.system(size: 12.5))
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.07)))
                .accessibilityLabel("Текст задачи")
            HStack(spacing: 8) {
                DSButton(isHub ? "Отправить хабу" : "Отправить мастеру", icon: "paperplane.fill", style: .primary, small: true) {
                    send(.task(unit: unit.id, text: draft))
                }
                if !isHub {
                    DSButton("Отдать хабу", small: true) { send(.handToHub(unit: unit.id, text: draft)) }
                        .help("Задача касается общего: уйдёт хабу с пометкой утилиты")
                }
            }
            .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// Поле очищается сразу, чтобы задача не ушла дважды. Отказ (на месте или от сервера) возвращает текст.
    private func send(_ action: StudioAction) {
        lastSent = draft
        draft = ""
        model.send(action)
    }

    @State private var lastSent: String?

    private func restoreDraft() {
        if draft.isEmpty, let lastSent { draft = lastSent }
        lastSent = nil
    }

    private var queueBox: some View {
        let items = detail?.queue ?? []
        let open = items.filter { !$0.done }
        let done = Array(items.filter(\.done).suffix(5))
        return box("Очередь · \(unit.openTasks)") {
            if open.isEmpty && done.isEmpty {
                Text(detail == nil ? "Загружаю…" : "Пусто: утилита в покое").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(open.enumerated()), id: \.offset) { _, item in queueRow(item) }
                    ForEach(Array(done.enumerated()), id: \.offset) { _, item in queueRow(item) }
                }
            }
        }
    }

    private func queueRow(_ item: StudioQueueItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: item.done ? "checkmark.circle.fill" : "circle").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            Text(item.text).font(.system(size: 12)).foregroundStyle(.white.opacity(item.done ? 0.38 : 0.8)).strikethrough(item.done)
                .lineLimit(3)
        }
    }

    private var caseBox: some View {
        box("Дело") {
            if let detail {
                ScrollView { StudioCaseView(text: detail.caseText) }
                    .frame(maxHeight: 220)
                if !detail.casePath.isEmpty {
                    Text(detail.casePath).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text("Загружаю…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private var actionsBox: some View {
        box("Действия") {
            HStack(spacing: 8) {
                DSButton("Стенд", icon: "hammer", small: true) { model.send(.stand(unit.id)) }
                    .help(unit.kind == .launcher ? "scripts/dev.sh --hub" : "scripts/dev.sh \(unit.id)")
                DSButton("Выпустить патч", icon: "shippingbox", small: true) { model.send(.release(unit.id)) }
                    .help("Просьба уйдёт мастеру, он сверит проверки и передаст хабу")
            }
            .disabled(busy)
        }
    }
}
