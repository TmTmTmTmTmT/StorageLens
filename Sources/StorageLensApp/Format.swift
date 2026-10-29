import Foundation

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
    static func signedBytes(_ n: Int64) -> String {
        (n >= 0 ? "+" : "−") + bytes(abs(n))
    }
    static let number: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.numberStyle = .decimal
        return f
    }()
    static func count(_ n: Int) -> String { number.string(from: NSNumber(value: n)) ?? "\(n)" }
    /// 경과 시간 "m분 s초" / "s초".
    static func elapsed(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 60 ? "\(s / 60)분 \(s % 60)초" : "\(s)초"
    }
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
    static func date(_ d: Date) -> String { date.string(from: d) }
    static func dateTime(_ d: Date) -> String { dateTime.string(from: d) }
}
