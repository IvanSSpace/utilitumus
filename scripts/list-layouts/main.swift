// Печатает включённые раскладки в том порядке, в каком их отдаёт система (как их берёт модуль «Клавиатура»).
// Запуск: swiftc -o /tmp/list-layouts scripts/list-layouts/main.swift Sources/Modules/Keyboard/InputSources.swift && /tmp/list-layouts
import Foundation

let current = InputSources.current()?.id
for (index, source) in InputSources.enabled().enumerated() {
    print("\(index + 1). \(source.name)  [\(source.id)]\(source.id == current ? "  <- сейчас" : "")")
}
print("Системное действие 🌐 (AppleFnUsageType):", FnSystemAction.usage.map(String.init) ?? "нет ключа")
print("Диктовка двойным Fn:", FnSystemAction.dictationOnDoubleFn)
