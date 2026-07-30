import AppKit
import Carbon.HIToolbox
import CoreGraphics

// MARK: - Findings

struct Finding: Identifiable, Equatable {
    enum Severity: Int, Equatable, Comparable {
        case fail, warn, info, ok

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .ok: "ok"
            case .warn: "warn"
            case .fail: "fail"
            case .info: "info"
            }
        }
    }

    let check: String
    let severity: Severity
    let detail: String
    /// What the user can do about it, when there is something.
    var remedy: String?
    /// Distinguishes findings that share a check name (e.g. one per process).
    var qualifier: String = ""

    var id: String { check + qualifier }
}

// MARK: - Event taps — the cursor-update delivery path

struct TapRow: Identifiable, Equatable {
    let id: UInt32
    let process: String
    let pid: pid_t
    let point: String
    let isActive: Bool
    let enabled: Bool
    let avgMicros: Float
    let maxMicros: Float
    let watchesPointer: Bool
    let watches: String

    var mode: String { isActive ? "active" : "listen" }
    var latency: String {
        avgMicros < 1 && maxMicros < 1 ? "—" : String(format: "%.1f / %.1f ms", avgMicros / 1000, maxMicros / 1000)
    }
    var isSuspect: Bool { isActive && (!enabled || avgMicros > Config.slowTapMicros) }
}

func fetchTaps() -> [TapRow] {
    var count: UInt32 = 0
    guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
    let buffer = UnsafeMutablePointer<CGEventTapInformation>.allocate(capacity: Int(count))
    defer { buffer.deallocate() }
    guard CGGetEventTapList(count, buffer, &count) == .success else { return [] }

    func mask(_ m: CGEventMask) -> (pointer: Bool, label: String) {
        func has(_ types: [CGEventType]) -> Bool {
            types.contains { m & (CGEventMask(1) << CGEventMask($0.rawValue)) != 0 }
        }
        let pointer = has([.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged])
        var parts: [String] = []
        if has([.mouseMoved]) { parts.append("mouse moves") }
        if has([.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { parts.append("drags") }
        if has([.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]) { parts.append("clicks") }
        if has([.scrollWheel]) { parts.append("scroll") }
        if has([.keyDown, .keyUp, .flagsChanged]) { parts.append("keyboard") }
        return (pointer, parts.isEmpty ? String(format: "0x%llx", m) : parts.joined(separator: ", "))
    }

    return (0..<Int(count)).map { index in
        let info = buffer[index]
        let (pointer, label) = mask(info.eventsOfInterest)
        let point: String
        switch info.tapPoint {
        case .cghidEventTap: point = "HID"
        case .cgSessionEventTap: point = "session"
        case .cgAnnotatedSessionEventTap: point = "annotated"
        @unknown default: point = "?"
        }
        return TapRow(
            id: info.eventTapID,
            process: nameForProcess(pid_t(info.tappingProcess)),
            pid: pid_t(info.tappingProcess),
            point: point,
            isActive: info.options != .listenOnly,
            enabled: info.enabled,
            avgMicros: info.avgUsecLatency,
            maxMicros: info.maxUsecLatency,
            watchesPointer: pointer,
            watches: label
        )
    }
}

// MARK: - Passive checks (read-only)

enum PassiveChecks {
    static func visibility() -> [Finding] {
        guard let visible = SkyLight.cursorIsVisible?() else {
            return [Finding(check: "Cursor visible", severity: .info,
                            detail: "Visibility SPI unavailable on this system.")]
        }
        return [Finding(
            check: "Cursor visible", severity: visible ? .ok : .fail,
            detail: visible
                ? "Visibility counter is balanced; the cursor is not hidden."
                : "Cursor is HIDDEN system-wide. Some process called CGDisplayHideCursor and never balanced it — a crash between hide and show does exactly this.",
            remedy: visible ? nil : "Run Unstick — it drains the hide count with repeated CGDisplayShowCursor calls.")]
    }

    static func position() -> [Finding] {
        let eventLocation = CGEvent(source: nil)?.location ?? .zero
        guard let getLocation = SkyLight.getCurrentCursorLocation,
              let connection = SkyLight.mainConnectionID else { return [] }
        var drawn = CGPoint.zero
        guard getLocation(connection(), &drawn) == 0 else { return [] }
        let drift = hypot(drawn.x - eventLocation.x, drawn.y - eventLocation.y)
        if drift > 4 {
            return [Finding(
                check: "Pointer / cursor agreement", severity: .fail,
                detail: String(format: "The drawn cursor is %.0f pt away from the pointer position. The mouse and the cursor image have been dissociated.", drift),
                remedy: "Run Unstick — it re-associates with CGAssociateMouseAndMouseCursorPosition(true). A game or remote-control app left it off.")]
        }
        return [Finding(check: "Pointer / cursor agreement", severity: .ok,
                        detail: "The drawn cursor tracks the pointer position — mouse and cursor are still associated.")]
    }

    static func scale() -> [Finding] {
        guard let getScale = SkyLight.getCursorScale,
              let connection = SkyLight.mainConnectionID else { return [] }
        var scale: Float = 0
        guard getScale(connection(), &scale) == 0, scale > 0 else { return [] }
        guard scale > 1.01 else { return [] }
        return [Finding(check: "Cursor scale", severity: .info,
                        detail: String(format: "Cursor is enlarged to %.2f× via Accessibility.", scale))]
    }

    static func secureInput() -> [Finding] {
        let enabled = IsSecureEventInputEnabled()
        return [Finding(
            check: "Secure event input", severity: enabled ? .warn : .ok,
            detail: enabled
                ? "Secure event input is ACTIVE. If no password field is focused, an app is leaking the assertion and interfering with event delivery."
                : "Secure event input is off.",
            remedy: enabled ? "Close any focused password field, or quit the app holding the assertion." : nil)]
    }

    static func taps(_ taps: [TapRow]) -> [Finding] {
        var findings: [Finding] = []

        // One finding per process, not per tap — a process can hold several
        // taps in the same state and repeating the identical row is noise.
        let disabled = Dictionary(grouping: taps.filter { $0.isActive && !$0.enabled }, by: \.pid)
        for (pid, rows) in disabled.sorted(by: { $0.key < $1.key }) {
            let tap = rows[0]
            let plural = rows.count > 1 ? " (\(rows.count) taps)" : ""
            findings.append(Finding(
                check: "Disabled filter tap", severity: .fail,
                detail: "\(tap.process) (pid \(pid)) holds an active \(tap.point) tap on \(tap.watches) that macOS has DISABLED\(plural) — the usual cause is exceeding the callback timeout. It may re-enable and time out repeatedly, and the flapping delays or reorders event delivery.",
                remedy: "Quit or update \(tap.process). A dead filtering tap is the classic cause of a system-wide cursor stall.",
                qualifier: "·\(pid)"))
        }

        let slow = Dictionary(grouping: taps.filter { $0.isActive && $0.enabled && $0.avgMicros > Config.slowTapMicros },
                              by: \.pid)
        for (pid, rows) in slow.sorted(by: { $0.key < $1.key }) {
            let worst = rows.max { $0.avgMicros < $1.avgMicros }!
            let pointer = rows.contains(where: \.watchesPointer)
            let count = rows.count > 1 ? "across \(rows.count) active taps " : ""
            findings.append(Finding(
                check: "Slow filter tap", severity: pointer ? .fail : .warn,
                detail: String(format: "%@ (pid %d) filters %@ at up to %.1f ms average %@(peak %.1f ms). %@",
                               worst.process, pid, worst.watches, worst.avgMicros / 1000, count, worst.maxMicros / 1000,
                               pointer
                                 ? "It sits directly in the mouse-move path, so cursor updates are delayed by that much."
                                 : "It does not watch pointer events, so it delays input but not the cursor."),
                remedy: "Quit \(worst.process) and retest. Anything over ~5 ms in a filtering tap risks the timeout that disables it.",
                qualifier: "·\(pid)"))
        }
        let pointerFilters = taps.filter { $0.isActive && $0.watchesPointer }
        if pointerFilters.count > 1 {
            findings.append(Finding(
                check: "Competing pointer filters", severity: .warn,
                detail: "\(pointerFilters.count) active taps filter pointer events: \(pointerFilters.map(\.process).joined(separator: ", ")). Each one can reorder or swallow mouse moves before the owning app sees them.",
                remedy: "Disable them one at a time to isolate the offender."))
        }
        if findings.isEmpty {
            findings.append(Finding(check: "Event taps", severity: .ok,
                                    detail: "No disabled or slow active tap sits in the pointer path."))
        }
        return findings
    }
}

// MARK: - Window under pointer

struct PointerContext: Equatable {
    let owner: String
    let zone: String
    let isEdge: Bool
    let isOwnWindow: Bool

    static let desktop = PointerContext(owner: "desktop", zone: "—", isEdge: false, isOwnWindow: false)
}

/// Names the window under the pointer and whether the pointer sits in the
/// resize band. The window list is front-to-back, but full-screen overlays
/// (the Dock spans the whole screen at layer 20) would swallow every hit, so
/// ordinary layer-0 windows are considered first.
func pointerContext(at point: CGPoint) -> PointerContext {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let myPID = Int(getpid())
    let ordered = list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
        + list.filter { ($0[kCGWindowLayer as String] as? Int) != 0 }
    for info in ordered {
        guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bounds["X"], let y = bounds["Y"],
              let w = bounds["Width"], let h = bounds["Height"],
              let layer = info[kCGWindowLayer as String] as? Int else { continue }
        if CGRect(x: x, y: y, width: w, height: h).contains(point) {
            let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
            let ownerPID = info[kCGWindowOwnerPID as String] as? Int ?? -1
            let title = info["kCGWindowName"] as? String ?? ""
            let edge = min(abs(point.x - x), abs(point.x - (x + w)), abs(point.y - y), abs(point.y - (y + h)))
            let isEdge = edge <= Config.edgeBand && layer == 0
            let zone = isEdge ? "EDGE(\(Int(edge))pt)" : "interior"
            let layerNote = layer == 0 ? "" : " layer\(layer)"
            return PointerContext(
                owner: "\(owner)\(layerNote)" + (title.isEmpty ? "" : " “\(title.prefix(24))”"),
                zone: zone, isEdge: isEdge, isOwnWindow: ownerPID == myPID)
        }
    }
    return .desktop
}
