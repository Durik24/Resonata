import SwiftUI

/// The silhouette that makes this read as "part of the hardware" rather than
/// "a black rectangle taped to the screen".
///
/// Top corners curve *outward* (concave), so the shape melts into the bezel.
/// Bottom corners are ordinary convex rounds. Both radii animate, which is what
/// gives you the Dynamic Island stretch when the size changes.
struct NotchShape: Shape {
    var topRadius: CGFloat = 8
    var bottomRadius: CGFloat = 16

    // Lets SwiftUI interpolate the radii during a spring animation.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tr = min(topRadius, rect.width / 2)
        let br = min(bottomRadius, rect.width / 2, rect.height)

        // Start just outside the top-left, at the bezel line.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Concave flare into the body.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
            control: CGPoint(x: rect.minX + tr, y: rect.minY)
        )

        // Left edge down.
        path.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))

        // Bottom-left round.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tr + br, y: rect.maxY),
            control: CGPoint(x: rect.minX + tr, y: rect.maxY)
        )

        // Bottom edge.
        path.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))

        // Bottom-right round.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
            control: CGPoint(x: rect.maxX - tr, y: rect.maxY)
        )

        // Right edge up.
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))

        // Concave flare back out to the bezel.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - tr, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}
