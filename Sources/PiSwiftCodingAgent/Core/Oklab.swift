/**
 * Oklab and OKHSL <-> sRGB conversion. This file has no MiniTui dependencies.
 *
 * This is a port of Björn Ottosson's reference implementation
 * (https://bottosson.github.io/posts/colorpicker/).
 * Copyright (c) 2021 Björn Ottosson, used under the MIT license:
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
 * associated documentation files (the "Software"), to deal in the Software without restriction, including
 * without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the
 * following conditions: The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
 * KIND, EXPRESS OR IMPLIED.
 */

import Foundation

enum OklabMath {
    typealias Vector = [Double]
    typealias Matrix = [Vector]

    struct RGB {
        let r: Double
        let g: Double
        let b: Double
    }

    struct OKHSL {
        let h: Double
        let s: Double
        let l: Double
    }

    private static let linearSrgbToLms: Matrix = [
        [0.4122214694707629, 0.5363325372617349, 0.0514459932675022],
        [0.2119034958178251, 0.6806995506452344, 0.1073969535369405],
        [0.0883024591900564, 0.2817188391361215, 0.6299787016738222],
    ]
    private static let lmsToLab: Matrix = [
        [0.210454268309314, 0.793617774702305, -0.0040720430116193],
        [1.9779985324311684, -2.42859224204858, 0.450593709617411],
        [0.0259040424655478, 0.7827717124575296, -0.8086757549230774],
    ]
    private static let labToLms: Matrix = [
        [1, 0.3963377773761749, 0.2158037573099136],
        [1, -0.1055613458156586, -0.0638541728258133],
        [1, -0.0894841775298119, -1.2914855480194092],
    ]
    private static let lmsToLinearSrgb: Matrix = [
        [4.0767416360759583, -3.3077115392580629, 0.2309699031821043],
        [-1.2684379732850315, 2.6097573492876882, -0.341319376002657],
        [-0.0041960761386756, -0.7034186179359362, 1.7076146940746117],
    ]
    private static let saturationFit: [(Vector, Vector)] = [
        ([-1.8817031, -0.80936501], [1.19086277, 1.76576728, 0.59662641, 0.75515197, 0.56771245]),
        ([1.8144408, -1.19445267], [0.73956515, -0.45954404, 0.08285427, 0.12541073, -0.14503204]),
        ([0.13110758, 1.81333971], [1.35733652, -0.00915799, -1.1513021, -0.50559606, 0.00692167]),
    ]
    private static let k1 = 0.206
    private static let k2 = 0.03
    private static let k3 = (1 + k1) / (1 + k2)

    private static func multiply(_ matrix: Matrix, _ vector: Vector) -> Vector {
        matrix.map { row in row[0] * vector[0] + row[1] * vector[1] + row[2] * vector[2] }
    }

    private static func dot(_ row: Vector, _ vector: Vector) -> Double {
        row[0] * vector[0] + row[1] * vector[1] + row[2] * vector[2]
    }

    static func oklabToOkhslLightness(_ x: Double) -> Double {
        0.5 * (k3 * x - k1 + sqrt(pow(k3 * x - k1, 2) + 4 * k2 * k3 * x))
    }

    private static func okhslToOklabLightness(_ x: Double) -> Double {
        (x * x + k1 * x) / (k3 * (x + k2))
    }

    private static func linearToSrgb(_ value: Double) -> Double {
        value > 0.0031308 ? 1.055 * pow(value, 1 / 2.4) - 0.055 : 12.92 * value
    }

    private static func srgbToLinear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func oklabToLinearSrgb(_ lab: Vector) -> Vector {
        multiply(lmsToLinearSrgb, multiply(labToLms, lab).map { $0 * $0 * $0 })
    }

    private static func linearSrgbToOklab(_ rgb: Vector) -> Vector {
        multiply(lmsToLab, multiply(linearSrgbToLms, rgb).map { cbrt($0) })
    }

    static func rgbToOklab(_ rgb: RGB) -> Vector {
        linearSrgbToOklab([rgb.r / 255, rgb.g / 255, rgb.b / 255].map { srgbToLinear($0) })
    }

    static func linearSrgbToRgb(_ linear: Vector) -> RGB {
        let channels = linear.map { floor(min(1, max(0, linearToSrgb($0))) * 255 + 0.5) }
        return RGB(r: channels[0], g: channels[1], b: channels[2])
    }

    private static func lmsSlopes(_ a: Double, _ b: Double) -> Vector {
        labToLms.map { $0[1] * a + $0[2] * b }
    }

    private static func maxSaturation(_ a: Double, _ b: Double) -> Double {
        let channel = saturationFit.firstIndex { fit in fit.0[0] * a + fit.0[1] * b > 1 } ?? 2
        let coefficients = saturationFit[channel].1
        let weights = lmsToLinearSrgb[channel]
        let saturation = coefficients[0] + coefficients[1] * a + coefficients[2] * b
            + coefficients[3] * a * a + coefficients[4] * a * b
        let slopes = lmsSlopes(a, b)
        let base = slopes.map { 1 + saturation * $0 }
        let f = dot(weights, base.map { $0 * $0 * $0 })
        let f1 = dot(weights, (0..<3).map { 3 * slopes[$0] * base[$0] * base[$0] })
        let f2 = dot(weights, (0..<3).map { 6 * slopes[$0] * slopes[$0] * base[$0] })
        return saturation - f * f1 / (f1 * f1 - 0.5 * f * f2)
    }

    private static func cusp(_ a: Double, _ b: Double) -> (Double, Double) {
        let saturation = maxSaturation(a, b)
        let lightness = cbrt(1 / (oklabToLinearSrgb([1, saturation * a, saturation * b]).max() ?? 1))
        return (lightness, lightness * saturation)
    }

    private static func maxChroma(_ a: Double, _ b: Double, _ lightness: Double, _ peak: (Double, Double)) -> Double {
        if lightness <= peak.0 { return peak.1 * lightness / peak.0 }
        let t = peak.1 * (lightness - 1) / (peak.0 - 1)
        let slopes = lmsSlopes(a, b)
        let lms = slopes.map { lightness + t * $0 }
        let cubes = lms.map { $0 * $0 * $0 }
        let first = (0..<3).map { 3 * slopes[$0] * lms[$0] * lms[$0] }
        let second = (0..<3).map { 6 * slopes[$0] * slopes[$0] * lms[$0] }
        let steps = lmsToLinearSrgb.map { row in
            let f = dot(row, cubes) - 1
            let f1 = dot(row, first)
            let f2 = dot(row, second)
            let u = f1 / (f1 * f1 - 0.5 * f * f2)
            return u >= 0 ? -f * u : Double.greatestFiniteMagnitude
        }
        return t + (steps.min() ?? 0)
    }

    private static func chromaStops(_ lightness: Double, _ a: Double, _ b: Double) -> (Double, Double, Double) {
        let peak = cusp(a, b)
        let cMax = maxChroma(a, b, lightness, peak)
        let k = cMax / min(lightness * peak.1 / peak.0, (1 - lightness) * peak.1 / (1 - peak.0))
        let midS = 0.11516993 + 1 / (7.4477897 + 4.1590124 * b
            + a * (-2.19557347 + 1.75198401 * b
            + a * (-2.13704948 - 10.02301043 * b + a * (-4.24894561 + 5.38770819 * b + 4.69891013 * a))))
        let midT = 0.11239642 + 1 / (1.6132032 - 0.68124379 * b
            + a * (0.40370612 + 0.90148123 * b
            + a * (-0.27087943 + 0.6122399 * b + a * (0.00299215 - 0.45399568 * b - 0.14661872 * a))))
        let cMid = 0.9 * k * sqrt(sqrt(1 / (1 / pow(lightness * midS, 4) + 1 / pow((1 - lightness) * midT, 4))))
        let c0 = sqrt(1 / (1 / pow(lightness * 0.4, 2) + 1 / pow((1 - lightness) * 0.8, 2)))
        return (c0, cMid, cMax)
    }

    static func okhslToRgb(hue: Double, saturation: Double, lightness: Double) -> RGB {
        let l = okhslToOklabLightness(lightness)
        var lab: Vector = [l, 0, 0]
        if l > 0 && l < 1 && saturation > 0 {
            let angle = 2 * Double.pi * ((hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)) / 360
            let a = cos(angle)
            let b = sin(angle)
            let (c0, cMid, cMax) = chromaStops(l, a, b)
            let chroma: Double
            if saturation < 0.8 {
                let t = 1.25 * saturation
                let k1 = 0.8 * c0
                chroma = t * k1 / (1 - (1 - k1 / cMid) * t)
            } else {
                let t = 5 * (saturation - 0.8)
                let k1 = 0.2 * cMid * cMid * 1.25 * 1.25 / c0
                chroma = cMid + t * k1 / (1 - (1 - k1 / (cMax - cMid)) * t)
            }
            lab = [l, chroma * a, chroma * b]
        }
        return linearSrgbToRgb(oklabToLinearSrgb(lab))
    }

    static func rgbToOkhsl(_ rgb: RGB) -> OKHSL {
        let lab = rgbToOklab(rgb)
        let (l, a, b) = (lab[0], lab[1], lab[2])
        let chroma = hypot(a, b)
        let lightness = oklabToOkhslLightness(l)
        if chroma < 1e-9 || lightness <= 0 || lightness >= 1 {
            return OKHSL(h: 0, s: 0, l: lightness)
        }
        let hue = ((atan2(b, a) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360))
        let (c0, cMid, cMax) = chromaStops(l, a / chroma, b / chroma)
        let saturation: Double
        if chroma < cMid {
            let k1 = 0.8 * c0
            saturation = 0.8 * chroma / (k1 + (1 - k1 / cMid) * chroma)
        } else {
            let k1 = 0.2 * cMid * cMid * 1.25 * 1.25 / c0
            let offset = chroma - cMid
            saturation = 0.8 + 0.2 * offset / (k1 + (1 - k1 / (cMax - cMid)) * offset)
        }
        return OKHSL(h: hue, s: min(1, max(0, saturation)), l: lightness)
    }
}

public func oklabToOkhslLightness(_ lightness: Double) -> Double {
    OklabMath.oklabToOkhslLightness(lightness)
}
