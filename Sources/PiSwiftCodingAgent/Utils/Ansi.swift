import Foundation

/*
 * Portions of this file are derived from ansi-regex and strip-ansi.
 * MIT License
 * Copyright (c) Sindre Sorhus <sindresorhus@gmail.com> (https://sindresorhus.com)
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

// v1.1.0 utils/ansi.ts:29-49. Use ASCII digits, as JavaScript's \d does.
private enum AnsiPatterns {
    static let terminator = #"(?:\u0007|\u001B\u005C|\u009C)"#
    static let oscStart = #"\u001B\]"#
    static let csiStart = #"[\u001B\u009B][\[\]()#;?]*(?:[0-9]{1,4}(?:[;:][0-9]{0,4})*)?"#
    static let csiFinal = #"[0-9A-PR-TZcf-nq-uy=><~]"#
    static let complete = try! NSRegularExpression(
        pattern: "(?:\(oscStart)[\\s\\S]*?\(terminator))|\(csiStart)\(csiFinal)"
    )
    static let unfinished = try! NSRegularExpression(
        pattern: "(?:\(oscStart)(?:[^\\u0007\\u009C\\u001B]|\\u001B(?!\\\\))*|\(csiStart))$"
    )
}

/// Remove complete ANSI escape sequences.
public func stripAnsi(_ value: String) -> String {
    guard value.contains("\u{1b}") || value.contains("\u{9b}") else { return value }
    return AnsiPatterns.complete.stringByReplacingMatches(
        in: value,
        range: NSRange(location: 0, length: value.utf16.count),
        withTemplate: ""
    )
}

/// Hold an unfinished ANSI suffix within the last 256 UTF-16 code units.
public func splitIncompleteAnsiSuffix(_ value: String) -> (complete: String, pending: String) {
    guard value.contains("\u{1b}") || value.contains("\u{9b}") else { return (value, "") }
    let length = value.utf16.count
    let windowStart = max(0, length - 256)
    guard let match = AnsiPatterns.unfinished.firstMatch(
        in: value, range: NSRange(location: windowStart, length: length - windowStart)
    ) else { return (value, "") }
    let text = value as NSString
    return (text.substring(to: match.range.location), text.substring(from: match.range.location))
}
