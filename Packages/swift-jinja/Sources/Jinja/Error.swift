import Foundation

/// Errors that can occur during Jinja template processing.
public enum JinjaError: LocalizedError {
    /// Error during tokenization of template source.
    case lexer(String)
    /// Error during parsing of tokens into AST.
    case parser(String)
    /// Error during template execution or evaluation.
    case runtime(String)
    /// Error due to invalid template syntax.
    case syntax(String)

    public var errorDescription: String? {
        switch self {
        case .lexer(let message): return "Lexer error: \(message)"
        case .parser(let message): return "Parser error: \(message)"
        case .runtime(let message): return "Runtime error: \(message)"
        case .syntax(let message): return "Syntax error: \(message)"
        }
    }
}
