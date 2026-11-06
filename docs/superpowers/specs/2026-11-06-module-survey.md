# Module survey: moving the 10 remaining modules to utilities

Read-only survey of branch `hub` at `98bdae0`. Nothing was built, launched or changed.
Paths are relative to `Sources/` unless they start with another top-level folder.

**How to read the numbers**

- "Props" means `@Published` properties the screen depends on. "Actions" means methods or setters the screen, the setup checklist or Dashboard calls on the model. Both are counted from the code.
- Lines of code are `wc -l` on the Swift files, plus helper sources where noted.
- Anything the code cannot show, such as how macOS will behave, is marked **Probe** or stated as an open question.
- Binary sizes come from the build currently installed in `/Applications/Utilitumus.app`.

---

## 1. Summary

| Order | Module | id | LOC | Props / actions | macOS grants the utility needs | Risk |
|---|---|---|---|---|---|---|
| 1 | Звук | `sound` | 905 | 8 / 3 | none | low |
| 2 | Мышь | `mouse` | 662 | 3 / 3 | Accessibility (required), maybe Input Monitoring for the Magic Mouse watch | low |
| 3 | Микшер | `mixer` | 1023 | 6 / 5 | system audio capture, plus an entitlement | medium |
| 4 | Стеш | `stash` | 1054 | 9 / 16 | Accessibility (required) | medium |
| 5 | Клавиатура | `keyboard` | 1340 | 15 / 14 | Input Monitoring (required) | high |
| 6 | Браузер | `browser` | 1894 + 40 helper | 6 / 7 | none (default-browser handler instead) | high |
| 7 | Нагрузка | `load` | 7672 | 14 / 21 | none | medium |
| 8 | Голос | `voice` | 1835 + 351 C helper | 11 / 15 | Microphone (required), Accessibility (optional), plus an entitlement | medium |
| 9 | Буфер | `clipboard` | 1762 | 10 / 16 | Accessibility (optional), Keychain item access | high |
| 10 | Вентиляторы | `fans` | 2149 + 183 helper + 181 shared | 15 / 14 | root service, `apple-events` entitlement | high |

Totals: 97 props and 114 actions.

This order differs from the spec's stage 4 (Нагрузка → Микшер → Буфер → Мышь → Звук → Браузер → Клавиатура → Голос → Вентиляторы → Стеш):

- **Нагрузка moves from first to seventh.** It needs no permissions, but it has the largest wire surface by far: 100 top-level types in its data folders, 1 of them declared `Codable`.
- **Стеш moves from last to fourth.** It is one store and one view with no background work.
- **Буфер moves late.** A failure there can lock the user out of encrypted history.

### Things the Awake pattern does not yet cover

Awake has no setup steps, no sliders, no images, no helper, one-field actions and about one state change per click. These gaps affect most other modules. Gap 3 is already visible on Awake today.

1. **The setup checklist reads the launcher's permissions, not the utility's.**
   - `App/Setup/SetupStep.swift:81` calls `AXIsProcessTrusted()` in the launcher. `App/ModuleRequirements.swift:37` evaluates it for every module, including external ones.
   - `RemoteAwakePage` wraps the screen in `ModuleScreen`, which consults that set (`App/ModuleChrome.swift:20`). Awake has no steps, so the bug never shows.
   - `AwakeApp.swift:162` hard-codes `needsSetup: 0`.
   - `SetupStep` lives in `App/` and references controllers, so a utility cannot compile it today.
   - `ModuleHandover.decide` keeps the built-in module until the utility reports `needsSetup == 0` (`App/Satellites/ModuleHandover.swift:24`), and no launcher screen shows the utility's steps during that time (`App/Store/StoreModel.swift:378`). See open question Q1.

2. **`statusChanged` is too expensive for live state.** Each ping triggers all of the following:
   - `SatelliteRegistry.poll`, which makes a new `LinkClient` and connection, sends `hello` and `status`, and does a detached `Info.plist` read (`SatelliteRegistry.swift:4,16-18,246`).
   - An `entries` assignment (`:279`), which is `@Published` and wakes every Dashboard slot subscribed to the registry (`App/Design/Dashboard.swift:103-107`).
   - A `moduleState` round trip from the remote model.

   Awake posts this on every `objectWillChange` (`Apps/Awake/AwakeApp.swift:89-91`). Copying that to Fans means all of the above every 2 s (`Fans/FanController.swift:202,338`), even with the window closed.

3. **The launcher's quick actions disappear when a module goes external, including on Awake today.**
   - `MenuBar.swift:65,72,77` hides the Fans, Awake and Stash sections behind `runsBuiltIn`.
   - `Dashboard.swift:179,197-203` returns only `status.line` for external modules, with no action button and no attention colour unless `needsSetup > 0`.
   - That loses "Максимум/Авто", "Спрятать/Вернуть", "Обновить", "Проверить", "Не спать" and the orange states for overheating, secure input, missing key and missing model.
   - This conflicts with the amendment that the launcher must not change visually. `LinkStatus` has only `enabled`, `line` and `needsSetup`.

4. **Blocking work on the utility's main thread reads as "module is dead".**
   - `LinkServer` runs every call on main (`Kit/Link/LinkServer.swift:40-44`) and the client timeout is 2 s (`LinkClient.swift:29`).
   - One failed read flips the tab to `SatellitePage` (`RemoteAwakeModel.swift:72`, `RemoteAwakePage.swift:22`).
   - Known blockers:
     - The Fans admin password dialog (`Fans/FanHelperInstaller.swift:231`, on main).
     - The Keychain read in `ClipboardController.start` (`Clipboard/ClipboardController.swift:103`).
     - Stash's AX calls (`Stash/StashStore.swift:447,516`).

5. **Self-identity checks use `Bundle.main` and will stop protecting the launcher.** Affected sites:
   - `Stash/StashStore.swift:233` would let Стеш close the launcher.
   - `Load/Native/Background/LaunchAgents.swift:60` covers the launcher's label, but other utilities' agents become stoppable "third-party" agents.
   - `Load/Native/Core/StopActions.swift:18-19` fences only the utility's pid and ancestors, so the launcher becomes stoppable.
   - `Keyboard/KeyboardController.swift:227`, `Clipboard/ClipboardController.swift:213`, `Voice/VoiceController.swift:202`, `Fans/GameModeController.swift:126,220`, `Browser/BrowserView.swift:659`.

6. **"Page active" and window visibility no longer exist inside a utility.**
   - `Load/Native/LoadStore.swift:92,113-116` and `Stash/StashStore.swift:274,317-320` skip work unless the process has a visible window. A windowless utility would measure nothing, forever.
   - Mixer, Fans, Stash and Load also need "screen open" as an action. The protocol has no signal for the launcher dying while the screen is "open", and `LinkServer` sets no `invalidationHandler`. A crashed launcher would leave the 1 s Mixer poll or a suspended hot key running until restart.

7. **`SatelliteRole.mustRelease` is Awake-specific.** Its comment (`Kit/SatelliteRole.swift:22-25`) relies on the built-in module doing nothing until a button is pressed. Every other module starts working at `start()`, so a passive utility must stop its work. Otherwise a utility started while the hub was off keeps running beside the built-in module once the hub launches: two writers to `index.bin`, two event taps, two enforcers of the default device.

8. **`UserDefaults.standard` inside a utility is a different, empty domain.** The result would look like total settings loss, followed by overwrite on the next save. Sites to change:

   | Module | `UserDefaults.standard` | `= .standard` default parameter | `@AppStorage` (stays on launcher) |
   |---|---|---|---|
   | Sound | 12 | 0 | 0 |
   | Keyboard | 17 | 0 | 0 |
   | Voice | 8 | 0 | 0 |
   | Clipboard | 6 | 0 | 0 |
   | Fans | 6 | 0 | 0 |
   | Mixer | 6 | 0 | 0 |
   | Mouse | 0 | 2 (`Mouse/MouseScrollLogic.swift:41,51`) | 0 |
   | Stash | 0 | 1 (`Stash/StashStore.swift:177`) | 0 |
   | Load | 0 | 0 | 3 |
   | Browser | 0 (already on a shared domain) | 0 | 1 |

   The default parameters will not show up in a search for `UserDefaults.standard`.

9. **Module folders do not compile alone**, and `scripts/build-app.sh:69` compiles only `Apps/<X>`, `Modules/<X>` and `Kit`:

   | Reference | Where | Affects |
   |---|---|---|
   | `.onPageActive`, `\.pageActive` are declared in `App/Design/Pages.swift:53-87` | used in view files | 9 of 10 modules (not Sound) |
   | `AccessState.shared.refresh()` | `Keyboard/KeyboardController.swift:140` | Keyboard |
   | `VoiceExcludedApps` | `Keyboard/KeyboardView.swift:117,158,165`; `Clipboard/ClipboardView.swift:142,149,162` | Keyboard, Clipboard |
   | `VoiceHotKey`, `HotKeyRecorder`, `VoiceHUD` | `Clipboard/ClipboardController.swift:60,269`; `Clipboard/ClipboardView.swift:7` | Clipboard |
   | `extension ClipboardController: HotKeyTarget {}` | `Voice/VoiceView.swift:324` | Voice depends on Clipboard |
   | `ActionLog.preparePrivate` | `Fans/FanController.swift:520` (declared in Load) | Fans |
   | `SMC`, `FanLink` | `Shared/`, not in the build-app file list | Fans |

---

## 2. Per module

### 2.1 Звук (`sound`)

1. **Size:** 905 lines in 8 files. No third-party dependencies.
2. **Permissions:** none. `App/Store/StoreModel.swift:94` lists no needs and `App/Setup/SetupStep.swift:137` has no steps. Listeners and writes are plain CoreAudio (`Sound/AudioMonitor.swift:49,170`).
3. **Where it runs:**
   - Utility: `AudioMonitor` (listeners, 5 s re-sync, policy, `CorrectionThrottle`), `KnownDeviceStore`, primary-device stores.
   - Launcher: `SoundView` only.
   - No taps, panels, hot keys or fast state. State is assigned only when changed (`AudioMonitor.swift:112-116`), so it fits push-on-change.
4. **Surface:** 8 props (`MonitorState` 5, `LockState` 1, `PrimaryInputStore` 1, `PrimaryOutputStore` 1). 3 actions: select input, select output, set Bluetooth lock. The view calls `AudioMonitor.shared.enforcePolicy()` itself in 4 places (`SoundView.swift:155,176,201,219`); those become part of the utility's action handler. `DisplayDevice` needs `Codable` (`Transport` already has it).
5. **Coupling and data:**
   - Hub: `Dashboard.swift:136,206`, `ModuleHooks+Live.swift:36`, `MicGuardMigration.run()` in `UtilitumusApp.swift:271`.
   - Keys: `MicGuardBluetoothLocked`, `MicGuardDisabledDeviceUIDs`, `MicGuardKnownDevicesOrder`, `UtilitumusKnownOutputDevices`, `UtilitumusPrimaryInput`, `UtilitumusPrimaryOutput`.
   - No files on disk.
6. **Risk: low.** No grants or files. The only hazard is two enforcers fighting over the default device if the passive rule (gap 7) is not fixed.
7. **Screen identity:** the code shows nothing that blocks an identical screen. It is the best first proof of the generic helper. A utility installed without the hub never runs the MicGuard migration; decide whether that matters.

### 2.2 Мышь (`mouse`)

1. **Size:** 662 lines in 5 files. No third-party dependencies.
2. **Permissions:**
   - Accessibility: active scroll tap `Mouse/MouseScrollTap.swift:72` (`.defaultTap`), checks `Mouse/MouseController.swift:19,56,62`, step `App/Setup/SetupStep.swift:150-152`.
   - HID: `IOHIDManagerOpen` at `Mouse/MouseScrollTap.swift:130` silently falls back when "нет прав" (comment at `:119`). No setup step covers it. **Probe:** whether the utility needs a separate Input Monitoring grant for the Magic Mouse watch.
3. **Where it runs:**
   - Utility: tap thread, 120 Hz animation timer, 2 s health poll. All of it stays inside the utility, so no fast state crosses XPC.
   - Launcher: `MouseView`.
4. **Surface:** 3 props (`settings`, `axTrusted`, `tapActive`). 3 actions: set settings, `refreshAccess`, `requestAccess`. `MouseSettings` has 5 fields and needs `Codable`.
5. **Coupling and data:** `Dashboard.swift:137,211`, `SetupStep.swift:152`, a chip in `App/ModuleChrome.swift:63`. Keys: `Mouse.Direction`, `.MagicDirection`, `.Smooth`, `.Speed`, `.Smoothness`.
6. **Risk: low.** The built-in module keeps working until the new Accessibility grant is given.
7. **Screen identity:**
   - The two sliders bind directly to the model (`MouseView.swift:29-35`) with no local drag value. Showing only the utility's reply would make the thumb lag. See Q4.
   - The Accessibility step is required even when `needsTap` is false, so someone with default settings blocks handover for a permission they do not need. Decide whether to make it conditional.
   - `speed` and `smoothness` are clamped only on load (`MouseScrollLogic.swift:47-48`), so the wire handler must clamp them.

### 2.3 Микшер (`mixer`)

1. **Size:** 1023 lines in 4 files. No third-party dependencies.
2. **Permissions:**
   - System audio capture: `Mixer/ProcessTap.swift:93,111`.
   - Entitlement `com.apple.security.device.audio-input` and `NSAudioCaptureUsageDescription`. Both must be added to the utility; `scripts/build-app.sh:85` signs with no entitlements and Awake's `Info.plist` has no usage strings.
   - The step is not verifiable in advance (`SetupStep.swift:157-165`, `verifiable: false`).
3. **Where it runs:**
   - Utility: HAL polling (1 s when visible, 4 s hidden, `MixerController.swift:70-71`), listeners, tap real-time path, `quietApps`.
   - Launcher: `MixerView`.
   - **Fast path:** a slider sends "tens of values per second" (`MixerController.swift:100`). `MixerRow` already has a local drag value (`MixerView.swift:33`), so the display is fine. But an action-and-reply carrying the full state on every tick is wasteful. Needs a no-reply or coalesced `setVolume`.
4. **Surface:** 6 props (`apps`, `idleApps`, `presetApps`, `otherApps`, `permissionProblem`, `lastError`). 5 actions: `setVolume`, `setMuted`, `reset`, `commitVolumes`, `setScreenVisible`.
   - `MixerApp` holds an `NSImage` (`:12`), which is not `Codable`. Send ids and have the launcher resolve icons, as `VoiceExcludedApps.icon` already does. **Probe:** `NSRunningApplication.icon` and `NSWorkspace.icon(forFile:)` must match pixel for pixel, and `exe:` entries use the generic symbol.
5. **Coupling and data:** `Dashboard.swift:144,307`, `SetupStep.swift:160`. Keys: `MixerVolumes`, `MixerMuted`, `MixerHeard`. Excludes itself by pid (`MixerController.swift:272,281-283`), so the launcher's own audio becomes visible in the list.
6. **Risk: medium.** Handover happens with no prior grant, because an unverifiable step counts as done. Saved volumes then fail until the user approves capture, and a tap with no data is torn down (`MixerController.swift:449-454`), so volumes silently stop applying.
7. **Screen identity:**
   - `MixerView.swift:198` tells the user to enable "Utilitumus" in Settings. The entry will be the utility.
   - `MixerView.swift:226` says everything returns on exit from Utilitumus. Quitting the launcher will no longer stop the mixer. See Q2.

### 2.4 Стеш (`stash`)

1. **Size:** 1054 lines in 2 files. No third-party dependencies.
2. **Permissions:** Accessibility (`Stash/StashStore.swift:78-120,167,253,416,442,486`; step `SetupStep.swift:147-149`, required). Also `terminate`/`forceTerminate`, `openApplication` and `/bin/ps`, none of which need a grant.
3. **Where it runs:**
   - Utility: capture and restore windows, terminate, launch, `ps`.
   - Launcher: `StashView` and its confirmation dialogs.
   - No background work (`ModuleHooks+Live.swift:69`). `refreshUsage` runs every 10 s from a view `.task` (`StashView.swift:512-517`), which needs the screen-open signal instead of `windowIsVisible` (`StashStore.swift:317`).
4. **Surface:** 9 props. 16 actions: `start`, `refreshAccess`, `refreshUsage`, `stashSelected`, `stash(scenario)`, `restore`, `forceTerminate`, `forceTerminateAll`, `setClosing`, `selectOnlyHeavy`, `addScenario`, `renameScenario`, `updateScenario`, `deleteScenario`, `select(scenario)`, `requestAccess`.
   - `RunningEntry` holds `NSRunningApplication` and `NSImage` (`:41-45`), and `selected` returns `[NSRunningApplication]`. The wire needs `bundleID`, name and the computed `selected`/`runningByWeight`.
   - `AppUsage` and `RestoreReport` need `Codable`.
   - `stash` and `restore` are `async` and long-running. Reply immediately and report through `busy`.
5. **Coupling and data:**
   - `MenuBar.swift:46,77-90`, `Dashboard.swift:140,162-168,252-262,341-354`, `SetupStep.swift:149`. Helpers `memoryText` and `programs` (`StashView.swift:35,275`) are used from `Dashboard`.
   - Unguarded hub call: `Dashboard.swift:352-354` uses `isOn(.stash)`, which is true for external modules (`ModuleManager.swift:118`), so the hub would keep refreshing its own stale store. Must become `runsBuiltIn`.
   - Keys: `StashedApps` (+ `.unreadable`), `StashExcludedBundleIDs`, `StashScenarios`.
6. **Risk: medium. Can lose data and weaken a check.** `StashedApps` is the only record of programs already closed; a missed `.standard` default makes it look empty, so those programs and window positions never come back. `isEligible` (`:233`) would no longer protect the launcher.
7. **Screen identity:** `StashView.swift:343` promises "Finder и Utilitumus не закрываются", which holds only if the launcher id is added to the protected list. The confirmation in `Dashboard.swift:341-349` reads `StashStore.shared.selected`; see Q9.

### 2.5 Клавиатура (`keyboard`)

1. **Size:** 1340 lines in 8 files. No third-party dependencies.
2. **Permissions:**
   - Input Monitoring: listen-only tap `Keyboard/KeyboardController.swift:443`, checks `:25,383,393`, step `SetupStep.swift:110-114`.
   - No TCC, but writes system preferences: `com.apple.HIToolbox AppleFnUsageType` (`Keyboard/InputSources.swift:49,170`), `com.apple.symbolichotkeys` (`:210,270`), runs `activateSettings` and SIGKILLs `TextInputSwitcher` (`:179-189`).
3. **Where it runs:**
   - Utility: tap on the main run loop (TIS requires main), detector, per-app layout memory, 30 s health timer, system-setting enforcement.
   - Launcher: `KeyboardView`.
   - Fast events stay in the utility; state only changes on layout switches. But `note()` publishes `logTail`/`logCount` on every Fn event (`:369-373,494-496`), so push must be limited to when the screen is open.
4. **Surface:** 15 props. 14 actions: `setFeature`, set `trigger`, `mode`, `newAppLayout`, `addExcluded`, `removeExcluded`, `repair`, `copyLog`, `refreshAccess`, `refreshSystem`, `requestAccess`, `disableSystemAction`, `disableDictationDoubleFn`, `disableAllSystemActions`. Plain values throughout; `KeyboardLog.Entry` and `LayoutItem` need `Codable`.
5. **Coupling and data:**
   - `App/ModuleManager.swift:63` calls `FnSystemAction.restore()` during reset. `App/ModuleReset.swift:24-26` knows its key names. `SetupStep.swift:103-125,155,217-219,271-274`, `Dashboard.swift:146,283-297`, `ModuleHooks+Live.swift:62-64`.
   - Keys: `Keyboard.Trigger`, `.Mode`, `.Feature.<id>`, `.AppLayout.Saved`, `.AppLayout.Excluded`, `.AppLayout.NewStart`, `.SavedFnUsage`, `.KeepSystemFnOff`, `.SavedDictationEnabled`.
   - File: `~/Library/Logs/Utilitumus/keyboard.log`.
6. **Risk: high. Handover as written undoes the user's system setting.**
   - `ModuleManager.setExternal` → `sync` → `hooks.stop()` (`App/ModuleManager.swift:157-160,222`) → `KeyboardController.stop()` → `FnSystemAction.restore()` (`KeyboardController.swift:110`).
   - That clears `KeepSystemFnOff` and `SavedFnUsage` and restores 🌐 (`InputSources.swift:153-166`). Then `migrateKeepOff` in the utility no longer sees the intent (`:83-86`).
   - The language then switches twice, and the utility reports `needsSetup` 1 right after handover.
   - The reverse gap: remove and update call the same `quit` (`App/Satellites/SatelliteInstaller.swift:124,160`), and `quit` must not restore (`KeyboardController.swift:114`). Uninstalling would leave 🌐 disabled for good.
   - Handover needs a `quit`-style stop, and `LinkXPC.quit` needs a reason, or uninstall needs a separate call.
7. **Screen identity:** nothing visible blocks it. `KeyboardController.swift:227` treats "our window" as `Bundle.main`, so switching to the launcher would restore or record a layout for it. Without the fix the launcher becomes an app with its own remembered layout.

### 2.6 Браузер (`browser`)

1. **Size:** 1894 lines in 5 files, plus `LinkHelper/main.swift` 40 lines and its `Info.plist`. Installed `Utilitumus Links.app` is 956 KB. No third-party dependencies.
2. **Permissions:** none in TCC (`StoreModel.swift:94`). It relies on the default-browser registration instead: `LSRegisterURL` at `UtilitumusApp.swift:294` and `Browser/BrowserView.swift:236`, `setDefaultApplication` at `BrowserView.swift:242` and `SetupStep.swift:92-100`.
3. **Where it runs:**
   - The real work is already out of process: `Utilitumus Links.app` handles the Apple Event (`LinkHelper/main.swift:9-11`) and shows the floating `BrowserPanel` (`Browser/BrowserPicker.swift:188`, global mouse monitor `:316`). This is unaffected by "launcher draws".
   - Launcher: `BrowserView`, `AddRuleSheet` (with `NSOpenPanel`, `:669`), `KeyRecorder` (local monitors, `:490,500`). None need permissions.
   - Settings already live in a shared domain with two writers (`BrowserCatalog.swift:42-44,99`).
4. **Surface:** 6 props (`browsers`, `hidden`, `fallbackID`, `rules`, `keys`, `signedIDs`). 7 actions: `setKey`, `setHidden`, `setFallback`, `move`, `addRule`, `removeRule`, `refresh`. `InstalledBrowser` holds `NSImage` and `URL`. The default-browser state and `setDefault`/`openTest` are `@State` and local view code (`BrowserView.swift:72-74,221-250`).
5. **Coupling and data:**
   - `UtilitumusApp.swift:294`, `SetupStep.swift:85-100`, `Dashboard.swift:139,155-160,241-248`, `App/UpdateBundle.swift:19-22`, `build.sh:84-98`, `install.sh:224-226`.
   - Keys: `Browser.Rules`, `.Order`, `.Hidden`, `.Fallback`, `.Keys`, `.introHidden`, each possibly with `.unreadable`.
   - State the upgrade must keep: the macOS default handler for http/https, which names the Links bundle.
6. **Risk: high. Can break every link on the Mac.**
   - `BrowserHelper.appURL` is `Bundle.main`-relative (`BrowserCatalog.swift:50-53`), so the launcher and the utility compute different copies. During migration two registered copies share the id `local.utilitumus.links`. **Probe:** which one LaunchServices opens, and what happens when one is deleted.
   - Removing the utility or the helper from the hub leaves no handler at all while the default still points at it.
   - **Logic break:** `moduleDisabled` reads `ModuleOn.browser` (`BrowserCatalog.swift:47`), but a utility's enabled state lives in `App.browser.Enabled`. `install` sets only that key (`SatelliteRegistry.swift:150-154`), so a fresh "＋" leaves the helper believing it is disabled, and the toggle stops controlling it.
   - **Weakened check:** see helper identity in §4.
7. **Screen identity and an open question:** the code suggests this module may need no XPC-backed model, since the launcher can keep `BrowserCatalog` against the shared domain. See Q7. `BrowserView.swift:176` shows "Utilitumus" as the default browser name.

### 2.7 Нагрузка (`load`)

1. **Size:** 7672 lines in 42 files. No linked third-party code. Optionally runs external tools such as `smartctl`, `tmux`, Docker via socket (`Load/Native/Core/Tool.swift`, `Sessions/MuxProbe.swift:104`).
2. **Permissions:** none in TCC (`StoreModel.swift:94`). Reads `~/.claude` (`Sessions/SessionsBuilder.swift:14-15`), kills processes (`Core/StopActions.swift:189`, `Background/BackgroundActions.swift:75`), runs `launchctl` (`:377`) and `bots.toml` commands (`:428`). `Tool.run` disclaims responsibility to keep the app's grants from child tools (`Core/Tool.swift:7-17`).
3. **Where it runs:**
   - Utility: `LoadEngine`, history loop (1 min), all stop and bot execution.
   - Launcher: all tabs, chart, `StopConfirmSheet`, palette computation.
   - **High-frequency state:** a measure every 3 s while the screen is open (`LoadStore.swift:21`). Publishing is already throttled by `SnapshotKey` (`:125`), with `LiveStats` separate. Payload size is unknown without running it.
   - The wire needs only `memory`, `groups`, `map`, `advice`, `sessions`, `disk`, not `procs`, `tree`, `fence`, `launchd` (`Core/LoadEngine.swift:5-27`; `SnapshotKey` lists what screens depend on). Decoding a payload this size on the launcher's main actor (as `RemoteAwakeModel.swift:65` does) could stall the UI, so decode off-main.
4. **Surface:** 14 props (`LoadStore` 6, `LiveStats` 4, `BackgroundStore` 4). 21 actions: 9 `requestStop` overloads (`LoadStore.swift:148,152`, `Sessions/SessionStop.swift:8-53`), `cancelStop`, `confirmStop`, `refreshNow`, `screenAppeared`, `screenDisappeared`, dismiss notice, `background.request` ×2, `cancel`, `confirm`, `setTabOpen`, `reloadJournal`. Those 9 overloads can become one action with a target enum. Top-level types in `Core`, `Sessions` and `Background`: 100, of which 1 declares `Codable` (`HistorySample`). Not all of them cross the wire.
5. **Coupling and data:** `Dashboard.swift:145,170,315`. `Fmt` is used from `Dashboard`. `ActionLog` is used by Fans. Keys `LoadViewMode` and `LoadTab` stay on the launcher. Files: `~/Library/Application Support/Utilitumus/load-history.json`, `bots.toml`, `~/Library/Logs/Utilitumus/actions.log`.
6. **Risk: medium. Security-sensitive.** No grants or irreplaceable data, but this is the widest action surface.
   - `confirm` must take only a utility-held plan id. A `StopPlan`, pid list or argv from the wire would let the launcher command arbitrary kills and bot commands, which the spec's anti-goals forbid.
   - The fence misses the launcher (gap 5).
   - `LoadStore.windowIsVisible` must go (gap 6).
   - Double running means two writers to `load-history.json`.
7. **Screen identity:** `OverviewTab.swift:79` shows "Utilitumus · memory · CPU" from `selfMemMB`/`selfCPU`, which would now measure the utility. Decide what that row means. `isSelf` on sessions (`SnapshotKey.swift:70`) has the same question.

### 2.8 Голос (`voice`)

1. **Size:** 1835 lines in 8 files, plus `VoiceHelper/main.c` 351 lines.
   - sherpa-onnx v2.0.1 in `Vendor/sherpa-onnx`: 112 MB on disk including the downloaded archive. The `lib` folder is about 96 MB and `libonnxruntime.a` alone is 75 MB. Linked statically by `build.sh:68-78`.
   - Installed `utilitumus-voice` is 25.4 MB, which is over the spec's "1–5 MB" per utility.
   - Models are downloaded separately: 170 MB or 487 MB.
2. **Permissions:**
   - Microphone: `Voice/VoiceController.swift:94,124,292,458,464`, `VoiceRecorder.swift:13` (`AVAudioEngine`). Needs the `audio-input` entitlement and `NSMicrophoneUsageDescription`.
   - Accessibility (optional): `VoiceController.swift:125,416,459,474`, synthetic ⌘V `:446-452`.
   - No permission for Carbon hot keys (`:236,250`).
3. **Where it runs:**
   - Utility: recorder, 15 Hz level timer (`:318`), `VoiceHUD` (`Voice/VoiceHUD.swift:61`, floating, non-activating), hot key and Esc, helper process, paste, model download.
   - Launcher: `VoiceView`.
   - **The 15 Hz level goes to the HUD inside the utility, so it never crosses XPC.** Only `phase` must. Download progress is per `didWriteData` (`VoiceModels.swift:305-308`) and needs throttling before it reaches the wire. `VoiceRecorder.inputDevices()` needs no permission and can stay in the launcher view (`VoiceView.swift:42,50`).
4. **Surface:** 11 props (`VoiceController` 9, `VoiceModelStore` 2). 15 actions: set `mode`, set `micUID`, `addExcluded`, `removeExcluded`, `setHotKey`, `resetHotKey`, `suspendHotKey`, `resumeHotKey`, `refreshPermissions`, `requestAccessibility`, `requestMic`, `download`, `cancel`, `delete`, set `selected`.
5. **Coupling and data:**
   - Provides `VoiceHotKey`, `HotKeyRecorder`, `VoiceExcludedApps`, `VoiceHUD` to Clipboard and Keyboard.
   - `StoreModel.swift:77,122,272,296-309,344,485,490,511-512` holds `VoiceModelStore` directly. `SetupStep.swift:176-209`, `Dashboard.swift:141,272-280`, `UpdateBundle.swift:27-30`, `build.sh:64-79`.
   - Keys: `Voice.HotKeyCode`, `.HotKeyModifiers`, `.Mode`, `.MicUID`, `.ExcludedApps`, `.Model`.
   - Files: `~/Library/Application Support/Utilitumus/Voice/Models/` (0700, excluded from backup).
6. **Risk: medium. One race can damage a download, and one check can be weakened.**
   - `VoiceModelStore.init` deletes all `.download-*` and `.staging-*` (`VoiceModels.swift:104,172-178`). The launcher creates that store at startup (`StoreModel.swift:272`; `SetupStep.swift:190`), so it can delete a download the utility is running.
   - `statuses` are computed once in `init` (`:105-107`), so a download done by the other process stays "not installed" until restart.
   - Store install, cancel, delete and `removeBuiltIn` (`StoreModel.swift:485,490,511-512`) must go through the utility once external. Models themselves survive; the path does not change.
   - Helper identity must keep being checked on install (§4). `VoiceEngine.verifyHelper` moves intact (`VoiceEngine.swift:63,78-85`).
7. **Screen identity:** the "Проверить" field cannot behave the same. `VoiceController.swift:410` inserts directly when `NSApp.isActive` and the key responder is a text view. In a utility that is never true for the launcher's `TextEditor` (`VoiceView.swift:243`), so test dictation falls through to AX paste, or to "Скопировано — вставь ⌘V" without Accessibility. See Q6.

### 2.9 Буфер (`clipboard`)

1. **Size:** 1762 lines in 7 files. No third-party dependencies; uses CryptoKit.
2. **Permissions:**
   - Accessibility (optional): `Clipboard/ClipboardController.swift:32,246,250,268`; synthetic ⌘V `:276-283`.
   - Pasteboard polling (`:130-151`) has no setup step.
   - Keychain item: `service local.utilitumus.clipboard`, `account history-key` (`Clipboard/ClipboardStore.swift:12-13,19-20`). No `kSecUseDataProtectionKeychain`, no access group, no explicit ACL.
3. **Where it runs:**
   - Utility: pasteboard timer (0.5 s), Carbon hot key (`:190`), `ClipboardPanel` (`Clipboard/ClipboardPanel.swift:392,472`, full-width `.nonactivatingPanel` at `.popUpMenu` with `sharingType = .none`), encrypted store, paste.
   - Launcher: `ClipboardView`.
   - The panel holds its own model and never crosses XPC. It needs no theme sync (no `dsThemed` in `Clipboard/`).
4. **Surface:** 10 props. 16 actions: `togglePanel`, `refreshPermissions`, `clearHistory`, `deleteSpace`, `setLimit`, `addSpace`, `renameSpace`, `setColor`, `moveSpace`, `addExcluded`, `removeExcluded`, `requestAccessibility`, `suspendHotKey`, `resumeHotKey`, `setHotKey`, `resetHotKey`.
   - The screen uses only total count, per-space counts, `historyCount` and the 5 recent rows (`ClipboardView.swift:60,88,104,179`). **The wire must not carry `items`.** Send counts and 5 trimmed rows.
5. **Coupling and data:**
   - Depends on Voice (gap 9). `Dashboard.swift:142,266-268`, `SetupStep.swift:166-168`.
   - Keys: `Clipboard.HotKeyCode`, `.HotKeyModifiers`, `.ExcludedApps`, `.Limit`.
   - Files: `~/Library/Application Support/Utilitumus/Clipboard/index.bin`, `img-<id>.bin`.
6. **Risk: high. Can lose or lock user data.**
   - The Keychain item was created by the hub. **Probe before writing any code:** whether the utility's identity can read it without a prompt, what a denial returns, and whether any status can be `errSecItemNotFound`. `key()` creates a new key on `errSecItemNotFound` (`ClipboardStore.swift:33-34`), and a store opened with a new key sets the old index aside (`:67-68`, `ClipboardController.swift:113`), which looks like lost history.
   - A Keychain prompt during `start()` blocks main (gap 4), so the launcher shows "Не отвечает".
   - `ClipboardStore` keeps everything in memory and rewrites the index, so two live instances mean last-writer-wins on real data (gap 7).
   - AX is optional, so handover is immediate and auto-paste silently degrades to "Скопировано — вставь ⌘V" until re-granted.
   - `VoiceHUD` must exist in the utility for that message (`:269`).
7. **Screen identity and open questions:** Q5 asks whether recent rows may cross XPC at all. **Probe:** `togglePanel` from the launcher button (`ClipboardView.swift:15`) with another process's non-activating panel: does it take the keyboard while the launcher is active, and where does paste go? Today panel and launcher share a process.

### 2.10 Вентиляторы (`fans`)

1. **Size:** 2149 lines in 8 files, plus `FanHelper/main.swift` 183, `Shared/SMC.swift` 134, `Shared/FanLink.swift` 47. Installed `utilitumus-fan` is 103 KB. No third-party dependencies.
2. **Permissions:**
   - Root service via `.privileged` XPC (`Shared/FanLink.swift:15`), already accepting `local.utilitumus.app.fans` (`:27`) with epoch (`:30`).
   - `NSAppleScript` with administrator privileges on install (`Fans/FanHelperInstaller.swift:229-231`), which needs the `automation.apple-events` entitlement.
   - SMC read without root through `SMC()`.
3. **Where it runs:**
   - Utility: 2 s tick, sensors, curves, hysteresis, safety trip, sleep/wake, GameMode (1 s while active, `GameModeController.swift:177`), installer, helper client.
   - Launcher: `FansView`.
   - **High-frequency state:** `fans`, `cpuSensors`, `gpuSensors` change almost every 2 s tick (`FanController.swift:338,342-343`). Push only while the screen or Dashboard is showing. The status line used by Dashboard changes at the same rate.
   - Sliders bind straight to `configs` (`FansView.swift:132,178`), with a persist debounce (`FanController.swift:90`). See Q4. Any rpm from the wire must be validated in the utility too, although the service clamps (`FanHelper/main.swift`, `hold`).
4. **Surface:** 15 props (`FanController` 8, `GameModeController` 5, `FanHelperInstaller` 2). 14 actions: set `fullPower`, set `configs`, `setAllAuto`, `restoreAutoBlocking` + `uninstall` (`FansView.swift:696`), `install`, `refresh`, `screenOpen`, set `game.isEnabled`, `addGame`, `removeGame`, `setLauncherGame`, `refreshRunning`, terminate conflicting app (`FansView.swift:582`, `NSRunningApplication` in `conflictingApp`, `FanController.swift:73`). `RunningCandidate` holds `NSImage`. `FanReading` and `SensorReading` need `Codable`.
5. **Coupling and data:**
   - **`Updater.swift:83-84` calls `FanController.shared.holdForUpdate()` and `resumeAfterFailedUpdate()`.** `MenuBar.swift:45,65-69`, `Dashboard.swift:138,154,220-237`, `App/ModuleRequirements.swift:22,26`, `SetupStep.swift:140-146,216`, `StoreModel.swift:35`, `UpdateBundle.swift:23-26`, `build.sh:57-62`. Depends on `ActionLog` in Load.
   - Keys: `FanConfigs`, `GameModeEnabled`, `GameModeMyGames`, `GameModeGameLaunchers`, `GameModeLiftedLaunchers`.
   - Files: `/Library/PrivilegedHelperTools/local.utilitumus.fan`, `/Library/LaunchDaemons/local.utilitumus.fan.plist`, `~/Library/Logs/Utilitumus/fans.log`.
6. **Risk: high. Hardware state and a privileged component.**
   - The service does not return fans to Auto when a client disconnects (`FanHelper/main.swift:155-160`, only an idle exit). The only recovery is `releaseStuckFans` on a later tick (`FanController.swift:430`). A killed utility leaves fans in manual until it starts again.
   - The Awake self-update restarts with `kickstart -k` (`AwakeApp.swift:254`). `SatelliteSelfUpdate.install` has no `beforeReplace` hook, and the hub path has one because "after replacing the bundle the service may not accept this process" (`Updater.swift:146`). The utility needs the same hold; copying Awake's restart path is unsafe.
   - `FanHelperInstaller.swift:95` compares versions for equality. The spec (line 217) says only a newer version installs and there is no downgrade. With a hub and a utility on different `helperVersion`, each would call the other's helper outdated and could ask for a password back and forth. Fix this before two bundles carry the helper.
   - The admin dialog must move off main (gap 4).
7. **Screen identity:** `FansView.swift:692` says quitting Utilitumus returns fans to Auto. That stops being true. `FansView.swift:581` names Utilitumus. Password dialog wording comes from the calling app's name. See Q2. Moving SMC reads out of the hub also empties the `MenuBar`/`Dashboard` quick controls (gap 3).

---

## 3. Permissions and grants that break on move

The spec accepts that each utility is a new identity for macOS (`local.utilitumus.app.<id>`), so grants given to `local.utilitumus` do not carry over.

| Grant | Today | After the move |
|---|---|---|
| Accessibility | 1 entry: Utilitumus | 4 entries: Мышь, Стеш, Голос, Буфер |
| Input Monitoring | 1 entry | Клавиатура, possibly Мышь (**Probe**) |
| Microphone | 1 entry | Голос |
| System audio capture | 1 entry | Микшер |
| Keychain | item created by hub | Буфер (**Probe**) |

Required steps keep the built-in module running until granted: Мышь, Стеш, Клавиатура, Голос mic. Steps that do not block handover, so function degrades immediately: Голос Accessibility, Буфер Accessibility, Микшер capture.

---

## 4. Security checks that weaken unless changed

- **Helper identity.** `UpdateBundle.verify` separately checks `local.utilitumus.links`, `.fan`, `.voice` (`App/UpdateBundle.swift:17-30`), and its comment explains why: nested code is sealed, but its signer's identity is not checked. `SatelliteInstaller.liveVerify` (`App/Satellites/SatelliteInstaller.swift:77-79`) and `SatelliteSelfUpdate.install` (`Kit/SatelliteSelfUpdate.swift:37`) check only the outer bundle. Those plus `install.sh` need the per-helper check when a helper moves.
- **Requirement label.** Each `Sources/Apps/<X>/Info.plist` must carry `UtilitumusSecurityEpoch` (`Apps/Awake/Info.plist`), or the XPC peer requirement rejects it (`Kit/KitSigning.swift:24-26`).
- **Action validation.** Awake's rules must repeat per module: size limit, enum decode, value range, errors with no state change (`Modules/Awake/AwakeWire.swift:50-68`). Free-form strings arrive in `renameSpace`, `addSpace`, `addExcluded`, `addRule`, `addScenario`. Numbers arrive in `setVolume`, fan `configs`, mouse `speed`.
- **Launcher as a client of powerful actions.** Stash force-terminate and Load stop or bots must take ids resolved inside the utility, never paths, pids from stale lists or argv.
- **Self-protection** (gap 5).
- **Status pings reveal activity.** `DistributedNotificationCenter` is unauthenticated (`Kit/Link/LinkProtocol.swift:22-26`). A ping on each `objectWillChange` tells any local app when dictation starts or something is copied. Coalesce, and do not post per event.

---

## 5. How much of Awake repeats

| Piece | Lines | Module-specific | Reusable |
|---|---|---|---|
| `App/Satellites/RemoteAwakeModel.swift` | 108 | 16 (`:25-28,42-53`) | 92 |
| `App/Satellites/RemoteAwakePage.swift` | 37 | names only | 37 after parameterising |
| `Modules/Awake/AwakeWire.swift` | 71 | 47 | 24 |
| `Apps/Awake/AwakeApp.swift` | 325 | 29 lines mention controller, status or title | ~296 |
| `Apps/Awake/main.swift` | 24 | ~2 | ~22 |
| Reusable total | | | **~470 per module, ~4,700 over 10 copies** |
| Tests: `AwakeRemoteCheck.swift`, `run-awake-remote-check.sh`, `run-awake-app-check.sh` | 1003 | not separated here | mostly harness |

The ~470 and ~4,700 figures are arithmetic on these counts, not a measurement of finished code.

The module-specific part cannot be shared but is mechanical: 97 props and 114 actions, each written in the model protocol, the wire state or action enum, the handler and the remote forwarder. At the rate Awake used (about 4 places per prop, 4 to 6 per action) that is about 1,000 lines overall, weighted toward Load, Keyboard, Fans, Voice and Clipboard.

---

## 6. Do these once, before the first module

Ideally before `awake-v1.0.0` and hub 0.6.0 ship (they are unreleased). `LinkClient.decodeHello` requires an exact `protocolVersion` (`Kit/Link/LinkClient.swift:71`), so any protocol change after release breaks every installed utility until hub and utility update together.

1. **Generic remote model** in `App/Satellites`: `RemoteModuleModel<State, Action>` holding `state`, `responding`, `actionError`, tickets, `read`, `perform`, off-main decode for large payloads. Also a `RemoteModulePage<Content>`. Tolerate one failed read before switching the page.
2. **Generic utility host** in `Kit`: everything in `AwakeApp` except the module, driven by a small `SatelliteModule` protocol: `id`, `start`, `stop`, `stopForUpdate`, `statusLine`, `setup`, `state()`, `handle(Data) -> Data`, `changes`, `windowRoot`. Passive means stopped (gap 7).
3. **Wire helpers** in `Kit`: identity enum, reply envelope, size limit, encoded-or-empty.
4. **Protocol v3:**
   - Setup steps in status, with a "perform step" action.
   - `attention` and quick action in status (gap 3).
   - A separate `stateChanged` ping that does not go through registry polling and is throttled.
   - A screen lease tied to the connection, ended on invalidation.
   - `quit(reason)` for update versus uninstall.
   - A rule for skew between hub and utility (Q3).
5. **Move shared bits to `Kit`:**
   - `onPageActive` and `pageActive`.
   - `VoiceHotKey`, `HotKeyRecorder`, `HotKeyTarget`, `VoiceExcludedApps`, and `VoiceHUD` (or a smaller message HUD).
   - `ActionLog.preparePrivate`.
   - Move `extension ClipboardController: HotKeyTarget` into Clipboard. Replace the `AccessState` call in Keyboard with a callback.
6. **Shared self-identity:** `Kit.ownBundleIDs` and `Kit.isOurs`, used at every site in gap 5.
7. **Build manifest** for `scripts/build-app.sh`: per-app extra sources, entitlements, nested helpers signed inner-first. `build.sh:53` links CoreAudio, AudioToolbox and IOKit explicitly while `build-app.sh:70` links only SwiftUI and AppKit. Awake links IOKit by import alone, so autolinking may cover this; check it at the first audio module.
8. **Installer:** per-helper identity check (§4); fan helper version direction (2.10).
9. **Guard test:** in the style of `Tests/run-kit-boundary-check.sh`, fail if a migrated module contains `UserDefaults.standard` or `= .standard`. Plus a test harness generalised from the 1003 Awake lines.
10. **Hub stubs:** see §7.

---

## 7. Parallel work and shared files

**Disjoint work.** After §6, each module edits only `Modules/<X>`, `Apps/<X>`, its `Remote<X>` file and its own tests.

| Stage | Modules | Note |
|---|---|---|
| Parallel A | Звук, Мышь, Микшер, Стеш | Disjoint folders. Do Звук first alone to prove the helper. |
| Parallel B | Клавиатура, Нагрузка | Disjoint. |
| Serial | Браузер, Голос, Вентиляторы | Each moves a helper, so each edits `build.sh`, `App/UpdateBundle.swift`, `install.sh` and the installer checks. |
| Serial | Буфер | After the Keychain probe. Disjoint from Голос only once item 5 of §6 is done. |

Serial items can overlap with parallel ones. They collide only with each other.

**Shared files every migration would touch, and how to avoid conflicts:**

| File | Conflict | Avoidance |
|---|---|---|
| `App/UtilitumusApp.swift:9-13,276` | a `case` per module, a refresh per module | Prep commit adds all 10 cases, each calling its own `Remote<X>Page`. Replace `:276` with a loop over a registry. |
| `App/Design/Dashboard.swift:136-193` | `source`, `perform`, `compute` | Prep commit moves external modules to status-driven data (protocol v3). |
| `App/MenuBar.swift:45-90` | quick sections | Same, driven by `status` quick actions. |
| `App/Setup/SetupStep.swift:134-187` | per-module steps | Prep commit: remote steps for external modules, one code path. |
| `App/Store/StoreModel.swift` | Voice specifics | Only Голос touches it after the prep. |
| `App/ModuleManager.swift`, `ModuleHooks+Live.swift` | hook behaviour | Prep commit adds "handover stop". Hooks stay until code removal. |
| `scripts/build-app.sh` | per-app flags | Per-app manifest file in `Apps/<X>/`, so the script no longer changes. |
| `build.sh` | helper builds and sources | Serial stage only. |
| `Catalog/catalog.json`, `Resources/WhatsNew.json`, `Info.plist` version | release edits | Written only by `scripts/release-app.sh`, which requires `HEAD == origin/main`. Release one at a time, not from branches. |
| `Tests/` shared scripts | list of checks | One new file per module, no shared list. |

Use a separate worktree per module from the post-§6 commit and merge in order, re-running `Tests/run-hub-e2e.sh` at each merge.

---

## 8. Open design questions

Each is a decision for the author. I did not guess.

- **Q1. Who draws the checklist before handover?** Until handover, the launcher shows the built-in screen, and that screen's checklist reads the launcher's grants. The grant has to happen somewhere. Options: the utility's own window, a launcher screen backed by the utility's steps, or a special phase in the Store. It also needs a decision on whether a required step that a user doesn't need (mouse default settings) should block handover forever.
- **Q2. What does "quit Utilitumus" mean now?** `FansView.swift:692` and `MixerView.swift:226` promise that everything returns to normal on exit. A launcher quit no longer stops utilities (spec goal: utilities outlive it). Change the text, or have a launcher quit stop some modules?
- **Q3. Skew between hub and utility.** Screens compile into the hub and state comes from a separately updated utility. A new required `State` field fails to decode and flips the tab to "Не отвечает". Options: optional-only additions, a `moduleWire` version per module, or a `minHub` per catalog entry. Also: a screen change now always needs a hub release.
- **Q4. Slider feedback.** Awake's "show the reply" rule makes Mouse and Fans sliders lag. Options: a local drag value everywhere, as `MixerRow` already has, or optimistic state in the generic model. Pixel tests would not catch this.
- **Q5. May clipboard text reach the launcher?** The amendment allows "what the screen shows", and the screen shows 5 recent rows. The alternative is showing only counts and kinds, which changes the screen.
- **Q6. Voice "Проверить" field.** Options: send recognised text to the launcher for that field only (a new text path out of the utility), rely on AX paste (needs the grant first), or change the section.
- **Q7. Does Браузер need a utility process?** Its work already runs in Links.app, it needs no TCC grants and its settings are already a shared domain. Options: a thin utility that only packages the helper with no XPC model (launcher keeps the current screen), or a full model for consistency. Also: which bundle owns the handler during the transition?
- **Q8. Launcher crash during lease.** How quickly should the utility fall back (hot key suspended, 1 s polling)? Tied to the connection, or a timeout?
- **Q9. Quick actions and confirmation.** Should Dashboard and menu-bar actions run through `moduleAction`? The Stash confirmation needs the list of names, so status alone isn't enough.
- **Q10. Model protocol or state and action?** Awake uses a per-module protocol and a generic view. Load has four observed objects (`LoadStore`, `BackgroundStore`, `LiveStats`, `ChartHover`), and Sound and Fans have several. Options: nested generics, or a single store of `State` plus `send(Action)` used by both built-in and remote variants. The second reduces the 1,000-line forwarding estimate but rewrites more view bindings now.
- **Q11. Removing built-in code later.** `FnSystemAction.restore()` in `ModuleManager.swift:63`, `MicGuardMigration`, and `FanController.shared` as `@ObservedObject` in `MenuBar.swift:45` all keep controller code live in the hub, and `.shared` instantiates controllers even when external. Should controllers be split from pure types now, or at stage 5 of the spec's migration steps?

## 9. Not established by this survey

- Payload sizes and CPU cost of XPC and JSON for Load and Fans: nothing was run.
- macOS behaviour marked **Probe** above: the Keychain item from another identity, two Links copies under one bundle id, Input Monitoring for `IOHIDManagerOpen`, a non-activating panel opened from another app's button, icon equality.
- What happens to Mixer's muted audio if the utility is killed. The tap and aggregate are private (`Mixer/ProcessTap.swift:91,102`), but the code does not show cleanup after a kill.
- `Tests/` coverage for each module beyond file names.
