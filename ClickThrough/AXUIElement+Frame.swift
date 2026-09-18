import ApplicationServices

extension AXUIElement {
    /// This element's frame, in one round trip, or `nil` if it does not have one.
    ///
    /// `kAXPosition` is reported in the same coordinate space as
    /// `CGEvent.location` and `kCGWindowBounds` - top-left origin on the primary
    /// display - so a frame read here can be compared with a click location or a
    /// window from the window list without any conversion.
    ///
    /// One `AXUIElementCopyMultipleAttributeValues` rather than two single reads:
    /// every round trip is to another process, and this is called from the
    /// event-tap thread while the user's mouse-down is held.
    var frame: CGRect? {
        var values: CFArray?
        let attributes = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(self, attributes, [], &values) == .success,
              let pair = values as? [AnyObject], pair.count == 2,
              CFGetTypeID(pair[0]) == AXValueGetTypeID(), CFGetTypeID(pair[1]) == AXValueGetTypeID()
        else { return nil }

        let position = pair[0] as! AXValue
        let size = pair[1] as! AXValue
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize else { return nil }

        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &origin)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }
}
