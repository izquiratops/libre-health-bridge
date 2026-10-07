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
    public let isUpdate: Bool
}

public struct ImportPlan: Sendable {
    public let writes: [PlannedWrite]
    public let alreadyImported: Int
    public var inserted: Int { writes.filter { !$0.isUpdate }.count }
    public var updated: Int { writes.filter(\.isUpdate).count }
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
        var alreadyImported = 0
        var visited: Set<String> = []
        for reading in readings {
            guard visited.insert(reading.id).inserted else { continue }
            if let old = stored[reading.id] {
                guard old.version > 0, old.version < Int.max else { throw ImportPlanningError.invalidStoredVersion }
                if abs(old.valueMgDl - reading.valueMgDl) < 0.000001 {
                    alreadyImported += 1
                } else {
                    writes.append(PlannedWrite(reading: reading, version: old.version + 1, isUpdate: true))
                }
            } else {
                writes.append(PlannedWrite(reading: reading, version: 1, isUpdate: false))
            }
        }
        return ImportPlan(writes: writes, alreadyImported: alreadyImported)
    }
}

public struct ImportReport: Codable, Sendable {
    public let completedAt: Date
    public let inserted: Int
    public let updated: Int
    public let alreadyImported: Int
    public let skipped: [SkipReason: Int]
    public var skippedCount: Int { skipped.values.reduce(0, +) }
    public var wroteSamples: Bool { inserted + updated > 0 }

    public init(completedAt: Date, inserted: Int, updated: Int, alreadyImported: Int, skipped: [SkipReason: Int]) {
        self.completedAt = completedAt
        self.inserted = inserted
        self.updated = updated
        self.alreadyImported = alreadyImported
        self.skipped = skipped
    }
}
