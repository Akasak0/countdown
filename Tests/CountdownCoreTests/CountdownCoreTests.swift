import Testing
import Foundation
@testable import CountdownCore

@Suite struct CountdownCoreTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    @Test func testTimeInputs() throws {
        checkEqual(try TimeSpecification.parse("9:5"), .clock(hour: 9, minute: 5, second: 0))
        checkEqual(try TimeSpecification.parse("09:05:03"), .clock(hour: 9, minute: 5, second: 3))
        checkEqual(try TimeSpecification.parse("9:5:3"), .clock(hour: 9, minute: 5, second: 3))
        checkEqual(try TimeSpecification.parse("1h30m"), .duration(5400))
        checkEqual(try TimeSpecification.parse("1h5s"), .duration(3605))
        checkEqual(try TimeSpecification.parse("90s"), .duration(90))
        checkEqual(try TimeSpecification.parse(" 90m\n"), .duration(5400))
    }

    @Test func testInvalidAndOverflowInputs() {
        for text in ["", "3", "1745", "24:00", "1:60", "1:2:60", "1:", "1:2:3:4", "-1m", "0s",
                     "1m2h", "1m2m", "1.5m", "1:30m", "3M", "１m", "1h 3m", "999999999999999999999999999999999999999999h"] {
            checkThrows(try TimeSpecification.parse(text), "Unexpected acceptance: \(text)")
        }
    }

    @Test func testClockRollsToNextDay() throws {
        let now = date("2026-11-08T18:00:00+09:00")
        let end = try TimeSpecification.parse("17:45").deadline(from: now, calendar: calendar)
        checkEqual(end, date("2026-11-09T17:45:00+09:00"))
        let today = try TimeSpecification.parse("19:00").deadline(from: now, calendar: calendar)
        checkEqual(today, date("2026-11-08T19:00:00+09:00"))
    }

    @Test func testDaylightSavingDoesNotAddFixed24Hours() throws {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        let now = date("2026-03-07T10:00:00-05:00")
        let end = try TimeSpecification.parse("9:00").deadline(from: now, calendar: c)
        checkEqual(end, date("2026-03-08T09:00:00-04:00"))
    }

    @Test func testSleepAndRestorePreserveOriginalDeadline() throws {
        let now = date("2026-11-08T14:00:00+09:00")
        var note = TimerNote()
        try note.start(input: "3m", specification: .duration(180), now: now, order: 1)
        let encoded = try JSONEncoder().encode(note)
        let restored = try JSONDecoder().decode(TimerNote.self, from: encoded)
        checkEqual(restored.remaining(at: now.addingTimeInterval(120)), 60)
        checkTrue(restored.isFinished(at: now.addingTimeInterval(300)))
        checkEqual(restored.deadline, now.addingTimeInterval(180))
    }

    @Test func testPauseResumeAndAbsoluteDeadline() throws {
        let now = date("2026-11-08T14:00:00+09:00")
        var note = TimerNote()
        try note.start(input: "3m", specification: .duration(180), now: now, order: 1)
        note.pause(at: now.addingTimeInterval(60))
        checkEqual(note.remaining(at: now.addingTimeInterval(500)), 120)
        let restored = try JSONDecoder().decode(TimerNote.self, from: JSONEncoder().encode(note))
        checkEqual(restored.pausedRemaining, 120)
        note.resume(at: now.addingTimeInterval(500))
        checkEqual(note.deadline, now.addingTimeInterval(620))
        try note.start(input: "date", specification: .date(now.addingTimeInterval(180)), now: now, order: 2)
        note.pause(at: now.addingTimeInterval(60))
        checkNil(note.pausedRemaining)
        checkEqual(note.deadline, now.addingTimeInterval(180))
    }

    @Test func testCompletionEffectsAreOneShotAndSuppressedOnWake() throws {
        let now = Date()
        var note = TimerNote()
        try note.start(input: "1s", specification: .duration(1), now: now, order: 1)
        checkFalse(note.completeIfNeeded(at: now, allowEffects: true))
        checkTrue(note.completeIfNeeded(at: now.addingTimeInterval(2), allowEffects: true))
        checkFalse(note.completeIfNeeded(at: now.addingTimeInterval(3), allowEffects: true))
        try note.start(input: "1s", specification: .duration(1), now: now, order: 2)
        checkFalse(note.completeIfNeeded(at: now.addingTimeInterval(2), allowEffects: false))
        checkFalse(note.completeIfNeeded(at: now.addingTimeInterval(3), allowEffects: true))
    }

    @Test func testHistoryChoosesLatestOpenThenLatestClosed() throws {
        var state = AppState()
        var a = TimerNote(), b = TimerNote(), c = TimerNote()
        let now = Date()
        try a.start(input: "3m", specification: .duration(180), now: now, order: 1)
        try b.start(input: "5m", specification: .duration(300), now: now, order: 2)
        try c.start(input: "7m", specification: .duration(420), now: now, order: 3)
        state.open = [a, b, c, TimerNote()]
        checkEqual(state.previous?.input, "7m")
        state.archive(c.id)
        checkEqual(state.previous?.input, "5m")
        state.archive(b.id)
        checkEqual(state.previous?.input, "3m")
        state.archive(a.id)
        checkEqual(state.previous?.input, "3m")
        let restored = state.restoreLast()
        checkEqual(restored?.id, a.id)
        checkEqual(restored?.deadline, a.deadline)
        checkEqual(state.closed.count, 2)
    }

    @Test func testStateRoundTripAndCorruptFileDoesNotGetOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StateStore(url: directory.appendingPathComponent("state.json"))
        var state = AppState()
        state.preferences.showSeconds = true
        state.open = [TimerNote()]
        try store.save(state)
        let restored = try store.load()
        checkEqual(restored.open.first?.id, state.open.first?.id)
        checkTrue(restored.preferences.showSeconds)
        let broken = Data("broken".utf8)
        try broken.write(to: store.url)
        checkThrows(try store.load())
        checkEqual(try Data(contentsOf: store.url), broken)
    }

    @Test func testDisplayRoundsUpWithoutChangingDeadline() {
        checkEqual(RemainingTime.text(seconds: 1, showSeconds: false), "1分")
        checkEqual(RemainingTime.text(seconds: 61, showSeconds: false), "2分")
        checkEqual(RemainingTime.text(seconds: 3660, showSeconds: false), "1時間01分")
        checkEqual(RemainingTime.text(seconds: 1.2, showSeconds: true), "00:00:02")
        checkEqual(RemainingTime.text(seconds: -1, showSeconds: true), "00:00:00")
    }

    @Test func testExpiredExplicitDateCannotRestartAccidentally() {
        checkThrows(try TimeSpecification.date(Date(timeIntervalSince1970: 0)).deadline(from: Date()))
    }
}

private func checkEqual<T: Equatable>(_ actual: T, _ expected: T) { #expect(actual == expected) }
private func checkTrue(_ value: Bool) { #expect(value) }
private func checkFalse(_ value: Bool) { #expect(!value) }
private func checkNil<T>(_ value: T?) { #expect(value == nil) }
private func checkThrows(_ expression: @autoclosure () throws -> Any, _ message: String = "") {
    #expect(throws: (any Error).self) { try expression() }
}
