import SwiftUI

private func rpm(_ v: Double) -> String { "\(Int(v.rounded())) об/мин" }
private func celsius(_ v: Double?) -> String { v.map { String(format: "%.0f °C", $0) } ?? "—" }

private struct FanRow: View {
    let fan: FanReading
    @Binding var config: FanConfig
    let enabled: Bool
    /// «Полная мощность» перебивает режим вентилятора — показываем это, а не
    /// «Оборотами управляет macOS», которое тогда было бы неправдой.
    let fullPower: Bool

    private var load: Double {
        guard fan.max > fan.min else { return 0 }
        return min(max((fan.actual - fan.min) / (fan.max - fan.min), 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "fan.fill")
                    .foregroundStyle(fan.isManual ? Color.accentColor : .secondary)
                Text("Вентилятор \(fan.index + 1)").font(.headline)
                if fan.isSpinningUp {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("раскручивается до \(rpm(fan.target))")
                    }
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.green.opacity(0.2), in: Capsule())
                } else if fan.isManual {
                    Text("вручную")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.2), in: Capsule())
                }
                Spacer()
                Text(rpm(fan.actual))
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }

            ProgressView(value: load)
            HStack {
                Text(rpm(fan.min))
                Spacer()
                Text(rpm(fan.max))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Picker("Режим", selection: $config.mode) {
                ForEach(FanMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(fullPower)
            .opacity(fullPower ? 0.5 : 1)

            if fullPower {
                Text("Сейчас на максимуме: включена «Полная мощность». Выключишь её — вернётся «\(config.mode.title)».")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                switch config.mode {
                case .auto:
                    Text("Оборотами управляет macOS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .constant:
                    HStack {
                        Slider(value: Binding(
                            get: { config.rpm == 0 ? fan.min : min(max(config.rpm, fan.min), fan.max) },
                            set: { config.rpm = $0 }
                        ), in: fan.min...fan.max, step: 100)
                        Text(rpm(config.rpm == 0 ? fan.min : config.rpm))
                            .monospacedDigit()
                            .frame(width: 100, alignment: .trailing)
                    }

                case .sensor:
                    Picker("Датчик", selection: $config.sensor) {
                        ForEach(SensorSource.allCases) { Text($0.title).tag($0) }
                    }
                    TempSlider(title: "Начинать разгон с", value: $config.fromTemp, range: 30...(config.toTemp - 5))
                    TempSlider(title: "Максимум при", value: $config.toTemp, range: (config.fromTemp + 5)...100)
                    Text("Ниже \(Int(config.fromTemp)) °C — минимум, от \(Int(config.toTemp)) °C — максимум, между ними плавно.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!enabled)
        .padding(.vertical, 4)
    }
}

private struct TempSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            Text(title).frame(width: 150, alignment: .leading)
            Slider(value: $value, in: range, step: 1)
            Text("\(Int(value)) °C").monospacedDigit().frame(width: 50, alignment: .trailing)
        }
    }
}

private struct SensorGroup: View {
    let title: String
    let sensors: [SensorReading]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], alignment: .leading, spacing: 6) {
                ForEach(sensors) { s in
                    HStack(spacing: 6) {
                        Text(s.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(celsius(s.value)).font(.caption).monospacedDigit()
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Text(title)
                Spacer()
                if !sensors.isEmpty {
                    let avg = sensors.map(\.value).reduce(0, +) / Double(sensors.count)
                    Text("средн. \(celsius(avg))").foregroundStyle(.secondary)
                    Text("макс. \(celsius(sensors.map(\.value).max()))").monospacedDigit().fontWeight(.semibold)
                } else {
                    Text("нет датчиков").foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Одна большая кнопка «всё на максимум» — перед игрой, без возни с режимами.
private struct FullPowerButton: View {
    @Binding var isOn: Bool
    let enabled: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 14) {
                // Включено — вентилятор крутится: оборот за 0.8 с. TimelineView,
                // а не repeatForever-анимация: та при выключении дёргается и не
                // останавливается чисто.
                TimelineView(.animation(paused: !isOn)) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8) / 0.8
                    Image(systemName: "fan.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .rotationEffect(.degrees(isOn ? turn * 360 : 0))
                }
                .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isOn ? "Полная мощность включена" : "Полная мощность")
                        .font(.title3.weight(.semibold))
                    Text(isOn ? "Нажми, чтобы вернуть обычный режим" : "Все вентиляторы на максимум")
                        .font(.callout)
                        .opacity(0.8)
                }
                Spacer()
            }
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(isOn ? Color.green : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// Экран модуля «Вентиляторы» — аналог Macs Fan Control.
struct FansView: View {
    @ObservedObject var controller = FanController.shared
    @ObservedObject var installer = FanHelperInstaller.shared

    private var canControl: Bool { installer.status != .notInstalled && controller.conflictingApp == nil }

    var body: some View {
        Form {
            if installer.status != .ready {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(installer.status == .outdated ? "Доступ нужно обновить" : "Нужен доступ к вентиляторам",
                              systemImage: "lock.shield")
                            .font(.headline)
                        Text(installer.status == .outdated
                             ? "Приложение обновилось, помощник для вентиляторов — ещё нет. macOS спросит пароль администратора один раз."
                             : "Смотреть обороты и температуру можно и так, а менять обороты macOS разрешает только администратору. Utilitumus поставит маленького помощника — macOS спросит пароль или Touch ID один раз.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(installer.status == .outdated ? "Обновить доступ…" : "Дать доступ…") {
                            installer.install()
                        }
                        .buttonStyle(.borderedProminent)
                        if let error = installer.lastError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if let app = controller.conflictingApp {
                Section {
                    HStack {
                        Label("\(app.localizedName ?? "Другая программа") сейчас управляет вентиляторами. Пока она открыта, Utilitumus не вмешивается.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Закрыть её") { app.terminate() }
                    }
                }
            }

            Section {
                FullPowerButton(isOn: $controller.fullPower, enabled: canControl)
            }

            if controller.safetyTripped && !controller.fullPower {
                Section {
                    Label("Процессор горячее \(Int(FanController.safetyTrip)) °C — вентиляторы отданы системе, пока не остынет ниже \(Int(FanController.safetyRelease)) °C.",
                          systemImage: "flame.fill")
                        .foregroundStyle(.red)
                }
            }

            Section("Вентиляторы") {
                if controller.fans.isEmpty {
                    Text("Вентиляторы не найдены").foregroundStyle(.secondary)
                }
                ForEach(controller.fans) { fan in
                    if fan.index < controller.configs.count {
                        FanRow(fan: fan, config: $controller.configs[fan.index], enabled: canControl,
                               fullPower: controller.fullPower)
                    }
                }
            }

            Section("Температура") {
                SensorGroup(title: "Процессор", sensors: controller.cpuSensors)
                SensorGroup(title: "Видеокарта", sensors: controller.gpuSensors)
            }

            Section {
                if let error = controller.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Text("При выходе из Utilitumus вентиляторы возвращаются в «Авто».")
                    Spacer()
                    if installer.status != .notInstalled {
                        Button("Забрать доступ…") { installer.uninstall() }
                            .buttonStyle(.link)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Вентиляторы")
        .navigationSubtitle(controller.cpuMax.map { "Процессор \(celsius($0))" } ?? "")
        .toolbar {
            ToolbarItem {
                Button {
                    controller.setAllAuto()
                } label: {
                    Label("Всё авто", systemImage: "arrow.uturn.backward")
                }
                .help("Вернуть все вентиляторы системе")
                .disabled(!canControl)
            }
        }
        .onAppear { installer.refresh() }
    }
}
