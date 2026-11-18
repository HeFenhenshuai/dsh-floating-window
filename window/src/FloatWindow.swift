// The floating window itself.
//
// It is a normal macOS window (`titled`, `fullSizeContentView`): the system owns
// the rounded corners, the shadow, the traffic lights, dragging by the title bar,
// resizing from every edge and double-click-to-zoom. What makes it a *floating*
// window is the level — `.floating` while the pin is on, so it stays above every
// normal application — plus `fullScreenAuxiliary`, so it also survives the DSH
// window going full screen or the user switching Spaces.

import AppKit

final class FloatWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Pinned windows float over every application and follow the user across
    /// Spaces; unpinned ones behave like an ordinary window again.
    func applyPin(_ pinned: Bool) {
        level = pinned ? .floating : .normal
        collectionBehavior = pinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.managed, .participatesInCycle]
        hidesOnDeactivate = false
    }
}
