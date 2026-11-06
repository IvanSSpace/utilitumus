import Foundation

// Крошечный процесс шва для run-stand-isolation-check.sh. Собирается с KIT_TEST_DEFAULTS и Sources/Kit/KitDefaults.swift.
//   probe <файл-вывода>   пишет пути, какие видит стенд
//   probe real-write      пытается пройти охрану с настоящим путём: должен упасть
let fm = FileManager.default
if CommandLine.arguments[1] == "real-write" {
    Kit.assertStandPath(Kit.realHome + "/Library/Application Support/Utilitumus/Voice/Models/gigaam", "проверка")
    print("НЕ УПАЛ")
    exit(0)
}
let lines = [
    "home=\(NSHomeDirectory())",
    "homeURL=\(fm.homeDirectoryForCurrentUser.path)",
    "appSupport=\(fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path)",
    "library=\(NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true)[0])",
    "realHome=\(Kit.realHome)",
    "guardTemp=\(Kit.standForbiddenRoot(of: NSTemporaryDirectory() + "x") ?? "ok")",
    "guardHomeFake=\(Kit.standForbiddenRoot(of: NSHomeDirectory() + "/Library/Logs/x") ?? "ok")",
    "guardApplications=\(Kit.standForbiddenRoot(of: "/Applications/Utilitumus/Awake.app") ?? "ok")",
    "guardLibrary=\(Kit.standForbiddenRoot(of: "/Library/PrivilegedHelperTools/local.utilitumus.fan") ?? "ok")",
    "guardRealLogs=\(Kit.standForbiddenRoot(of: Kit.realHome + "/Library/Logs/Utilitumus/fans.log") ?? "ok")",
    "guardTestPrefs=\(Kit.standForbiddenRoot(of: Kit.realHome + "/Library/Preferences/local.utilitumus.test.kit.plist") ?? "ok")",
]
try? (lines.joined(separator: "\n") + "\n").write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
