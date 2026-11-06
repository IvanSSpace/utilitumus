import Combine
import SwiftUI

// Утилита-проба: `SatelliteModule` с шагами, быстрыми действиями и журналом вызовов в файл из `Test.Journal`.
// Имя на связи из `probeName`: скрипт генерирует его, поэтому две пробы идут одновременно.

@MainActor
final class ProbeModule: SatelliteModule {
    let module = Module.sound
    let linkName = probeName
    private var current = ProbeState()
    private var granted = false
    private let subject = PassthroughSubject<Void, Never>()

    private func journal(_ line: String) {
        guard let path = Kit.defaults.string(forKey: "Test.Journal"), let file = fopen(path, "a") else { return }
        fputs(line + "\n", file)
        fclose(file)
    }

    private func change(_ edit: (inout ProbeState) -> Void) {
        subject.send()
        edit(&current)
    }

    func start() {
        journal("start")
        change { $0.running = true }
    }
    func stop() {
        journal("stop")
        change { $0.running = false }
    }
    func stopForUpdate() { journal("stopForUpdate") }
    func stopForUninstall() { journal("stopForUninstall") }
    func screenOpen(_ open: Bool) { journal("screen \(open)") }

    func statusLine(passiveReason: String?) -> String { passiveReason ?? current.line }
    var attention: Bool { current.attention }
    var quickActions: [LinkQuickAction] {
        [LinkQuickAction(title: "Поднять", icon: "arrow.up", action: LinkWire.encoded(ProbeAction.setLevel(42)))]
    }
    var setupSteps: [LinkSetupStep] {
        [LinkSetupStep(id: "grant", title: "Разрешение", why: "нужно", icon: "lock", done: granted),
         LinkSetupStep(id: "tip", title: "Совет", why: "можно", icon: "star", kind: .recommendation, required: false, done: false),
         LinkSetupStep(id: "broken", title: "Сломан", why: "можно", icon: "xmark", required: false, verifiable: false, done: false)]
    }
    func performSetupStep(_ id: String) -> String? {
        journal("step \(id)")
        if id == "grant" { granted = true }
        return id == "broken" ? "Не вышло" : nil
    }

    func state() -> Data { LinkWire.encoded(current) }
    func handle(_ data: Data) -> Data {
        LinkWire.handle(data, as: ProbeAction.self, limit: 1024, state: { current }) { action in
            change { $0.handled += 1 }
            switch action {
            case .setLevel(let level):
                guard level <= 100 else { return "Больше 100 нельзя" }
                change { $0.level = level }
            case .setLine(let line): change { $0.line = line }
            case .setAttention(let on): change { $0.attention = on }
            case .burst(let count): burst(count)
            case .setBlob(let bytes): change { $0.blob = String(repeating: "я", count: bytes / 2) }
            case .hang(let ms): Thread.sleep(forTimeInterval: Double(ms) / 1000)
            case .pair(let a, _): change { $0.level = a }
            }
            return nil
        }
    }
    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }
    func windowRoot() -> AnyView { AnyView(Text("проба")) }

    private func burst(_ left: Int) {
        guard left > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { [weak self] in
            MainActor.assumeIsolated {
                self?.change { $0.level += 1 }
                self?.burst(left - 1)
            }
        }
    }

    #if KIT_TEST_DEFAULTS
    func standCommand() { change { $0.level += 1 } }
    #endif
}
