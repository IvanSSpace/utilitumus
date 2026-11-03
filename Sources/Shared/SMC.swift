import Foundation
import IOKit

/// Минимальный клиент AppleSMC (контроллер вентиляторов и датчиков).
/// Используется и приложением (чтение — без прав), и `utilitumus-fan`
/// (запись — только от root, иначе SMC отвечает kIOReturnNotPrivileged).
///
/// Раскладка структуры обязана совпадать с C-структурой `SMCKeyData_t` ядра
/// (80 байт). Swift кладёт поля в хвостовой padding вложенных структур, C —
/// нет, поэтому в `KeyInfo` явный `pad`: без него `result` съезжает на 37-й
/// байт вместо 40-го и все вызовы молча возвращают «ключа нет».
final class SMC {
    private struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
    private struct PLimitData { var version: UInt16 = 0, length: UInt16 = 0, cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0 }
    private struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0, pad: (UInt8, UInt8, UInt8) = (0, 0, 0) }
    private typealias Bytes32 = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                 UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                 UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                 UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    private struct KeyData {
        var key: UInt32 = 0
        var version = Version()
        var pLimitData = PLimitData()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0, pad: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes32 = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                              0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private enum Command: UInt8 {
        case readKey = 5
        case writeKey = 6
        case keyInfo = 9
    }

    private var connection: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit {
        IOServiceClose(connection)
    }

    // MARK: - Типизированный доступ

    func float(_ key: String) -> Float? {
        guard let (type, bytes) = read(key), type == "flt ", bytes.count == 4 else { return nil }
        return bytes.withUnsafeBytes { $0.load(as: Float.self) }
    }

    func uint8(_ key: String) -> UInt8? {
        guard let (type, bytes) = read(key), type == "ui8 ", bytes.count == 1 else { return nil }
        return bytes[0]
    }

    @discardableResult
    func setFloat(_ key: String, _ value: Float) -> Bool {
        write(key, withUnsafeBytes(of: value) { Array($0) })
    }

    @discardableResult
    func setUInt8(_ key: String, _ value: UInt8) -> Bool {
        write(key, [value])
    }

    // MARK: - Сырой доступ

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var outputSize = MemoryLayout<KeyData>.stride
        let status = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<KeyData>.stride, &output, &outputSize)
        guard status == KERN_SUCCESS, output.result == 0 else { return nil }
        return output
    }

    private func info(_ key: String) -> KeyInfo? {
        var input = KeyData()
        input.key = Self.fourCC(key)
        input.data8 = Command.keyInfo.rawValue
        return call(&input)?.keyInfo
    }

    private func read(_ key: String) -> (type: String, bytes: [UInt8])? {
        guard let info = info(key) else { return nil }
        var input = KeyData()
        input.key = Self.fourCC(key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Command.readKey.rawValue
        guard let output = call(&input) else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.dataSize))) }
        return (Self.string(info.dataType), bytes)
    }

    private func write(_ key: String, _ bytes: [UInt8]) -> Bool {
        guard let info = info(key), Int(info.dataSize) == bytes.count else { return false }
        var input = KeyData()
        input.key = Self.fourCC(key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Command.writeKey.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { buffer in
            for (i, byte) in bytes.enumerated() { buffer[i] = byte }
        }
        return call(&input) != nil
    }

    private static func fourCC(_ key: String) -> UInt32 {
        key.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func string(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, encoding: .ascii) ?? ""
    }
}
