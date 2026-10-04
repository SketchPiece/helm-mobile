import CoreGraphics
import Foundation
import SwiftUI

/// Parses SVG path data (`<path d="…">`) into absolute segments and a SwiftUI `Path`.
/// Covers the full command set, relative and absolute, implicit repetition, compact numbers
/// (`1.5.5`, `-.5`, `1e-3`) and packed arc flags. Arcs become cubic Béziers.
/// Parse once and keep the result: the provider logos hold theirs in static lets.
enum SVGPath {
    enum Segment: Equatable {
        case move(CGPoint)
        case line(CGPoint)
        case quad(to: CGPoint, control: CGPoint)
        case cubic(to: CGPoint, control1: CGPoint, control2: CGPoint)
        case close
    }

    struct ParseError: Error, Equatable {
        let message: String
        let offset: Int
    }

    static func path(_ data: String) throws -> Path {
        var path = Path()
        for segment in try segments(data) {
            switch segment {
            case .move(let point): path.move(to: point)
            case .line(let point): path.addLine(to: point)
            case .quad(let to, let control): path.addQuadCurve(to: to, control: control)
            case .cubic(let to, let c1, let c2): path.addCurve(to: to, control1: c1, control2: c2)
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    static func segments(_ data: String) throws -> [Segment] {
        var scanner = Scanner(Array(data.utf8))
        var output: [Segment] = []
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        // Reflection sources for S/s and T/t.
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var command: UInt8?

        while true {
            scanner.skipSeparators()
            guard let next = scanner.peek else { break }
            if Scanner.isCommand(next) {
                command = next
                scanner.index += 1
            } else if command == nil || command == UInt8(ascii: "Z") || command == UInt8(ascii: "z") {
                throw ParseError(message: "expected a command", offset: scanner.index)
            }
            guard let cmd = command else { break }
            let relative = cmd >= UInt8(ascii: "a")
            let base = relative ? current : .zero
            func point() throws -> CGPoint {
                let x = try scanner.number(), y = try scanner.number()
                return CGPoint(x: base.x + x, y: base.y + y)
            }
            var cubicControl: CGPoint?
            var quadControl: CGPoint?

            switch cmd | 0x20 { // lowercased
            case UInt8(ascii: "m"):
                current = try point()
                subpathStart = current
                output.append(.move(current))
                // Further pairs after a moveto are implicit linetos.
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "l"):
                current = try point()
                output.append(.line(current))
            case UInt8(ascii: "h"):
                let x = try scanner.number()
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                output.append(.line(current))
            case UInt8(ascii: "v"):
                let y = try scanner.number()
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                output.append(.line(current))
            case UInt8(ascii: "c"):
                let c1 = try point(), c2 = try point(), to = try point()
                output.append(.cubic(to: to, control1: c1, control2: c2))
                cubicControl = c2
                current = to
            case UInt8(ascii: "s"):
                let c1 = lastCubicControl.map { reflect($0, about: current) } ?? current
                let c2 = try point(), to = try point()
                output.append(.cubic(to: to, control1: c1, control2: c2))
                cubicControl = c2
                current = to
            case UInt8(ascii: "q"):
                let control = try point(), to = try point()
                output.append(.quad(to: to, control: control))
                quadControl = control
                current = to
            case UInt8(ascii: "t"):
                let control = lastQuadControl.map { reflect($0, about: current) } ?? current
                let to = try point()
                output.append(.quad(to: to, control: control))
                quadControl = control
                current = to
            case UInt8(ascii: "a"):
                let rx = try scanner.number(), ry = try scanner.number(), rotation = try scanner.number()
                let largeArc = try scanner.flag(), sweep = try scanner.flag()
                let to = try point()
                output += arc(from: current, to: to, rx: rx, ry: ry, rotation: rotation, largeArc: largeArc, sweep: sweep)
                current = to
            case UInt8(ascii: "z"):
                output.append(.close)
                current = subpathStart
            default:
                throw ParseError(message: "unknown command", offset: scanner.index - 1)
            }
            lastCubicControl = cubicControl
            lastQuadControl = quadControl
        }
        return output
    }

    private static func reflect(_ point: CGPoint, about center: CGPoint) -> CGPoint {
        CGPoint(x: 2 * center.x - point.x, y: 2 * center.y - point.y)
    }

    /// Converts an SVG elliptical arc (endpoint form) to cubics, one per quarter turn at most
    /// (SVG 1.1 appendix F.6.5 for the centre, then the 4/3·tan(θ/4) handle length).
    static func arc(from start: CGPoint, to end: CGPoint, rx: Double, ry: Double, rotation: Double,
                    largeArc: Bool, sweep: Bool) -> [Segment] {
        if start == end { return [] }
        var rx = abs(rx), ry = abs(ry)
        if rx == 0 || ry == 0 { return [.line(end)] }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        // Scale radii up when they can't span the endpoints.
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coefficient = (max(0, numerator) / denominator).squareRoot()
        if largeArc == sweep { coefficient = -coefficient }
        let cxp = coefficient * rx * y1p / ry
        let cyp = -coefficient * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let count = max(1, Int((abs(delta) / (.pi / 2) - 1e-9).rounded(.up)))
        let step = delta / Double(count)
        let handle = 4.0 / 3.0 * tan(step / 4)
        func onEllipse(_ t: Double) -> CGPoint {
            let x = rx * cos(t), y = ry * sin(t)
            return CGPoint(x: cx + cosPhi * x - sinPhi * y, y: cy + sinPhi * x + cosPhi * y)
        }
        func derivative(_ t: Double) -> CGPoint {
            let x = -rx * sin(t), y = ry * cos(t)
            return CGPoint(x: cosPhi * x - sinPhi * y, y: sinPhi * x + cosPhi * y)
        }
        var segments: [Segment] = []
        var t = theta1
        var from = start
        for index in 0..<count {
            let next = t + step
            let to = index == count - 1 ? end : onEllipse(next)
            let d1 = derivative(t), d2 = derivative(next)
            segments.append(.cubic(
                to: to,
                control1: CGPoint(x: from.x + handle * d1.x, y: from.y + handle * d1.y),
                control2: CGPoint(x: to.x - handle * d2.x, y: to.y - handle * d2.y)
            ))
            from = to
            t = next
        }
        return segments
    }

    /// Reads numbers and flags off the path bytes.
    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        static func isCommand(_ byte: UInt8) -> Bool {
            switch byte | 0x20 {
            case UInt8(ascii: "m"), UInt8(ascii: "l"), UInt8(ascii: "h"), UInt8(ascii: "v"), UInt8(ascii: "c"),
                 UInt8(ascii: "s"), UInt8(ascii: "q"), UInt8(ascii: "t"), UInt8(ascii: "a"), UInt8(ascii: "z"):
                // Only letters map onto these under `| 0x20`; `e` is not among them, so exponents never read as commands.
                return true
            default:
                return false
            }
        }

        mutating func skipSeparators() {
            while let byte = peek, byte == UInt8(ascii: " ") || byte == UInt8(ascii: ",") || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C {
                index += 1
            }
        }

        mutating func number() throws -> Double {
            skipSeparators()
            let start = index
            if let sign = peek, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") { index += 1 }
            var digits = 0
            while let byte = peek, isDigit(byte) { index += 1; digits += 1 }
            if peek == UInt8(ascii: ".") {
                index += 1
                while let byte = peek, isDigit(byte) { index += 1; digits += 1 }
            }
            guard digits > 0 else { throw ParseError(message: "expected a number", offset: start) }
            if let e = peek, e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
                var lookahead = index + 1
                if lookahead < bytes.count, bytes[lookahead] == UInt8(ascii: "+") || bytes[lookahead] == UInt8(ascii: "-") {
                    lookahead += 1
                }
                if lookahead < bytes.count, isDigit(bytes[lookahead]) {
                    index = lookahead
                    while let byte = peek, isDigit(byte) { index += 1 }
                }
            }
            guard let text = String(bytes: bytes[start..<index], encoding: .ascii), let value = Double(text) else {
                throw ParseError(message: "bad number", offset: start)
            }
            return value
        }

        /// Arc flags are a single 0 or 1 and may be packed without separators (`a1 1 0 011 1`).
        mutating func flag() throws -> Bool {
            skipSeparators()
            switch peek {
            case UInt8(ascii: "0"): index += 1; return false
            case UInt8(ascii: "1"): index += 1; return true
            default: throw ParseError(message: "expected an arc flag", offset: index)
            }
        }

        private func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }
    }
}
