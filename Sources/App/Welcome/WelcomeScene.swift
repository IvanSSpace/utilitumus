import SwiftUI

// Приветствие при первом запуске (и после обновления с версии, где его ещё не было).
// Полноэкранная сцена поверх главного окна: тёмный переливающийся градиент в цветах трёх категорий,
// три шага, в конце — переход в Стор. Показывается один раз.

enum Welcome {
    /// Флаг «приветствие показано». Старые версии его не пишут, поэтому после обновления оно показывается
    /// и тем, кто уже пользуется; новая установка тоже без флага.
    static let seenKey = "Welcome.Seen.v1"

    static var isSeen: Bool { UserDefaults.standard.bool(forKey: seenKey) }
    static func markSeen() { UserDefaults.standard.set(true, forKey: seenKey) }
    /// «Посмотреть приветствие» из «О проекте»: показать ещё раз, без перехода в Стор.
    static let replay = Notification.Name("Welcome.replay")

    /// Цвета категорий на тёмном фоне: насыщеннее, чем в боковой панели.
    static func tint(_ category: ModuleCategory) -> Color {
        Color(hue: category.hue, saturation: 0.62, brightness: 0.92)
    }
}

// MARK: - Сцена

struct WelcomeScene: View {
    /// Вызывается и по «Открыть Стор», и по «Пропустить».
    let finish: () -> Void
    @State private var step: Int
    private let last = 2

    init(step: Int = 0, finish: @escaping () -> Void) {
        _step = State(initialValue: step)
        self.finish = finish
    }

    var body: some View {
        ZStack {
            WelcomeBackdrop()
            ZStack {
                switch step {
                case 0: WelcomeIntroStep()
                case 1: WelcomeCategoriesStep()
                default: WelcomePrivacyStep()
                }
            }
            .id(step)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 14)),
                                    removal: .opacity.combined(with: .offset(y: -14))))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 70)
        }
        .overlay(alignment: .bottom) { controls }
        .overlay(alignment: .topTrailing) {
            Button("Пропустить", action: finish)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.top, 14).padding(.trailing, 22)
                .focusEffectDisabled()
        }
        .animation(.easeInOut(duration: 0.35), value: step)
        .preferredColorScheme(.dark)
        // Сцена закрывает окно целиком: клики не должны доходить до панели под ней.
        .contentShape(Rectangle())
    }

    private var controls: some View {
        VStack(spacing: 18) {
            HStack(spacing: 7) {
                ForEach(0...last, id: \.self) { index in
                    Capsule().fill(.white.opacity(index == step ? 0.9 : 0.25))
                        .frame(width: index == step ? 22 : 6, height: 6)
                }
            }
            Button {
                if step < last { step += 1 } else { finish() }
            } label: {
                HStack(spacing: 7) {
                    Text(step < last ? "Дальше" : "Открыть Стор").font(.system(size: 14.5, weight: .semibold))
                    Image(systemName: step < last ? "arrow.right" : "bag.fill").font(.system(size: 12.5, weight: .bold))
                }
                .foregroundStyle(.black.opacity(0.85))
                .padding(.horizontal, 26).frame(height: 42)
                .background(Capsule().fill(.white.opacity(0.94)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .focusEffectDisabled()
        }
        .padding(.bottom, 34)
    }
}

// MARK: - Фон

/// Тёмная основа и три больших цветных пятна — по цвету на категорию, — медленно плывущих по кругу.
/// Перерисовка раз в 0,1 с: пятна движутся плавно за счёт малой скорости, а нагрузка почти нулевая.
/// Пока сцена в дереве, идёт только эта таймерная отрисовка; после ухода сцены её нет вовсе.
private struct WelcomeBackdrop: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.02)))
                let radius = max(size.width, size.height) * 0.5
                for (index, category) in ModuleCategory.all.enumerated() {
                    // У каждого пятна свой период (≈ 40–60 с) и фаза, чтобы они не двигались в такт.
                    let phase = Double(index) * 2.1
                    let angle = t / (7.0 + Double(index) * 1.7) * 0.55 + phase
                    let cx = size.width * (0.5 + 0.34 * cos(angle) * (index == 1 ? -1 : 1))
                    let cy = size.height * (0.5 + 0.30 * sin(angle * 0.8 + phase))
                    let color = Welcome.tint(category)
                    context.fill(
                        Path(ellipseIn: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)),
                        with: .radialGradient(Gradient(colors: [color.opacity(0.25), color.opacity(0)]),
                                              center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: radius))
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Шаг 1: имя

private struct WelcomeIntroStep: View {
    private let title = Array("Utilitumus")
    @State private var shown = false
    @State private var subtitleShown = false

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 0) {
                ForEach(Array(title.enumerated()), id: \.offset) { index, letter in
                    Text(String(letter))
                        .font(.system(size: 84, weight: .bold, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.72)],
                                                        startPoint: .top, endPoint: .bottom))
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown ? 0 : 16)
                        .blur(radius: shown ? 0 : 8)
                        .animation(.easeOut(duration: 0.6).delay(0.15 + Double(index) * 0.05), value: shown)
                }
            }
            Text("Одно приложение вместо россыпи утилит")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .opacity(subtitleShown ? 1 : 0)
                .offset(y: subtitleShown ? 0 : 8)
                .animation(.easeOut(duration: 0.6), value: subtitleShown)
        }
        .onAppear {
            shown = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { subtitleShown = true }
        }
    }
}

// MARK: - Шаг 2: категории

private struct WelcomeCategoriesStep: View {
    @State private var shown = false

    private static let lines: [String: String] = [
        "background": "Настроил и забыл",
        "handy": "Каждый день",
        "ai": "Когда агенты съедают память",
    ]

    var body: some View {
        VStack(spacing: 30) {
            VStack(spacing: 10) {
                Text("Ставь только нужное")
                    .font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text("Модули лежат в Сторе. Что поставил, то и появится в панели")
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.65))
            }
            HStack(spacing: 14) {
                ForEach(Array(ModuleCategory.all.enumerated()), id: \.element.id) { index, category in
                    card(category)
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown ? 0 : 14)
                        .animation(.easeOut(duration: 0.4).delay(0.12 + Double(index) * 0.1), value: shown)
                }
            }
            HStack(spacing: 7) {
                Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold))
                Text("Категории остались в Сторе, в панели модули идут общим списком")
                    .font(.system(size: 13))
            }
            .foregroundStyle(.white.opacity(0.5))
            .opacity(shown ? 1 : 0)
            .animation(.easeOut(duration: 0.4).delay(0.5), value: shown)
        }
        .onAppear { shown = true }
    }

    private func card(_ category: ModuleCategory) -> some View {
        let tint = Welcome.tint(category)
        return VStack(spacing: 14) {
            Image(systemName: category.icon)
                .font(.system(size: 26, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 60, height: 60)
                .background(Circle().fill(tint.opacity(0.18)))
            Text(category.title).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Text(Self.lines[category.id] ?? category.subtitle)
                .font(.system(size: 14)).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 24)
        .frame(width: 210, height: 200, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(tint.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(tint.opacity(0.4), lineWidth: 0.8))
        )
    }
}

// MARK: - Шаг 3: безопасность

private struct WelcomePrivacyStep: View {
    @State private var shown = false

    private let points: [(icon: String, title: String, text: String)] = [
        ("checkmark.seal.fill", "Обновления подписаны",
         "Подпись каждого обновления проверяется до установки"),
        ("hand.raised.fill", "Разрешения видно до установки",
         "Модуль заранее говорит, что ему понадобится и зачем"),
        ("lock.shield.fill", "Ничего не уходит в сеть",
         "Кроме проверки обновлений и скачивания моделей"),
    ]

    var body: some View {
        VStack(spacing: 32) {
            Text("Всё остаётся на твоём Mac")
                .font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(.white)
            VStack(spacing: 10) {
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    HStack(spacing: 16) {
                        Image(systemName: point.icon)
                            .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                            .frame(width: 46, height: 46)
                            .background(Circle().fill(.white.opacity(0.1)))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(point.title).font(.system(size: 16.5, weight: .semibold)).foregroundStyle(.white)
                            Text(point.text).font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.65))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    .frame(width: 520)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.07))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.1), lineWidth: 0.7)))
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 12)
                    .animation(.easeOut(duration: 0.4).delay(0.1 + Double(index) * 0.1), value: shown)
                }
            }
        }
        .onAppear { shown = true }
    }
}
