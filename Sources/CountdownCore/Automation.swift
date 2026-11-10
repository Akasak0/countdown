import Foundation

public struct AutomationError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum AutomationEffect: String, Codable, CaseIterable {
    case each, last, none
    public var title: String {
        switch self {
        case .each: return "各区間の終了時"
        case .last: return "最後の区間だけ"
        case .none: return "知らせない"
        }
    }
}

public struct AutomationStep: Codable, Equatable {
    public var label: String
    public var until: String?
    public var duration: String?
    public init(label: String = "", until: String? = nil, duration: String? = nil) {
        self.label = label; self.until = until; self.duration = duration
    }

    public func specification() throws -> TimeSpecification {
        guard (until != nil) != (duration != nil) else {
            throw AutomationError("until（時刻）と duration（時間の長さ）は、どちらか一方を指定してください。")
        }
        let spec = try TimeSpecification.parse(until ?? duration ?? "")
        switch spec {
        case .clock where until != nil, .duration where duration != nil: return spec
        default: throw AutomationError(until != nil ? "until には 10:30 のような時刻を指定してください。" : "duration には 25m のような時間の長さを指定してください。")
        }
    }
}

extension AutomationStep {
    private enum CodingKeys: String, CodingKey { case label, until, duration }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        label = try values.decodeIfPresent(String.self, forKey: .label) ?? ""
        until = try values.decodeIfPresent(String.self, forKey: .until)
        duration = try values.decodeIfPresent(String.self, forKey: .duration)
    }
}

public struct AutomationDefinition: Codable, Equatable {
    public var name: String
    public var steps: [AutomationStep]
    public var completionEffect: AutomationEffect
    public init(name: String, steps: [AutomationStep], completionEffect: AutomationEffect = .each) {
        self.name = name; self.steps = steps; self.completionEffect = completionEffect
    }

    public func validate() throws {
        guard !name.isEmpty, name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              name.count <= 80, !name.contains(where: { $0.isNewline }) else {
            throw AutomationError("名前は前後の空白・改行なしで、1〜80文字にしてください。")
        }
        guard (try? TimeSpecification.parse(Self.key(name))) == nil else {
            throw AutomationError("「\(name)」は時間入力と重なるため、名前に使えません。")
        }
        guard !steps.isEmpty else { throw AutomationError("「\(name)」には区間を1つ以上追加してください。") }
        for (index, step) in steps.enumerated() {
            do {
                guard step.label.count <= 100 else { throw AutomationError("ラベルは100文字以内にしてください。") }
                _ = try step.specification()
            } catch { throw AutomationError("「\(name)」の区間\(index + 1): \(error.localizedDescription)") }
        }
        // A fixed reference date also checks chronology without depending on today's time.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        _ = try resolve(from: Date(timeIntervalSince1970: 0), calendar: calendar)
    }

    public static func key(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    public func resolve(from now: Date, calendar: Calendar = .current) throws -> [Date] {
        var deadlines: [Date] = []
        let day = calendar.startOfDay(for: now)
        for (index, step) in steps.enumerated() {
            let end: Date
            switch try step.specification() {
            case .duration(let seconds): end = (deadlines.last ?? now).addingTimeInterval(seconds)
            case .clock(let hour, let minute, let second):
                guard let date = calendar.nextDate(after: day.addingTimeInterval(-1),
                    matching: DateComponents(hour: hour, minute: minute, second: second),
                    matchingPolicy: .nextTime, repeatedTimePolicy: .first), calendar.isDate(date, inSameDayAs: day) else {
                    throw AutomationError("区間\(index + 1)の時刻を今日の日付で計算できませんでした。")
                }
                end = date
            case .date: throw AutomationError("オートメーションでは日付指定を使えません。")
            }
            if let previous = deadlines.last, end <= previous {
                throw AutomationError("「\(name)」の区間\(index + 1): 終了時刻は前の区間より後にしてください。時刻はすべて今日として扱います。")
            }
            guard end.timeIntervalSince(deadlines.first.map { min($0, now) } ?? now) <= 365 * 86400 else {
                throw AutomationError("「\(name)」の全区間の長さは365日以内にしてください。")
            }
            deadlines.append(end)
        }
        return deadlines
    }
}

public struct AutomationLibrary: Codable, Equatable {
    public var version = 1
    public var automations: [AutomationDefinition] = []
    public init(automations: [AutomationDefinition] = []) { self.automations = automations }

    public func named(_ name: String) -> AutomationDefinition? {
        automations.first { AutomationDefinition.key($0.name) == AutomationDefinition.key(name) }
    }

    public func matching(_ query: String) -> [AutomationDefinition] {
        let query = AutomationDefinition.key(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty, (try? TimeSpecification.parse(query)) == nil else { return [] }
        let matches = automations.filter { AutomationDefinition.key($0.name).contains(query) }
        return matches.filter { AutomationDefinition.key($0.name) == query }
            + matches.filter { AutomationDefinition.key($0.name) != query && AutomationDefinition.key($0.name).hasPrefix(query) }
            + matches.filter { !AutomationDefinition.key($0.name).hasPrefix(query) }
    }

    public func validate() throws {
        guard version == 1 else { throw AutomationError("対応していないオートメーションの version です（対応: 1）。") }
        var names = Set<String>()
        for definition in automations {
            try definition.validate()
            guard names.insert(AutomationDefinition.key(definition.name)).inserted else {
                throw AutomationError("「\(definition.name)」という名前が重複しています。")
            }
        }
    }

    public static func decode(_ data: Data) throws -> AutomationLibrary {
        do {
            // Catch misspelled keys rather than silently discarding settings.
            let object = try JSONSerialization.jsonObject(with: data)
            func keys(_ value: Any, allowed: Set<String>, at path: String) throws {
                guard let object = value as? [String: Any] else { return }
                if let key = object.keys.sorted().first(where: { !allowed.contains($0) }) {
                    throw AutomationError("\(path).\(key): 未対応のキーです。")
                }
            }
            try keys(object, allowed: ["version", "automations"], at: "JSON")
            if let root = object as? [String: Any], let definitions = root["automations"] as? [Any] {
                for (i, definition) in definitions.enumerated() {
                    let path = "automations[\(i)]"
                    try keys(definition, allowed: ["name", "steps", "completionEffect"], at: path)
                    if let definition = definition as? [String: Any], let steps = definition["steps"] as? [Any] {
                        for (j, step) in steps.enumerated() {
                            try keys(step, allowed: ["label", "until", "duration"], at: "\(path).steps[\(j)]")
                        }
                    }
                }
            }
            let library = try JSONDecoder().decode(Self.self, from: data)
            try library.validate()
            return library
        } catch let error as AutomationError { throw error }
        catch let DecodingError.keyNotFound(key, context) {
            throw AutomationError("\(path(context.codingPath + [key])): 必須の項目がありません。")
        } catch let DecodingError.typeMismatch(_, context) {
            throw AutomationError("\(path(context.codingPath)): 値の種類が違います。")
        } catch let DecodingError.valueNotFound(_, context) {
            throw AutomationError("\(path(context.codingPath)): null は指定できません。")
        } catch let DecodingError.dataCorrupted(context) {
            throw AutomationError("\(path(context.codingPath)): JSONの値を読み込めません。\(context.debugDescription)")
        } catch { throw AutomationError("JSONを読み込めません。\(error.localizedDescription)") }
    }

    private static func path(_ keys: [CodingKey]) -> String {
        keys.reduce("JSON") { $0 + ($1.intValue.map { "[\($0)]" } ?? ".\($1.stringValue)") }
    }
}

extension AutomationDefinition {
    private enum CodingKeys: String, CodingKey { case name, steps, completionEffect }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        steps = try values.decode([AutomationStep].self, forKey: .steps)
        completionEffect = try values.decodeIfPresent(AutomationEffect.self, forKey: .completionEffect) ?? .each
    }
}

public struct AutomationRun: Codable, Equatable {
    public let definition: AutomationDefinition
    public let deadlines: [Date]
    public var currentIndex: Int
    public var stopped = false

    public init(definition: AutomationDefinition, now: Date, calendar: Calendar = .current) throws {
        try definition.validate()
        self.definition = definition
        deadlines = try definition.resolve(from: now, calendar: calendar)
        currentIndex = deadlines.firstIndex { $0 > now } ?? (deadlines.count - 1)
    }

    public func validate() throws {
        try definition.validate()
        guard deadlines.count == definition.steps.count, deadlines.indices.contains(currentIndex),
              deadlines.allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              zip(deadlines, deadlines.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw AutomationError("保存したオートメーションの実行情報が不正です。")
        }
    }
}

public struct AutomationStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func data() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
    public func load() throws -> AutomationLibrary {
        try data().map { try AutomationLibrary.decode($0) } ?? AutomationLibrary()
    }
    public func save(_ library: AutomationLibrary, replacing expected: Data?) throws -> Data {
        try library.validate()
        guard try data() == expected else {
            throw AutomationError("JSONが別の場所で変更されています。編集内容を確認してから「再読み込み」してください。ファイルは上書きしていません。")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(library)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return data
    }
}

public enum TimerRequest {
    case timer(input: String, specification: TimeSpecification)
    case automation(AutomationDefinition)

    public static func resolve(_ raw: String, previous: TimerNote?, library: AutomationLibrary) throws -> Self {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty {
            guard let previous else { throw TimeInputError.invalid }
            if let run = previous.automation {
                guard let definition = library.named(run.definition.name) else {
                    throw AutomationError("「\(run.definition.name)」が見つかりません。設定のオートメーションを確認してください。")
                }
                return .automation(definition)
            }
            guard let input = previous.input, let spec = previous.specification else { throw TimeInputError.invalid }
            return .timer(input: input, specification: spec)
        }
        if let definition = library.named(input) { return .automation(definition) }
        return .timer(input: input, specification: try TimeSpecification.parse(input))
    }
}
