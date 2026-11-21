import Foundation

// Печатает плист агента так, как его пишет установщик центра: Tests/run-studio-install-check.sh сверяет с ним scripts/install-personal.sh.
FileHandle.standardOutput.write(SatelliteAgent.plist(id: "studio", executable: URL(fileURLWithPath: CommandLine.arguments[1])))
