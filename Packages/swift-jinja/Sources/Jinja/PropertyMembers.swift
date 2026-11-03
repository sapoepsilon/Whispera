import Foundation
@_exported import OrderedCollections

/// Property member access handlers for different value types.
///
/// This provides dot-notation property access functionality for various value types,
/// such as string methods (`str.upper()`), object properties, and built-in methods.
public enum PropertyMembers {
    /// Evaluates property member access on a value.
    ///
    /// - Parameters:
    ///   - object: The object to access the property on
    ///   - propertyName: The name of the property to access
    /// - Returns: The property value or `.undefined` if not found
    /// - Throws: `JinjaError.runtime` for invalid operations
    public static func evaluate(_ object: Value, _ propertyName: String) throws -> Value {
        switch object {
        case let .string(str):
            return try evaluateStringProperty(str, propertyName)
        case let .object(obj):
            return try evaluateObjectProperty(obj, propertyName)
        default:
            return .undefined
        }
    }

    // MARK: - String Properties

    private static func evaluateStringProperty(_ str: String, _ propertyName: String) throws
        -> Value
    {
        switch propertyName {
        case "upper":
            return .function { args, kwargs, _ in
                _ = try resolveCallArguments(args: args, kwargs: kwargs, parameters: [])
                return .string(str.uppercased())
            }
        case "lower":
            return .function { args, kwargs, _ in
                _ = try resolveCallArguments(args: args, kwargs: kwargs, parameters: [])
                return .string(str.lowercased())
            }
        case "title":
            return .function { args, kwargs, _ in
                _ = try resolveCallArguments(args: args, kwargs: kwargs, parameters: [])
                return .string(str.capitalized)
            }
        case "strip":
            return .function { args, kwargs, _ in
                _ = try resolveCallArguments(args: args, kwargs: kwargs, parameters: [])
                return .string(str.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        case "lstrip":
            return .function { args, kwargs, _ in
                _ = try resolveCallArguments(args: args, kwargs: kwargs, parameters: [])
                let trimmed = str.drop(while: { $0.isWhitespace })
                return .string(String(trimmed))
            }
        case "rstrip":
            return .function { args, kwargs, _ in
                _ = try resolveCallArguments(args: args, kwargs: kwargs, parameters: [])
                let reversed = str.reversed().drop(while: { $0.isWhitespace })
                return .string(String(reversed.reversed()))
            }
        case "split":
            return .function { args, kwargs, _ in
                let arguments = try resolveCallArguments(
                    args: args,
                    kwargs: kwargs,
                    parameters: ["separator", "maxsplit"],
                    defaults: ["separator": .null, "maxsplit": .int(-1)]
                )

                let separator: String? = {
                    guard case let .string(sep) = arguments["separator"] else { return nil }
                    return sep
                }()

                let limit: Int? = {
                    guard case let .int(maxsplit) = arguments["maxsplit"], maxsplit >= 0 else {
                        return nil
                    }
                    return maxsplit
                }()

                let components = split(string: str, separator: separator, limit: limit)
                return .array(components.map(Value.string))
            }
        case "replace":
            return .function { args, kwargs, _ in
                let arguments = try resolveCallArguments(
                    args: args,
                    kwargs: kwargs,
                    parameters: ["old", "new", "count"],
                    defaults: ["count": .int(-1)]
                )

                guard case let .string(old) = arguments["old"],
                    case let .string(new) = arguments["new"]
                else {
                    throw JinjaError.runtime("replace() requires 'old' and 'new' string arguments")
                }

                let maxReplacements: Int? = {
                    guard case let .int(count) = arguments["count"], count >= 0 else { return nil }
                    return count
                }()

                let result = replace(
                    string: str,
                    old: old,
                    new: new,
                    maxReplacements: maxReplacements
                )
                return .string(result)
            }
        case "startswith":
            return .function { args, kwargs, _ in
                let arguments = try resolveCallArguments(
                    args: args,
                    kwargs: kwargs,
                    parameters: ["prefix"]
                )

                guard case let .string(prefix) = arguments["prefix"] else {
                    throw JinjaError.runtime("startswith() requires a string prefix")
                }
                return .boolean(str.hasPrefix(prefix))
            }
        case "endswith":
            return .function { args, kwargs, _ in
                let arguments = try resolveCallArguments(
                    args: args,
                    kwargs: kwargs,
                    parameters: ["suffix"]
                )

                guard case let .string(suffix) = arguments["suffix"] else {
                    throw JinjaError.runtime("endswith() requires a string suffix")
                }
                return .boolean(str.hasSuffix(suffix))
            }
        default:
            return .undefined
        }
    }

    // MARK: - Object Properties

    private static func evaluateObjectProperty(
        _ obj: OrderedDictionary<String, Value>,
        _ propertyName: String
    ) throws -> Value {
        switch propertyName {
        case "items":
            let fn: @Sendable ([Value], [String: Value], Environment) throws -> Value = {
                args,
                kwargs,
                _ in
                _ = try resolveCallArguments(args: args, kwargs: kwargs, parameters: [])
                let pairs = obj.map { key, value in Value.array([.string(key), value]) }
                return .array(pairs)
            }
            return .function(fn)
        case "get":
            let fn: @Sendable ([Value], [String: Value], Environment) throws -> Value = {
                args,
                kwargs,
                _ in
                let arguments = try resolveCallArguments(
                    args: args,
                    kwargs: kwargs,
                    parameters: ["key", "default"],
                    defaults: ["default": .null]
                )

                guard let keyValue = arguments["key"] else {
                    throw JinjaError.runtime("get() requires a 'key' argument")
                }

                let key: String
                switch keyValue {
                case let .string(s):
                    key = s
                default:
                    key = keyValue.description
                }

                let defaultValue = arguments["default"] ?? .null
                return obj[key] ?? defaultValue
            }
            return .function(fn)
        case "keys":
            let fn: @Sendable ([Value], [String: Value], Environment) throws -> Value = {
                args,
                kwargs,
                _ in
                _ = try resolveCallArguments(args: args, kwargs: kwargs, parameters: [])
                let keys = obj.keys.map { Value.string($0) }
                return .array(keys)
            }
            return .function(fn)
        case "values":
            let fn: @Sendable ([Value], [String: Value], Environment) throws -> Value = {
                args,
                kwargs,
                _ in
                _ = try resolveCallArguments(args: args, kwargs: kwargs, parameters: [])
                return .array(Array(obj.values))
            }
            return .function(fn)
        default:
            return obj[propertyName] ?? .undefined
        }
    }
}

// MARK: - Private Helper Functions

/// Splits a string using a separator and optional limit.
/// - Parameters:
///   - string: The string to split
///   - separator: The separator to split on (nil for whitespace)
///   - limit: Maximum number of splits to perform (nil for unlimited)
/// - Returns: Array of string components
private func split(string: String, separator: String?, limit: Int?) -> [String] {
    if let separator = separator {
        if let limit = limit {
            // Split with limit: split at most 'limit' times
            var components: [String] = []
            var remaining = string
            var splits = 0

            while splits < limit, let range = remaining.range(of: separator) {
                components.append(String(remaining[..<range.lowerBound]))
                remaining = String(remaining[range.upperBound...])
                splits += 1
            }
            // Add the remainder
            components.append(remaining)
            return components
        } else {
            return string.components(separatedBy: separator)
        }
    } else {
        // Split on whitespace
        return string.split(separator: " ").map(String.init)
    }
}

/// Replaces occurrences of old string with new string, optionally limiting replacements.
/// - Parameters:
///   - string: The string to perform replacements on
///   - old: The substring to replace
///   - new: The replacement string
///   - maxReplacements: Maximum number of replacements (nil for unlimited)
/// - Returns: The string with replacements made
private func replace(string: String, old: String, new: String, maxReplacements: Int?)
    -> String
{
    // Special case: replacing empty string inserts at character boundaries
    if old.isEmpty {
        var result = ""
        var replacements = 0
        for char in string {
            if let count = maxReplacements, replacements >= count {
                result += String(char)
            } else {
                result += new + String(char)
                replacements += 1
            }
        }
        // Add final replacement if we haven't hit the count limit
        if maxReplacements == nil || replacements < maxReplacements! {
            result += new
        }
        return result
    }

    if let count = maxReplacements {
        // Replace only the first 'count' occurrences
        var result = string
        var replacements = 0
        while replacements < count, let range = result.range(of: old) {
            result.replaceSubrange(range, with: new)
            replacements += 1
        }
        return result
    } else {
        return string.replacingOccurrences(of: old, with: new)
    }
}
