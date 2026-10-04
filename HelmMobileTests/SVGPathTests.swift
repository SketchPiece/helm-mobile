import SwiftUI
import XCTest
@testable import HelmMobile

final class SVGPathTests: XCTestCase {
    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    private func end(_ segment: SVGPath.Segment?) -> CGPoint? {
        switch segment {
        case .move(let to), .line(let to), .quad(let to, _), .cubic(let to, _, _): to
        default: nil
        }
    }

    private func assertClose(_ a: CGPoint?, _ b: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        guard let a else { return XCTFail("no point", file: file, line: line) }
        XCTAssertEqual(a.x, b.x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-9, file: file, line: line)
    }

    func testMoveLineCloseAbsoluteAndRelative() throws {
        XCTAssertEqual(try SVGPath.segments("M10 20 L30 40 Z"), [.move(p(10, 20)), .line(p(30, 40)), .close])
        XCTAssertEqual(try SVGPath.segments("M10 20 l5 5 l-10 0 z"), [.move(p(10, 20)), .line(p(15, 25)), .line(p(5, 25)), .close])
        // A leading relative moveto is relative to the origin.
        XCTAssertEqual(try SVGPath.segments("m3 4"), [.move(p(3, 4))])
    }

    func testImplicitRepetition() throws {
        // Pairs after a moveto are linetos (relative after `m`).
        XCTAssertEqual(try SVGPath.segments("M0 0 10 0 10 10"), [.move(p(0, 0)), .line(p(10, 0)), .line(p(10, 10))])
        XCTAssertEqual(try SVGPath.segments("m1 1 2 0 0 2"), [.move(p(1, 1)), .line(p(3, 1)), .line(p(3, 3))])
        XCTAssertEqual(try SVGPath.segments("M0 0H1 2V3 4"), [.move(p(0, 0)), .line(p(1, 0)), .line(p(2, 0)), .line(p(2, 3)), .line(p(2, 4))])
        XCTAssertEqual(try SVGPath.segments("M0 0h1 2v3 4"), [.move(p(0, 0)), .line(p(1, 0)), .line(p(3, 0)), .line(p(3, 3)), .line(p(3, 7))])
        XCTAssertEqual(try SVGPath.segments("M0 0c1 1 2 2 3 3 1 1 2 2 3 3"), [
            .move(p(0, 0)),
            .cubic(to: p(3, 3), control1: p(1, 1), control2: p(2, 2)),
            .cubic(to: p(6, 6), control1: p(4, 4), control2: p(5, 5)),
        ])
    }

    func testHorizontalVertical() throws {
        XCTAssertEqual(try SVGPath.segments("M5 5H20V30h-5v-10"), [
            .move(p(5, 5)), .line(p(20, 5)), .line(p(20, 30)), .line(p(15, 30)), .line(p(15, 20)),
        ])
    }

    func testCubicAndSmoothCubicReflect() throws {
        XCTAssertEqual(try SVGPath.segments("M0 0C0 10 10 10 10 0S20 -10 20 0"), [
            .move(p(0, 0)),
            .cubic(to: p(10, 0), control1: p(0, 10), control2: p(10, 10)),
            .cubic(to: p(20, 0), control1: p(10, -10), control2: p(20, -10)),
        ])
        XCTAssertEqual(try SVGPath.segments("M10 10c0 10 10 10 10 0s10-10 10 0"), [
            .move(p(10, 10)),
            .cubic(to: p(20, 10), control1: p(10, 20), control2: p(20, 20)),
            .cubic(to: p(30, 10), control1: p(20, 0), control2: p(30, 0)),
        ])
        // Without a preceding curve the first control point is the current point.
        XCTAssertEqual(try SVGPath.segments("M1 1S5 5 9 1"), [.move(p(1, 1)), .cubic(to: p(9, 1), control1: p(1, 1), control2: p(5, 5))])
    }

    func testQuadAndSmoothQuadReflect() throws {
        XCTAssertEqual(try SVGPath.segments("M0 0Q5 10 10 0T20 0"), [
            .move(p(0, 0)), .quad(to: p(10, 0), control: p(5, 10)), .quad(to: p(20, 0), control: p(15, -10)),
        ])
        XCTAssertEqual(try SVGPath.segments("M0 0q5 10 10 0t10 0"), [
            .move(p(0, 0)), .quad(to: p(10, 0), control: p(5, 10)), .quad(to: p(20, 0), control: p(15, -10)),
        ])
        // A T after a cubic doesn't reflect anything.
        XCTAssertEqual(try SVGPath.segments("M0 0C1 1 2 2 3 3T9 9").last, .quad(to: p(9, 9), control: p(3, 3)))
    }

    func testCompactNumbers() throws {
        XCTAssertEqual(try SVGPath.segments("M.5.5L-.5-1.5e1l.25,2E+1M1e-3-4e0"), [
            .move(p(0.5, 0.5)), .line(p(-0.5, -15)), .line(p(-0.25, 5)), .move(p(0.001, -4)),
        ])
        XCTAssertEqual(try SVGPath.segments("M1,2,3,4"), [.move(p(1, 2)), .line(p(3, 4))])
    }

    func testCurrentPointAfterCloseIsSubpathStart() throws {
        XCTAssertEqual(try SVGPath.segments("M10 10L20 10ZL15 15").last, .line(p(15, 15)))
        XCTAssertEqual(try SVGPath.segments("M10 10l10 0zl5 5").last, .line(p(15, 15)))
    }

    func testMalformedDataThrows() {
        XCTAssertThrowsError(try SVGPath.segments("10 10"))
        XCTAssertThrowsError(try SVGPath.segments("M10"))
        XCTAssertThrowsError(try SVGPath.segments("M0 0 Z 5 5"))
        XCTAssertThrowsError(try SVGPath.segments("M0 0 A1 1 0 2 0 3 3"))
    }

    func testArcHalfCircleEndsOnTargetAndBulgesTheRightWay() throws {
        // Upper half circle of radius 10 around (10, 0), clockwise on screen (sweep = 1).
        let segments = try SVGPath.segments("M0 0A10 10 0 0 1 20 0")
        XCTAssertEqual(segments.count, 3) // move + two quarter-circle cubics
        guard case .cubic(let mid, _, _) = segments[1], case .cubic(let end, _, _) = segments[2] else {
            return XCTFail("expected cubics")
        }
        XCTAssertEqual(mid.x, 10, accuracy: 1e-9)
        XCTAssertEqual(mid.y, -10, accuracy: 1e-9)
        XCTAssertEqual(end, p(20, 0))
        // Same arc with sweep = 0 goes below.
        guard case .cubic(let other, _, _) = try SVGPath.segments("M0 0A10 10 0 0 0 20 0")[1] else { return XCTFail() }
        XCTAssertEqual(other.y, 10, accuracy: 1e-9)
    }

    func testArcQuarterCircleControlPoints() throws {
        // One quarter: handles are 0.5523 * r along the tangents.
        let segments = try SVGPath.segments("M10 0a10 10 0 0 1-10 10")
        XCTAssertEqual(segments.count, 2)
        guard case .cubic(let to, let c1, let c2) = segments[1] else { return XCTFail("expected a cubic") }
        let k = 4.0 / 3.0 * tan(Double.pi / 8) * 10
        XCTAssertEqual(to, p(0, 10))
        XCTAssertEqual(c1.x, 10, accuracy: 1e-9)
        XCTAssertEqual(c1.y, k, accuracy: 1e-9)
        XCTAssertEqual(c2.x, k, accuracy: 1e-9)
        XCTAssertEqual(c2.y, 10, accuracy: 1e-9)
    }

    func testArcLargeFlagAndScaledRadii() throws {
        // Large arc of a radius-10 circle through (0,0) and (10,10): three quarters, ends exactly.
        let large = try SVGPath.segments("M0 0A10 10 0 1 1 10 10")
        XCTAssertEqual(large.count, 4)
        XCTAssertEqual(end(large.last), p(10, 10))
        // Radii too small to span the chord are scaled up to a half ellipse.
        let scaled = try SVGPath.segments("M0 0a1 1 0 0 0 20 0")
        XCTAssertEqual(scaled.count, 3)
        // Packed flags and a zero radius (a straight line).
        XCTAssertEqual(try SVGPath.segments("M0 0a5 5 0 0110 0").count, 3)
        XCTAssertEqual(try SVGPath.segments("M0 0A0 5 0 0 1 4 4"), [.move(p(0, 0)), .line(p(4, 4))])
        // Rotated ellipse still ends on its endpoint.
        let rotated = try SVGPath.segments("M3 7A8 4 30 1 0 12 -2")
        XCTAssertEqual(end(rotated.last), p(12, -2))
    }

    func testRealLogosFillTheirViewBoxes() throws {
        let logos: [(String, ProviderLogo)] = [
            ("claude", .claude), ("grok", .grok), ("cursor", .cursor), ("pi", .pi),
            ("opencode", .opencode), ("openAI", .openAI), ("acpRegistry", .acpRegistry),
        ]
        for (name, logo) in logos {
            var bounds = CGRect.null
            for layer in logo.layers {
                XCTAssertFalse(layer.path.isEmpty, "\(name) has an empty layer")
                bounds = bounds.union(layer.path.boundingRect)
            }
            let box = logo.viewBox
            // Inside the viewBox (a hair of slack) and covering most of it on the longer axis.
            XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(bounds), "\(name) \(bounds) outside \(box)")
            let coverage = max(bounds.width / box.width, bounds.height / box.height)
            XCTAssertGreaterThan(coverage, 0.85, "\(name) \(bounds) in \(box)")
        }
    }

    func testRealLogoPathDataParses() throws {
        // The logos swallow parse errors at runtime; these must parse cleanly.
        let claude = try SVGPath.segments("m50.228 170.321 50.357-28.257.843-2.463-.843-1.361h-2.462l-8.426-.518Z")
        assertClose(end(claude[1]), p(100.585, 142.064))
        assertClose(end(claude[2]), p(101.428, 139.601))
        XCTAssertEqual(claude.count, 7)
        let acp = try SVGPath.segments("M517.278 27.966a6.81 6.81 0 0 0 5.911 3.411")
        assertClose(end(acp.last), p(523.189, 31.377))
    }

    func testOfficialAcpRegistryIconURL() {
        XCTAssertEqual(
            ProviderLogo.officialAcpRegistryIconURL("https://cdn.agentclientprotocol.com/registry/v1/latest/pi-acp.svg")?.absoluteString,
            "https://cdn.agentclientprotocol.com/registry/v1/latest/pi-acp.svg"
        )
        XCTAssertNil(ProviderLogo.officialAcpRegistryIconURL("https://cdn.agentclientprotocol.com.evil/registry/v1/latest/pi-acp.svg"))
        XCTAssertNil(ProviderLogo.officialAcpRegistryIconURL("https://user@cdn.agentclientprotocol.com/registry/v1/latest/pi-acp.svg"))
        XCTAssertNil(ProviderLogo.officialAcpRegistryIconURL("http://cdn.agentclientprotocol.com/x.svg"))
        XCTAssertNil(ProviderLogo.officialAcpRegistryIconURL("https://cdn.agentclientprotocol.com:8443/x.svg"))
        XCTAssertNil(ProviderLogo.officialAcpRegistryIconURL(nil))
        XCTAssertNil(ProviderLogo.officialAcpRegistryIconURL(""))
    }
}
