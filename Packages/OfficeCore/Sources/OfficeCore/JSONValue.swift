import Foundation

public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(any: Any?) {
        switch any {
        case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID(): self = .bool(value.boolValue)
        case let value as NSNumber: self = .number(value.doubleValue)
        case let value as String: self = .string(value)
        case let value as [Any]: self = .array(value.map { JSONValue(any: $0) })
        case let value as [String: Any]: self = .object(value.mapValues { JSONValue(any: $0) })
        default: self = .null
        }
    }

    public var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value.rounded() == value && abs(value) < 1e15 ? Int(value) as Any : value
        case .string(let value): value
        case .array(let value): value.map(\.any)
        case .object(let value): value.mapValues(\.any)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    public var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public func setting(_ key: String, to value: JSONValue) -> JSONValue {
        guard case .object(var object) = self else { return self }
        object[key] = value
        return .object(object)
    }
}
