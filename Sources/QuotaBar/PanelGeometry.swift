import Foundation

enum PanelGeometry {
    static func frame(for contentSize: CGSize, anchoredTo anchor: CGRect, within screen: CGRect) -> CGRect {
        let available = screen.insetBy(dx: 4, dy: 4)
        let size = CGSize(width: min(contentSize.width, available.width), height: min(contentSize.height, available.height))
        let x = min(max(anchor.midX - size.width / 2, available.minX), available.maxX - size.width)
        let y = min(max(anchor.minY - size.height - 4, available.minY), available.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}
