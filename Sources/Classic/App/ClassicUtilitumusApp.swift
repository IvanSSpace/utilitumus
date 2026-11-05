import SwiftUI
import AppKit

/// Белый значок на цветной скруглённой плашке — один вид везде, где показан модуль.
struct ClassicModuleIconBadge: View {
    let module: Module
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(module.tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: module.icon)
                    .font(.system(size: size * 0.55, weight: .medium))
                    .foregroundStyle(.white)
            }
    }
}

struct ClassicModuleDetail: View {
    let module: Module

    var body: some View {
        ClassicModuleScreen(module: module) {
            switch module {
            case .sound: ClassicSoundView()
            case .fans: ClassicFansView()
            case .load: ClassicLoadScreen()
            case .stash: ClassicStashView()
            case .mixer: ClassicMixerView()
            case .mouse: ClassicMouseView()
            case .browser: ClassicBrowserView()
            case .voice: ClassicVoiceView()
            case .clipboard: ClassicClipboardView()
            case .keyboard: ClassicKeyboardView()
            case .awake: ClassicAwakeView()
            }
        }
        // Свой экран на каждый модуль: состояние (лист «Об инструменте») не переезжает между ними.
        .id(module)
    }
}

struct ClassicMainView: View {
    @AppStorage("SelectedModule") private var selection: Module = .sound
    @ObservedObject private var modules = ModuleManager.shared
    @ObservedObject private var whatsNew = WhatsNew.shared
    /// «О проекте» — не модуль, поэтому отдельный флаг; не сохраняем, окно открывается на модуле.
    @State private var showAbout = false
    /// Скрытый модуль, открытый со страницы «О проекте»: показываем один раз,
    /// состояние не меняем, в панели его по-прежнему нет.
    @State private var peeked: Module?
    /// Модуль, чей экран сейчас построен. Догоняет `displayed` следующим кадром: так выделение
    /// в боковой панели переключается сразу, а не ждёт 100–200 мс, пока соберётся экран модуля.
    @State private var built: Module?

    var body: some View {
        // Выбранный модуль могли скрыть или выключить: показываем первый из показанных.
        let current = modules.resolve(selection)
        let displayed = peeked ?? current
        let detail = displayed == nil ? nil : (built ?? displayed)
        NavigationSplitView {
            List(selection: Binding(
                // На странице «О проекте» и при разовом показе скрытого выделение снято.
                get: { showAbout || peeked != nil ? nil : current },
                set: { if let new = $0 { selection = new; peeked = nil; showAbout = false } }
            )) {
                ForEach(modules.shownModules) { module in
                    let on = modules.isOn(module)
                    Label {
                        Text(module.title)
                    } icon: {
                        ClassicModuleIconBadge(module: module, size: 20)
                            .opacity(on ? 1 : 0.4)
                    }
                        .foregroundStyle(on ? .primary : .secondary)
                        .help(on ? "" : "Выключен — открой, чтобы включить")
                        .tag(module)
                        .contextMenu {
                            Button(on ? "Выключить модуль" : "Включить модуль") { modules.setOn(module, !on) }
                            Button("Скрыть из панели") { modules.setHidden(module, true) }
                            Divider()
                            Button("Настроить модули…") { modules.settingsShown = true }
                        }
                }
                .onMove { modules.moveShown(from: $0, to: $1) }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { ClassicUpdateFooter(showAbout: $showAbout, peeked: $peeked) }
        } detail: {
            if showAbout {
                ClassicAboutView { module in
                    if !modules.isHidden(module) {
                        selection = module
                        peeked = nil
                    } else {
                        peeked = module
                    }
                    showAbout = false
                }
            } else if let detail {
                ClassicModuleDetail(module: detail)
                    .toolbar { ClassicModuleToolbar(module: detail, modules: modules) }
            } else {
                ClassicNoShownModules()
            }
        }
        .sheet(item: $modules.infoModule) { ModuleInfoSheet(module: $0) }
        .sheet(isPresented: $whatsNew.isShown) { WhatsNewSheet() }
        // Настройки модулей — лист поверх окна, а не отдельное окно: настроил, закрыл и сразу в приложении.
        .sheet(isPresented: $modules.settingsShown) { ClassicSettingsView() }
        .onAppear { whatsNew.showIfUpdated() }
        .onChange(of: displayed) {
            DispatchQueue.main.async { built = displayed }
        }
        // Минимальный размер — окну, а не рамкой на корне: рамка заставляет NSHostingView перемерять всё дерево.
        .background(WindowMinSize(width: 680, height: 460))
        .onChange(of: modules.hidden) {
            if let resolved = modules.resolve(selection), resolved != selection { selection = resolved }
            // Разовый показ имеет смысл только пока модуль скрыт: вернули в панель — сбрасываем.
            if let peeked, !modules.isHidden(peeked) { self.peeked = nil }
        }
    }
}

/// В панели нет ни одного модуля: подсказка и быстрый переход в настройки.
struct ClassicNoShownModules: View {
    var body: some View {
        ContentUnavailableView {
            Label("Панель пуста", systemImage: "square.grid.2x2")
        } description: {
            Text("Нет модулей в панели — верни нужные в Настройках")
        } actions: {
            Button("Открыть настройки") { ModuleManager.shared.settingsShown = true }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Внизу боковой панели: скрытые модули, «О проекте», версия и, если вышла новая, кнопка установки.
struct ClassicUpdateFooter: View {
    @ObservedObject var updater = Updater.shared
    @ObservedObject private var modules = ModuleManager.shared
    @Binding var showAbout: Bool
    @Binding var peeked: Module?
    /// Свёрнутость списка помним между запусками: скрытые открывают редко, но привычка остаётся.
    @AppStorage("HiddenModulesExpanded") private var hiddenExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch updater.state {
            case let .available(version, _, _):
                Button {
                    updater.install()
                } label: {
                    Label("Обновить до \(version)", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            case .installing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Устанавливаю…").font(.caption)
                }
            case .failed(let message):
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            case .upToDate:
                Text("Обновлений нет")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
            hiddenSection
            Button {
                WhatsNew.shared.isShown = true
            } label: {
                Label("Что нового", systemImage: "sparkles")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.primary)
            // Порядок, скрытие и выключение модулей — в Настройках; без этой строки туда попадали только через Cmd+, или контекстное меню.
            Button {
                modules.settingsShown = true
            } label: {
                Label("Настроить модули", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.primary)
            Button {
                showAbout = true
            } label: {
                Label("О проекте", systemImage: "info.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(showAbout ? Color.accentColor : .primary)
            HStack {
                // Клик по версии — «Обновление стороннего программного обеспечения»: что нового.
                Button("Версия \(updater.currentVersion)") { WhatsNew.shared.isShown = true }
                    .buttonStyle(.plain)
                    .help("Что изменилось в последних версиях")
                Spacer()
                Button {
                    updater.check()
                } label: {
                    if updater.state == .checking {
                        ProgressView().controlSize(.mini)
                    } else if updater.state == .upToDate {
                        Image(systemName: "checkmark")
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.borderless)
                .help(updater.state == .upToDate ? "Установлена последняя версия" : "Проверить обновления")
                .disabled(updater.state == .checking || updater.state == .installing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

extension ClassicUpdateFooter {
    /// «Скрытые · N» над «О проекте»: без скрытых модулей строки нет совсем.
    @ViewBuilder
    var hiddenSection: some View {
        let hidden = modules.hiddenModules
        if !hidden.isEmpty {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { hiddenExpanded.toggle() }
            } label: {
                HStack(spacing: 0) {
                    Label("Скрытые · \(hidden.count)", systemImage: "eye.slash")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(hiddenExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)

            if hiddenExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(hidden) { module in
                        Button {
                            // Разовый показ: состояние не меняем, выделение в основном списке снимается через peeked.
                            peeked = module
                            showAbout = false
                        } label: {
                            HStack(spacing: 8) {
                                ClassicModuleIconBadge(module: module, size: 18)
                                    .opacity(0.6)
                                Text(module.title)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(peeked == module && !showAbout ? Color.accentColor : .secondary)
                        .contextMenu {
                            Button("Показать в панели") { modules.setHidden(module, false) }
                            Button(modules.isOn(module) ? "Выключить модуль" : "Включить модуль") {
                                modules.setOn(module, !modules.isOn(module))
                            }
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
    }
}
