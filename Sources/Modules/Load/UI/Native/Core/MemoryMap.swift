import Foundation

/// Доля сегмента полосы памяти: macOS, программа или «прочее».
struct SplitRow: Sendable, Codable, Equatable, Identifiable {
    /// «macos», «rest» или id группы.
    var key: String
    var name: String
    var mb: Int
    /// По нему подбирается цвет: один у программы во всех категориях.
    var colorKey: String
    var id: String { key }
}

/// Кандидат в «Что можно освободить»: группа с её памятью в RAM и сжатой.
struct FreeCandidate: Sendable, Codable, Equatable, Identifiable {
    var key: String
    var name: String
    var ramMB: Int
    var compressedMB: Int
    /// Подсказка, если кнопка «Остановить группу» не освободит и половины.
    var hint: String
    /// Группа, которую можно остановить кнопкой; nil — только подсказка.
    var stoppableGroup: String?
    var id: String { key }
    var totalMB: Int { ramMB + compressedMB }
}

struct RamSplitRow: Sendable, Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var kind: GroupKind
    var ramMB: Int
    var swappedMB: Int
}

struct CompressedRow: Sendable, Codable, Equatable, Identifiable {
    var pid: Int32
    var name: String
    var group: String
    var mb: Int
    var stoppable: Bool
    var uniqueID: UInt64 = 0
    var id: Int32 { pid }
    var rowID: LoadRowID { LoadRowID(pid: pid, uniqueID: uniqueID) }
}

struct WiredRow: Sendable, Codable, Equatable, Identifiable {
    var pid: Int32
    var name: String
    var mb: Double
    var id: Int32 { pid }
}

/// Карта памяти: из чего состоит «занято» и что можно освободить. Разбор по группам — оценки
/// процессов, они с vm_stat один в один не сходятся, поэтому доли подогнаны под итоги.
struct MemoryMap: Sendable, Codable, Equatable {
    var macosMB = 0
    var programsMB = 0
    var cacheMB = 0
    var wiredMB = 0
    var splitApp: [SplitRow] = []
    var splitCompressed: [SplitRow] = []
    var freeCandidates: [FreeCandidate] = []
    var appBreakdown: [RamSplitRow] = []
    var compressedBreakdown: [CompressedRow] = []
    var wiredBreakdown: [WiredRow] = []
    /// Сколько памяти в программах держат процессы всего и сколько из этого сжато или в свопе.
    var heldMB = 0
    var swappedMB = 0

    static let wiredNote = "Ядро, драйверы и видеопамять GPU. Уменьшится, если закрыть тяжёлые графические приложения"
    static let cachedNote = "Недавно прочитанные файлы. macOS отдаст эту память, когда понадобится"
    static let freeNote = "Не занята ничем. Мало свободной — нормально: macOS отдаёт её под кэш файлов."
}
