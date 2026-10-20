import Foundation

/// Parses JSON that may be cut off mid-way, such as tool input that is still streaming.
///
/// This is a port of the AI SDK's `parsePartialJson`: it first tries a strict
/// parse and otherwise closes any open strings, arrays and objects, dropping a
/// trailing incomplete key, number or literal.
public enum PartialJSON {
    public enum ParseState: String, Sendable, Hashable {
        case undefinedInput = "undefined-input"
        case successfulParse = "successful-parse"
        case repairedParse = "repaired-parse"
        case failedParse = "failed-parse"
    }

    public struct Result: Sendable, Hashable {
        public var value: JSONValue?
        public var state: ParseState
    }

    public static func parse(_ text: String?) -> Result {
        guard let text else { return Result(value: nil, state: .undefinedInput) }
        if let value = try? JSONValue(parsing: text) {
            return Result(value: value, state: .successfulParse)
        }
        if let value = try? JSONValue(parsing: repair(text)) {
            return Result(value: value, state: .repairedParse)
        }
        return Result(value: nil, state: .failedParse)
    }

    private enum State {
        case root
        case finish
        case insideString
        case insideStringEscape
        case insideStringUnicodeEscape
        case insideLiteral
        case insideNumber
        case insideObjectStart
        case insideObjectKey
        case insideObjectAfterKey
        case insideObjectBeforeValue
        case insideObjectAfterValue
        case insideObjectAfterComma
        case insideArrayStart
        case insideArrayAfterValue
        case insideArrayAfterComma
    }

    /// Closes the open structures of a truncated JSON document.
    public static func repair(_ input: String) -> String {
        let characters = Array(input.unicodeScalars)
        var stack: [State] = [.root]
        var lastValidIndex = -1
        var literalStart: Int?
        var unicodeEscapeDigits = 0

        func processValueStart(_ character: Unicode.Scalar, _ index: Int, _ swapState: State) {
            switch character {
            case "\"":
                lastValidIndex = index
                stack.removeLast()
                stack.append(swapState)
                stack.append(.insideString)
            case "f", "t", "n":
                lastValidIndex = index
                literalStart = index
                stack.removeLast()
                stack.append(swapState)
                stack.append(.insideLiteral)
            case "-":
                stack.removeLast()
                stack.append(swapState)
                stack.append(.insideNumber)
            case "0"..."9":
                lastValidIndex = index
                stack.removeLast()
                stack.append(swapState)
                stack.append(.insideNumber)
            case "{":
                lastValidIndex = index
                stack.removeLast()
                stack.append(swapState)
                stack.append(.insideObjectStart)
            case "[":
                lastValidIndex = index
                stack.removeLast()
                stack.append(swapState)
                stack.append(.insideArrayStart)
            default:
                break
            }
        }

        func processAfterObjectValue(_ character: Unicode.Scalar, _ index: Int) {
            switch character {
            case ",":
                stack.removeLast()
                stack.append(.insideObjectAfterComma)
            case "}":
                lastValidIndex = index
                stack.removeLast()
            default:
                break
            }
        }

        func processAfterArrayValue(_ character: Unicode.Scalar, _ index: Int) {
            switch character {
            case ",":
                stack.removeLast()
                stack.append(.insideArrayAfterComma)
            case "]":
                lastValidIndex = index
                stack.removeLast()
            default:
                break
            }
        }

        func literal(from start: Int, through end: Int) -> String {
            var scalars = String.UnicodeScalarView()
            scalars.append(contentsOf: characters[start...end])
            return String(scalars)
        }

        for (index, character) in characters.enumerated() {
            guard let currentState = stack.last else { break }
            switch currentState {
            case .root:
                processValueStart(character, index, .finish)
            case .insideObjectStart:
                switch character {
                case "\"":
                    stack.removeLast()
                    stack.append(.insideObjectKey)
                case "}":
                    lastValidIndex = index
                    stack.removeLast()
                default:
                    break
                }
            case .insideObjectAfterComma:
                if character == "\"" {
                    stack.removeLast()
                    stack.append(.insideObjectKey)
                }
            case .insideObjectKey:
                if character == "\"" {
                    stack.removeLast()
                    stack.append(.insideObjectAfterKey)
                }
            case .insideObjectAfterKey:
                if character == ":" {
                    stack.removeLast()
                    stack.append(.insideObjectBeforeValue)
                }
            case .insideObjectBeforeValue:
                processValueStart(character, index, .insideObjectAfterValue)
            case .insideObjectAfterValue:
                processAfterObjectValue(character, index)
            case .insideString:
                switch character {
                case "\"":
                    stack.removeLast()
                    lastValidIndex = index
                case "\\":
                    stack.append(.insideStringEscape)
                default:
                    lastValidIndex = index
                }
            case .insideArrayStart:
                if character == "]" {
                    lastValidIndex = index
                    stack.removeLast()
                } else {
                    lastValidIndex = index
                    processValueStart(character, index, .insideArrayAfterValue)
                }
            case .insideArrayAfterValue:
                switch character {
                case ",":
                    stack.removeLast()
                    stack.append(.insideArrayAfterComma)
                case "]":
                    lastValidIndex = index
                    stack.removeLast()
                default:
                    lastValidIndex = index
                }
            case .insideArrayAfterComma:
                processValueStart(character, index, .insideArrayAfterValue)
            case .insideStringEscape:
                stack.removeLast()
                if character == "u" {
                    unicodeEscapeDigits = 0
                    stack.append(.insideStringUnicodeEscape)
                } else {
                    lastValidIndex = index
                }
            case .insideStringUnicodeEscape:
                if character.properties.isASCIIHexDigit {
                    unicodeEscapeDigits += 1
                    if unicodeEscapeDigits == 4 {
                        stack.removeLast()
                        lastValidIndex = index
                    }
                }
            case .insideNumber:
                switch character {
                case "0"..."9":
                    lastValidIndex = index
                case "e", "E", "-", ".":
                    break
                case ",":
                    stack.removeLast()
                    if stack.last == .insideArrayAfterValue { processAfterArrayValue(character, index) }
                    if stack.last == .insideObjectAfterValue { processAfterObjectValue(character, index) }
                case "}":
                    stack.removeLast()
                    if stack.last == .insideObjectAfterValue { processAfterObjectValue(character, index) }
                case "]":
                    stack.removeLast()
                    if stack.last == .insideArrayAfterValue { processAfterArrayValue(character, index) }
                default:
                    stack.removeLast()
                }
            case .insideLiteral:
                let partial = literal(from: literalStart ?? index, through: index)
                if !"false".hasPrefix(partial), !"true".hasPrefix(partial), !"null".hasPrefix(partial) {
                    stack.removeLast()
                    if stack.last == .insideObjectAfterValue {
                        processAfterObjectValue(character, index)
                    } else if stack.last == .insideArrayAfterValue {
                        processAfterArrayValue(character, index)
                    }
                } else {
                    lastValidIndex = index
                }
            case .finish:
                break
            }
        }

        var result = String.UnicodeScalarView()
        if lastValidIndex >= 0 {
            result.append(contentsOf: characters[0...lastValidIndex])
        }
        var output = String(result)

        for state in stack.reversed() {
            switch state {
            case .insideString:
                output += "\""
            case .insideObjectKey, .insideObjectAfterKey, .insideObjectAfterComma, .insideObjectStart,
                 .insideObjectBeforeValue, .insideObjectAfterValue:
                output += "}"
            case .insideArrayStart, .insideArrayAfterComma, .insideArrayAfterValue:
                output += "]"
            case .insideLiteral:
                let start = literalStart ?? characters.count
                let partial = start < characters.count ? literal(from: start, through: characters.count - 1) : ""
                for candidate in ["true", "false", "null"] where candidate.hasPrefix(partial) {
                    output += String(candidate.dropFirst(partial.count))
                    break
                }
            default:
                break
            }
        }
        return output
    }
}
