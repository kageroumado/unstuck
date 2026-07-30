import AppKit

struct CursorSample {
    let fingerprint: Int
    let label: String
    let image: NSImage?
}

struct CursorGlyph: Identifiable, Equatable {
    let id: Int
    let label: String
    let image: NSImage?

    static func == (lhs: CursorGlyph, rhs: CursorGlyph) -> Bool {
        lhs.id == rhs.id && lhs.label == rhs.label
    }
}

/// Names the live cursor by rasterizing it and comparing against every cursor
/// the AppKit runtime can construct.
@MainActor
enum CursorIdentity {
    /// Rasterizes a cursor image to a fixed-size PNG so images that are
    /// logically the same compare equal. NSCursor.currentSystem hands back a
    /// bitmap WindowServer reconstructed — it never byte-matches the TIFF of a
    /// locally constructed NSCursor even for the identical cursor.
    static func canonicalKey(_ image: NSImage) -> Data? {
        let side = 32
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSRect(x: 0, y: 0, width: side, height: side).clip()
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Canonical raster → human-readable name, built from every NSCursor
    /// factory the runtime exposes, including the private _windowResize*
    /// family AppKit actually uses on window edges.
    static let names: [Data: String] = {
        let publicSelectors = [
            "arrowCursor": "arrow", "IBeamCursor": "I-beam", "crosshairCursor": "crosshair",
            "closedHandCursor": "closed hand", "openHandCursor": "open hand",
            "pointingHandCursor": "pointing hand", "resizeLeftCursor": "resize left",
            "resizeRightCursor": "resize right", "resizeLeftRightCursor": "resize ↔",
            "resizeUpCursor": "resize up", "resizeDownCursor": "resize down",
            "resizeUpDownCursor": "resize ↕", "disappearingItemCursor": "disappearing item",
            "IBeamCursorForVerticalLayout": "I-beam vertical",
            "operationNotAllowedCursor": "not allowed", "dragLinkCursor": "drag link",
            "dragCopyCursor": "drag copy", "contextualMenuCursor": "contextual menu",
        ]
        let privateSelectors = [
            "_windowResizeNorthSouthCursor": "window resize ↕",
            "_windowResizeEastWestCursor": "window resize ↔",
            "_windowResizeNorthEastSouthWestCursor": "window resize ⤢",
            "_windowResizeNorthWestSouthEastCursor": "window resize ⤡",
            "_windowResizeNorthCursor": "window resize N",
            "_windowResizeSouthCursor": "window resize S",
            "_windowResizeEastCursor": "window resize E",
            "_windowResizeWestCursor": "window resize W",
            "_windowResizeNorthEastCursor": "window resize NE",
            "_windowResizeNorthWestCursor": "window resize NW",
            "_windowResizeSouthEastCursor": "window resize SE",
            "_windowResizeSouthWestCursor": "window resize SW",
            "_helpCursor": "help", "_zoomInCursor": "zoom in", "_zoomOutCursor": "zoom out",
            "_waitCursor": "wait", "_copyDragCursor": "copy drag",
            // _genericDragCursor's artwork IS the plain arrow; the system-defined
            // arrow has no local bitmap, so this entry is what the live arrow
            // matches. Label it as what the user sees.
            "_genericDragCursor": "arrow", "_aliasDragCursor": "alias drag",
            "_moveCursor": "move", "_cellCursor": "cell", "_verticalTextCursor": "vertical text",
            "_busyButClickableCursor": "busy but clickable",
            "_columnResizeCursor": "column resize", "_rowResizeCursor": "row resize",
        ]
        var table: [Data: String] = [:]
        for (selectorName, label) in publicSelectors.merging(privateSelectors, uniquingKeysWith: { a, _ in a }) {
            guard let cursor = CursorShimTryFactory(selectorName) else { continue }
            // Arrow, I-beam and friends are SYSTEM-DEFINED: set by integer ID,
            // with WindowServer owning the artwork. Their local NSImage is a
            // 0×0 placeholder, so every one of them would rasterize to the
            // same blank key and mislabel real cursors. Skip them.
            guard cursor.image.size.width > 0, cursor.image.size.height > 0,
                  let key = canonicalKey(cursor.image) else { continue }
            // First writer wins so public names beat private aliases.
            if table[key] == nil { table[key] = label }
        }
        return table
    }()

    /// Stable session-local letters for cursors that cannot be named — the
    /// system-defined ones have no local bitmap to compare against. What
    /// matters diagnostically is telling them apart consistently.
    private static var unnamedLabels: [Data: String] = [:]
    private static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// Samples the live cursor exactly ONCE and derives identity and label
    /// from that single observation. Reading NSCursor.currentSystem twice is
    /// a correctness bug: during fast motion the cursor can change between
    /// the reads, reporting a phantom transition from a cursor to itself.
    static func sample() -> CursorSample {
        guard let cursor = NSCursor.currentSystem else {
            return CursorSample(fingerprint: 0, label: "none (cursor hidden)", image: nil)
        }
        guard let key = canonicalKey(cursor.image) else {
            return CursorSample(fingerprint: 1, label: "unreadable", image: nil)
        }
        let fingerprint = key.hashValue
        let image = cursor.image.size.width > 0 ? cursor.image : nil
        if let name = names[key] {
            return CursorSample(fingerprint: fingerprint, label: name, image: image)
        }
        if let existing = unnamedLabels[key] {
            return CursorSample(fingerprint: fingerprint, label: existing, image: image)
        }
        let letter = unnamedLabels.count < letters.count ? String(letters[unnamedLabels.count]) : "?"
        let label = "system cursor \(letter)"
        unnamedLabels[key] = label
        return CursorSample(fingerprint: fingerprint, label: label, image: image)
    }
}
