import Foundation

// Метка стенда: собирается дважды, с швом и без (KIT_TEST_DEFAULTS), и печатает, что видит. Подписей нет.
let fm = FileManager.default
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let seam: Bool = {
    #if KIT_TEST_DEFAULTS
    true
    #else
    false
    #endif
}()
var failed = false
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print((ok ? "ok   " : "ПРОВАЛ ") + (seam ? "[шов] " : "[боевая] ") + name + (ok ? "" : ": " + detail()))
    if !ok { failed = true }
}

func bundle(_ name: String, epoch: String?, binary: String) -> URL {
    let app = dir.appendingPathComponent(name + (seam ? "-seam" : "-prod")).appendingPathComponent("X.app")
    try? fm.removeItem(at: app)
    try! fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try! Data(binary.utf8).write(to: app.appendingPathComponent("Contents/MacOS/X"))
    var info: [String: Any] = ["CFBundleIdentifier": "local.utilitumus.app.x"]
    if let epoch { info[KitSigning.securityEpochKey] = epoch }
    (info as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
    return app
}
func epochAccepted(_ app: URL) -> Bool { (try? KitSigning.checkEpoch(of: app)) != nil }

let requirement = KitSigning.peerRequirement(identifier: "local.utilitumus", leafHash: "aa")
// Боевое требование: «>= 1» плюс верхняя граница, иначе «test.1» (для строкового сравнения больше «1») прошло бы как боевая.
let epochKey = #"info["UtilitumusSecurityEpoch"]"#
let expectedClause = seam ? #"\#(epochKey) = "test.1""# : #"\#(epochKey) >= "1" and \#(epochKey) < "a""#
check("требование к собеседнику: \(expectedClause)", requirement.hasSuffix(" and " + expectedClause), requirement)

/// Настоящий `codesign -v -R=`: бандл с меткой, подписанный ad-hoc (метка в Info.plist скреплена подписью), против одной оговорки о метке.
func codesignAccepts(epoch: String) -> Bool {
    let app = dir.appendingPathComponent("cs-\(epoch)-\(seam ? "seam" : "prod")").appendingPathComponent("X.app")
    try? fm.removeItem(at: app.deletingLastPathComponent())
    try! fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try! fm.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/X").path)
    let info: NSDictionary = ["CFBundleIdentifier": "local.utilitumus.app.x", "CFBundleExecutable": "X", KitSigning.securityEpochKey: epoch]
    info.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
    func run(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
    guard run(["--force", "--sign", "-", app.path]) == 0 else { return false }
    return run(["--verify", "-R=" + KitSigning.peerEpochClause, app.path]) == 0
}
check("codesign: метка 1 проходит требование", codesignAccepts(epoch: "1") == !seam)
check("codesign: метка 2 проходит требование", codesignAccepts(epoch: "2") == !seam)
check("codesign: метка 225 проходит требование (число, не строка)", codesignAccepts(epoch: "225") == !seam)
check("codesign: метка test.1 боевое требование не проходит", codesignAccepts(epoch: "test.1") == seam)
check("codesign: метка не из цифр «abc» не проходит", !codesignAccepts(epoch: "abc"))
check("метка стенда не равна боевой", KitSigning.testPeerEpoch != KitSigning.securityEpoch)

check("метка 1 читается", epochAccepted(bundle("e1", epoch: "1", binary: "x")))
check("метка 2 читается: будущие выпуски", epochAccepted(bundle("e2", epoch: "2", binary: "x")))
check("метки нет — отказ", !epochAccepted(bundle("e0", epoch: nil, binary: "x")))
check("метка стенда: боевая сборка отказывает, стенд принимает", epochAccepted(bundle("et", epoch: KitSigning.testPeerEpoch, binary: "x")) == seam)

let needle = ["local", "utilitumus", "test", "kit"].joined(separator: ".")
let clean = bundle("clean", epoch: "1", binary: "бинарник без шва")
let dirty = bundle("dirty", epoch: "1", binary: "\0\0" + needle + "\0")
check("бандл без шва проходит", (try? KitSigning.rejectTestSeam(in: clean)) != nil)
check("бандл со швом: боевая проверка отказывает, стенд пропускает", ((try? KitSigning.rejectTestSeam(in: dirty)) != nil) == seam)

exit(failed ? 1 : 0)
