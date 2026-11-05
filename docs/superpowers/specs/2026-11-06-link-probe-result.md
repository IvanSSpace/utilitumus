# Проба связи: XPC через Mach-сервис launchd с самоподписанным сертификатом

**Вердикт: XPC.** Ни один из критериев провала не сработал: rogue не прошёл, наши соединились, ручного одобрения не потребовалось.

Две вещи работают не так, как ожидала спека, и влияют на следующие задачи: см. «Что учесть».

## Условия

- macOS 26.2 (25C56), arm64, Swift 6.2.3, цель сборки `arm64-apple-macos14.2`, `swiftc -O -parse-as-library`.
- Бинарники командной строки вне бандла, лежат во временной папке.
- Подпись: `codesign --force --options runtime --sign "Utilitumus Signing" --identifier <id>`. Team ID нет. Ad-hoc варианты: `--sign -`.
- Mach-сервис `local.utilitumus.test.probe.xpc`, метка `local.utilitumus.test.probe`, домен `gui/$UID`.
- Требование: `identifier "<id>" and certificate leaf = H"31e93f4b9e4ada7f6de82066c2194b35d92f7db4"`.

## Таблица из брифа

| Случай | Ожидание | Факт | Итог |
|---|---|---|---|
| `probe-hub` → `probe-sat` | ответ получен | `pong`, exit 0; сервис запущен launchd по подключению (`ppid=1`) | да |
| `probe-rogue` → `probe-sat` | отказ, `ping` не исполнен | клиент: `interruptionHandler`, ошибка 4097. У сервиса нет ни `ping`, ни вызова делегата | да |
| подмена: `probe-sat` с ad-hoc подписью | `probe-hub` отказывается | клиент: ошибка 4102, ответ не доставлен. **Но `ping` на подменённом сервисе исполнился** | да, с оговоркой |
| `launchctl print` после bootstrap | state не требует одобрения, подъём по подключению | до подключения `state = not running`, `runs = 0`; после `state = running`, `immediate reason = ipc (mach)` | да |
| запуск `probe-sat` напрямую | второго слушателя нет: регистрация падает, процесс выходит | второго слушателя нет, но **ошибки нет и процесс не выходит**: `resume()` проходит молча, процесс висит | наполовину |

## Дополнительные случаи

| Случай | Факт |
|---|---|
| сертификат наш, identifier чужой: клиент → `probe-sat` | как rogue: 4097, делегат и `ping` не вызваны |
| сертификат наш, identifier чужой: подменённый сервис, принимает всех | клиент: 4102 |
| ad-hoc сервис без требования на слушателе | клиент: 4102 |
| rogue подключается первым, сервис не запущен | launchd запускает сервис, сервис остаётся работать; делегат и `ping` не вызваны |
| прямой запуск, сервис загружен и работает | подключения получает процесс launchd, прямой не получает ничего |
| прямой запуск, сервис загружен, но не запущен | launchd запускает свой экземпляр и отдаёт подключение ему; прямой не получает ничего |
| прямой запуск, сервис выгружен | клиент: `invalidationHandler`, ошибка 4099; прямой не получает ничего |
| сервис убит `kill -9` | `state = not running`; следующее подключение поднимает новый процесс, `runs = 2` |
| страж `XPC_SERVICE_NAME` | напрямую: значение `0`, exit 3. Из launchd: значение равно метке, работает |
| подмена, три `ping` подряд и один через 2 с после отказа | клиент получил 4102 четыре раза; **подменённый сервис исполнил все четыре** |

## Что учесть

**1. Требование на клиенте защищает только ответы, исходящие сообщения уходят.** `NSXPCConnection.setCodeSigningRequirement` не мешает сообщению дойти до подменённого сервиса, и соединение после первого 4102 само не закрывается: следующее сообщение тоже доходит. Поэтому:

- первым вызовом центр делает рукопожатие без данных и шлёт что-либо ещё только после его ответа;
- при 4102 центр вызывает `invalidate()` и больше не отправляет по этому соединению.

Требование на слушателе работает строже: неподходящий клиент не доходит ни до делегата, ни до метода.

**2. Прямой запуск не падает сам.** Сбоя регистрации `NSXPCListener` не показывает, метода с таким сигналом нет. Утилита, которой нельзя работать вне launchd, должна проверять это сама, в начале `main`:

```swift
guard ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label else { exit(3) }
```

`ppid == 1` для этого не годится по задумке: приложения, открытые через Finder, тоже обычно дети launchd. Запуск `.app` через Finder проба не проверяла, и значение `XPC_SERVICE_NAME` у него не измерено; это решить в задаче про утилиту.

**3. Коды ошибок на стороне клиента.**

| Код | Константа | Когда |
|---|---|---|
| 4097 | `NSXPCConnectionInterrupted` | нас отверг слушатель; по документации этот же код приходит при падении сервиса (проба этого не воспроизводила) |
| 4099 | `NSXPCConnectionInvalid` | сервиса нет |
| 4102 | `NSXPCConnectionCodeSigningRequirementFailure` | сервис не прошёл наше требование |

**4. Запись в «Объектах входа» остаётся.** `launchctl bootstrap` создаёт запись BTM (`sfltool dumpbtm`, тип `legacy agent`). При чтении во время прогона: `[enabled, allowed, not notified]`; при чтении после прогона: `[enabled, allowed, notified]`. Интервал не замерялся. После `bootout` и удаления плиста запись `local.utilitumus.test.probe` осталась. Показалось ли уведомление на экране, из командной строки не наблюдается; флаг `notified` не доказывает, что его видел пользователь.

## Рабочий код

Слушатель, запуск только из launchd:

```swift
let listener = NSXPCListener(machServiceName: "local.utilitumus.test.probe.xpc")
listener.setConnectionCodeSigningRequirement(
    "identifier \"local.utilitumus.test.hub\" and certificate leaf = H\"<хэш>\"")
listener.delegate = delegate   // держать сильную ссылку
listener.resume()
dispatchMain()
```

Делегат: `exportedInterface`, `exportedObject`, затем `c.resume()` и `return true`.

Клиент:

```swift
let c = NSXPCConnection(machServiceName: "local.utilitumus.test.probe.xpc", options: [])
c.setCodeSigningRequirement(
    "identifier \"local.utilitumus.test.sat\" and certificate leaf = H\"<хэш>\"")
c.remoteObjectInterface = NSXPCInterface(with: ProbeProtocol.self)
c.resume()
let proxy = c.remoteObjectProxyWithErrorHandler { err in /* err as NSError: .code */ } as! ProbeProtocol
proxy.ping { reply in /* ответ */ }
```

Опция `.privileged` не нужна: сервис в домене пользователя. Оба метода требования собрались с целью 14.2 без `@available`.

Плист в `~/Library/LaunchAgents/<метка>.plist`, `KeepAlive` и `RunAtLoad` не заданы:

```xml
<key>Label</key><string>local.utilitumus.test.probe</string>
<key>ProgramArguments</key><array><string>/путь/к/probe-sat</string></array>
<key>MachServices</key><dict><key>local.utilitumus.test.probe.xpc</key><true/></dict>
```

`StandardOutPath` и `StandardErrorPath` использовались только для журнала пробы.

Команды: `launchctl bootstrap gui/$UID <плист>`, `launchctl bootout gui/$UID/<метка>`, `launchctl print gui/$UID/<метка>`.

## Что проба не проверила

- Запуск на macOS 14 и 15: только сборка с такой целью, запуск только на 26.2.
- Mac без сертификата в связке. Здесь «Utilitumus Signing» лежит в списке связок, настроек доверия к нему нет (`security dump-trust-settings` пуст). Требование с `certificate leaf` не просит доверия, и `Updater` уже проверяет им же подпись на чужих Mac, но через `codesign`, а не через XPC.
- Бандл `.app` в `/Applications/Utilitumus/`, запуск через Finder.
- Отключённая пользователем запись в «Объектах входа».
