import SwiftUI
import AppKit
import QuartzCore
import DonbyCore
import DonbyNetwork

class FlippedLayerHostView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

class LayerOnlyCellRootView: FlippedLayerHostView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class NonDraggableScrollView: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { false }
    var onWidthChanged: ((CGFloat) -> Void)?
    private var lastWidth: CGFloat = 0

    override func layout() {
        super.layout()
        let width = contentView.bounds.width
        if abs(width - lastWidth) > 1.0, width > 0 {
            lastWidth = width
            onWidthChanged?(width)
        }
    }
}

final class HorizontalShelfScrollView: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func tile() {
        super.tile()
        if let scroller = horizontalScroller {
            scroller.isHidden = true
            scroller.alphaValue = 0
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
            return
        }
        (documentView as? InteractiveCollectionView)?.clearHover()
        super.scrollWheel(with: event)
    }
}

@MainActor
protocol HoverableCollectionItem: NSCollectionViewItem {
    func setHovered(_ hovered: Bool)
    func hitTestHoverPoint(_ pointInItemView: NSPoint) -> Bool
    func handleClick(at pointInItemView: NSPoint)
}

final class InteractiveCollectionView: NSCollectionView {
    override var mouseDownCanMoveWindow: Bool { false }

    var canHover: (() -> Bool)?
    private var hoverTrackingArea: NSTrackingArea?
    private weak var activeHoveredItem: (any HoverableCollectionItem)?
    private var mouseDownWindowPoint: NSPoint?
    private weak var mouseDownItem: (any HoverableCollectionItem)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    func clearHover() {
        activeHoveredItem?.setHovered(false)
        activeHoveredItem = nil
    }

    // LayerOnlyCellRootView returns nil from hitTest for fast 120Hz scrolling, which also makes
    // NSCollectionView.indexPathForItem(at:) return nil on AppKit, so resolve against visibleItems directly.
    private func hoverableItem(at point: NSPoint) -> (any HoverableCollectionItem)? {
        for cell in visibleItems().reversed() {
            guard let hoverable = cell as? any HoverableCollectionItem,
                  cell.view.superview != nil,
                  !cell.view.isHidden else { continue }
            let localPoint = cell.view.convert(point, from: self)
            if cell.view.bounds.contains(localPoint) {
                return hoverable
            }
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        guard canHover?() ?? true else {
            clearHover()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let cell = hoverableItem(at: point) else {
            clearHover()
            return
        }
        let localPoint = cell.view.convert(point, from: self)
        guard cell.hitTestHoverPoint(localPoint) else {
            clearHover()
            return
        }
        if activeHoveredItem !== cell {
            activeHoveredItem?.setHovered(false)
            activeHoveredItem = cell
        }
        cell.setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let cell = hoverableItem(at: point) {
            mouseDownWindowPoint = event.locationInWindow
            mouseDownItem = cell
            return
        }
        mouseDownWindowPoint = nil
        mouseDownItem = nil
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let downPoint = mouseDownWindowPoint, let targetCell = mouseDownItem else {
            super.mouseUp(with: event)
            return
        }
        mouseDownWindowPoint = nil
        mouseDownItem = nil
        guard targetCell.view.superview != nil else { return }
        let upWindowPoint = event.locationInWindow
        guard hypot(upWindowPoint.x - downPoint.x, upWindowPoint.y - downPoint.y) < 6 else { return }
        let upPoint = convert(upWindowPoint, from: nil)
        let localPoint = targetCell.view.convert(upPoint, from: self)
        targetCell.handleClick(at: localPoint)
    }
}

@MainActor
final class ScrollHoverGate {
    private(set) var isActivelyScrolling = false
    private var lastScrollActivityTime: CFTimeInterval = 0
    private var hasPendingIdleCheck = false
    private let idleDelay: TimeInterval
    private let onScrollBegan: () -> Void
    private let onScrollEnded: (() -> Void)?

    init(
        idleDelay: TimeInterval = 0.14,
        onScrollBegan: @escaping () -> Void,
        onScrollEnded: (() -> Void)? = nil
    ) {
        self.idleDelay = idleDelay
        self.onScrollBegan = onScrollBegan
        self.onScrollEnded = onScrollEnded
    }

    var canHover: Bool {
        !isActivelyScrolling && (CACurrentMediaTime() - lastScrollActivityTime >= idleDelay)
    }

    func markScrollingActivity() {
        lastScrollActivityTime = CACurrentMediaTime()
        if !isActivelyScrolling {
            isActivelyScrolling = true
            ScrollActivityTracker.setScrolling(true)
            onScrollBegan()
        }
        scheduleIdleEvaluation()
    }

    func scheduleIdleEvaluation() {
        guard !hasPendingIdleCheck else { return }
        hasPendingIdleCheck = true
        DispatchQueue.main.asyncAfter(deadline: .now() + idleDelay + 0.01) { [weak self] in
            self?.evaluateIdle()
        }
    }

    private func evaluateIdle() {
        hasPendingIdleCheck = false
        let elapsed = CACurrentMediaTime() - lastScrollActivityTime
        if elapsed < idleDelay - 0.005 {
            hasPendingIdleCheck = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (idleDelay - elapsed) + 0.01) { [weak self] in
                self?.evaluateIdle()
            }
        } else {
            isActivelyScrolling = false
            ScrollActivityTracker.setScrolling(false)
            onScrollEnded?()
        }
    }
}

@MainActor
protocol NativeCardActionDelegate: AnyObject {
    func cardDidSelect(_ item: EmbyItem)
    func cardDidPlay(_ item: EmbyItem)
}
