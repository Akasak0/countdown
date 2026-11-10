import Testing
import Foundation
@testable import CountdownCore

@Suite struct AutomationTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return value
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private var now: Date { date("2026-11-10T10:00:00+09:00") }
    private func sequence(effect: AutomationEffect = .each) -> AutomationDefinition {
        AutomationDefinition(name: "作業と休憩", steps: [
            AutomationStep(label: "作業", duration: "25m"),
            AutomationStep(label: "休憩", duration: "5m"),
            AutomationStep(label: "作業2", duration: "25m")
        ], completionEffect: effect)
    }

    @Test func allDeadlinesAreAnchoredAtStartAndTransitionsDoNotDrift() throws {
        var note = TimerNote()
        try note.start(automation: sequence(), now: now, order: 1, calendar: calendar)
        #expect(note.label == "作業")
        #expect(note.automation?.deadlines == [now.addingTimeInterval(1500), now.addingTimeInterval(1800), now.addingTimeInterval(3300)])
        expectEvent(note.completeIfNeeded(at: now.addingTimeInterval(1501), allowEffects: true))
        #expect(note.label == "休憩")
        #expect(note.deadline == now.addingTimeInterval(1800))
        expectEvent(!note.completeIfNeeded(at: now.addingTimeInterval(1502), allowEffects: true))
        expectEvent(note.completeIfNeeded(at: now.addingTimeInterval(1800), allowEffects: true))
        #expect(note.label == "作業2")
    }

    @Test func sleepAndRelaunchSkipExpiredStepsWithoutReplayingEffects() throws {
        var note = TimerNote()
        try note.start(automation: sequence(), now: now, order: 1, calendar: calendar)
        let data = try JSONEncoder().encode(note)
        note = try JSONDecoder().decode(TimerNote.self, from: data)
        expectEvent(!note.completeIfNeeded(at: now.addingTimeInterval(2000), allowEffects: false))
        #expect(note.label == "作業2")
        #expect(note.remaining(at: now.addingTimeInterval(2000)) == 1300)
        expectEvent(!note.completeIfNeeded(at: now.addingTimeInterval(2001), allowEffects: true))
        expectEvent(!note.completeIfNeeded(at: now.addingTimeInterval(4000), allowEffects: false))
        #expect(note.isFinished(at: now.addingTimeInterval(4000)))
        expectEvent(!note.completeIfNeeded(at: now.addingTimeInterval(4001), allowEffects: true))
    }

    @Test func clockScheduleStartsInCurrentStepAndNeverRollsToTomorrow() throws {
        let definition = AutomationDefinition(name: "講義", steps: [
            AutomationStep(label: "1限", until: "10:30"), AutomationStep(label: "休憩", until: "10:40"),
            AutomationStep(label: "2限", until: "12:10")
        ])
        var note = TimerNote()
        try note.start(automation: definition, now: date("2026-11-10T10:35:00+09:00"), order: 1, calendar: calendar)
        #expect(note.label == "休憩")
        #expect(note.deadline == date("2026-11-10T10:40:00+09:00"))
        try note.start(automation: definition, now: date("2026-11-10T18:00:00+09:00"), order: 2, calendar: calendar)
        #expect(note.deadline == date("2026-11-10T12:10:00+09:00"))
        #expect(note.completionHandled)
        #expect(note.isFinished(at: date("2026-11-10T18:00:00+09:00")))
        expectEvent(!note.completeIfNeeded(at: date("2026-11-10T18:00:01+09:00"), allowEffects: true))
    }

    @Test func mixedStepsUsePreviousDeadlineAndMayCrossMidnightByDuration() throws {
        let definition = AutomationDefinition(name: "夜の作業", steps: [
            AutomationStep(label: "準備", until: "23:50"), AutomationStep(label: "作業", duration: "25m")
        ])
        let deadlines = try definition.resolve(from: now, calendar: calendar)
        #expect(deadlines == [date("2026-11-10T23:50:00+09:00"), date("2026-11-11T00:15:00+09:00")])
        let backwards = AutomationDefinition(name: "逆順", steps: [AutomationStep(until: "12:00"), AutomationStep(until: "11:00")])
        #expect(throws: (any Error).self) { try backwards.validate() }
        let relativeThenClock = AutomationDefinition(name: "混在", steps: [AutomationStep(duration: "1h"), AutomationStep(until: "12:00")])
        #expect(throws: (any Error).self) { try relativeThenClock.resolve(from: date("2026-11-10T13:00:00+09:00"), calendar: calendar) }
    }

    @Test func midnightAndDaylightSavingUseCalendarDates() throws {
        let midnight = AutomationDefinition(name: "深夜", steps: [AutomationStep(until: "00:00")])
        #expect(try midnight.resolve(from: now, calendar: calendar) == [date("2026-11-10T00:00:00+09:00")])
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        let definition = AutomationDefinition(name: "朝", steps: [AutomationStep(until: "09:00"), AutomationStep(duration: "1h")])
        let start = date("2026-03-08T00:00:00-05:00")
        #expect(try definition.resolve(from: start, calendar: ny) == [date("2026-03-08T09:00:00-04:00"), date("2026-03-08T10:00:00-04:00")])
    }

    @Test func effectPoliciesAreOneShotAndRespectSuppression() throws {
        for policy in AutomationEffect.allCases {
            var note = TimerNote()
            try note.start(automation: sequence(effect: policy), now: now, order: 1, calendar: calendar)
            expectEvent(note.completeIfNeeded(at: now.addingTimeInterval(1500), allowEffects: true) == (policy == .each))
            expectEvent(!note.completeIfNeeded(at: now.addingTimeInterval(1500.5), allowEffects: true))
            expectEvent(!note.completeIfNeeded(at: now.addingTimeInterval(1800), allowEffects: false))
            expectEvent(note.completeIfNeeded(at: now.addingTimeInterval(3300), allowEffects: true) == (policy != .none))
            expectEvent(!note.completeIfNeeded(at: now.addingTimeInterval(3301), allowEffects: true))
        }
    }

    @Test func editingTemplatesDoesNotChangeRunButEmptyEnterUsesLatest() throws {
        var library = AutomationLibrary(automations: [sequence()])
        var note = TimerNote()
        try note.start(automation: library.automations[0], now: now, order: 1, calendar: calendar)
        library.automations[0].steps[0].duration = "30m"
        #expect(note.deadline == now.addingTimeInterval(1500))
        #expect(note.automation?.definition.steps[0].duration == "25m")
        guard case .automation(let latest) = try TimerRequest.resolve("", previous: note, library: library) else {
            Issue.record("Empty Enter did not resolve automation"); return
        }
        try note.start(automation: latest, now: now, order: 2, calendar: calendar)
        #expect(note.deadline == now.addingTimeInterval(1800))
        library.automations.removeAll()
        #expect(throws: (any Error).self) { try TimerRequest.resolve("", previous: note, library: library) }
    }

    @Test func aliasesCompletionsAndOrdinaryHistoryCoexist() throws {
        let library = AutomationLibrary(automations: [sequence(), AutomationDefinition(name: "月曜の講義", steps: [AutomationStep(until: "12:00")])])
        #expect(library.matching("講義").map(\.name) == ["月曜の講義"])
        #expect(library.matching("3m").isEmpty)
        #expect(library.matching("").isEmpty)
        let overlapping = AutomationLibrary(automations: [
            AutomationDefinition(name: "作業ロング", steps: [AutomationStep(duration: "1m")]),
            AutomationDefinition(name: "作業", steps: [AutomationStep(duration: "1m")]),
            AutomationDefinition(name: "夕方の作業", steps: [AutomationStep(duration: "1m")])
        ])
        #expect(overlapping.matching("作業").map(\.name) == ["作業", "作業ロング", "夕方の作業"])
        guard case .automation(let found) = try TimerRequest.resolve("作業と休憩", previous: nil, library: library) else {
            Issue.record("Name not resolved"); return
        }
        #expect(found == sequence())
        var note = TimerNote()
        try note.start(input: "3m", specification: .duration(180), now: now, order: 1)
        guard case .timer(let input, let spec) = try TimerRequest.resolve("", previous: note, library: library) else {
            Issue.record("Timer history not resolved"); return
        }
        #expect(input == "3m")
        #expect(spec == .duration(180))
    }

    @Test func stopPauseAndReplacementDoNotLeaveHiddenAutomationRunning() throws {
        var note = TimerNote()
        try note.start(automation: sequence(), now: now, order: 1, calendar: calendar)
        #expect(!note.canPause)
        note.pause(at: now.addingTimeInterval(60))
        #expect(note.pausedRemaining == nil)
        note.stopAutomation(at: now.addingTimeInterval(60))
        #expect(note.isFinished(at: now.addingTimeInterval(60)))
        expectEvent(!note.completeIfNeeded(at: now.addingTimeInterval(1500), allowEffects: true))
        try note.start(input: "3m", specification: .duration(180), now: now, order: 2)
        #expect(note.automation == nil)
        #expect(note.canPause)
    }

    @Test func definitionValidationRejectsAmbiguousNamesAndBadSchedules() throws {
        for name in ["", " x", "x\n", "12", "1234", "3m", "3M", "１２", "1:30"] {
            #expect(throws: (any Error).self) { try AutomationDefinition(name: name, steps: [AutomationStep(duration: "1m")]).validate() }
        }
        let duplicate = AutomationLibrary(automations: [AutomationDefinition(name: "Work", steps: [AutomationStep(duration: "1m")]), AutomationDefinition(name: "work", steps: [AutomationStep(duration: "1m")])])
        #expect(throws: (any Error).self) { try duplicate.validate() }
        let invalidSteps: [[AutomationStep]] = [[], [AutomationStep()], [AutomationStep(until: "10:00", duration: "1m")],
            [AutomationStep(until: "3m")], [AutomationStep(duration: "10:00")], [AutomationStep(duration: "0s")],
            [AutomationStep(duration: "4800h"), AutomationStep(duration: "4800h")]]
        for steps in invalidSteps {
            #expect(throws: (any Error).self) { try AutomationDefinition(name: "不正", steps: steps).validate() }
        }
    }

    @Test func jsonErrorsIdentifyPathsAndDefaultsAreOptional() throws {
        let minimal = Data(#"{"version":1,"automations":[{"name":"作業","steps":[{"label":"集中","duration":"25m"}]}]}"#.utf8)
        #expect(try AutomationLibrary.decode(minimal).automations[0].completionEffect == .each)
        let noLabel = Data(#"{"version":1,"automations":[{"name":"作業","steps":[{"duration":"25m"}]}]}"#.utf8)
        #expect(try AutomationLibrary.decode(noLabel).automations[0].steps[0].label == "")
        for (json, expected) in [
            (#"{"version":1,"automations":[{"name":"作業","steps":[{"label":"集中","duraton":"25m"}]}]}"#, "steps[0].duraton"),
            (#"{"version":1,"automations":[{"name":"作業","steps":[{"label":12,"duration":"25m"}]}]}"#, "steps[0].label"),
            (#"{"version":1,"automations":[{"steps":[]}]}"#, "name"),
            (#"{"version":2,"automations":[]}"#, "version"),
            (#"{"version":1,"automations":[{"name":"作業","steps":[],"completionEffect":"typo"}]}"#, "completionEffect")
        ] {
            do { _ = try AutomationLibrary.decode(Data(json.utf8)); Issue.record("Invalid JSON was accepted") }
            catch { #expect(error.localizedDescription.contains(expected)) }
        }
    }

    @Test func storePreservesExternalEditsAndCorruptFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AutomationStore(url: directory.appendingPathComponent("automations.json"))
        let library = AutomationLibrary(automations: [sequence()])
        let baseline = try store.save(library, replacing: nil)
        #expect(try store.load() == library)
        let changed = try store.save(AutomationLibrary(), replacing: baseline)
        #expect(throws: (any Error).self) { try store.save(library, replacing: baseline) }
        #expect(try store.data() == changed)
        let broken = Data("broken".utf8)
        try broken.write(to: store.url)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try store.save(library, replacing: changed) }
        #expect(try store.data() == broken)
    }

    @Test func legacyStateAndClosedAutomationRestoreWithoutLosingDeadline() throws {
        let old = AppState()
        var state = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(old))
        var note = TimerNote()
        try note.start(automation: sequence(), now: now, order: 1, calendar: calendar)
        state.open = [note]
        state.archive(note.id)
        let data = try JSONEncoder().encode(state)
        state = try JSONDecoder().decode(AppState.self, from: data)
        var restored = state.restoreLast()!
        #expect(restored.automation?.definition == sequence())
        expectEvent(!restored.completeIfNeeded(at: now.addingTimeInterval(2000), allowEffects: false))
        #expect(restored.label == "作業2")
        #expect(restored.deadline == now.addingTimeInterval(3300))
        #expect(state.previous?.input == "作業と休憩")
    }

    @Test func exampleDocumentIsValid() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let library = try AutomationLibrary.decode(Data(contentsOf: root.appendingPathComponent("Examples/automations.json")))
        #expect(library.automations.count == 2)
    }

    @Test func malformedPersistedRunIsRejectedWithoutOverwritingState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StateStore(url: directory.appendingPathComponent("state.json"))
        var note = TimerNote()
        try note.start(automation: sequence(), now: now, order: 1, calendar: calendar)
        var state = AppState()
        state.open = [note]
        try store.save(state)
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as! [String: Any]
        var notes = object["open"] as! [[String: Any]]
        var run = notes[0]["automation"] as! [String: Any]
        run["deadlines"] = []
        notes[0]["automation"] = run
        object["open"] = notes
        let broken = try JSONSerialization.data(withJSONObject: object)
        try broken.write(to: store.url)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(try Data(contentsOf: store.url) == broken)
    }
}

private func expectEvent(_ value: Bool) { #expect(value) }
