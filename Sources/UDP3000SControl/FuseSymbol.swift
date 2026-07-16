import SwiftUI

/// The IEEE/ANSI schematic fuse symbol: a straight lead running through an
/// unfilled rectangular body. Used in place of a text label for the
/// protection (OVP/OCP) disclosure - dark when either is enabled, pale
/// grey when neither is.
struct FuseSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY
        let bodyWidth = rect.width * 0.45
        let bodyX0 = rect.midX - bodyWidth / 2

        // the lead runs straight across, unbroken, through the body
        path.move(to: CGPoint(x: rect.minX, y: midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: midY))

        // unfilled rectangular body straddling the lead
        path.addRect(CGRect(x: bodyX0, y: rect.minY, width: bodyWidth, height: rect.height))
        return path
    }
}
