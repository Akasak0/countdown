import Foundation

public enum TimeInputError: Error, LocalizedError {
    case invalid, tooLong, pastDate

    public var errorDescription: String? {
        switch self {
        case .invalid: return "17:45、1745、17 または 3m の形式で入力してください。"
        case .tooLong: return "時間の長さは365日以内で指定してください。"
        case .pastDate: return "指定した日時は過ぎています。終了日時を指定し直してください。"
        }
    }
}

public enum TimeSpecification: Codable, Equatable {
    case duration(TimeInterval)
    case clock(hour: Int, minute: Int, second: Int)
    case date(Date)

    public static func parse(_ raw: String) throws -> TimeSpecification {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains(":") {
            let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
            guard (2...3).contains(pieces.count), pieces.allSatisfy({
                (1...2).contains($0.count) && $0.utf8.allSatisfy { (48...57).contains($0) }
            }), let hour = Int(pieces[0]), let minute = Int(pieces[1]) else { throw TimeInputError.invalid }
            let second = pieces.count == 3 ? Int(pieces[2])! : 0
            guard hour < 24, minute < 60, second < 60 else { throw TimeInputError.invalid }
            return .clock(hour: hour, minute: minute, second: second)
        }
        if (text.count == 2 || text.count == 4), text.utf8.allSatisfy({ (48...57).contains($0) }) {
            let digits = Array(text.utf8)
            let hour = Int(digits[0] - 48) * 10 + Int(digits[1] - 48)
            let minute = digits.count == 4 ? Int(digits[2] - 48) * 10 + Int(digits[3] - 48) : 0
            guard hour < 24, minute < 60 else { throw TimeInputError.invalid }
            return .clock(hour: hour, minute: minute, second: 0)
        }
        let expression = try NSRegularExpression(pattern: "^(?:([0-9]+)h)?(?:([0-9]+)m)?(?:([0-9]+)s)?$")
        let range = NSRange(text.startIndex..., in: text)
        guard !text.isEmpty, let match = expression.firstMatch(in: text, range: range), match.range == range else {
            throw TimeInputError.invalid
        }
        var total: Double = 0
        for (index, multiplier) in [(1, 3600.0), (2, 60.0), (3, 1.0)] {
            if let capture = Range(match.range(at: index), in: text) {
                guard let number = Double(text[capture]), number.isFinite else { throw TimeInputError.tooLong }
                total += number * multiplier
            }
        }
        guard total.isFinite, total <= 365 * 86400 else { throw TimeInputError.tooLong }
        guard total > 0 else { throw TimeInputError.invalid }
        return .duration(total)
    }

    public var canPause: Bool {
        if case .duration = self { return true }
        return false
    }

    public func deadline(from now: Date, calendar: Calendar = .current) throws -> Date {
        switch self {
        case .duration(let seconds): return now.addingTimeInterval(seconds)
        case .clock(let hour, let minute, let second):
            guard let result = calendar.nextDate(after: now,
                matching: DateComponents(hour: hour, minute: minute, second: second),
                matchingPolicy: .nextTime, repeatedTimePolicy: .first) else { throw TimeInputError.invalid }
            return result
        case .date(let date):
            guard date > now else { throw TimeInputError.pastDate }
            return date
        }
    }
}

public enum TimeDisplayMode: String, Codable, CaseIterable {
    case minutes, seconds, automatic

    public var title: String {
        switch self {
        case .minutes: return "分"
        case .seconds: return "時:分:秒"
        case .automatic: return "自動"
        }
    }
}

public enum RemainingTime {
    public static func text(seconds: TimeInterval, mode: TimeDisplayMode) -> String {
        guard mode == .automatic else { return text(seconds: seconds, showSeconds: mode == .seconds) }
        let safe = seconds.isFinite ? max(0, min(seconds, TimeInterval(Int.max / 2))) : 0
        let rounded = Int(ceil(safe))
        if rounded >= 86400 {
            let hours = Int(ceil(safe / 3600))
            return "\(hours / 24)日\(hours % 24)時間"
        }
        if rounded >= 3600 {
            let minutes = Int(ceil(safe / 60))
            return "\(minutes / 60)時間\(minutes % 60)分"
        }
        if rounded >= 60 { return "\(rounded / 60)分\(rounded % 60)秒" }
        return "\(rounded)秒"
    }

    public static func text(seconds: TimeInterval, showSeconds: Bool) -> String {
        let seconds = seconds.isFinite ? max(0, min(seconds, TimeInterval(Int.max / 2))) : 0
        if showSeconds {
            let rounded = Int(ceil(seconds))
            return String(format: "%02d:%02d:%02d", rounded / 3600, rounded / 60 % 60, rounded % 60)
        }
        let minutes = Int(ceil(seconds / 60))
        return minutes >= 60 ? String(format: "%d時間%02d分", minutes / 60, minutes % 60) : "\(minutes)分"
    }
}
