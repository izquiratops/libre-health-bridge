import Foundation

public enum TimestampParser {
    private static let regex = try! NSRegularExpression(pattern: #"^(\d{1,2})/(\d{1,2})/(\d{4}) (\d{1,2}):(\d{2}):(\d{2}) (AM|PM)$"#)
    /// LibreLinkUp's FactoryTimestamp uses US ordering and, per reference clients, UTC.
    /// Never parse the display Timestamp with the phone's timezone or locale.
    public static func parse(_ input: String?) -> Date? {
        guard let input,
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input))
        else { return nil }
        let ns = input as NSString
        let parts = (1 ... 6).compactMap { Int(ns.substring(with: match.range(at: $0))) }
        guard parts.count == 6 else { return nil }
        let (month, day, year, hour, minute, second) = (parts[0], parts[1], parts[2], parts[3], parts[4], parts[5])
        guard (2000 ... 9999).contains(year), (1 ... 12).contains(month), (1 ... 31).contains(day),
              (1 ... 12).contains(hour), (0 ... 59).contains(minute), (0 ... 59).contains(second)
        else { return nil }
        let hour24 = hour % 12 + (ns.substring(with: match.range(at: 7)) == "PM" ? 12 : 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day, hour: hour24, minute: minute, second: second)
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day,
              roundTrip.hour == hour24, roundTrip.minute == minute, roundTrip.second == second
        else { return nil }
        return date
    }
}

public enum ReadingNormalizer {
    public struct Validation {
        public let timestamp: Date?
        public let exclusion: SkipReason?
    }

    public static func validate(_ raw: RawMeasurement, now: Date, timestamp: Date? = nil) -> Validation {
        let date = timestamp ?? TimestampParser.parse(raw.factoryTimestamp)
        guard let date else { return Validation(timestamp: nil, exclusion: .invalidTimestamp) }
        // Do not write future-dated medical records. The phone clock must be correct.
        guard date <= now else { return Validation(timestamp: date, exclusion: .futureTimestamp) }
        guard let high = raw.isHigh, let low = raw.isLow else {
            return Validation(timestamp: date, exclusion: .missingRangeFlags)
        }
        if high { return Validation(timestamp: date, exclusion: .flaggedHigh) }
        if low { return Validation(timestamp: date, exclusion: .flaggedLow) }
        // A supported numeric range is separate from the high/low sensor flags.
        guard let value = raw.valueMgDl, value.isFinite, (1 ... 1000).contains(value) else {
            return Validation(timestamp: date, exclusion: .invalidValue)
        }
        return Validation(timestamp: date, exclusion: nil)
    }

    public static func exclusion(_ raw: RawMeasurement, now: Date) -> SkipReason? {
        validate(raw, now: now).exclusion
    }

    public static func normalize(history: [RawMeasurement], latest: RawMeasurement?,
                                 patientID: String, now: Date) -> ReadingBatch {
        var unique: [Date: RawMeasurement] = [:]
        var skipped: [SkipReason: Int] = [:]
        var overlaps = 0
        // Latest replaces history before validation, including a new invalid/range flag.
        for raw in history + (latest.map { [$0] } ?? []) {
            guard let date = TimestampParser.parse(raw.factoryTimestamp) else {
                skipped[.invalidTimestamp, default: 0] += 1
                continue
            }
            if unique.updateValue(raw, forKey: date) != nil { overlaps += 1 }
        }
        var readings: [GlucoseReading] = []
        for (date, raw) in unique {
            if let reason = validate(raw, now: now, timestamp: date).exclusion {
                skipped[reason, default: 0] += 1
            } else if let value = raw.valueMgDl {
                readings.append(GlucoseReading(patientID: patientID, timestamp: date, valueMgDl: value))
            }
        }
        return ReadingBatch(readings: readings.sorted { $0.timestamp < $1.timestamp },
                            skipped: skipped, overlapCount: overlaps)
    }
}
