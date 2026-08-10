//
//  StrictJSON.swift
//  LicenseSeatSDK
//
//  Bounded JSON grammar validation with duplicate-object-key rejection.
//

import Foundation

/// Validates untrusted JSON before Foundation decodes it into a model.
///
/// Foundation's high-level JSON decoders accept duplicate object member names
/// and retain one value. That behavior is unsafe at authorization and signed
/// data boundaries because two parsers can disagree about which duplicate is
/// authoritative. This parser validates one complete RFC 8259 JSON value,
/// rejects duplicate decoded keys at every depth, and enforces work limits
/// before the normal model decoder runs.
enum StrictJSON {
    struct Limits {
        let maxBytes: Int
        let maxDepth: Int
        let maxNodes: Int
        let maxKeyBytes: Int
        let maxStringBytes: Int
        let maxNumberBytes: Int

        static let api = Limits(
            maxBytes: 2 * 1024 * 1024,
            maxDepth: 20,
            maxNodes: 10_000,
            maxKeyBytes: 256,
            maxStringBytes: 256 * 1024,
            maxNumberBytes: 128
        )

        static let signedPayload = Limits(
            maxBytes: 1024 * 1024,
            maxDepth: 20,
            maxNodes: 10_000,
            maxKeyBytes: 256,
            maxStringBytes: 64 * 1024,
            maxNumberBytes: 128
        )

        static let cache = Limits(
            maxBytes: 2 * 1024 * 1024,
            maxDepth: 20,
            maxNodes: 10_000,
            maxKeyBytes: 256,
            maxStringBytes: 256 * 1024,
            maxNumberBytes: 128
        )
    }

    static func validate(_ data: Data, limits: Limits) throws {
        guard !data.isEmpty, data.count <= limits.maxBytes else {
            throw StrictJSONError.sizeLimitExceeded
        }

        var parser = Parser(bytes: Array(data), limits: limits)
        try parser.parseDocument()
    }
}

enum StrictJSONError: Error, Equatable {
    case invalidSyntax
    case duplicateKey
    case depthLimitExceeded
    case nodeLimitExceeded
    case sizeLimitExceeded
    case nonFiniteNumber
}

private extension StrictJSON {
    struct Parser {
        let bytes: [UInt8]
        let limits: Limits
        var index = 0
        var nodes = 0

        mutating func parseDocument() throws {
            skipWhitespace()
            try parseValue(depth: 0)
            skipWhitespace()
            guard index == bytes.count else {
                throw StrictJSONError.invalidSyntax
            }
        }

        mutating func parseValue(depth: Int) throws {
            try recordNode(at: depth)
            guard let byte = currentByte else {
                throw StrictJSONError.invalidSyntax
            }

            switch byte {
            case asciiQuote:
                _ = try parseString(maximumBytes: limits.maxStringBytes)
            case asciiLeftBrace:
                try parseObject(depth: depth)
            case asciiLeftBracket:
                try parseArray(depth: depth)
            case asciiT:
                try consumeLiteral([asciiT, asciiR, asciiU, asciiE])
            case asciiF:
                try consumeLiteral([
                    asciiF, asciiLowerA, asciiL, asciiS, asciiE
                ])
            case asciiN:
                try consumeLiteral([asciiN, asciiU, asciiL, asciiL])
            case asciiMinus, asciiZero...asciiNine:
                try parseNumber()
            default:
                throw StrictJSONError.invalidSyntax
            }
        }

        mutating func recordNode(at depth: Int) throws {
            guard depth <= limits.maxDepth else {
                throw StrictJSONError.depthLimitExceeded
            }
            nodes += 1
            guard nodes <= limits.maxNodes else {
                throw StrictJSONError.nodeLimitExceeded
            }
        }

        mutating func parseObject(depth: Int) throws {
            try consume(asciiLeftBrace)
            skipWhitespace()
            if consumeIfPresent(asciiRightBrace) {
                return
            }

            var keys = Set<String>()
            while true {
                guard currentByte == asciiQuote else {
                    throw StrictJSONError.invalidSyntax
                }
                let key = try parseString(maximumBytes: limits.maxKeyBytes)
                guard keys.insert(key).inserted else {
                    throw StrictJSONError.duplicateKey
                }

                skipWhitespace()
                try consume(asciiColon)
                skipWhitespace()
                try parseValue(depth: depth + 1)
                skipWhitespace()

                if consumeIfPresent(asciiRightBrace) {
                    return
                }
                try consume(asciiComma)
                skipWhitespace()
            }
        }

        mutating func parseArray(depth: Int) throws {
            try consume(asciiLeftBracket)
            skipWhitespace()
            if consumeIfPresent(asciiRightBracket) {
                return
            }

            while true {
                try parseValue(depth: depth + 1)
                skipWhitespace()
                if consumeIfPresent(asciiRightBracket) {
                    return
                }
                try consume(asciiComma)
                skipWhitespace()
            }
        }

        mutating func parseString(maximumBytes: Int) throws -> String {
            let start = index
            try consume(asciiQuote)

            while let byte = currentByte {
                switch byte {
                case asciiQuote:
                    return try finishString(
                        startingAt: start,
                        maximumBytes: maximumBytes
                    )
                case asciiBackslash:
                    try consumeEscapeSequence()
                case 0x00...0x1F:
                    throw StrictJSONError.invalidSyntax
                default:
                    index += 1
                }
            }

            throw StrictJSONError.invalidSyntax
        }

        mutating func finishString(
            startingAt start: Int,
            maximumBytes: Int
        ) throws -> String {
            index += 1
            let raw = Data(bytes[start..<index])
            guard raw.count <= limits.maxBytes else {
                throw StrictJSONError.sizeLimitExceeded
            }
            guard let decoded = try? JSONDecoder().decode(String.self, from: raw) else {
                throw StrictJSONError.invalidSyntax
            }
            guard decoded.utf8.count <= maximumBytes else {
                throw StrictJSONError.sizeLimitExceeded
            }
            return decoded
        }

        mutating func consumeEscapeSequence() throws {
            index += 1
            guard let escape = currentByte else {
                throw StrictJSONError.invalidSyntax
            }
            if escape == asciiU {
                index += 1
                for _ in 0..<4 {
                    guard let hex = currentByte, isHexDigit(hex) else {
                        throw StrictJSONError.invalidSyntax
                    }
                    index += 1
                }
                return
            }

            guard [
                asciiQuote, asciiBackslash, asciiSlash,
                asciiB, asciiF, asciiN, asciiR, asciiT
            ].contains(escape) else {
                throw StrictJSONError.invalidSyntax
            }
            index += 1
        }

        mutating func parseNumber() throws {
            let start = index
            _ = consumeIfPresent(asciiMinus)

            if consumeIfPresent(asciiZero) {
                if let byte = currentByte, isDigit(byte) {
                    throw StrictJSONError.invalidSyntax
                }
            } else {
                guard let byte = currentByte, (asciiOne...asciiNine).contains(byte) else {
                    throw StrictJSONError.invalidSyntax
                }
                consumeDigits()
            }

            if consumeIfPresent(asciiDot) {
                guard let byte = currentByte, isDigit(byte) else {
                    throw StrictJSONError.invalidSyntax
                }
                consumeDigits()
            }

            if currentByte == asciiE || currentByte == asciiUpperE {
                index += 1
                if currentByte == asciiPlus || currentByte == asciiMinus {
                    index += 1
                }
                guard let byte = currentByte, isDigit(byte) else {
                    throw StrictJSONError.invalidSyntax
                }
                consumeDigits()
            }

            let count = index - start
            guard count <= limits.maxNumberBytes else {
                throw StrictJSONError.sizeLimitExceeded
            }
            guard let text = String(bytes: bytes[start..<index], encoding: .utf8),
                  let number = Double(text),
                  number.isFinite else {
                throw StrictJSONError.nonFiniteNumber
            }
        }

        mutating func consumeDigits() {
            while let byte = currentByte, isDigit(byte) {
                index += 1
            }
        }

        mutating func consumeLiteral(_ literal: [UInt8]) throws {
            guard index + literal.count <= bytes.count,
                  Array(bytes[index..<(index + literal.count)]) == literal else {
                throw StrictJSONError.invalidSyntax
            }
            index += literal.count
        }

        mutating func consume(_ expected: UInt8) throws {
            guard currentByte == expected else {
                throw StrictJSONError.invalidSyntax
            }
            index += 1
        }

        mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
            guard currentByte == expected else { return false }
            index += 1
            return true
        }

        mutating func skipWhitespace() {
            while let byte = currentByte,
                  byte == asciiSpace ||
                    byte == asciiTab ||
                    byte == asciiLineFeed ||
                    byte == asciiCarriageReturn {
                index += 1
            }
        }

        var currentByte: UInt8? {
            index < bytes.count ? bytes[index] : nil
        }

        func isDigit(_ byte: UInt8) -> Bool {
            (asciiZero...asciiNine).contains(byte)
        }

        func isHexDigit(_ byte: UInt8) -> Bool {
            (asciiZero...asciiNine).contains(byte) ||
                (asciiUpperA...asciiUpperF).contains(byte) ||
                (asciiLowerA...asciiLowerF).contains(byte)
        }
    }
}

private let asciiTab: UInt8 = 0x09
private let asciiLineFeed: UInt8 = 0x0A
private let asciiCarriageReturn: UInt8 = 0x0D
private let asciiSpace: UInt8 = 0x20
private let asciiQuote: UInt8 = 0x22
private let asciiPlus: UInt8 = 0x2B
private let asciiComma: UInt8 = 0x2C
private let asciiMinus: UInt8 = 0x2D
private let asciiDot: UInt8 = 0x2E
private let asciiSlash: UInt8 = 0x2F
private let asciiZero: UInt8 = 0x30
private let asciiOne: UInt8 = 0x31
private let asciiNine: UInt8 = 0x39
private let asciiColon: UInt8 = 0x3A
private let asciiUpperA: UInt8 = 0x41
private let asciiUpperE: UInt8 = 0x45
private let asciiUpperF: UInt8 = 0x46
private let asciiLeftBracket: UInt8 = 0x5B
private let asciiBackslash: UInt8 = 0x5C
private let asciiRightBracket: UInt8 = 0x5D
private let asciiLowerA: UInt8 = 0x61
private let asciiB: UInt8 = 0x62
private let asciiE: UInt8 = 0x65
private let asciiF: UInt8 = 0x66
private let asciiL: UInt8 = 0x6C
private let asciiN: UInt8 = 0x6E
private let asciiR: UInt8 = 0x72
private let asciiS: UInt8 = 0x73
private let asciiT: UInt8 = 0x74
private let asciiU: UInt8 = 0x75
private let asciiLowerF: UInt8 = 0x66
private let asciiLeftBrace: UInt8 = 0x7B
private let asciiRightBrace: UInt8 = 0x7D
