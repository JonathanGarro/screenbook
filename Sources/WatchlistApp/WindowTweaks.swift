import AppKit
import ObjectiveC

// small appkit adjustments swiftui has no setting for: no line between the sidebar and the middle pane,
// and overlay scroll bars (just the handle, no track) that appear when the pointer
// moves onto a pane.

enum WindowTweaks {
    private static var lastScrollView: NSScrollView?

    private static weak var sidebarEdge: NSView?

    static func install() {
        useOverlayScrollers()
        flashScrollersOnHover()
        // the sidebar edge can be rebuilt whenever the split view lays out, so check after every window
        // update; once found and hidden, the check is a single comparison
        NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { note in
            if let edge = sidebarEdge, edge.window != nil, isFilled(edge) { return }
            guard let root = (note.object as? NSWindow)?.contentView?.superview else { return }
            hideSidebarEdge(in: root)
        }
        if let path = UserDefaults.standard.string(forKey: "dumpViewsTo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { dump(to: path) }
        }
    }

    /// the sidebar is drawn as a raised panel in swiftui, so the column's sidebar material becomes the
    /// window's material and the divider in the gap beside it is made transparent. the window's background then shows around the
    /// panel and through the gap, the same as behind the middle pane, with no seam. the divider still
    /// resizes the sidebar when dragged.
    private static func hideSidebarEdge(in view: NSView) {
        if String(describing: type(of: view)) == "NSVibrantSplitDividerView" {
            for sub in view.subviews { sub.alphaValue = 0 }
            sidebarEdge = view
            return
        }
        // the sidebar content lives inside this view, so it gets the window's own material instead of
        // being hidden
        if let effect = view as? NSVisualEffectView, effect.material == .sidebar {
            effect.material = .windowBackground
            effect.blendingMode = .behindWindow
        }
        for sub in view.subviews { hideSidebarEdge(in: sub) }
    }

    private static func isFilled(_ edge: NSView) -> Bool {
        edge.subviews.allSatisfy { $0.alphaValue == 0 }
    }

    /// debug: -dumpViewsTo <path> writes the main window's view tree, for finding stray lines
    private static func dump(to path: String) {
        guard let root = NSApp.windows.first(where: { $0.isVisible })?.contentView?.superview else { return }
        var out = ""
        func walk(_ v: NSView, _ depth: Int) {
            let f = v.convert(v.bounds, to: nil)
            var extra = " alpha=\(v.alphaValue) hidden=\(v.isHidden) layer=\(v.wantsLayer)"
            if let e = v as? NSVisualEffectView { extra += " material=\(e.material.rawValue)" }
            if let c = v.layer?.backgroundColor { extra += " bg=\(c)" }
            if let b = v.layer?.borderWidth, b > 0 { extra += " border=\(b)" }
            out += String(repeating: "  ", count: depth) + "\(type(of: v)) x=\(Int(f.minX)) w=\(Int(f.width))\(extra)\n"
            for c in v.subviews { walk(c, depth + 1) }
        }
        walk(root, 0)
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
        // a picture of this app's own window, which needs no screen recording permission
        if let window = NSApp.windows.first(where: { $0.isVisible }),
           let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming]) {
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            try? png?.write(to: URL(fileURLWithPath: path + ".png"))
        }
    }

    /// overlay scrollers even when a mouse is connected, which would otherwise show the full track
    private static func useOverlayScrollers() {
        guard let method = class_getClassMethod(NSScroller.self, #selector(getter: NSScroller.preferredScrollerStyle)) else { return }
        let replacement: @convention(block) (AnyObject) -> NSScroller.Style = { _ in .overlay }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    }

    /// shows the scroll handle briefly when the pointer moves onto a scrollable pane
    private static func flashScrollersOnHover() {
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            guard let window = event.window, let content = window.contentView else { return event }
            let point = content.convert(event.locationInWindow, from: nil)
            let scroll = content.hitTest(point)?.enclosingScrollView
            if let scroll, scroll !== lastScrollView {
                scroll.flashScrollers()
            }
            lastScrollView = scroll
            return event
        }
        // mouse moved events only arrive once a window asks for them
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            (note.object as? NSWindow)?.acceptsMouseMovedEvents = true
        }
    }
}
