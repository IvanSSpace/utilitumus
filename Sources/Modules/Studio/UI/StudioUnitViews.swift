import AppKit
import SwiftUI

// Мелкие части экрана «Студия»: значок, точка мастера, полоска контекста, пилюля статуса, карточка утилиты.

extension StudioStatusKey {
    var color: Color {
        switch self {
        case .work: return Color(red: 0.36, green: 0.66, blue: 1.0)
        case .ready: return Color(red: 0.35, green: 0.84, blue: 0.5)
        case .stable: return .white.opacity(0.55)
        case .bug: return Color(red: 1.0, green: 0.42, blue: 0.38)
        case .dev: return Color(red: 0.74, green: 0.55, blue: 1.0)
        }
    }
}

extension StudioMasterState {
    var color: Color {
        switch self {
        case .working: return Color(red: 0.35, green: 0.84, blue: 0.5)
        case .waiting: return Color(red: 1.0, green: 0.7, blue: 0.25)
        case .idle: return Color(red: 0.4, green: 0.72, blue: 1.0)
        case .asleep, .none: return .white.opacity(0.28)
        }
    }
}

extension Color {
    /// `#RRGGBB` с провода; всё остальное — серый.
    init(studioHex hex: String) {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else {
            self = Color(white: 0.55)
            return
        }
        self = Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

/// Значок утилиты: PNG с провода или буква на плашке её цвета.
struct StudioIcon: View {
    let unit: StudioUnit
    let png: Data?
    var side: CGFloat = 36

    var body: some View {
        Group {
            if let png, let image = NSImage(data: png) {
                // Значок приложения и так скруглён, а квадратная картинка без скругления выбивалась бы из сетки.
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: side * 0.27, style: .continuous).fill(Color(studioHex: unit.tint))
                    .overlay(Text(String(unit.title.prefix(1))).font(.system(size: side * 0.46, weight: .bold, design: .rounded))
                        .foregroundStyle(.white))
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// Точка состояния мастера; у «нет» — кольцо.
struct StudioMasterDot: View {
    let state: StudioMasterState
    var size: CGFloat = 8

    var body: some View {
        Group {
            if state == .none {
                Circle().stroke(state.color, lineWidth: 1.2)
            } else {
                Circle().fill(state.color)
            }
        }
        .frame(width: size, height: size)
        .help(state.label)
        .accessibilityLabel(state.label)
    }
}

/// Контекст мастера, тонкая полоска; от 60% красная.
struct StudioContextBar: View {
    let pct: Int?
    var height: CGFloat = 3

    var body: some View {
        let value = min(max(pct ?? 0, 0), 100)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule().fill(value >= 60 ? Color(red: 1.0, green: 0.42, blue: 0.38) : .white.opacity(0.5))
                    .frame(width: geo.size.width * CGFloat(value) / 100)
            }
        }
        .frame(height: height)
        .help(pct.map { "контекст мастера \($0)%" } ?? "контекст неизвестен")
        .accessibilityHidden(true)
    }
}

struct StudioStatusPill: View {
    let key: StudioStatusKey
    var body: some View { DSChip(key.label, color: key.color) }
}

/// Карточка утилиты в сетке. Нажатие выбирает её; выбранная подсвечена.
struct StudioUnitCard: View {
    let unit: StudioUnit
    let png: Data?
    let selected: Bool
    let busy: Bool
    let select: () -> Void
    @Environment(\.dsTint) private var tint

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top) {
                    StudioIcon(unit: unit, png: png, side: 34)
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 5) {
                        HStack(spacing: 5) {
                            if busy { ProgressView().controlSize(.mini).scaleEffect(0.8) }
                            if unit.openTasks > 0 {
                                Text("\(unit.openTasks)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.black.opacity(0.8))
                                    .padding(.horizontal, 6).padding(.vertical, 1.5).background(Capsule().fill(tint))
                                    .help("открытые задачи")
                            }
                        }
                        StudioMasterDot(state: unit.master)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(unit.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.95)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                HStack(spacing: 6) {
                    StudioStatusPill(key: unit.statusKey)
                    Spacer(minLength: 0)
                }
                StudioContextBar(pct: unit.contextPct)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.rowRadius + 3, style: .continuous)
                .fill(selected ? tint.opacity(0.2) : .white.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: DS.rowRadius + 3, style: .continuous)
                .stroke(selected ? tint.opacity(0.8) : .white.opacity(0.07), lineWidth: selected ? 1.2 : 0.7))
            .contentShape(RoundedRectangle(cornerRadius: DS.rowRadius + 3, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(unit.title), \(unit.statusKey.label), \(unit.master.label)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var subtitle: String {
        let version = unit.released ? "v\(unit.version ?? "")" : "не выпущена"
        return unit.lastActive == nil ? version : "\(version) · \(StudioAgo.text(unit.lastActive))"
    }
}
