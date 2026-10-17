import Foundation
import Testing
@testable import BridgeCore

private let past = TimestampParser.parse("10/6/2026 6:30:00 AM")!
private let now = TimestampParser.parse("10/6/2026 7:00:00 AM")!
private func raw(_ timestamp: String = "10/6/2026 6:30:00 AM", value: Double? = 108,
                 high: Bool? = false, low: Bool? = false) -> RawMeasurement {
    RawMeasurement(factoryTimestamp: timestamp, localTimestamp: "10/6/2026 8:30:00 AM",
                   valueMgDl: value, isHigh: high, isLow: low)
}

@Test func factoryTimestampUsesUTC() {
    #expect(past.timeIntervalSince1970 == 1_791_268_200)
    let formatter = ISO8601DateFormatter()
    #expect(formatter.string(from: past) == "2026-10-06T06:30:00Z")
    #expect(formatter.string(from: TimestampParser.parse("10/6/2026 12:00:00 AM")!) == "2026-10-06T00:00:00Z")
    #expect(formatter.string(from: TimestampParser.parse("10/6/2026 12:00:00 PM")!) == "2026-10-06T12:00:00Z")
    #expect(formatter.string(from: TimestampParser.parse("10/25/2026 1:30:00 AM")!) == "2026-10-25T01:30:00Z")
}

@Test(arguments: ["", "06/10/26", "2/29/2026 1:00:00 AM", "13/1/2026 1:00:00 AM",
                  "2/30/2026 1:00:00 AM", "1/1/2026 0:00:00 AM", "1/1/2026 13:00:00 PM", "1/1/2026 1:60:00 AM"])
func rejectsInvalidTimestamps(_ value: String) { #expect(TimestampParser.parse(value) == nil) }

@Test func acceptsLeapDay() { #expect(TimestampParser.parse("2/29/2028 1:00:00 AM") != nil) }

@Test func normalizationExcludesUnsafeReadingsAndDeduplicates() {
    let batch = ReadingNormalizer.normalize(history: [raw(), raw(), raw("10/6/2026 6:00:00 AM", high: true),
                                                      raw("10/6/2026 6:01:00 AM", low: true), raw("10/6/2026 6:02:00 AM", high: nil),
                                                      raw("10/6/2026 6:03:00 AM", value: nil), raw("10/6/2026 8:00:00 AM"), raw("bad")],
                                            latest: raw(value: 109), patientID: "patient-a", now: now)
    #expect(batch.readings.count == 1)
    #expect(batch.readings.first?.valueMgDl == 109)
    #expect(batch.overlapCount == 2)
    #expect(batch.skippedCount == 6)
    for reason in SkipReason.allCases { #expect(batch.skipped[reason] == 1) }
}

@Test func flaggedLatestReplacesValidHistoryBeforeNormalization() {
    let batch = ReadingNormalizer.normalize(history: [raw()], latest: raw(high: true), patientID: "p", now: now)
    #expect(batch.readings.isEmpty)
    #expect(batch.skipped[.flaggedHigh] == 1)
}

@Test(arguments: [0.0, -1, Double.infinity, Double.nan, 1e20, 1001])
func invalidGlucoseIsExcluded(_ value: Double) {
    #expect(ReadingNormalizer.exclusion(raw(value: value), now: now) == .invalidValue)
}

@Test func oversizedLatestCannotBeValidatedOrImported() {
    let measurement = raw(value: 1e20)
    let preview = MeasurementPreview(raw: measurement, now: now)
    #expect(!preview.canValidate)
    #expect(preview.valueMgDl == nil)
    let batch = ReadingNormalizer.normalize(history: [], latest: measurement, patientID: "p", now: now)
    #expect(batch.readings.isEmpty)
    #expect(batch.skipped[.invalidValue] == 1)
}

@Test func malformedRecordDoesNotDiscardTheWholeHistory() throws {
    let bytes = Data(#"[{"FactoryTimestamp":"10/6/2026 6:30:00 AM","ValueInMgPerDl":108,"isHigh":false,"isLow":false},{"ValueInMgPerDl":"108"},null]"#.utf8)
    let records = try JSONDecoder().decode([RawMeasurement].self, from: bytes)
    let batch = ReadingNormalizer.normalize(history: records, latest: nil, patientID: "p", now: now)
    #expect(batch.readings.count == 1)
    #expect(batch.skippedCount == 2)
}

@Test func unitsUseExplicitMgDlField() throws {
    let bytes = Data(#"{"FactoryTimestamp":"10/6/2026 6:30:00 AM","ValueInMgPerDl":108,"Value":6,"GlucoseUnits":1,"isHigh":false,"isLow":false}"#.utf8)
    let measurement = try JSONDecoder().decode(RawMeasurement.self, from: bytes)
    #expect(measurement.valueMgDl == 108)
    #expect(abs(GlucoseUnit.mmolL.value(fromMgDl: 108) - 5.994) < 0.001)
    #expect(GlucoseUnit.mgDl.value(fromMgDl: 108) == 108)
}

@Test func readingIDsAreStableAndPatientSpecific() {
    let a = GlucoseReading(patientID: "a", timestamp: past, valueMgDl: 108)
    let correction = GlucoseReading(patientID: "a", timestamp: past, valueMgDl: 109)
    let b = GlucoseReading(patientID: "b", timestamp: past, valueMgDl: 108)
    #expect(a.id == correction.id)
    #expect(a.id != b.id)
    #expect(a.id.hasPrefix("libre-health-bridge.v1."))
}

@Test func plannerHandlesNewRepeatedAndCorrectedSamples() throws {
    let a = GlucoseReading(patientID: "a", timestamp: past, valueMgDl: 108)
    let b = GlucoseReading(patientID: "a", timestamp: past.addingTimeInterval(60), valueMgDl: 110)
    let c = GlucoseReading(patientID: "a", timestamp: past.addingTimeInterval(120), valueMgDl: 111)
    let plan = try ImportPlanner.plan(readings: [a, a, b, c], existing: [
        StoredReading(id: a.id, valueMgDl: 108, version: 1),
        StoredReading(id: b.id, valueMgDl: 109, version: 2)
    ])
    #expect(plan.writes.count == 2)
    #expect(plan.writes.first?.reading.id == b.id)
    #expect(plan.writes.first?.version == 3)
    #expect(plan.writes.last?.reading.id == c.id)
    #expect(plan.writes.last?.version == 1)
    let second = try ImportPlanner.plan(readings: [a, b, c], existing: [
        StoredReading(id: a.id, valueMgDl: 108, version: 1)
    ] + plan.writes.map { StoredReading(id: $0.reading.id, valueMgDl: $0.reading.valueMgDl, version: $0.version) })
    #expect(second.writes.isEmpty)
}

@Test func plannerUsesHighestVersionAndRejectsOverflow() throws {
    let a = GlucoseReading(patientID: "a", timestamp: past, valueMgDl: 108)
    let plan = try ImportPlanner.plan(readings: [a], existing: [
        StoredReading(id: a.id, valueMgDl: 100, version: 1), StoredReading(id: a.id, valueMgDl: 108, version: 2)
    ])
    #expect(plan.writes.isEmpty)
    #expect(throws: ImportPlanningError.self) {
        try ImportPlanner.plan(readings: [a], existing: [StoredReading(id: a.id, valueMgDl: 108, version: Int.max)])
    }
}

private actor MockTransport: CloudTransport {
    private var replies: [HTTPResult]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [HTTPResult]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> HTTPResult {
        requests.append(request)
        guard !replies.isEmpty else { throw CloudError.network }
        return replies.removeFirst()
    }
}

private func reply(_ body: String, status: Int = 200) -> HTTPResult {
    HTTPResult(status: status, data: Data(body.utf8))
}
private let loginReply = reply(#"{"status":0,"data":{"user":{"id":"synthetic-account"},"authTicket":{"token":"synthetic-token"}}}"#)
private let connectionsReply = reply(#"{"status":0,"data":[{"patientId":"patient-a","firstName":"Test","glucoseMeasurement":{"FactoryTimestamp":"10/6/2026 6:30:00 AM","ValueInMgPerDl":108,"isHigh":false,"isLow":false}}]}"#)
private func client(_ transport: MockTransport) -> LibreCloudClient {
    LibreCloudClient(credentials: Credentials(email: "test@example.com", password: "test-password"), transport: transport)
}

@Test func cloudLoginHandlesRegionAndHashedAccountHeader() async throws {
    let mock = MockTransport([
        reply(#"{"status":0,"data":{"redirect":true,"region":"eu"}}"#), loginReply, connectionsReply
    ])
    let connections = try await client(mock).connections()
    #expect(connections.first?.patientId == "patient-a")
    let requests = await mock.requests
    #expect(requests.count == 3)
    #expect(requests[0].url?.host == "api.libreview.io")
    #expect(requests[1].url?.host == "api-eu.libreview.io")
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
    #expect(requests[2].value(forHTTPHeaderField: "account-id") == sha256("synthetic-account"))
    #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
    #expect(requests[2].httpBody == nil)
}

@Test func rejectsMaliciousRegion() async {
    let mock = MockTransport([reply(#"{"status":0,"data":{"redirect":true,"region":"eu.attacker.example/"}}"#)])
    await #expect(throws: CloudError.regionalRedirect) { try await client(mock).login() }
    #expect(await mock.requests.count == 1)
}

private struct CancelledTransport: CloudTransport {
    func send(_ request: URLRequest) async throws -> HTTPResult { throw URLError(.cancelled) }
}

@Test func urlCancellationRemainsCancellation() async {
    let api = LibreCloudClient(credentials: Credentials(email: "test@example.com", password: "x"),
                               transport: CancelledTransport())
    await #expect(throws: CancellationError.self) { try await api.login() }
}

@Test func redirectLoopsStop() async {
    let redirect = reply(#"{"status":0,"data":{"redirect":true,"region":"eu"}}"#)
    let mock = MockTransport([redirect, redirect])
    await #expect(throws: CloudError.regionalRedirect) { try await client(mock).login() }
    #expect(await mock.requests.count == 2)
}

@Test func termsAreNeverAcceptedAutomatically() async {
    let mock = MockTransport([reply(#"{"status":4,"data":{"private":"secret"}}"#)])
    await #expect(throws: CloudError.termsRequired) { try await client(mock).login() }
    #expect(await mock.requests.count == 1)
}

@Test func refreshesAuthenticationOnce() async throws {
    let mock = MockTransport([loginReply, reply("{}", status: 401), loginReply, connectionsReply])
    #expect(try await client(mock).connections().count == 1)
    #expect(await mock.requests.count == 4)
}

@Test func repeatedUnauthorizedStops() async {
    let mock = MockTransport([loginReply, reply("{}", status: 401), loginReply, reply("{}", status: 401)])
    await #expect(throws: CloudError.http(401)) { try await client(mock).connections() }
    #expect(await mock.requests.count == 4)
}

@Test func rateLimitsStopWithoutRetry() async {
    let mock = MockTransport([reply("{}", status: 429)])
    await #expect(throws: CloudError.rateLimited) { try await client(mock).login() }
    #expect(await mock.requests.count == 1)
}

@Test func rateLimitPreservesValidServerRetryDate() async {
    let until = Date(timeIntervalSince1970: 2_000_010_000)
    let mock = MockTransport([HTTPResult(status: 429, data: Data(), retryAfter: until)])
    await #expect(throws: CloudError.rateLimitedUntil(until)) { try await client(mock).login() }
    #expect(await mock.requests.count == 1)
}

@Test func errorBodiesAreNotExposed() async {
    let mock = MockTransport([reply(#"{"status":2,"error":{"message":"SECRET"}}"#)])
    do { try await client(mock).login(); Issue.record("Login unexpectedly succeeded") }
    catch {
        #expect(error as? CloudError == .invalidCredentials)
        #expect(!error.localizedDescription.contains("SECRET"))
    }
}

@Test func wrongPatientGraphIsRejected() async throws {
    let mock = MockTransport([loginReply, connectionsReply,
                              reply(#"{"status":0,"data":{"connection":{"patientId":"patient-b"},"graphData":[]}}"#)])
    let api = client(mock)
    let connection = try #require(try await api.connections().first)
    await #expect(throws: CloudError.wrongPatient) { try await api.snapshot(for: connection, now: now) }
}

@Test func snapshotPrefersFresherLatestEndpoint() async throws {
    let mock = MockTransport([loginReply, connectionsReply,
                              reply(#"{"status":0,"data":{"connection":{"patientId":"patient-a","glucoseMeasurement":{"FactoryTimestamp":"10/6/2026 6:20:00 AM","ValueInMgPerDl":107,"isHigh":false,"isLow":false}},"graphData":[]}}"#)])
    let api = client(mock)
    let connection = try #require(try await api.connections().first)
    let snapshot = try await api.snapshot(for: connection, now: now)
    #expect(snapshot.preview?.timestamp == past)
    #expect(snapshot.preview?.valueMgDl == 108)
    #expect(snapshot.batch.readings.count == 1)
}

@Test func equalTimestampCorrectionFromGraphWins() async throws {
    let mock = MockTransport([loginReply, connectionsReply,
                              reply(#"{"status":0,"data":{"connection":{"patientId":"patient-a","glucoseMeasurement":{"FactoryTimestamp":"10/6/2026 6:30:00 AM","ValueInMgPerDl":109,"isHigh":false,"isLow":false}},"graphData":[]}}"#)])
    let api = client(mock)
    let connection = try #require(try await api.connections().first)
    let snapshot = try await api.snapshot(for: connection, now: now)
    #expect(snapshot.preview?.valueMgDl == 109)
    #expect(snapshot.batch.readings.first?.valueMgDl == 109)
}

@Test func httpRedirectResponseIsNotTreatedAsLoginSuccess() async {
    let mock = MockTransport([reply("{}", status: 302)])
    await #expect(throws: CloudError.http(302)) { try await client(mock).login() }
    #expect(await mock.requests.count == 1)
}

@Test func missingGraphDataIsAnErrorRatherThanAnEmptySuccess() async throws {
    let mock = MockTransport([loginReply, connectionsReply, reply(#"{"status":0,"data":{}}"#)])
    let api = client(mock)
    let connection = try #require(try await api.connections().first)
    await #expect(throws: CloudError.invalidResponse) { try await api.snapshot(for: connection, now: now) }
}
