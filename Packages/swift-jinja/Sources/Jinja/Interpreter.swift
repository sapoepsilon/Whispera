import Foundation
@_exported import OrderedCollections

// MARK: - Context

/// A context is a dictionary of variables and their values.
public typealias Context = [String: Value]

// MARK: - Environment

/// Execution environment that stores variables and provides context for template rendering.
///
/// The environment maintains the variable scope during template execution and provides
/// configuration options that affect rendering behavior.
public final class Environment: @unchecked Sendable {
    private let parent: Environment?
    private(set) var variables: [String: Value] = [:]

    // Options

    /// Whether leading spaces and tabs are stripped from the start of a line to a block.
    /// The default value is `false`.
    public var lstripBlocks: Bool = false

    /// Whether the first newline after a block is removed.
    /// This applies to block tags, not variable tags.
    /// The default value is `false`.
    public var trimBlocks: Bool = false

    // MARK: -

    /// Creates a new environment with optional parent and initial variables.
    ///
    /// - Parameters:
    ///   - parent: The parent environment to inherit variables from
    ///   - initial: The initial variables to set in this environment
    ///   - includeBuiltIns: Whether to include built-in functions (default: true)
    public init(
        parent: Environment? = nil,
        initial: [String: Value] = [:]
    ) {
        self.parent = parent
        self.variables = initial

        if parent == nil {
            // Only add built-ins to the root environment to avoid duplication
            for (name, value) in Globals.builtIn {
                self.variables[name] = value
            }
        }
    }

    /// Gets or sets a variable in the environment.
    ///
    /// When getting a variable, this looks in the current environment first,
    /// then in parent environments. Returns `.undefined` if the variable is not found.
    ///
    /// - Parameter name: The variable name
    /// - Returns: The value associated with the variable name, or `.undefined`
    public subscript(name: String) -> Value {
        get {
            if let value = variables[name] {
                return value
            }

            // Check parent environment
            if let parent = parent {
                return parent[name]
            }

            return .undefined
        }
        set {
            variables[name] = newValue
        }
    }

    /// Sets a variable in the environment where it was originally defined.
    /// This searches up the environment chain to find where the variable exists
    /// and updates it there, ensuring namespace mutations persist across scopes.
    func setInChain(name: String, value: Value) {
        // Check if the variable exists in the current environment's variables
        if variables[name] != nil {
            self[name] = value
            return
        }

        // Search up the parent chain to find where the variable is defined
        if let parentEnv = parent {
            parentEnv.setInChain(name: name, value: value)
            return
        }

        // Fallback to setting in the current environment
        self[name] = value
    }
}

// MARK: - Interpreter

/// Internal control flow exceptions for loop statements.
enum ControlFlow: Error, Sendable {
    /// Control flow exception for break statement.
    case `break`
    /// Control flow exception for continue statement.
    case `continue`
}

/// Executes parsed Jinja template nodes to produce rendered output.
public enum Interpreter {
    /// Interprets nodes and renders them to a string using the given environment.
    ///
    /// - Parameters:
    ///   - nodes: The AST nodes to interpret and render
    ///   - environment: The execution environment containing variables
    /// - Returns: The rendered template output as a string
    /// - Throws: `RuntimeError` if an error occurs during interpretation
    public static func interpret(_ nodes: [Node], environment: Environment) throws -> String {
        // Use the fast path with synchronous environment
        let env = Environment(initial: environment.variables)
        var buffer = ""
        buffer.reserveCapacity(1024)
        try interpret(nodes, env: env, into: &buffer)
        return buffer
    }

    // MARK: -

    static func interpret(
        _ nodes: [Node],
        env: Environment,
        into buffer: inout String
    )
        throws
    {
        for node in nodes {
            try interpretNode(node, env: env, into: &buffer)
        }
    }

    static func interpretNode(
        _ node: Node,
        env: Environment,
        into buffer: inout String
    )
        throws
    {
        switch node {
        case let .text(content):
            buffer.append(content)

        case .comment:
            // Comments are ignored during execution
            break

        case let .expression(expr):
            let value = try evaluateExpression(expr, env: env)
            buffer.append(value.description)

        case let .statement(stmt):
            try executeStatementWithOutput(stmt, env: env, into: &buffer)
        }
    }

    static func evaluateExpression(_ expr: Expression, env: Environment) throws -> Value {
        switch expr {
        case let .string(value):
            return .string(value)

        case let .number(value):
            return .double(value)

        case let .integer(value):
            return .int(value)

        case let .boolean(value):
            return .boolean(value)

        case .null:
            return .null

        case let .array(elements):
            let values = try elements.map { try evaluateExpression($0, env: env) }
            return .array(values)

        case let .tuple(elements):
            let values = try elements.map { try evaluateExpression($0, env: env) }
            return .array(values)  // Tuples are represented as arrays in the runtime

        case let .object(pairs):
            let dict = try pairs.mapValues { try evaluateExpression($0, env: env) }
            return .object(dict)

        case let .identifier(name):
            return env[name]

        case let .unary(op, operand):
            let value = try evaluateExpression(operand, env: env)
            return try evaluateUnaryValue(op, value)

        case let .binary(op, left, right):
            let leftValue = try evaluateExpression(left, env: env)

            // Handle short-circuiting operators
            switch op {
            case .and:
                return leftValue.isTruthy ? try evaluateExpression(right, env: env) : leftValue
            case .or:
                return leftValue.isTruthy ? leftValue : try evaluateExpression(right, env: env)
            default:
                let rightValue = try evaluateExpression(right, env: env)
                return try evaluateBinaryValues(op, leftValue, rightValue)
            }

        case let .ternary(value, test, alternate):
            let testValue = try evaluateExpression(test, env: env)
            if testValue.isTruthy {
                return try evaluateExpression(value, env: env)
            } else if let alternate = alternate {
                return try evaluateExpression(alternate, env: env)
            } else {
                return .null
            }

        case let .member(object, property, computed):
            let objectValue = try evaluateExpression(object, env: env)

            if computed {
                let propertyValue = try evaluateExpression(property, env: env)
                return try evaluateComputedMember(objectValue, propertyValue)
            } else {
                guard case let .identifier(propertyName) = property else {
                    throw JinjaError.runtime("Property access requires identifier")
                }
                return try PropertyMembers.evaluate(objectValue, propertyName)
            }

        case let .filter(operand, filterName, args, kwargs):
            let operandValue = try evaluateExpression(operand, env: env)
            let argValues = try [operandValue] + args.map { try evaluateExpression($0, env: env) }
            let kwargValues = try kwargs.mapValues { try evaluateExpression($0, env: env) }
            return try evaluateFilter(filterName, argValues, kwargs: kwargValues, env: env)

        case let .test(operand, testName, args, negated):
            let operandValue = try evaluateExpression(operand, env: env)
            let argValues = try [operandValue] + args.map { try evaluateExpression($0, env: env) }
            let result = try evaluateTest(testName, argValues, env: env)
            return .boolean(negated ? !result : result)

        case let .call(callableExpr, argsExpr, kwargsExpr):
            let callableValue = try evaluateExpression(callableExpr, env: env)

            // Handle unpacking in arguments
            var argValues: [Value] = []
            for argExpr in argsExpr {
                if case let .unary(.splat, expr) = argExpr {
                    // Unpack the array/tuple
                    let value = try evaluateExpression(expr, env: env)
                    if case let .array(items) = value {
                        argValues.append(contentsOf: items)
                    } else {
                        throw JinjaError.runtime("Cannot unpack non-array value")
                    }
                } else {
                    argValues.append(try evaluateExpression(argExpr, env: env))
                }
            }

            let kwargs = try kwargsExpr.mapValues { try evaluateExpression($0, env: env) }

            switch callableValue {
            case .function(let function):
                return try function(argValues, kwargs, env)
            case .macro(let macro):
                return try callMacro(
                    macro: macro,
                    arguments: argValues,
                    keywordArguments: kwargs,
                    env: env
                )
            default:
                throw JinjaError.runtime("Cannot call non-function value")
            }

        case let .slice(array, start, stop, step):
            let value = try evaluateExpression(array, env: env)
            return try evaluateSlice(value: value, start: start, stop: stop, step: step, env: env)
        }
    }

    /// Synchronous statement execution with output
    static func executeStatementWithOutput(
        _ statement: Statement,
        env: Environment,
        into buffer: inout String
    )
        throws
    {
        switch statement {
        case let .`if`(test, body, alternate):
            let testValue = try evaluateExpression(test, env: env)
            let nodesToExecute = testValue.isTruthy ? body : alternate

            for node in nodesToExecute {
                try interpretNode(node, env: env, into: &buffer)
            }

        case let .for(loopVar, iterable, body, elseBody, test):
            let iterableValue = try evaluateExpression(iterable, env: env)

            switch iterableValue {
            case let .array(items):
                if items.isEmpty {
                    // Execute else block
                    for node in elseBody {
                        try interpretNode(node, env: env, into: &buffer)
                    }
                } else {
                    let childEnv = Environment(parent: env)
                    for (index, item) in items.enumerated() {
                        // Set loop variables
                        switch loopVar {
                        case let .single(varName):
                            childEnv[varName] = item
                        case let .tuple(varNames):
                            if case let .array(tupleItems) = item {
                                for (i, varName) in varNames.enumerated() {
                                    let value = i < tupleItems.count ? tupleItems[i] : .undefined
                                    childEnv[varName] = value
                                }
                            }
                        }

                        childEnv["loop"] = makeLoopObject(index: index, totalCount: items.count)
                        if let test = test {
                            let testValue = try evaluateExpression(test, env: childEnv)
                            if !testValue.isTruthy { continue }
                        }

                        var shouldBreak = false
                        for node in body {
                            do {
                                try interpretNode(node, env: childEnv, into: &buffer)
                            } catch ControlFlow.break {
                                shouldBreak = true
                                break
                            } catch ControlFlow.continue {
                                break  // Break from inner loop (current iteration)
                            }
                        }
                        if shouldBreak { break }
                    }
                }

            case let .object(dict):
                if dict.isEmpty {
                    for node in elseBody { try interpretNode(node, env: env, into: &buffer) }
                } else {
                    let childEnv = Environment(parent: env)
                    for (index, (key, value)) in dict.enumerated() {
                        switch loopVar {
                        case let .single(varName):
                            // Single variable gets the key
                            childEnv[varName] = .string(key)
                        case let .tuple(varNames):
                            // Tuple unpacking: first gets key, second gets value
                            if varNames.count >= 1 {
                                childEnv[varNames[0]] = .string(key)
                            }
                            if varNames.count >= 2 {
                                childEnv[varNames[1]] = value
                            }
                            // Set remaining variables to undefined
                            for i in 2 ..< varNames.count {
                                childEnv[varNames[i]] = .undefined
                            }
                        }
                        childEnv["loop"] = makeLoopObject(index: index, totalCount: dict.count)
                        if let test = test {
                            let testValue = try evaluateExpression(test, env: childEnv)
                            if !testValue.isTruthy { continue }
                        }
                        for node in body { try interpretNode(node, env: childEnv, into: &buffer) }
                    }
                }
            case let .string(str):
                let chars = str.map { Value.string(String($0)) }
                if chars.isEmpty {
                    for node in elseBody { try interpretNode(node, env: env, into: &buffer) }
                } else {
                    let childEnv = Environment(parent: env)
                    for (index, item) in chars.enumerated() {
                        switch loopVar {
                        case let .single(varName):
                            childEnv[varName] = item
                        case let .tuple(varNames):
                            for (i, varName) in varNames.enumerated() {
                                childEnv[varName] = i == 0 ? item : .undefined
                            }
                        }
                        childEnv["loop"] = makeLoopObject(index: index, totalCount: chars.count)
                        if let test = test {
                            let testValue = try evaluateExpression(test, env: childEnv)
                            if !testValue.isTruthy { continue }
                        }
                        for node in body { try interpretNode(node, env: childEnv, into: &buffer) }
                    }
                }
            default:
                throw JinjaError.runtime("Cannot iterate over non-iterable value")
            }

        case let .set(target, value, body):
            if let valueExpr = value {
                let evaluatedValue = try evaluateExpression(valueExpr, env: env)
                try assign(target: target, value: evaluatedValue, env: env)
            } else {
                var bodyBuffer = ""
                try interpret(body, env: env, into: &bodyBuffer)
                let renderedBody = bodyBuffer
                let valueToAssign = Value.string(renderedBody)
                try assign(target: target, value: valueToAssign, env: env)
            }

        case let .macro(name, parameters, defaults, body):
            try registerMacro(
                name: name,
                parameters: parameters,
                defaults: defaults,
                body: body,
                env: env
            )

        case let .program(nodes):
            try interpret(nodes, env: env, into: &buffer)

        case let .call(callExpr, callerParameters, body):
            let callable: Expression
            let args: [Expression]
            let kwargs: [String: Expression]
            switch callExpr {
            case let .call(c, a, k):
                callable = c
                args = a
                kwargs = k
            default:
                callable = callExpr
                args = []
                kwargs = [:]
            }

            let callableValue = try evaluateExpression(callable, env: env)

            let callTimeEnv = Environment(parent: env)
            callTimeEnv["caller"] = .function { callerArgs, _, _ in
                let bodyEnv = Environment(parent: env)
                for (paramName, value) in zip(callerParameters ?? [], callerArgs) {
                    guard case let .identifier(paramName) = paramName else {
                        throw JinjaError.runtime("Caller parameter must be an identifier")
                    }
                    bodyEnv[paramName] = value
                }
                var bodyBuffer = ""
                try interpret(body, env: bodyEnv, into: &bodyBuffer)
                return .string(bodyBuffer)
            }

            let finalArgs = try args.map { try evaluateExpression($0, env: env) }
            let finalKwargs = try kwargs.mapValues { try evaluateExpression($0, env: env) }

            switch callableValue {
            case .function(let function):
                let result = try function(finalArgs, finalKwargs, callTimeEnv)
                buffer.append(result.description)
            case .macro(let macro):
                let result = try callMacro(
                    macro: macro,
                    arguments: finalArgs,
                    keywordArguments: finalKwargs,
                    env: callTimeEnv
                )
                buffer.append(result.description)
            default:
                throw JinjaError.runtime("Cannot call non-function value")
            }

        case let .filter(filterExpr, body):
            var bodyBuffer = ""
            try interpret(body, env: env, into: &bodyBuffer)
            let renderedBody = bodyBuffer

            if case let .filter(_, name, args, _) = filterExpr {
                var filterArgs = [Value.string(renderedBody)]
                filterArgs.append(contentsOf: try args.map { try evaluateExpression($0, env: env) })
                // TODO: Handle kwargs in filters if necessary
                let filteredValue = try evaluateFilter(name, filterArgs, kwargs: [:], env: env)
                buffer.append(filteredValue.description)
            } else if case let .identifier(name) = filterExpr {
                let filteredValue = try evaluateFilter(
                    name,
                    [.string(renderedBody)],
                    kwargs: [:],
                    env: env
                )
                buffer.append(filteredValue.description)
            } else {
                throw JinjaError.runtime("Invalid filter expression in filter statement")
            }

        case let .generation(body):
            try interpret(body, env: env, into: &buffer)

        case .break:
            throw ControlFlow.break
        case .continue:
            throw ControlFlow.continue
        }
    }

    static func executeStatement(_ statement: Statement, env: Environment) throws {
        switch statement {
        case let .set(target, value, body):
            if let valueExpr = value {
                let evaluatedValue = try evaluateExpression(valueExpr, env: env)
                try assign(target: target, value: evaluatedValue, env: env)
            } else {
                var bodyBuffer = ""
                try interpret(body, env: env, into: &bodyBuffer)
                let renderedBody = bodyBuffer
                let valueToAssign = Value.string(renderedBody)
                try assign(target: target, value: valueToAssign, env: env)
            }

        case let .macro(name, parameters, defaults, body):
            try registerMacro(
                name: name,
                parameters: parameters,
                defaults: defaults,
                body: body,
                env: env
            )

        // These statements do not produce output directly or are handled elsewhere.
        case .if, .for, .program, .break, .continue, .call, .filter, .generation:
            break
        }
    }

    static func assign(target: Expression, value: Value, env: Environment) throws {
        switch target {
        case .identifier(let name):
            env[name] = value
        case .tuple(let expressions):
            guard case let .array(values) = value else {
                throw JinjaError.runtime("Cannot unpack non-array value for tuple assignment.")
            }
            guard expressions.count == values.count else {
                throw JinjaError.runtime(
                    "Tuple assignment mismatch: \(expressions.count) variables and \(values.count) values."
                )
            }
            for (expr, val) in zip(expressions, values) {
                try assign(target: expr, value: val, env: env)
            }
        case .member(let objectExpr, let propertyExpr, let computed):
            // Handle property assignment like ns.foo = 'bar'
            let objectValue = try evaluateExpression(objectExpr, env: env)

            if computed {
                let propertyValue = try evaluateExpression(propertyExpr, env: env)
                guard case let .string(key) = propertyValue else {
                    throw JinjaError.runtime("Computed property key must be a string")
                }
                if case var .object(dict) = objectValue {
                    dict[key] = value
                    // Update the object in the environment
                    if case let .identifier(name) = objectExpr {
                        env.setInChain(name: name, value: .object(dict))
                    }
                }
            } else {
                guard case let .identifier(propertyName) = propertyExpr else {
                    throw JinjaError.runtime("Property assignment requires identifier")
                }
                if case var .object(dict) = objectValue {
                    dict[propertyName] = value
                    // Update the object in the environment
                    if case let .identifier(name) = objectExpr {
                        env.setInChain(name: name, value: .object(dict))
                    }
                }
            }
        default:
            throw JinjaError.runtime("Invalid target for assignment: \(target)")
        }
    }

    // MARK: -

    static func registerMacro(
        name: String,
        parameters: [String],
        defaults: OrderedDictionary<String, Expression>,
        body: [Node],
        env: Environment
    ) throws {
        env[name] = .macro(
            Macro(name: name, parameters: parameters, defaults: defaults, body: body)
        )
    }

    static func callMacro(
        macro: Macro,
        arguments: [Value],
        keywordArguments: [String: Value],
        env: Environment
    ) throws -> Value {
        let macroEnv = Environment(parent: env)

        let caller = env["caller"]
        if caller != .undefined {
            macroEnv["caller"] = caller
        }

        // Start with defaults
        for (key, expr) in macro.defaults {
            // Evaluate defaults in current env
            let val = try evaluateExpression(expr, env: env)
            macroEnv[key] = val
        }

        // Bind positional args
        for (index, paramName) in macro.parameters.enumerated() {
            let value =
                index < arguments.count ? arguments[index] : macroEnv[paramName]
            macroEnv[paramName] = value
        }

        // Bind keyword args
        for (key, value) in keywordArguments {
            macroEnv[key] = value
        }

        var macroBuffer = ""
        try interpret(macro.body, env: macroEnv, into: &macroBuffer)
        return .string(macroBuffer)
    }

    static func evaluateBinaryValues(
        _ op: Expression.BinaryOp,
        _ left: Value,
        _ right: Value
    ) throws
        -> Value
    {
        switch op {
        case .add:
            return try left.add(with: right)
        case .subtract:
            return try left.subtract(by: right)
        case .multiply:
            return try left.multiply(by: right)
        case .divide:
            return try left.divide(by: right)
        case .floorDivide:
            return try left.floorDivide(by: right)
        case .power:
            return try left.power(by: right)
        case .modulo:
            return try left.modulo(by: right)
        case .concat:
            return try left.concatenate(with: right)
        case .equal:
            return .boolean(left.isEquivalent(to: right))
        case .notEqual:
            return .boolean(!left.isEquivalent(to: right))
        case .less:
            return .boolean(try left.compare(to: right) < 0)
        case .lessEqual:
            return .boolean(try left.compare(to: right) <= 0)
        case .greater:
            return .boolean(try left.compare(to: right) > 0)
        case .greaterEqual:
            return .boolean(try left.compare(to: right) >= 0)
        case .and:
            return left.isTruthy ? right : left
        case .or:
            return left.isTruthy ? left : right
        case .`in`:
            return .boolean(try left.isContained(in: right))
        case .notIn:
            return .boolean(!(try left.isContained(in: right)))
        }
    }

    static func evaluateUnaryValue(_ op: Expression.UnaryOp, _ value: Value) throws -> Value {
        switch op {
        case .not:
            return .boolean(!value.isTruthy)
        case .minus:
            switch value {
            case let .double(n):
                return .double(-n)
            case let .int(i):
                return .int(-i)
            default:
                throw JinjaError.runtime("Cannot negate non-numeric value")
            }
        case .plus:
            switch value {
            case .double, .int:
                return value
            default:
                throw JinjaError.runtime("Cannot apply unary plus to non-numeric value")
            }
        case .splat:
            // This should not be evaluated directly - it's only used for unpacking in calls
            throw JinjaError.runtime("Unpacking operator can only be used in function calls")
        }
    }

    static func evaluateComputedMember(_ object: Value, _ property: Value) throws -> Value {
        switch (object, property) {
        case let (.array(arr), .int(index)):
            let safeIndex = index < 0 ? arr.count + index : index
            guard safeIndex >= 0 && safeIndex < arr.count else {
                return .undefined
            }
            return arr[safeIndex]

        case let (.object(obj), .string(key)):
            return obj[key] ?? .undefined

        case let (.string(str), .int(index)):
            let safeIndex = index < 0 ? str.count + index : index
            guard safeIndex >= 0 && safeIndex < str.count else {
                return .undefined
            }
            let char = str[str.index(str.startIndex, offsetBy: safeIndex)]
            return .string(String(char))

        default:
            return .undefined
        }
    }

    static func evaluateTest(_ testName: String, _ argValues: [Value], env: Environment)
        throws -> Bool
    {
        // Try environment-provided tests first
        let testValue = env[testName]
        if case let .function(fn) = testValue {
            let result = try fn(argValues, [:], env)
            if case let .boolean(b) = result { return b }
            return result.isTruthy
        }

        // Fallback to built-in tests
        if let testFunction = Tests.builtIn[testName] {
            return try testFunction(argValues, [:], env)
        }

        throw JinjaError.runtime("Unknown test: \(testName)")
    }

    static func evaluateFilter(
        _ filterName: String,
        _ argValues: [Value],
        kwargs: [String: Value],
        env: Environment
    )
        throws -> Value
    {
        // Try environment-provided filters first
        let filterValue = env[filterName]
        if case let .function(fn) = filterValue {
            return try fn(argValues, kwargs, env)
        }

        // Fallback to built-in filters
        if let filterFunction = Filters.builtIn[filterName] {
            return try filterFunction(argValues, kwargs, env)
        }

        throw JinjaError.runtime("Unknown filter: \(filterName)")
    }

    private static func makeLoopObject(index: Int, totalCount: Int) -> Value {
        var loopContext: OrderedDictionary<String, Value> = [
            "index": .int(index + 1),
            "index0": .int(index),
            "first": .boolean(index == 0),
            "last": .boolean(index == totalCount - 1),
            "length": .int(totalCount),
            "revindex": .int(totalCount - index),
            "revindex0": .int(totalCount - index - 1),
        ]

        loopContext["cycle"] = .function { args, _, _ in
            guard !args.isEmpty else { return .string("") }
            let cycleIndex = index % args.count
            return args[cycleIndex]
        }

        return .object(loopContext)
    }

    private static func evaluateSlice(
        value: Value,
        start: Expression?,
        stop: Expression?,
        step: Expression?,
        env: Environment
    ) throws -> Value {
        let startVal = try start.map { try evaluateExpression($0, env: env) }
        let stopVal = try stop.map { try evaluateExpression($0, env: env) }
        let stepVal = try step.map { try evaluateExpression($0, env: env) }

        let step: Int
        if let s = stepVal, case let .int(val) = s {
            if val == 0 { throw JinjaError.runtime("Slice step cannot be zero") }
            step = val
        } else {
            step = 1
        }

        switch value {
        case .array(let items):
            let count = items.count

            let startIdx: Int
            if let s = startVal, case let .int(val) = s {
                startIdx = val >= 0 ? val : count + val
            } else {
                startIdx = step > 0 ? 0 : count - 1
            }

            let stopIdx: Int
            if let s = stopVal, case let .int(val) = s {
                stopIdx = val >= 0 ? val : count + val
            } else {
                stopIdx = step > 0 ? count : -1
            }

            var result: [Value] = []
            for i in stride(from: startIdx, to: stopIdx, by: step) {
                if i >= 0 && i < count {
                    result.append(items[i])
                }
            }
            return .array(result)

        case .string(let str):
            let count = str.count

            let startIdx: Int
            if let s = startVal, case let .int(val) = s {
                startIdx = val >= 0 ? val : count + val
            } else {
                startIdx = step > 0 ? 0 : count - 1
            }

            let stopIdx: Int
            if let s = stopVal, case let .int(val) = s {
                stopIdx = val >= 0 ? val : count + val
            } else {
                stopIdx = step > 0 ? count : -1
            }

            var result = ""
            for i in stride(from: startIdx, to: stopIdx, by: step) {
                if i >= 0 && i < count {
                    let index = str.index(str.startIndex, offsetBy: i)
                    result.append(str[index])
                }
            }
            return .string(String(result))

        default:
            throw JinjaError.runtime("Slice requires array or string")
        }
    }
}
