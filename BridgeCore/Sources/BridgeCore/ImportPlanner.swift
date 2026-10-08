import Foundation

public struct StoredReading: Sendable {
    public let id: String
    public let valueMgDl: Double
    public let version: Int

    public init(id: String, valueMgDl: Double, version: Int) {
        self.id = id
        self.valueMgDl = valueMgDl
        self.version = version
    }
}

public struct PlannedWrite: Sendable {
    public let reading: GlucoseReading
    public let version: Int
}

public struct ImportPlan: Sendable {
    public let writes: [PlannedWrite]
}

public enum ImportPlanningError: Error, LocalizedError {
    case invalidStoredVersion
    public var errorDescription: String? { "error.import.invalidStoredVersion" }
}

public enum ImportPlanner {
    public static func plan(readings: [GlucoseReading], existing: [StoredReading]) throws -> ImportPlan {
        var stored: [String: StoredReading] = [:]
        for sample in existing {
            if let previous = stored[sample.id], previous.version >= sample.version { continue }
            stored[sample.id] = sample
        }
        var writes: [PlannedWrite] = []
        var visited: Set<String> = []
        for reading in readings {
            guard visited.insert(reading.id).inserted else { continue }
            if let old = stored[reading.id] {
                guard old.version > 0, old.version < Int.max else { throw ImportPlanningError.invalidStoredVersion }
                if abs(old.valueMgDl - reading.valueMgDl) >= 0.000001 {
                    writes.append(PlannedWrite(reading: reading, version: old.version + 1))
                }
            } else {
                writes.append(PlannedWrite(reading: reading, version: 1))
            }
        }
        return ImportPlan(writes: writes)
    }
}
