import CryptoKit
import Foundation

public struct Credentials: Codable, Sendable {
    public let email: String
    public let password: String

    public init(email: String, password: String) {
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password
    }
}

/// Tolerant field decoding lets the importer count and exclude malformed readings.
/// It never guesses a value, unit, timestamp, or missing range flag.
public struct RawMeasurement: Codable, Sendable {
    public let factoryTimestamp: String?
    public let localTimestamp: String?
    public let valueMgDl: Double?
    public let isHigh: Bool?
    public let isLow: Bool?

    enum CodingKeys: String, CodingKey {
        case factoryTimestamp = "FactoryTimestamp"
        case localTimestamp = "Timestamp"
        case valueMgDl = "ValueInMgPerDl"
        case isHigh, isLow
    }

    public init(factoryTimestamp: String?, localTimestamp: String? = nil,
                valueMgDl: Double?, isHigh: Bool? = false, isLow: Bool? = false) {
        self.factoryTimestamp = factoryTimestamp
        self.localTimestamp = localTimestamp
        self.valueMgDl = valueMgDl
        self.isHigh = isHigh
        self.isLow = isLow
    }

    public init(from decoder: any Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        factoryTimestamp = try? c?.decode(String.self, forKey: .factoryTimestamp)
        localTimestamp = try? c?.decode(String.self, forKey: .localTimestamp)
        valueMgDl = try? c?.decode(Double.self, forKey: .valueMgDl)
        isHigh = try? c?.decode(Bool.self, forKey: .isHigh)
        isLow = try? c?.decode(Bool.self, forKey: .isLow)
    }
}

public struct Connection: Decodable, Identifiable, Sendable {
    public let patientId: String
    public let firstName: String?
    public let lastName: String?
    public let glucoseMeasurement: RawMeasurement?
    public var id: String { patientId }
    public var displayName: String? {
        let name = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

public struct Graph: Decodable, Sendable {
    public let connection: Connection?
    public let graphData: [RawMeasurement]
}

public enum GlucoseUnit: String, CaseIterable, Codable, Sendable {
    case mgDl = "mg/dL"
    case mmolL = "mmol/L"

    public func value(fromMgDl value: Double) -> Double {
        self == .mgDl ? value : value / 18.0182
    }
}

public enum ReadingIdentity {
    public static let prefix = "libre-health-bridge.v1."
    public static func recognizes(_ id: String) -> Bool { id.hasPrefix(prefix) }
}

public struct GlucoseReading: Identifiable, Sendable, Equatable {
    public let id: String
    public let timestamp: Date
    public let valueMgDl: Double

    public init(patientID: String, timestamp: Date, valueMgDl: Double) {
        // Namespace and second-precision UTC identity are stable across app restarts.
        id = ReadingIdentity.prefix + sha256("\(patientID)\n\(Int64(timestamp.timeIntervalSince1970))")
        self.timestamp = timestamp
        self.valueMgDl = valueMgDl
    }
}

public enum SkipReason: String, Codable, CaseIterable, Sendable {
    case invalidTimestamp, futureTimestamp, missingRangeFlags, flaggedHigh, flaggedLow, invalidValue

}

public struct MeasurementPreview: Sendable {
    public let timestamp: Date?
    public let sourceLocalTimestamp: String?
    public let valueMgDl: Double?
    public let exclusion: SkipReason?
    public var canValidate: Bool { timestamp != nil && valueMgDl != nil && exclusion == nil }

    public init(raw: RawMeasurement, now: Date) {
        let validated = ReadingNormalizer.validate(raw, now: now)
        timestamp = validated.timestamp
        sourceLocalTimestamp = raw.localTimestamp
        exclusion = validated.exclusion
        valueMgDl = exclusion == nil ? raw.valueMgDl : nil
    }
}

public struct ReadingBatch: Sendable {
    public let readings: [GlucoseReading]
    public let skipped: [SkipReason: Int]
    public let overlapCount: Int
    public var skippedCount: Int { skipped.values.reduce(0, +) }
}

public struct CloudSnapshot: Sendable {
    public let patientID: String
    public let fetchedAt: Date
    public let historyCount: Int
    public let preview: MeasurementPreview?
    public let batch: ReadingBatch
}

public func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}
