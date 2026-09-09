import AppKit
import Testing
@testable import Nootch

struct PanelMovementTests {
    let screen = NSRect(x: 100, y: 50, width: 1440, height: 900)
    let panel = NSSize(width: 640, height: 480)

    @Test func verticalBoundsUseVisibleRail() {
        for position in [NotchPosition.right, .leftCenter] {
            let bounds = PanelMovement.bounds(screen: screen, panelSize: panel, position: position, providerCount: 1)
            #expect(bounds.lowerBound + panel.height - 172 == screen.minY + 12)
            #expect(bounds.upperBound + panel.height == screen.maxY - 12)
            #expect(bounds.upperBound - bounds.lowerBound == 704)
        }
    }

    @Test func positionRoundTripsOnBothAxes() {
        for position in [NotchPosition.right, .leftCenter, .bottomCenter] {
            let bounds = PanelMovement.bounds(screen: screen, panelSize: panel, position: position, providerCount: 1)
            for offset in [-1.0, -0.5, 0, 0.5, 1] {
                let coordinate = PanelMovement.coordinate(offset: offset, bounds: bounds, horizontal: position == .bottomCenter)
                let restored = PanelMovement.offset(coordinate: coordinate, bounds: bounds, horizontal: position == .bottomCenter)
                #expect(abs(restored - offset) < 0.000001)
            }
        }
    }

    @Test func bottomBoundsIncludeSettingsButton() {
        let bounds = PanelMovement.bounds(screen: screen, panelSize: panel, position: .bottomCenter, providerCount: 1)
        let halfWidth = HorizontalBarLayout.expandedWidth(for: 1) / 2 + 50
        #expect(bounds.lowerBound + panel.width / 2 - halfWidth == screen.minX + 12)
        #expect(bounds.upperBound + panel.width / 2 + halfWidth == screen.maxX - 12)
    }

    @Test func shortScreensHaveValidBounds() {
        let bounds = PanelMovement.bounds(screen: NSRect(x: 0, y: 0, width: 200, height: 100), panelSize: panel, position: .right, providerCount: 1)
        #expect(bounds.lowerBound == bounds.upperBound)
        #expect(PanelMovement.offset(coordinate: bounds.lowerBound, bounds: bounds, horizontal: false) == 0)
    }
}
