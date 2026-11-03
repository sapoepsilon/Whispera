import Foundation

/// Built-in filters for Jinja template rendering.
///
/// Filters transform values in template expressions using the pipe syntax (`|`).
/// All filter functions follow the same signature pattern, accepting an array of values
/// (with the filtered value as the first element), optional keyword arguments, and an environment.
public enum Filters {
    // MARK: - Basic String Filters

    /// Converts a string to uppercase.
    @Sendable public static func upper(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard case let .string(str) = args.first else {
            throw JinjaError.runtime("upper filter requires string")
        }

        _ = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: [],
            defaults: [:]
        )

        return .string(str.uppercased())
    }

    /// Converts a string to lowercase.
    @Sendable public static func lower(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard case let .string(str) = args.first else {
            throw JinjaError.runtime("lower filter requires string")
        }

        _ = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: [],
            defaults: [:]
        )

        return .string(str.lowercased())
    }

    /// Returns the length of a string, array, or object.
    @Sendable public static func length(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        _ = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: [],
            defaults: [:]
        )

        switch args.first {
        case let .string(str):
            return .int(str.count)
        case let .array(arr):
            return .int(arr.count)
        case let .object(obj):
            return .int(obj.count)
        case .undefined:
            return .int(0)
        default:
            throw JinjaError.runtime("length filter requires string, array, or object")
        }
    }

    /// Joins an array of values with a separator.
    @Sendable public static func join(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard case let .array(array) = args.first else {
            throw JinjaError.runtime("join filter requires array")
        }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["separator", "attribute"],
            defaults: ["separator": .string(""), "attribute": .null]
        )

        guard case let .string(separator) = arguments["separator"] else {
            throw JinjaError.runtime("join filter requires string separator")
        }

        let strings: [String]
        if let attribute = arguments["attribute"], attribute != .null {
            strings = try array.map {
                let value = try resolveAttributeValue($0, attribute: attribute)
                return value.description
            }
        } else {
            strings = array.map { $0.description }
        }
        return .string(strings.joined(separator: separator))
    }

    /// Returns a default value if the input is undefined,
    /// or if the input is false and the second / `boolean` argument is `true`.
    @Sendable public static func `default`(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        let input = args.first ?? .undefined

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["default_value", "boolean"],
            defaults: ["boolean": .boolean(false)]
        )

        let defaultValue = arguments["default_value"]!
        let boolean = arguments["boolean"]!.isTruthy

        // If input is undefined, return default value
        if input == .undefined {
            return defaultValue
        }

        // If boolean is true and input is false, return default value
        if boolean, input == false {
            return defaultValue
        }

        // Otherwise return the input value
        return input
    }

    // MARK: - Array Filters

    /// Returns the first item from an array.
    @Sendable public static func first(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first else {
            return .undefined
        }

        _ = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: [],
            defaults: [:]
        )

        switch value {
        case let .array(arr):
            return arr.first ?? .undefined
        case let .string(str):
            return str.first.map { .string(String($0)) } ?? .undefined
        default:
            throw JinjaError.runtime("first filter requires array or string")
        }
    }

    /// Returns the last item from an array.
    @Sendable public static func last(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first else {
            return .undefined
        }

        _ = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: [],
            defaults: [:]
        )

        switch value {
        case let .array(arr):
            return arr.last ?? .undefined
        case let .string(str):
            return str.last.map { .string(String($0)) } ?? .undefined
        default:
            throw JinjaError.runtime("last filter requires array or string")
        }
    }

    /// Returns a random item from an array.
    @Sendable public static func random(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first else {
            return .undefined
        }

        _ = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: [],
            defaults: [:]
        )

        switch value {
        case let .array(arr):
            return arr.randomElement() ?? .undefined
        case let .string(str):
            return str.randomElement().map { .string(String($0)) } ?? .undefined
        case let .object(dict):
            if dict.isEmpty { return .undefined }
            let randomIndex = dict.keys.indices.randomElement()!
            let randomKey = dict.keys[randomIndex]
            return .string(randomKey)
        default:
            return .undefined
        }
    }

    /// Reverses an array or string.
    @Sendable public static func reverse(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first else {
            return .undefined
        }

        _ = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: [],
            defaults: [:]
        )

        switch value {
        case let .array(arr):
            return .array(arr.reversed())
        case let .string(str):
            return .string(String(str.reversed()))
        default:
            throw JinjaError.runtime("reverse filter requires array or string")
        }
    }

    /// Sorts an array.
    @Sendable public static func sort(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first, case let .array(items) = value else {
            return .array([])
        }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["reverse", "case_sensitive", "attribute"],
            defaults: [
                "reverse": .boolean(false),
                "case_sensitive": .boolean(false),
                "attribute": .null,
            ]
        )

        let reverse = arguments["reverse"]!.isTruthy
        let caseSensitive = arguments["case_sensitive"]!.isTruthy

        func compare(_ lhs: Value, _ rhs: Value) throws -> Int {
            try compareValues(lhs, rhs, caseSensitive: caseSensitive)
        }

        func stableSorted(_ values: [Value], by comparator: (Value, Value) throws -> Int) rethrows
            -> [Value]
        {
            return try values.enumerated().sorted { a, b in
                let comparison = try comparator(a.element, b.element)
                if comparison == 0 { return a.offset < b.offset }
                return comparison < 0
            }.map(\.element)
        }

        let sortedItems: [Value]
        if case let .string(attribute) = arguments["attribute"] {
            let attributes = attribute.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if attributes.isEmpty {
                sortedItems = try stableSorted(items, by: compare)
            } else {
                var sorted = items
                for attr in attributes.reversed() {
                    sorted = try stableSorted(sorted) { a, b in
                        let aValue = try PropertyMembers.evaluate(a, String(attr))
                        let bValue = try PropertyMembers.evaluate(b, String(attr))
                        return try compare(aValue, bValue)
                    }
                }
                sortedItems = sorted
            }
        } else {
            sortedItems = try stableSorted(items, by: compare)
        }

        return .array(reverse ? Array(sortedItems.reversed()) : sortedItems)
    }

    /// Groups items by a given attribute.
    @Sendable public static func groupby(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first, case let .array(items) = value else {
            return .array([])
        }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["attribute", "default", "case_sensitive"],
            defaults: ["default": .null, "case_sensitive": .boolean(false)]
        )

        guard case let .string(attribute) = arguments["attribute"] else {
            throw JinjaError.runtime("groupby filter requires attribute parameter")
        }

        let defaultValue = arguments["default"] ?? .null
        let caseSensitive = arguments["case_sensitive"]!.isTruthy

        func normalizedKey(_ key: Value) -> Value {
            if !caseSensitive, case let .string(str) = key {
                return .string(str.lowercased())
            }
            return key
        }

        func compare(_ lhs: Value, _ rhs: Value) -> Int {
            (try? compareValues(
                lhs,
                rhs,
                caseSensitive: caseSensitive,
                useStringComparisonWhenCaseSensitive: true,
                fallbackToDescription: true
            )) ?? 0
        }

        let keyedItems: [(item: Value, displayKey: Value, normalized: Value)] = try items.map {
            let rawKey = try PropertyMembers.evaluate($0, attribute)
            let displayKey = rawKey == .undefined ? defaultValue : rawKey
            return (item: $0, displayKey: displayKey, normalized: normalizedKey(displayKey))
        }

        let sortedKeyedItems = keyedItems.enumerated().sorted { lhs, rhs in
            let comparison = compare(lhs.element.normalized, rhs.element.normalized)
            if comparison == 0 { return lhs.offset < rhs.offset }
            return comparison < 0
        }.map(\.element)

        var grouped: [(displayKey: Value, normalized: Value, items: [Value])] = []
        for item in sortedKeyedItems {
            if let last = grouped.last, last.normalized.isEquivalent(to: item.normalized) {
                grouped[grouped.count - 1].items.append(item.item)
            } else {
                grouped.append((displayKey: item.displayKey, normalized: item.normalized, items: [item.item]))
            }
        }

        let result = grouped.map { group in
            Value.object([
                "grouper": group.displayKey,
                "list": .array(group.items),
            ])
        }
        return .array(result)
    }

    /// Slices an array into multiple slices.
    @Sendable public static func slice(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first, case let .array(items) = value else {
            return .array([])
        }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["numSlices", "fillWith"],
            defaults: ["fillWith": .null]
        )

        guard case let .int(numSlices) = arguments["numSlices"], numSlices > 0 else {
            throw JinjaError.runtime("slice filter requires positive integer numSlices parameter")
        }

        let fillWith = arguments["fillWith"]!
        var result = Array(repeating: [Value](), count: numSlices)
        let itemsPerSlice = (items.count + numSlices - 1) / numSlices

        for i in 0 ..< itemsPerSlice {
            for j in 0 ..< numSlices {
                let index = i * numSlices + j
                if index < items.count {
                    result[j].append(items[index])
                } else {
                    result[j].append(fillWith)
                }
            }
        }

        return .array(result.map { .array($0) })
    }

    /// Maps items through a filter or extracts attribute values.
    @Sendable public static func map(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first, case let .array(items) = value else {
            return .array([])
        }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["filterName", "attribute", "default"],
            defaults: ["filterName": .null, "attribute": .null, "default": .null]
        )

        if case let .string(filterName) = arguments["filterName"] {
            return try .array(
                items.map {
                    try Interpreter.evaluateFilter(filterName, [$0], kwargs: [:], env: env)
                }
            )
        } else if let attribute = arguments["attribute"], attribute != .null {
            let defaultValue = arguments["default"] ?? .null

            return try .array(
                items.map {
                    let value = try resolveAttributeValue($0, attribute: attribute)
                    return value == .undefined ? defaultValue : value
                }
            )
        }

        return .array([])
    }

    /// Selects items that pass a test.
    @Sendable public static func select(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first, case let .array(items) = value else {
            return .array([])
        }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["testname"],
            defaults: ["testname": .null]
        )

        if case let .string(testName) = arguments["testname"] {
            let testArgs = Array(args.dropFirst(2))
            return try .array(
                items.filter {
                    try Interpreter.evaluateTest(testName, [$0] + testArgs, env: env)
                }
            )
        } else {
            // No test name provided, filter by truthiness
            return .array(
                items.filter { $0.isTruthy }
            )
        }
    }

    /// Rejects items that pass a test.
    @Sendable public static func reject(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first, case let .array(items) = value else {
            return .array([])
        }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["testname"],
            defaults: ["testname": .null]
        )

        if case let .string(testName) = arguments["testname"] {
            let testArgs = Array(args.dropFirst(2))
            return try .array(
                items.filter {
                    try !Interpreter.evaluateTest(testName, [$0] + testArgs, env: env)
                }
            )
        } else {
            // No test name provided, filter by falsy values
            return .array(
                items.filter { !$0.isTruthy }
            )
        }
    }

    /// Selects items with an attribute that passes a test.
    /// If no test is specified,
    /// the attribute's value will be evaluated as a Boolean.
    @Sendable public static func selectattr(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard case let .array(items)? = args.first else {
            return .array([])
        }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["attribute", "testname"],
            defaults: ["testname": .null]
        )

        guard case let .string(attribute) = arguments["attribute"] else {
            throw JinjaError.runtime("selectattr filter requires attribute parameter")
        }

        let testArgs = Array(args.dropFirst(2))
        return try .array(
            items.filter {
                let attrValue = try PropertyMembers.evaluate($0, attribute)
                guard case let .string(testName) = arguments["testname"] else {
                    return attrValue.isTruthy
                }

                return try Interpreter.evaluateTest(
                    testName,
                    [attrValue] + testArgs.dropFirst(1),
                    env: env
                )
            }
        )
    }

    /// Rejects items with an attribute that passes a test.
    /// If no test is specified,
    /// the attribute's value will be evaluated as a Boolean.
    @Sendable public static func rejectattr(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first, case let .array(items) = value else {
            return .array([])
        }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["attribute", "testname"],
            defaults: ["testname": .null]
        )

        guard case let .string(attribute) = arguments["attribute"] else {
            throw JinjaError.runtime("rejectattr filter requires attribute parameter")
        }

        let testArgs = Array(args.dropFirst(2))
        return try .array(
            items.filter {
                let attrValue = try PropertyMembers.evaluate($0, attribute)
                guard case let .string(testName) = arguments["testname"] else {
                    return !attrValue.isTruthy
                }

                return try !Interpreter.evaluateTest(
                    testName,
                    [attrValue] + testArgs.dropFirst(1),
                    env: env
                )
            }
        )
    }

    // MARK: - Object Filters

    /// Gets an attribute from an object.
    @Sendable public static func attr(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let obj = args.first else {
            return .undefined
        }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["attribute"],
            defaults: [:]
        )

        guard case let .string(attribute) = arguments["attribute"] else {
            throw JinjaError.runtime("attr filter requires attribute parameter")
        }

        return try PropertyMembers.evaluate(obj, attribute)
    }

    /// Sorts a dictionary by keys and returns key-value pairs.
    @Sendable public static func dictsort(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard case let .object(dict) = args.first else {
            return .array([])
        }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["case_sensitive", "by", "reverse"],
            defaults: [
                "case_sensitive": .boolean(false),
                "by": .string("key"),
                "reverse": .boolean(false),
            ]
        )

        let caseSensitive = arguments["case_sensitive"]!.isTruthy
        let by: String
        if case let .string(s) = arguments["by"] {
            by = s
        } else {
            by = "key"
        }
        let reverse = arguments["reverse"]!.isTruthy

        let sortedPairs: [(key: String, value: Value)]
        if by == "value" {
            sortedPairs = dict.sorted { a, b in
                let comparison =
                    caseSensitive
                    ? a.value.description.compare(b.value.description)
                    : a.value.description.localizedCaseInsensitiveCompare(b.value.description)
                return reverse ? comparison == .orderedDescending : comparison == .orderedAscending
            }
        } else {
            sortedPairs = dict.sorted { a, b in
                let comparison =
                    caseSensitive
                    ? a.key.compare(b.key)
                    : a.key.localizedCaseInsensitiveCompare(b.key)
                return reverse ? comparison == .orderedDescending : comparison == .orderedAscending
            }
        }

        let resultArray = sortedPairs.map { key, value in
            Value.array([.string(key), value])
        }
        return .array(resultArray)
    }

    // MARK: - String Processing Filters

    /// Escapes HTML characters.
    @Sendable public static func forceescape(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard case let .string(str) = args.first else {
            return .string("")
        }

        _ = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: [],
            defaults: [:]
        )

        let escaped =
            str
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&#34;")
            .replacingOccurrences(of: "'", with: "&#39;")
        return .string(escaped)
    }

    /// Marks a string as safe (no-op for basic implementation).
    @Sendable public static func safe(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        _ = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: [],
            defaults: [:]
        )

        return args.first ?? .string("")
    }

    /// Strips HTML tags from a string.
    @Sendable public static func striptags(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard case let .string(str) = args.first else {
            return .string("")
        }

        _ = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: [],
            defaults: [:]
        )

        let htmlTags = /<[^>]+>/.ignoresCase()
        let noTags = str.replacing(htmlTags, with: "")
        let components = noTags.components(separatedBy: .whitespacesAndNewlines)
        return .string(components.filter { !$0.isEmpty }.joined(separator: " "))
    }

    /// Basic string formatting.
    @Sendable public static func format(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard args.count > 1, case let .string(formatString) = args[0] else {
            return args.first ?? .string("")
        }

        _ = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: [],
            defaults: [:]
        )

        let formatArgs = Array(args.dropFirst())
        var result = ""
        var formatIdx = formatString.startIndex
        var argIdx = 0
        while formatIdx < formatString.endIndex {
            let char = formatString[formatIdx]
            if char == "%", argIdx < formatArgs.count {
                let nextIdx = formatString.index(after: formatIdx)
                if nextIdx < formatString.endIndex {
                    let specifier = formatString[nextIdx]
                    if specifier == "s" {
                        result += formatArgs[argIdx].description
                        argIdx += 1
                    } else {
                        result.append("%")
                        result.append(specifier)
                    }
                    formatIdx = formatString.index(after: nextIdx)
                } else {
                    result.append("%")
                    formatIdx = nextIdx
                }
            } else {
                result.append(char)
                formatIdx = formatString.index(after: formatIdx)
            }
        }
        return .string(result)
    }

    /// Wraps text to a specified width.
    @Sendable public static func wordwrap(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first, case let .string(str) = value else {
            return .string("")
        }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["width", "break_long_words", "wrapstring", "break_on_hyphens"],
            defaults: [
                "width": .int(79),
                "break_long_words": .boolean(true),
                "wrapstring": .null,
                "break_on_hyphens": .boolean(true),
            ]
        )

        let width: Int
        if case let .int(w) = arguments["width"] {
            width = w
        } else {
            width = 79
        }
        let breakLongWords = arguments["break_long_words"]!.isTruthy
        let breakOnHyphens = arguments["break_on_hyphens"]!.isTruthy

        let wrapstring: String
        if case let .string(value) = arguments["wrapstring"] {
            wrapstring = value
        } else {
            wrapstring = "\n"
        }

        var lines = [String]()
        let paragraphs = str.components(separatedBy: .newlines)
        for paragraph in paragraphs {
            var line = ""
            let words = paragraph.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

            func flushLine() {
                if !line.isEmpty {
                    lines.append(line)
                    line = ""
                }
            }

            func splitToken(_ token: String) -> [String] {
                if !breakLongWords || token.count <= width {
                    return [token]
                }

                var parts = [String]()
                let segments: [String]
                if breakOnHyphens, token.contains("-") {
                    let raw = token.split(separator: "-", omittingEmptySubsequences: false)
                    segments = raw.enumerated().map { index, segment in
                        if index < raw.count - 1 {
                            return "\(segment)-"
                        }
                        return String(segment)
                    }
                } else {
                    segments = [token]
                }

                for segment in segments {
                    if segment.count <= width {
                        parts.append(segment)
                    } else {
                        var startIndex = segment.startIndex
                        while startIndex < segment.endIndex {
                            let endIndex =
                                segment.index(
                                    startIndex,
                                    offsetBy: width,
                                    limitedBy: segment.endIndex
                                ) ?? segment.endIndex
                            parts.append(String(segment[startIndex ..< endIndex]))
                            startIndex = endIndex
                        }
                    }
                }
                return parts
            }

            for word in words {
                for token in splitToken(word) {
                    if line.isEmpty {
                        line = token
                    } else if line.count + token.count + 1 <= width {
                        line += " \(token)"
                    } else {
                        flushLine()
                        line = token
                    }
                }
            }

            flushLine()
        }
        return .string(lines.joined(separator: wrapstring))
    }

    /// Formats file size in human readable format.
    @Sendable public static func filesizeformat(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first else {
            return .string("")
        }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["binary"],
            defaults: ["binary": .boolean(false)]
        )

        let bytes: Double
        switch value {
        case let .double(num):
            bytes = num
        case let .int(num):
            bytes = Double(num)
        default:
            return .string("")
        }

        let binary = arguments["binary"]!.isTruthy
        let unit: Double = binary ? 1024 : 1000
        if bytes < unit {
            return .string("\(Int(bytes)) Bytes")
        }
        let exp = Int(log(bytes) / log(unit))
        let pre = (binary ? "KMGTPEZY" : "kMGTPEZY")
        let clampedExp = Swift.min(Swift.max(exp, 1), pre.count)
        let preIndex = pre.index(pre.startIndex, offsetBy: clampedExp - 1)
        let preChar = pre[preIndex]
        let suffix = binary ? "iB" : "B"
        return .string(
            String(
                format: "%.1f %@\(suffix)",
                bytes / pow(unit, Double(clampedExp)),
                String(preChar)
            )
        )
    }

    /// Formats object attributes as XML attributes.
    @Sendable public static func xmlattr(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first, case let .object(dict) = value else {
            return .string("")
        }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["autospace"],
            defaults: ["autospace": .boolean(true)]
        )

        let autospace = arguments["autospace"]!.isTruthy
        var result = ""
        var needsSpace = false
        for (key, value) in dict {
            if value == .null || value == .undefined { continue }
            // Validate key doesn't contain invalid characters
            if key.contains(" ") || key.contains("/") || key.contains(">") || key.contains("=") {
                throw JinjaError.runtime("Invalid character in XML attribute key: '\(key)'")
            }
            let escapedValue = value.description
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            if needsSpace { result += " " }
            result += "\(key)=\"\(escapedValue)\""
            needsSpace = true
        }
        if autospace && !result.isEmpty {
            result = " " + result
        }
        return .string(result)
    }

    /// Converts a value to a string.
    @Sendable public static func string(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first else { return .string("") }

        _ = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: [],
            defaults: [:]
        )

        return .string(value.description)
    }

    // MARK: - Additional Filters

    /// Trims whitespace from a string.
    @Sendable public static func trim(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard case let .string(str) = args.first else {
            return .string("")
        }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["chars"],
            defaults: ["chars": .null]
        )

        let characterSet: CharacterSet
        if case let .string(chars) = arguments["chars"], !chars.isEmpty {
            characterSet = CharacterSet(charactersIn: chars)
        } else {
            characterSet = .whitespacesAndNewlines
        }

        return .string(str.trimmingCharacters(in: characterSet))
    }

    /// Escapes HTML characters (alias for forceescape).
    @Sendable public static func escape(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        _ = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: [],
            defaults: [:]
        )

        return try forceescape(args, kwargs: kwargs, env: env)
    }

    /// Converts value to JSON string.
    ///
    /// - Parameters:
    ///   - indent: Number of spaces to use for indentation (optional).
    ///   - ensure_ascii: If true (default), escape non-ASCII characters as `\uXXXX`.
    ///                   If false, output Unicode characters directly.
    @Sendable public static func tojson(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first else { return .string("null") }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["indent", "ensure_ascii"],
            defaults: ["indent": .null, "ensure_ascii": .boolean(true)]
        )

        let encoder = JSONEncoder()
        if let indent = arguments["indent"],
            case .int(let count) = indent,
            count > 0
        {
            encoder.outputFormatting = .prettyPrinted
        }

        let ensureASCII: Bool
        if let ensureASCIIValue = arguments["ensure_ascii"] {
            ensureASCII = ensureASCIIValue.isTruthy
        } else {
            ensureASCII = true
        }

        if let jsonData = (try? encoder.encode(value)),
            let jsonString = String(data: jsonData, encoding: .utf8)
        {
            if ensureASCII {
                return .string(escapeNonASCII(jsonString))
            }
            return .string(jsonString)
        } else {
            return .string("null")
        }
    }

    /// Escapes non-ASCII characters in a string as `\uXXXX` sequences.
    private static func escapeNonASCII(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.utf16.count)
        // Iterate UTF-16 code units so non-BMP scalars emit surrogate pairs.
        for codeUnit in string.utf16 {
            if codeUnit > 127 {
                result += String(format: "\\u%04x", codeUnit)
            } else if let scalar = UnicodeScalar(codeUnit) {
                result.append(Character(scalar))
            }
        }
        return result
    }

    /// Returns absolute value of a number.
    @Sendable public static func abs(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first else {
            return .int(0)
        }

        _ = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: [],
            defaults: [:]
        )

        switch value {
        case let .int(i):
            return .int(Swift.abs(i))
        case let .double(n):
            return .double(Swift.abs(n))
        default:
            throw JinjaError.runtime("abs filter requires number or integer")
        }
    }

    /// Capitalizes the first letter and lowercases the rest.
    @Sendable public static func capitalize(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard case let .string(str) = args.first else {
            return .string("")
        }

        _ = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: [],
            defaults: [:]
        )

        return .string(str.prefix(1).uppercased() + str.dropFirst().lowercased())
    }

    /// Centers a string within a specified width.
    @Sendable public static func center(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard case let .string(str) = args.first else {
            return args.first ?? .string("")
        }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["width"],
            defaults: [:]
        )

        guard case let .int(width) = arguments["width"] else {
            throw JinjaError.runtime("center filter requires width parameter")
        }

        let padCount = width - str.count
        if padCount <= 0 {
            return .string(str)
        }
        let leftPad = String(repeating: " ", count: padCount / 2)
        let rightPad = String(repeating: " ", count: padCount - (padCount / 2))
        return .string(leftPad + str + rightPad)
    }

    /// Converts a value to float.
    @Sendable public static func float(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first else { return .double(0.0) }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["default"],
            defaults: ["default": .double(0.0)]
        )

        let defaultValue = arguments["default"]!

        switch value {
        case let .int(i):
            return .double(Double(i))
        case let .double(n):
            return .double(n)
        case let .string(s):
            if let converted = Double(s) {
                return .double(converted)
            } else {
                return defaultValue
            }
        default:
            return defaultValue
        }
    }

    /// Converts a value to integer.
    @Sendable public static func int(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first else { return .int(0) }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["default", "base"],
            defaults: ["default": .int(0), "base": .int(10)]
        )

        let defaultValue = arguments["default"]!
        let base: Int
        if case let .int(value) = arguments["base"] {
            base = value
        } else {
            base = 10
        }

        switch value {
        case let .int(i):
            return .int(i)
        case let .double(n):
            return .int(Int(n))
        case let .string(s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("0b") || trimmed.hasPrefix("0B") {
                let digits = String(trimmed.dropFirst(2))
                if let converted = Int(digits, radix: 2) { return .int(converted) }
                return defaultValue
            }
            if trimmed.hasPrefix("0o") || trimmed.hasPrefix("0O") {
                let digits = String(trimmed.dropFirst(2))
                if let converted = Int(digits, radix: 8) { return .int(converted) }
                return defaultValue
            }
            if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
                let digits = String(trimmed.dropFirst(2))
                if let converted = Int(digits, radix: 16) { return .int(converted) }
                return defaultValue
            }
            if base != 10, (2 ... 36).contains(base), let converted = Int(trimmed, radix: base) {
                return .int(converted)
            }
            if let converted = Int(trimmed) {
                return .int(converted)
            }
            return defaultValue
        default:
            return defaultValue
        }
    }

    /// Converts a value to list.
    /// If it was a string the returned list will be a list of characters.
    @Sendable public static func list(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first else { return .array([]) }

        _ = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: [],
            defaults: [:]
        )

        switch value {
        case let .array(arr):
            return .array(arr)
        case let .string(str):
            return .array(str.map { .string(String($0)) })
        case let .object(dict):
            return .array(dict.values.map { $0 })
        default:
            return .array([])
        }
    }

    /// Returns the maximum value from an array.
    @Sendable public static func max(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first, case let .array(items) = value else { return .undefined }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["case_sensitive", "attribute"],
            defaults: ["case_sensitive": .boolean(false), "attribute": .null]
        )

        let caseSensitive = arguments["case_sensitive"]!.isTruthy

        if case let .string(attribute) = arguments["attribute"] {
            return try items.max(by: { a, b in
                let aValue = try PropertyMembers.evaluate(a, attribute)
                let bValue = try PropertyMembers.evaluate(b, attribute)
                return try compareValues(aValue, bValue, caseSensitive: caseSensitive) < 0
            }) ?? .undefined
        } else {
            return items.max(by: { a, b in
                do {
                    return try compareValues(a, b, caseSensitive: caseSensitive) < 0
                } catch {
                    return false
                }
            }) ?? .undefined
        }
    }

    /// Returns the minimum value from an array.
    @Sendable public static func min(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first, case let .array(items) = value else { return .undefined }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["case_sensitive", "attribute"],
            defaults: ["case_sensitive": .boolean(false), "attribute": .null]
        )

        let caseSensitive = arguments["case_sensitive"]!.isTruthy

        if case let .string(attribute) = arguments["attribute"] {
            return try items.min(by: { a, b in
                let aValue = try PropertyMembers.evaluate(a, attribute)
                let bValue = try PropertyMembers.evaluate(b, attribute)
                return try compareValues(aValue, bValue, caseSensitive: caseSensitive) < 0
            }) ?? .undefined
        } else {
            return items.min(by: { a, b in
                do {
                    return try compareValues(a, b, caseSensitive: caseSensitive) < 0
                } catch {
                    return false
                }
            }) ?? .undefined
        }
    }

    /// Rounds a number to specified precision.
    @Sendable public static func round(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first else { return .double(0.0) }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["precision", "method"],
            defaults: ["precision": .int(0), "method": .string("common")]
        )

        let number: Double
        switch value {
        case let .int(intValue):
            number = Double(intValue)
        case let .double(doubleValue):
            number = doubleValue
        default:
            return value  // Or throw error
        }

        let precision: Int
        if case let .int(p) = arguments["precision"]! {
            precision = p
        } else {
            precision = 0
        }

        let method: String
        if case let .string(m) = arguments["method"]! {
            method = m
        } else {
            method = "common"
        }

        if method == "common" {
            let divisor = pow(10.0, Double(precision))
            return .double((number * divisor).rounded() / divisor)
        } else if method == "ceil" {
            let divisor = pow(10.0, Double(precision))
            return .double(ceil(number * divisor) / divisor)
        } else if method == "floor" {
            let divisor = pow(10.0, Double(precision))
            return .double(floor(number * divisor) / divisor)
        }
        return .double(number)
    }

    /// Capitalizes each word in a string.
    @Sendable public static func title(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard case let .string(str) = args.first else {
            return .string("")
        }

        _ = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: [],
            defaults: [:]
        )

        return .string(str.capitalized)
    }

    /// Counts words in a string.
    @Sendable public static func wordcount(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard case let .string(str) = args.first else {
            return .int(0)
        }

        _ = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: [],
            defaults: [:]
        )

        let words = str.split { $0.isWhitespace || $0.isNewline }
        return .int(words.count)
    }

    /// Return string with all occurrences of a substring replaced with a new one.
    /// The first argument is the substring that should be replaced,
    /// the second is the replacement string.
    /// If the optional third argument count is given,
    /// only the first count occurrences are replaced.
    @Sendable public static func replace(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard case let .string(str) = args.first else {
            return args.first ?? .string("")
        }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["old", "new", "count"],
            defaults: ["count": .null]
        )

        guard case let .string(old) = arguments["old"],
            case let .string(new) = arguments["new"]
        else {
            throw JinjaError.runtime("replace() requires 'old' and 'new' string arguments.")
        }

        // Handle count parameter - can be positional (3rd arg) or named (count=)
        let count: Int?
        if case let .int(c) = arguments["count"] {
            count = c
        } else {
            count = nil
        }

        // Special case: replacing empty string inserts at character boundaries
        if old.isEmpty {
            var result = ""
            var replacements = 0

            // Insert at the beginning
            if count == nil || replacements < count! {
                result += new
                replacements += 1
            }

            // Insert between each character
            for char in str {
                result += String(char)
                if count == nil || replacements < count! {
                    result += new
                    replacements += 1
                }
            }

            return .string(result)
        }

        // Regular case: replace occurrences of the substring
        var result = ""
        var remaining = str
        var replacements = 0

        while let range = remaining.range(of: old) {
            if let count = count, replacements >= count {
                break
            }

            result += remaining[..<range.lowerBound]
            result += new
            remaining = String(remaining[range.upperBound...])
            replacements += 1
        }

        result += remaining
        return .string(result)
    }

    /// URL encodes a string or object.
    @Sendable public static func urlencode(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first else {
            return .string("")
        }

        _ = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: [],
            defaults: [:]
        )

        if case let .string(s) = value {
            return .string(s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        }
        if case .object(let dict) = value {
            var components = URLComponents()
            components.queryItems = dict.map { key, value in
                URLQueryItem(name: key, value: value.description)
            }
            return .string(components.percentEncodedQuery ?? "")
        }
        return .string("")
    }

    /// Batches items into groups.
    @Sendable public static func batch(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first, case let .array(items) = value else {
            return .array([])
        }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["batchSize", "fillWith"],
            defaults: ["fillWith": .null]
        )

        guard case let .int(batchSize) = arguments["batchSize"], batchSize > 0 else {
            throw JinjaError.runtime("batch filter requires positive integer batchSize parameter")
        }

        let fillWith = arguments["fillWith"]!

        var result = [Value]()
        var batch = [Value]()
        for item in items {
            batch.append(item)
            if batch.count == batchSize {
                result.append(.array(batch))
                batch = []
            }
        }
        if !batch.isEmpty {
            while batch.count < batchSize {
                batch.append(fillWith)
            }
            result.append(.array(batch))
        }
        return .array(result)
    }

    /// Sums values in an array.
    @Sendable public static func sum(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first, case let .array(items) = value else {
            return .int(0)
        }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["attribute", "start"],
            defaults: ["attribute": .null, "start": .int(0)]
        )

        let start = arguments["start"]!

        let valuesToSum: [Value]
        if case let .string(attribute) = arguments["attribute"] {
            valuesToSum = try items.map { item in
                try PropertyMembers.evaluate(item, attribute)
            }
        } else {
            valuesToSum = items
        }

        let sum = try valuesToSum.reduce(start) { acc, next in
            try acc.add(with: next)
        }
        return sum
    }

    /// Truncates a string to a specified length.
    @Sendable public static func truncate(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard case let .string(str) = args.first else {
            return .string("")
        }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["length", "killwords", "end", "leeway"],
            defaults: [
                "length": .int(255),
                "killwords": .boolean(false),
                "end": .string("..."),
                "leeway": .int(5),
            ]
        )

        let length: Int
        if case let .int(l) = arguments["length"]! {
            length = l
        } else {
            length = 255
        }

        let killwords = arguments["killwords"]!.isTruthy

        let leeway: Int
        if case let .int(value) = arguments["leeway"]! {
            leeway = Swift.max(0, value)
        } else {
            leeway = 5
        }

        let end: String
        if case let .string(e) = arguments["end"]! {
            end = e
        } else {
            end = "..."
        }

        if str.count <= length + leeway {
            return .string(str)
        }

        if killwords {
            return .string(str.prefix(length) + end)
        } else {
            let truncated = str.prefix(length)
            if let lastSpace = truncated.lastIndex(where: { $0.isWhitespace }) {
                return .string(truncated[..<lastSpace] + end)
            } else {
                return .string(truncated + end)
            }
        }
    }

    /// Returns unique items from an array.
    @Sendable public static func unique(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first, case let .array(items) = value else {
            return .array([])
        }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["case_sensitive", "attribute"],
            defaults: ["case_sensitive": .boolean(false), "attribute": .null]
        )

        let caseSensitive = arguments["case_sensitive"]!.isTruthy

        func normalizedKey(_ value: Value) -> Value {
            if !caseSensitive, case let .string(str) = value {
                return .string(str.lowercased())
            }
            return value
        }

        var seen = Set<Value>()
        var result = [Value]()
        for item in items {
            let key: Value
            if let attribute = arguments["attribute"], attribute != .null {
                key = try resolveAttributeValue(item, attribute: attribute)
            } else {
                key = item
            }
            let normalized = normalizedKey(key)
            if !seen.contains(normalized) {
                seen.insert(normalized)
                result.append(item)
            }
        }
        return .array(result)
    }

    /// Indents text.
    @Sendable public static func indent(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard case let .string(str) = args.first else {
            return .string("")
        }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["width", "first", "blank"],
            defaults: ["width": .int(4), "first": .boolean(false), "blank": .boolean(false)]
        )

        let widthString: String
        switch arguments["width"] {
        case .int(let n):
            widthString = String(repeating: " ", count: n)
        case .string(let s):
            widthString = s
        default:
            widthString = "    "
        }

        let first = arguments["first"]!.isTruthy
        let blank = arguments["blank"]!.isTruthy

        let lines = str.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result = ""

        for (i, line) in lines.enumerated() {
            if i == 0 && !first {
                result += line
            } else if line.isEmpty && !blank {
                result += line
            } else {
                result += widthString + line
            }
            if i < lines.count - 1 {
                result += "\n"
            }
        }
        return .string(result)
    }

    /// Returns items (key-value pairs) of a dictionary/object.
    @Sendable public static func items(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first else {
            return .array([])
        }

        _ = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: [],
            defaults: [:]
        )

        if case let .object(obj) = value {
            let pairs = obj.map { key, value in
                Value.array([.string(key), value])
            }
            return .array(pairs)
        }

        return .array([])
    }

    /// Pretty prints a variable (useful for debugging).
    @Sendable public static func pprint(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard let value = args.first else { return .string("") }

        _ = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: [],
            defaults: [:]
        )

        func prettyPrint(_ val: Value, indent: Int = 0) -> String {
            let indentString = String(repeating: "  ", count: indent)
            switch val {
            case let .array(arr):
                if arr.isEmpty { return "[]" }
                let items = arr.map { prettyPrint($0, indent: indent + 1) }
                return "[\n" + items.map { "\(indentString)  \($0)" }.joined(separator: ",\n")
                    + "\n\(indentString)]"
            case let .object(dict):
                if dict.isEmpty { return "{}" }
                let items = dict.map { key, value in
                    "\(indentString)  \"\(key)\": \(prettyPrint(value, indent: indent + 1))"
                }
                return "{\n" + items.joined(separator: ",\n") + "\n\(indentString)}"
            case let .string(str):
                return "\"\(str)\""
            default:
                return val.description
            }
        }

        return .string(prettyPrint(value))
    }

    /// Converts URLs in text into clickable links.
    @Sendable public static func urlize(
        _ args: [Value],
        kwargs: [String: Value] = [:],
        env: Environment
    ) throws -> Value {
        guard case let .string(text) = args.first else {
            return .string("")
        }

        let arguments = try resolveCallArguments(
            args: Array(args.dropFirst()),
            kwargs: kwargs,
            parameters: ["trim_url_limit", "nofollow", "target", "rel", "extra_schemes"],
            defaults: [
                "trim_url_limit": .null,
                "nofollow": .boolean(false),
                "target": .null,
                "rel": .null,
                "extra_schemes": .null,
            ]
        )

        let trimUrlLimit: Int?
        if case let .int(limit)? = arguments["trim_url_limit"] {
            trimUrlLimit = limit
        } else {
            trimUrlLimit = nil
        }

        let nofollow = arguments["nofollow"]!.isTruthy

        let target: String?
        if case let .string(t)? = arguments["target"] {
            target = t
        } else {
            target = nil
        }

        let rel: String?
        if case let .string(r)? = arguments["rel"] {
            rel = r
        } else {
            rel = nil
        }

        func buildAttributes() -> String {
            var attributes = ""
            if nofollow { attributes += " rel=\"nofollow\"" }
            if let target = target { attributes += " target=\"\(htmlEscape(target))\"" }
            if let rel = rel { attributes += " rel=\"\(htmlEscape(rel))\"" }
            return attributes
        }

        let extraSchemes: Set<String> = {
            guard case let .array(values) = arguments["extra_schemes"] else { return [] }
            return Set(
                values.compactMap { value in
                    if case let .string(scheme) = value { return scheme.lowercased() }
                    return nil
                }
            )
        }()
        let safeSchemes = Set(["http", "https", "mailto"])
        let allowedSchemes = safeSchemes.union(extraSchemes)

        let leadingPunctuation = CharacterSet(charactersIn: "([")
        let trailingPunctuation = CharacterSet(charactersIn: ".,:;!?)\"]")

        let nsText = text as NSString
        let regex = try NSRegularExpression(pattern: "\\S+")
        var result = ""
        var lastIndex = 0
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            let range = match.range
            if range.location > lastIndex {
                result += nsText.substring(with: NSRange(location: lastIndex, length: range.location - lastIndex))
            }
            let word = nsText.substring(with: range)
            var core = word
            var prefix = ""
            var suffix = ""

            while let first = core.unicodeScalars.first, leadingPunctuation.contains(first) {
                prefix.append(Character(first))
                core.removeFirst()
            }
            while let last = core.unicodeScalars.last, trailingPunctuation.contains(last) {
                suffix.insert(Character(last), at: suffix.startIndex)
                core.removeLast()
            }

            var replacement = word
            if !core.isEmpty {
                let lower = core.lowercased()
                let hasScheme = core.contains(":")
                let isMailto = lower.hasPrefix("mailto:")
                let isHttp = lower.hasPrefix("http://") || lower.hasPrefix("https://")
                let isWww = lower.hasPrefix("www.")
                let isEmail = core.contains("@") && !isHttp && !isMailto

                let schemeMatch: Bool = {
                    guard hasScheme else { return false }
                    let scheme = lower.split(separator: ":").first.map(String.init) ?? ""
                    return allowedSchemes.contains(scheme)
                }()

                if isHttp || isWww || isMailto || isEmail || schemeMatch {
                    let url: String
                    if isEmail && !isMailto {
                        url = "mailto:\(core)"
                    } else if isWww {
                        url = "https://\(core)"
                    } else {
                        url = core
                    }

                    let displayUrl =
                        trimUrlLimit != nil && core.count > trimUrlLimit!
                        ? String(core.prefix(trimUrlLimit!)) + "..." : core
                    let escapedUrl = htmlEscape(url)
                    let escapedDisplayUrl = htmlEscape(displayUrl)
                    replacement =
                        "\(prefix)<a href=\"\(escapedUrl)\"\(buildAttributes())>\(escapedDisplayUrl)</a>\(suffix)"
                }
            }

            result += replacement
            lastIndex = range.location + range.length
        }

        if lastIndex < nsText.length {
            result += nsText.substring(from: lastIndex)
        }

        return .string(result)
    }

    /// Dictionary of all built-in filters available for use in templates.
    ///
    /// Each filter function accepts an array of values (with the input as the first element),
    /// optional keyword arguments, and the current environment, then returns a transformed value.
    public static let builtIn: [String: @Sendable ([Value], [String: Value], Environment) throws -> Value] = [
        "upper": upper,
        "lower": lower,
        "length": length,
        "count": length,  // alias for length
        "join": join,
        "default": `default`,
        "d": `default`,  // alias for default
        "first": first,
        "last": last,
        "random": random,
        "reverse": reverse,
        "sort": sort,
        "groupby": groupby,
        "slice": slice,
        "map": map,
        "select": select,
        "reject": reject,
        "selectattr": selectattr,
        "rejectattr": rejectattr,
        "attr": attr,
        "dictsort": dictsort,
        "forceescape": forceescape,
        "safe": safe,
        "striptags": striptags,
        "format": format,
        "wordwrap": wordwrap,
        "filesizeformat": filesizeformat,
        "xmlattr": xmlattr,
        "string": string,
        "trim": trim,
        "escape": escape,
        "e": escape,  // alias for escape
        "tojson": tojson,
        "abs": abs,
        "capitalize": capitalize,
        "center": center,
        "float": float,
        "int": int,
        "list": list,
        "max": max,
        "min": min,
        "round": round,
        "title": title,
        "wordcount": wordcount,
        "replace": replace,
        "urlencode": urlencode,
        "batch": batch,
        "sum": sum,
        "truncate": truncate,
        "unique": unique,
        "indent": indent,
        "items": items,
        "pprint": pprint,
        "urlize": urlize,
    ]
}

// MARK: -

private func resolveAttributeValue(_ item: Value, attribute: Value) throws -> Value {
    switch attribute {
    case let .string(name):
        return try PropertyMembers.evaluate(item, name)
    case let .int(index):
        switch item {
        case let .array(values):
            if index >= 0, index < values.count {
                return values[index]
            }
            return .undefined
        case let .object(values):
            return values[String(index)] ?? .undefined
        default:
            return .undefined
        }
    default:
        return .undefined
    }
}

private func compareValues(
    _ lhs: Value,
    _ rhs: Value,
    caseSensitive: Bool,
    useStringComparisonWhenCaseSensitive: Bool = false,
    fallbackToDescription: Bool = false
) throws -> Int {
    if case let .string(aStr) = lhs, case let .string(bStr) = rhs {
        if !caseSensitive || useStringComparisonWhenCaseSensitive {
            let left = caseSensitive ? aStr : aStr.lowercased()
            let right = caseSensitive ? bStr : bStr.lowercased()
            if left == right { return 0 }
            return left < right ? -1 : 1
        }
    }

    do {
        return try lhs.compare(to: rhs)
    } catch {
        if fallbackToDescription {
            let left = lhs.description
            let right = rhs.description
            if left == right { return 0 }
            return left < right ? -1 : 1
        }
        throw error
    }
}

private func htmlEscape(_ string: String) -> String {
    string
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&#34;")
        .replacingOccurrences(of: "'", with: "&#39;")
}
