# Командный центр и первая отдельная утилита: план

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Utilitumus ставит, обновляет и показывает отдельное приложение «Не спать»; утилита работает и без центра, связь узкая и с проверкой подписи.

**Architecture:** Общий код уходит в `Sources/Kit` и компилируется исходниками в каждый бинарник. Утилита — `Sources/Apps/<X>` + `Sources/Modules/<X>` + `Sources/Kit`. Центр и утилита говорят по XPC через Mach-сервис launchd с проверкой подписи с обеих сторон.

**Tech Stack:** Swift (режим Swift 5, `swiftc` напрямую из `build.sh`), SwiftUI/AppKit, NSXPC, launchd, `codesign`, `ditto`, `gh`.

**Spec:** `docs/superpowers/specs/2026-11-06-hub-and-satellites-design.md`

**Объём:** этапы 0–3 спеки. Этап 4 (остальные модули) — отдельные планы по одному модулю, после проверки пилота автором.

## Global Constraints

- Минимальная система — как в `Info.plist` сейчас (`LSMinimumSystemVersion` 14.2), цель сборки как в `build.sh`.
- Hardened runtime и подпись сертификатом «Utilitumus Signing» у всего, что выходит из `build.sh`; без dylib/framework и без `disable-library-validation`.
- Идентификаторы: центр `local.utilitumus`; утилита `local.utilitumus.app.<id>`; Mach-сервис `local.utilitumus.app.<id>.xpc`; LaunchAgent label = bundle id утилиты; путь `/Applications/Utilitumus/<Имя>.app`.
- Требование подписи — точный identifier и `certificate leaf = H"<хэш из trustedLeafHashes>"`; префиксов нет.
- Домен настроек один: `local.utilitumus`. В центре `.standard`, в утилите suite. Ключи модуля не переименовывать.
- Комментарии и тексты интерфейса на русском; интерфейс говорит «модули», не «утилиты» внутри центра.
- Коммиты только `Ivan MacOS <oldrum75@gmail.com>`, в git-сообщениях без строк атрибуции. git вызывать как `/usr/bin/git` (обычный `git` переписывается хуком rtk).
- Перед коммитом: нет личного (пути `/Users`, почты, MAC-адреса, имена устройств). Репозиторий публичный.
- Агентам нельзя: открывать видимые окна; трогать `/Applications/Utilitumus.app`, `/Applications/Utilitumus/` и настройки `local.utilitumus` этого Mac; запускать `release.sh`/`release-app.sh` без `--dry-run`; пушить. Проверка вида — окно за экраном (`x: -10000`) + `cacheDisplay` → PNG; такие стенды запускать только из папки стенда со своим именем бинарника (другой домен настроек).
- launchd в тестах: метки только `local.utilitumus.test.*` (кроме Task 8), каждая снимается `launchctl bootout` даже при падении теста (`trap`). Плисты тестов — только с этими метками.

## Review Focus

- Нет сети или каталог битый при запуске центра: Стор показывает все встроенные модули, «＋» ставит их как раньше (тест в Task 7).
- Бандл утилиты удалён руками в Finder: центр не держит встроенный модуль выключенным, снимает мёртвый LaunchAgent, строка возвращается к встроенному (тест в Task 7).
- Утилита зависла или упала: вызов укладывается в таймаут 2 с, главный поток не блокируется, в центре «не отвечает» (тест в Task 3).
- Обновление с 0.5.3 с включённым `ModuleOn.awake`: сброс модулей не повторяется, настройки целы, assertion не удваивается (тест в Task 6).
- Центр вышел или обновился при работающей утилите: утилита продолжает работу, центр после запуска подключается снова (тест в Task 8).

---

### Task 1: Проба связи (этап 0)

Выкидной код в папке вне репозитория; в репозиторий идёт только отчёт.

**Files:**
- Create: `docs/superpowers/specs/2026-11-06-link-probe-result.md`

**Interfaces:**
- Produces: вердикт `XPC` или `SOCKET`. При `SOCKET` менеджер правит Task 3 до его запуска.

- [ ] **Step 1: Собрать три бинарника, подписанных с hardened runtime**

`probe-sat` — `NSXPCListener(machServiceName: "local.utilitumus.test.probe.xpc")` + `setConnectionCodeSigningRequirement` (identifier `local.utilitumus.test.hub`, leaf-хэш); запуск только launchd. `probe-hub` — клиент с `setCodeSigningRequirement` (identifier `local.utilitumus.test.sat`, leaf-хэш), вызывает `ping`. `probe-rogue` — тот же клиент, identifier `local.utilitumus.test.hub`, но подпись ad-hoc. Подпись — как в `build.sh` (связка `~/Library/Keychains/utilitumus-signing.keychain-db`, разблокировка паролем из `~/.config/utilitumus/keychain-password`).

- [ ] **Step 2: Плист в `~/Library/LaunchAgents`, `launchctl bootstrap gui/$UID`, `trap` на `bootout` и удаление**

- [ ] **Step 3: Прогнать таблицу и записать фактические результаты**

| Случай | Ожидание |
|---|---|
| `probe-hub` → `probe-sat` | ответ получен |
| `probe-rogue` → `probe-sat` | отказ, `ping` не исполнен |
| сервис подменён: `probe-sat` с ad-hoc подписью | `probe-hub` отказывается |
| `launchctl print gui/$UID/<label>` после bootstrap | state не требует одобрения, сервис поднимается по подключению |
| запуск `probe-sat` напрямую, не из launchd | второго слушателя нет: регистрация падает, процесс выходит |

- [ ] **Step 4: Записать отчёт: версия macOS, таблица, вердикт. Провал по спеке — любое из: rogue прошёл; наши не соединились; нужно ручное одобрение**

- [ ] **Step 5: Убедиться, что `launchctl list | grep local.utilitumus.test` пуст и плиста нет; закоммитить отчёт**

---

### Task 2: `Sources/Kit` без зависимости от центра

Поведение центра не меняется.

**Files:**
- Create: `Sources/Kit/KitDefaults.swift`, `Sources/Kit/KitSigning.swift`, `Sources/Kit/ModuleControls.swift`, `Tests/run-kit-boundary-check.sh`
- Move в `Sources/Kit/`: `Sources/App/Design/{Theme,Components,ScrollThumb,ThemePreview}.swift`, `Sources/App/SegmentedControl.swift`, `Sources/App/ModuleCategory.swift`, `Sources/App/ModuleInfo.swift`, объявление `enum Module` из `Sources/App/UtilitumusApp.swift` (в `Sources/Kit/Module.swift`)
- Modify: `Sources/App/Updater.swift`, `Sources/Modules/Voice/VoiceEngine.swift:83`, `Sources/Modules/Fans/FanHelperInstaller.swift:86-87`, `build.sh` (и его `find` для хелпера ссылок)

Если для компиляции Kit файл из списка тянет что-то ещё, переместить только данные и чистые типы; никакой логики центра.

**Interfaces:**
- Produces:
  - `enum Kit { static let hubBundleID = "local.utilitumus"; static let defaults: UserDefaults }` — `.standard`, если `Bundle.main.bundleIdentifier == hubBundleID`, иначе `UserDefaults(suiteName: hubBundleID)!`.
  - `enum KitSigning { static let trustedLeafHashes: [String]; static func requirement(identifier: String, leafHash: String) -> String; static func verifySignature(of: URL, identifier: String, strict: Bool) throws }` — перенос из `Updater`. У `Updater` остаются переадресующие `static`, если так меньше правок.
  - `EnvironmentValues.moduleControls: (Module) -> AnyView` — `DSPageHeader` рисует его результат вместо прямого `DSModuleControls`. По умолчанию `EmptyView`.
  - `DSModuleControls` остаётся в центре (`Sources/App/ModuleControlsHub.swift`), центр ставит окружение в корне своего окна.

- [ ] **Step 1: Снять эталон**

Стенд за экраном: `AwakeView`, `StoreView`, страница «Настройки», «Фоном»-страница `MixerView`, тема `dusk`. PNG сохранить вне репозитория как эталон.

- [ ] **Step 2: Написать `Tests/run-kit-boundary-check.sh`**

Проверки: `swiftc -typecheck -parse-as-library -target <как в build.sh> $(find Sources/Kit -name '*.swift') -framework SwiftUI -framework AppKit` завершается с 0; `grep -rE '\b(ModuleManager|StoreModel|SetupFlow|Updater|AccessState|[A-Z][a-z]+Controller)\b' Sources/Kit` пусто.

- [ ] **Step 3: Запустить, увидеть провал (`Sources/Kit` нет)**

- [ ] **Step 4: Перенести файлы и развязать; в `build.sh` основной `find` исключает `Sources/Apps/*`**

`module.info`, цвета и значки остаются чистыми данными. Если `ModuleInfo` ссылается на типы центра, эти поля уходят в `extension` в `Sources/App`.

- [ ] **Step 5: Запустить проверку границы — проходит; `Tests/run-module-reset-check.sh`, `run-fan-gate-check.sh`, `run-clipboard-check.sh`, `scripts/test-app-layout.sh` проходят**

- [ ] **Step 6: `BUILD_DIR=<scratch> NO_INSTALL=1 ./build.sh` без ошибок; снять те же PNG, сравнить с эталоном — без отличий**

- [ ] **Step 7: Commit** `Общий код вынесен в Sources/Kit`

---

### Task 3: Протокол связи

**Files:**
- Create: `Sources/Kit/Link/LinkProtocol.swift`, `Sources/Kit/Link/LinkServer.swift`, `Sources/Kit/Link/LinkClient.swift`, `Tests/LinkCheck.swift`, `Tests/run-link-check.sh`

**Interfaces:**
- Consumes: `KitSigning.requirement`, `Kit.hubBundleID`; вердикт Task 1.
- Produces:
  - `enum KitLink { static let protocolVersion = 1; static func bundleID(_ id: String) -> String; static func machService(_ id: String) -> String; static func statusChanged(_ id: String) -> Notification.Name }`
  - `struct LinkHello: Codable, Equatable { id: String; version: String; protocolVersion: Int }`
  - `struct LinkStatus: Codable, Equatable { enabled: Bool; line: String; needsSetup: Int }` — `init` обрезает `line` до 80 символов, декодирование тоже.
  - `@objc protocol LinkXPC { hello(reply: (Data) -> Void); status(reply: (Data) -> Void); setEnabled(_: Bool, reply: () -> Void); openWindow(reply: () -> Void); quit(reply: () -> Void) }`
  - `@MainActor protocol LinkHandler: AnyObject { func linkHello() -> LinkHello; func linkStatus() -> LinkStatus; func linkSetEnabled(_: Bool); func linkOpenWindow(); func linkQuit() }`
  - `final class LinkServer { init(id: String, handler: LinkHandler, peerIdentifier: String = Kit.hubBundleID); func resume() }`
  - `final class LinkClient { init(id: String, timeout: TimeInterval = 2); func hello() async throws -> LinkHello; func status() async throws -> LinkStatus; func setEnabled(_: Bool) async throws; func openWindow() async throws; func quit() async throws }` и `enum LinkError: Error { case timeout, rejected, incompatible(Int) }`
  - `static func KitLink.postStatusChanged(_ id: String)` через `DistributedNotificationCenter`, без `userInfo`.

- [ ] **Step 1: Написать тесты**

`Tests/LinkCheck.swift` (чистая логика): строка статуса 200 символов → длина 80; `bundleID("awake") == "local.utilitumus.app.awake"`; `machService("awake") == "local.utilitumus.app.awake.xpc"`; `LinkHello`/`LinkStatus` переживают кодирование; `hello` с `protocolVersion = 99` → `LinkError.incompatible(99)`; битый JSON в ответе → ошибка, не падение.

`Tests/run-link-check.sh` (подписанные бинарники и launchd, метка сервиса подставляется тестовым `id` = `test.link`, identifier сервера `local.utilitumus.app.test.link`, клиента — временный `--peer`): клиент получает hello и status; rogue с ad-hoc подписью — `rejected`; сервер, который не отвечает 10 с, — `timeout` за ≤2,5 с, при этом таймер главного потока клиента не пропускает тиков дольше 0,3 с; сервер убит `kill -9` — клиент получает ошибку, а после перезапуска launchd новый вызов успешен; `grep -c userInfo Sources/Kit/Link` = 0.

- [ ] **Step 2: Запустить, увидеть провал**

- [ ] **Step 3: Реализовать**

Ответ на вызов приходит на главный поток; ни одного синхронного ожидания. Сервер при каждом подключении ставит точное требование; соединение без него не возобновляется.

- [ ] **Step 4: Оба теста проходят, `launchctl list` без тестовых меток**

- [ ] **Step 5: Commit** `Протокол связи центра и утилит`

---

### Task 4: Каталог и установщик

**Files:**
- Create: `Sources/App/Satellites/SatelliteCatalog.swift`, `Sources/App/Satellites/SatelliteInstaller.swift`, `Sources/App/Satellites/SatelliteAgent.swift`, `Catalog/catalog.json`, `Tests/SatelliteInstallerCheck.swift`, `Tests/run-satellite-installer-check.sh`

**Interfaces:**
- Consumes: `KitSigning.verifySignature`, `KitLink.bundleID`, `LinkClient.quit`.
- Produces:
  - `struct CatalogApp: Codable, Equatable { id, version, minHub, url: URL, sha256: String, sizeMB: Int }`; `struct Catalog: Codable { schema: Int; apps: [CatalogApp] }`; `enum SatelliteCatalog { static let url = URL(string: "https://raw.githubusercontent.com/IvanSSpace/utilitumus/main/Catalog/catalog.json")!; static func decode(_: Data) throws -> Catalog; static func available(_: Catalog, hubVersion: String) -> [CatalogApp] }` — `schema` ≠ 1 → ошибка; `minHub` новее центра → приложения нет в выдаче.
  - `struct SatellitePaths { var appsDir: URL; var agentsDir: URL; static let live }` — `live`: `/Applications/Utilitumus`, `~/Library/LaunchAgents`.
  - `struct SatelliteAgent { static func plist(id: String, executable: URL) -> Data }` — `Label`, `ProgramArguments`, `RunAtLoad = true`, `KeepAlive = false`, `MachServices`.
  - `final class SatelliteInstaller { init(paths: SatellitePaths, launchctl: @escaping ([String]) throws -> Void, download: @escaping (URL) async throws -> URL, verify: @escaping (URL, String) throws -> Void); func install(_: CatalogApp, name: String) async throws; func remove(id: String, name: String) async throws; func removeStaleAgent(id: String) throws }`

- [ ] **Step 1: Написать тесты (подставные `launchctl` и `download`, реальные zip во временной папке; `verify` реальный для подписанного фикстур-приложения, собираемого скриптом)**

Хороший архив → бандл на месте, плист на месте, `launchctl` получил `bootstrap`. Неверный `sha256` → ошибка, в `appsDir` и `agentsDir` ничего. Подпись ad-hoc или чужой identifier → то же. Установка поверх старой версии падает на проверке → старая версия цела и работает её плист. Архив с `../` или двумя `.app` → отказ. `decode` на мусоре и `schema: 2` → ошибка. `minHub: "9.0.0"` → нет в выдаче. `remove` → нет бандла, нет плиста, был `bootout`; настройки не тронуты. `release`-версии сравниваются числами (`0.10.0` новее `0.9.0`). Плист парсится и содержит ровно нужные ключи.

- [ ] **Step 2: Запустить, увидеть провал**

- [ ] **Step 3: Реализовать**

Порядок установки — как в спеке: скачать → `sha256` → `ditto -x -k` во временную папку на том же томе → проверка → атомарная замена (`replaceItemAt`) → плист → `bootstrap`. `Catalog/catalog.json` = `{"schema":1,"apps":[]}`.

- [ ] **Step 4: Тесты проходят**

- [ ] **Step 5: Commit** `Каталог и установщик утилит`

---

### Task 5: Сборка и выпуск утилит

**Files:**
- Modify: `build.sh`, `scripts/release.sh`, `install.sh`
- Create: `scripts/release-app.sh`, `scripts/build-app.sh`, `Tests/run-release-app-check.sh`

**Interfaces:**
- Produces:
  - `scripts/build-app.sh <id> <Имя> <версия> <каталог-вывода>` собирает `<Имя>.app` из `Sources/Apps/<Имя>`, `Sources/Modules/<Имя>`, `Sources/Kit`; identifier `local.utilitumus.app.<id>`; `--options runtime`.
  - `scripts/release-app.sh <id> <Имя> X.Y.Z [--dry-run]`: предусловия как у `release.sh`; тег `<id>-vX.Y.Z`, ассет `<Имя>.zip`, `gh release create --latest=false`; **после** успешной выкладки — запись в `Catalog/catalog.json`, коммит, push. `--dry-run` печатает команды `gh`/`git`, изменённый каталог пишет во временный файл и ничего не выкладывает.
  - `release.sh` передаёт `--latest=true`.
  - `install.sh [<id>]`: без аргумента как сейчас; с аргументом ставит утилиту по каталогу с той же проверкой подписи.

- [ ] **Step 1: Написать `Tests/run-release-app-check.sh`**

`--dry-run` на фикстуре: в плане есть `--latest=false`, тег `awake-v1.2.3`; порядок — выкладка раньше коммита каталога; во временном каталоге верные `version`, `url`, `sha256`; каталог не изменён в рабочем дереве; `release.sh` содержит `--latest=true`; нечистое дерево → отказ. `bash -n install.sh`.

- [ ] **Step 2: Запустить, увидеть провал**

- [ ] **Step 3: Реализовать (сборка центра не трогает `Sources/Apps/*`)**

- [ ] **Step 4: Тест проходит; `NO_INSTALL=1 ./build.sh` проходит**

- [ ] **Step 5: Commit** `Сборка и выпуск отдельных утилит`

---

### Task 6: Приложение «Не спать»

**Files:**
- Create: `Sources/Apps/Awake/main.swift`, `Sources/Apps/Awake/AwakeApp.swift`, `Sources/Apps/Awake/Info.plist`, `Sources/Kit/SatelliteRole.swift`, `Tests/SatelliteRoleCheck.swift`, `Tests/run-satellite-role-check.sh`, `Tests/run-awake-app-check.sh`
- Modify: `Sources/Modules/Awake/AwakeController.swift` (`UserDefaults.standard` → `Kit.defaults`)

**Interfaces:**
- Consumes: `LinkServer`, `LinkHandler`, `Kit.defaults`, `environment(\.moduleControls)`, `build-app.sh`.
- Produces:
  - `enum SatelliteRole { enum Mode: Equatable { case active, passive(reason: String), forwardAndExit }; static func decide(launchedByLaunchd: Bool, hubRunning: Bool, hubVersion: String?, hubModuleOn: Bool, handedOver: Bool) -> Mode }`
  - `enum SatelliteEnabled { static func key(_ id: String) -> String /* "App.<id>.Enabled" */; static func load(id: String, defaults: UserDefaults) -> Bool }` — нет ключа → значение `ModuleOn.<id>`, и оно записывается.
  - Ключ передачи `App.<id>.HandedOver` (`Bool`): пишет центр, выключив встроенный.

Таблица `decide`:

| launchd | центр запущен | версия центра | `ModuleOn` | передано | результат |
|---|---|---|---|---|---|
| нет | любое | любая | любое | любое | `forwardAndExit` |
| да | нет | любая | любое | любое | `active` |
| да | да | ≥ 0.6.0 | нет | любое | `active` |
| да | да | ≥ 0.6.0 | да | нет | `passive` («Ждём передачу от центра») |
| да | да | ≥ 0.6.0 | да | да | `active` |
| да | да | < 0.6.0 | да | любое | `passive` («Модуль уже работает в Utilitumus — обновите центр») |
| да | да | < 0.6.0 | нет | любое | `active` |

- [ ] **Step 1: Написать тесты**

Вся таблица; битая версия центра считается `< 0.6.0`. `SatelliteEnabled.load`: при `ModuleOn.awake = true` и нет своего ключа → `true`, ключ записан, `Modules.ResetForStore.v1` и остальные ключи домена не тронуты (отдельный тестовый suite). `run-awake-app-check.sh` (метка `local.utilitumus.test.*`, identifier через `build-app.sh` с фиктивным id): `hello` отвечает верной версией; `setEnabled(false)` при активной блокировке — в `pmset -g assertions` нет `Utilitumus: Keep Awake`; `quit` снимает assertion и процесс выходит; повторный запуск напрямую (без launchd) выходит сам ≤3 с, а второго процесса нет; в пассивном режиме команда «Не спать» не создаёт assertion.

- [ ] **Step 2: Запустить, увидеть провал**

- [ ] **Step 3: Реализовать**

`LSUIElement = true`; окно 480×520 c `AwakeView` в `dsThemed()`; значок в меню-баре (`cup.and.saucer.fill`), скрыт, пока запущен центр; `moduleControls` рисует переключатель `App.awake.Enabled`. Строка статуса: «Mac не уснёт» / «Mac не уснёт · ещё 1 ч» / «Mac засыпает как обычно» / при пассивном режиме — причина. `linkSetEnabled` заново вызывает `SatelliteRole.decide`: после передачи от центра пассивная утилита становится активной без перезапуска. Изменение статуса → `KitLink.postStatusChanged`. `AwakeController` компилируется и в центр, и в утилиту без условной компиляции. Проверка обновлений без центра — раз в сутки через `SatelliteCatalog`; если код нужен и центру и утилите, каталог и версии переезжают в `Sources/Kit` (бандл заменяет себя как `Updater`, без `SatelliteInstaller`).

- [ ] **Step 4: Тесты проходят; стенд за экраном показывает окно в теме `dusk` — приложить PNG к отчёту**

- [ ] **Step 5: Commit** `Отдельное приложение «Не спать»`

---

### Task 7: Центр ведёт утилиты

**Files:**
- Create: `Sources/App/Satellites/SatelliteRegistry.swift`, `Sources/App/Satellites/ModuleHandover.swift`, `Sources/App/Satellites/SatellitePage.swift`, `Tests/ModuleHandoverCheck.swift`, `Tests/run-module-handover-check.sh`, `Tests/run-store-catalog-check.sh`
- Modify: `Sources/App/ModuleManager.swift`, `Sources/App/Store/StoreModel.swift`, `Sources/App/Store/StoreView.swift`, `Sources/App/Store/StoreDetail.swift`, `Sources/App/Design/Shell.swift`, `Sources/App/UtilitumusApp.swift`

**Interfaces:**
- Consumes: `SatelliteCatalog`, `SatelliteInstaller`, `LinkClient`, `KitLink.statusChanged`, `App.<id>.HandedOver`.
- Produces:
  - `enum ModuleHandover { enum Decision: Equatable { case keepBuiltIn, handOver, satelliteOwns, returnToBuiltIn }; static func decide(bundlePresent: Bool, handedOver: Bool, reply: LinkStatus?) -> Decision }`
  - `@MainActor final class SatelliteRegistry: ObservableObject { static let shared; @Published private(set) var entries: [Module: Entry]; func refresh() }`; `Entry { catalog: CatalogApp?; installedVersion: String?; status: LinkStatus?; responding: Bool }`. Опрос: при запуске, при открытии Стора, по `statusChanged`. Без таймера в простое.
  - `ModuleManager.setExternal(_: Module, _: Bool)` — встроенный модуль не стартует и останавливается; `isOn`/`isInstalled` учитывают внешний вариант, `ModuleReset` не меняется.
  - `SatellitePage(module:)` — статус, «Открыть окно», переключатель, «Нужны доступы: N».

Таблица `decide`:

| бандл | передано | ответ | решение |
|---|---|---|---|
| нет | нет | — | `keepBuiltIn` |
| нет | да | — | `returnToBuiltIn` (снять мёртвого агента, сбросить `HandedOver`) |
| да | нет | нет ответа | `keepBuiltIn` |
| да | нет | `needsSetup > 0` | `keepBuiltIn` |
| да | нет | `needsSetup == 0` | `handOver` (выключить встроенный, поставить `HandedOver`, затем `setEnabled`) |
| да | да | любой или нет | `satelliteOwns` (нет ответа — «не отвечает», встроенный не включаем) |

- [ ] **Step 1: Написать тесты**

Вся таблица. `run-store-catalog-check.sh` (стенд за экраном): каталог недоступен — Стор рисует все модули, `install(.awake)` ставит встроенный; каталог с `awake` — `install` идёт через установщик (подставной), после ошибки установщика плитка снова «＋» и видна ошибка; ни при каких условиях вкладки не заперты. Бандл удалён при `HandedOver = true` — после `refresh()` агент снят, ключ сброшен, модуль снова встроенный. `refresh()` при зависшей утилите не блокирует главный поток дольше 0,3 с.

- [ ] **Step 2: Запустить, увидеть провал**

- [ ] **Step 3: Реализовать**

Кнопка «Удалить» в Сторе зовёт `SatelliteInstaller.remove`, настройки остаются. Плитка Стора не меняется визуально. Модули без записи в каталоге работают ровно как сейчас.

- [ ] **Step 4: Тесты проходят; все прежние `Tests/run-*` и `scripts/test-app-layout.sh` проходят; PNG Стора и страницы утилиты приложить к отчёту**

- [ ] **Step 5: Commit** `Центр ставит и показывает отдельные утилиты`

---

### Task 8: Проверка целиком

**Files:**
- Create: `Tests/run-hub-e2e.sh`, `Tests/HubE2E.swift`

Настоящая метка `local.utilitumus.app.awake` разрешена только здесь, предварительно проверено, что такой метки у пользователя нет; `trap` снимает её и удаляет всё. Настройки — не `local.utilitumus` этого Mac: на время теста значения не меняются, `App.awake.*` в конце удаляются, если их не было.

**Interfaces:**
- Consumes: всё выше. Харнесс собирается из тех же исходников, `SatellitePaths.appsDir` — временная папка, каталог — `file://`.

- [ ] **Step 1: Написать харнесс: собрать настоящий `Awake.zip` через `build-app.sh`, каталог с его хэшем, пройти сценарий**

Установка → агент запущен → `hello` с версией → `status` → `setEnabled(true/false)` → завершить центр-харнесс и убедиться, что утилита жива и держит assertion → запустить харнесс снова, `hello` успешен → обновление на версию выше (архив с новым номером): `quit`, замена, `hello` с новой версией → удаление: нет бандла, агента, процесса, assertion. Подмена: архив с чужой подписью не меняет установленное.

- [ ] **Step 2: Запустить, все шаги зелёные, `launchctl list` без `local.utilitumus.app.*`, `pmset -g assertions` без `Utilitumus: Keep Awake`**

- [ ] **Step 3: Обновить `README.md` (раздел о центре и утилитах, без личного) и память не трогать; Commit** `Сквозная проверка центра и утилиты`

---

## Вне этого плана: требует решения автора

- Слияние `hub` в `main`, выпуск центра 0.6.0 и утилиты `awake-v1.0.0`, запись в `Resources/WhatsNew.json`, строка в реальном `Catalog/catalog.json`. Публикация только после проверки автором на своём Mac.
- Этап 4 — отдельные планы по модулям, в порядке спеки.
