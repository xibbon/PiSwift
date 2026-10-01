import Foundation
import Testing
@testable import PiSwiftCodingAgent

private enum VectorInput: Decodable {
    case text(String)
    case index(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .index(try container.decode(Double.self))
        }
    }

    func color() throws -> Color {
        switch self {
        case .text(let text): try parseColor(text)
        case .index(let value): try parseColor(value)
        }
    }
}

private struct RgbVector: Decodable {
    let r: Double
    let g: Double
    let b: Double
}

private struct OklchVector: Decodable {
    let l: Double
    let c: Double
    let h: Double
}

private struct OkhslVector: Decodable {
    let h: Double
    let s: Double
    let l: Double
}

private struct ExpectedColor: Decodable {
    let kind: String
    let hex: String
    let rgb: RgbVector
    let oklch: OklchVector
    let okhsl: OkhslVector?
}

private struct ColorVector: Decodable {
    let input: VectorInput
    let expected: ExpectedColor
}

private struct MixVector: Decodable {
    let first: String
    let second: String
    let amount: Double
    let space: String
    let expected: ExpectedColor
}

private struct AnsiVector: Decodable {
    let input: VectorInput
    let mode: String
    let foreground: String
    let background: String
}

private struct ColorVectors: Decodable {
    let schema: String
    let source: String
    let validColors: [ColorVector]
    let invalidInputs: [VectorInput]
    let mixCases: [MixVector]
    let ansiCases: [AnsiVector]
}

private func loadColorVectors() throws -> ColorVectors {
    let url = try #require(Bundle.module.url(forResource: "color-vectors", withExtension: "json"))
    return try JSONDecoder().decode(ColorVectors.self, from: Data(contentsOf: url))
}

private func kind(_ color: Color) -> String {
    switch color {
    case .indexed: "indexed"
    case .rgb: "rgb"
    case .oklch: "oklch"
    }
}

private func near(_ actual: Double, _ expected: Double, tolerance: Double = 1e-9) -> Bool {
    abs(actual - expected) <= tolerance
}

private func hueNear(_ actual: Double, _ expected: Double) -> Bool {
    let delta = abs(actual - expected)
    return min(delta, abs(delta - 360)) <= 1e-7
}

private func checkColor(_ color: Color, expected: ExpectedColor) {
    #expect(kind(color) == expected.kind)
    #expect(colorToHex(color) == expected.hex)
    let rgb = colorToRgb(color)
    #expect(near(rgb.r, expected.rgb.r))
    #expect(near(rgb.g, expected.rgb.g))
    #expect(near(rgb.b, expected.rgb.b))
    let oklch = colorToOklch(color)
    #expect(near(oklch.l, expected.oklch.l))
    #expect(near(oklch.c, expected.oklch.c))
    #expect(hueNear(oklch.h, expected.oklch.h))
    if let expectedOkhsl = expected.okhsl {
        let okhsl = colorToOkhsl(color)
        #expect(hueNear(okhsl.h, expectedOkhsl.h))
        #expect(near(okhsl.s, expectedOkhsl.s, tolerance: 1e-7))
        #expect(near(okhsl.l, expectedOkhsl.l))
    }
}

@Suite("Colors from pi-mono v0.99.1")
struct ThemeColorMathTests {
    @Test("upstream parsing and gamut limits")
    func upstreamLimits() throws {
        #expect(try parseColor("#abc") == rgbColor(170, 187, 204))
        #expect(try parseColor("oklch(62% 0.1 200)") == oklchColor(0.62, 0.1, 200))
        #expect(try colorToHex(oklchColor(0.627955, 0.257683, 29.2339)) == "#ff0000")
        #expect(try colorToHex(oklchColor(1, 0.3, 150)) == "#ffffff")
        #expect(try colorToHex(oklchColor(0, 0.3, 150)) == "#000000")
        #expect(try parseColor("okhsl(29.23 100% 56.8%)") == rgbColor(255, 0, 0))
        #expect(try parseColor("OKHSL(250deg 60% 55%)") == okhslColor(250, 0.6, 0.55))
        #expect(throws: ColorError.self) { try parseColor("okhsl(250 160% 55%)") }
    }
    @Test("shared vectors cover parsing and conversions")
    func sharedVectors() throws {
        let vectors = try loadColorVectors()
        #expect(vectors.schema == "mini-tui-color-vectors-v1")
        #expect(vectors.source.contains("v0.99.1"))
        for vector in vectors.validColors {
            checkColor(try vector.input.color(), expected: vector.expected)
        }
        for input in vectors.invalidInputs {
            #expect(throws: ColorError.self) { try input.color() }
        }
    }

    @Test("OKHSL returns sRGB and round trips source colors")
    func okhslRoundTrips() throws {
        for hex in ["#4f8eb3", "#20242a", "#f8f9fa"] {
            let channels = colorToOkhsl(try parseColor(hex))
            let result = try okhslColor(channels.h, channels.s, channels.l)
            #expect(kind(result) == "rgb")
            #expect(colorToHex(result) == hex)
        }
    }

    @Test("mixing follows the upstream color spaces and shortest hue arc")
    func mixing() throws {
        for vector in try loadColorVectors().mixCases {
            let space = try #require(ColorMixSpace(rawValue: vector.space))
            let mixed = try mixColors(parseColor(vector.first), parseColor(vector.second), amount: vector.amount, space: space)
            checkColor(mixed, expected: vector.expected)
        }
        #expect(throws: ColorError.self) {
            try mixColors(parseColor("#000"), parseColor("#fff"), amount: -0.1)
        }
    }

    @Test("ANSI output uses indexed colors and rounded gray candidates")
    func ansi() throws {
        for vector in try loadColorVectors().ansiCases {
            let mode = try #require(TerminalColorMode(rawValue: vector.mode))
            let color = try vector.input.color()
            #expect(foregroundAnsi(color, mode) == vector.foreground)
            #expect(backgroundAnsi(color, mode) == vector.background)
        }
    }

    @Test("styles close their sequences in reverse order")
    func styles() throws {
        let style = TextStyle(fg: try rgbColor(18, 52, 86), bg: try indexedColor(9),
                              attributes: .init(bold: true, italic: true))
        #expect(styleText("Ready", options: style, mode: .truecolor)
                == "\u{001B}[38;2;18;52;86m\u{001B}[48;5;9m\u{001B}[1m\u{001B}[3mReady\u{001B}[23m\u{001B}[22m\u{001B}[49m\u{001B}[39m")
        #expect(styleTextWithAnsi("x", fgAnsi: "\u{001B}[38;5;1m", bgAnsi: nil, options: .init(dim: true))
                == "\u{001B}[38;5;1m\u{001B}[2mx\u{001B}[22m\u{001B}[39m")
    }

    @Test("constructors reject invalid channels")
    func errors() {
        #expect(throws: ColorError.self) { try indexedColor(1.5) }
        #expect(throws: ColorError.self) { try rgbColor(.infinity, 0, 0) }
        #expect(throws: ColorError.self) { try rgbColor(256, 0, 0) }
        #expect(throws: ColorError.self) { try oklchColor(0.5, -0.1, 0) }
        #expect(throws: ColorError.self) { try okhslColor(0, 2, 0.5) }
        do {
            _ = try parseColor("red")
            Issue.record("Expected an invalid color error")
        } catch let error as ColorError {
            #expect(error.errorDescription == "Invalid color value: red")
        } catch {
            Issue.record("Expected ColorError")
        }
    }
}
