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
check("требование к собеседнику ждёт «\(seam ? "test.1" : "1")»",
      requirement.hasSuffix(#"info["UtilitumusSecurityEpoch"] = "\#(seam ? "test.1" : "1")""#), requirement)
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
