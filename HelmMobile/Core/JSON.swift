import Foundation

/// A loosely typed JSON value. The server's schemas evolve faster than this client, so wire
/// payloads are decoded into this first and read leniently; unknown fields never break decoding.
enum JSON: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    subscript(index: Int) -> JSON? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    var string: String? { if case .string(let s) = self { s } else { nil } }
    var double: Double? {
        switch self {
        case .number(let n): n
        case .string(let s): Double(s)
        default: nil
        }
    }
    var int: Int? { double.map { Int($0) } }
    var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    var array: [JSON]? { if case .array(let a) = self { a } else { nil } }
    var object: [String: JSON]? { if case .object(let o) = self { o } else { nil } }
    var isNull: Bool { if case .null = self { true } else { false } }

    /// Non-null value or nil, for `T | null` and optional fields alike.
    var nonNull: JSON? { isNull ? nil : self }

    static func parse(_ data: Data) throws -> JSON {
        try JSONDecoder().decode(JSON.self, from: data)
    }

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Decodes a typed value out of this JSON (used for small, stable shapes).
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: data())
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral
{
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(nilLiteral: ()) { self = .null }
}

enum ISODate {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
    private static let lock = NSLock()

    static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let date = fastParse(string) { return date }
        lock.lock(); defer { lock.unlock() }
        return fractional.date(from: string) ?? plain.date(from: string)
    }

    /// The server's own shape, `2026-10-13T16:58:40.123Z`, read by hand: the formatter took
    /// tens of microseconds a date, and a thread list or snapshot has thousands of them.
    /// Anything else (an offset instead of Z, a missing field) goes to the formatter.
    static func fastParse(_ string: String) -> Date? {
        string.utf8.withContiguousStorageIfAvailable { bytes -> Date? in
            guard bytes.count >= 20, bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[10] == 0x54 || bytes[10] == 0x20,
                  bytes[13] == 0x3A, bytes[16] == 0x3A, bytes[bytes.count - 1] == 0x5A
            else { return nil }
            func number(_ from: Int, _ count: Int) -> Int? {
                var value = 0
                for index in from..<(from + count) {
                    let digit = Int(bytes[index]) - 48
                    guard (0...9).contains(digit) else { return nil }
                    value = value * 10 + digit
                }
                return value
            }
            guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
                  let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
                  (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
            else { return nil }
            var fraction = 0.0
            let end = bytes.count - 1
            if end > 19 {
                guard bytes[19] == 0x2E, (21...29).contains(end), let digits = number(20, end - 20) else { return nil }
                var scale = 1.0
                for _ in 20..<end { scale *= 10 }
                fraction = Double(digits) / scale
            } else if end != 19 {
                return nil
            }
            // Days since 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's days_from_civil).
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yoe = y - era * 400
            let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            let days = era * 146_097 + doe - 719_468
            let seconds = Double(days * 86_400 + hour * 3600 + minute * 60 + second) + fraction
            return Date(timeIntervalSince1970: seconds)
        } ?? nil
    }

    static func string(_ date: Date = Date()) -> String {
        lock.lock(); defer { lock.unlock() }
        return fractional.string(from: date)
    }
}
