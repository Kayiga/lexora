import SwiftUI

/// A custom `Layout` that wraps subviews into rows, left-to-right, flowing
/// to the next line when there isn't enough horizontal space. Works on iOS 16+.
struct FlowLayout: Layout {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(
            proposal: proposal,
            subviews: subviews
        )
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        let offsetX = bounds.minX
        let offsetY = bounds.minY
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: frame.origin.x + offsetX, y: frame.origin.y + offsetY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    // MARK: - Private layout engine

    private struct ArrangeResult {
        var frames: [CGRect]
        var size: CGSize
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> ArrangeResult {
        let maxWidth = proposal.width ?? .infinity
        var frames = [CGRect](repeating: .zero, count: subviews.count)
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth, currentX > 0 {
                // Wrap to next row
                currentY += rowHeight + spacing
                currentX = 0
                rowHeight = 0
            }

            frames[index] = CGRect(origin: CGPoint(x: currentX, y: currentY), size: size)
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, currentX - spacing)
            totalHeight = currentY + rowHeight
        }

        return ArrangeResult(frames: frames, size: CGSize(width: maxX, height: totalHeight))
    }
}
