import AppKit
import Observation

// MARK: - Derived UI state

struct Verdict: Equatable {
    enum State: Equatable { case ok, warn, fail, unavailable }
    let state: State
    let headline: String
    let detail: String
}

struct ModeStatus: Equatable {
    let name: String
    let hit: Bool
    let description: String
    let signature: String
}

struct TraceLine: Identifiable, Equatable {
    enum Kind: Equatable { case change, reset, verdict, info }
    let id: UUID
    let time: String
    let kind: Kind
    let text: String
    let context: String

    init(time: String, kind: Kind, text: String, context: String = "") {
        self.id = UUID()
        self.time = time
        self.kind = kind
        self.text = text
        self.context = context
    }
}

// MARK: - Monitor

@MainActor @Observable
final class Monitor {
    // Live rate
    private(set) var rate = 0
    private(set) var history: [Int] = Array(repeating: 0, count: Config.historyLength)
    private(set) var totalSets = 0
    private(set) var lastActivity: String?
    // Cursor identity
    private(set) var recentCursors: [CursorGlyph] = []
    private(set) var lastCursorChange: Date?
    // Failure modes
    private(set) var flickerHit = false
    private(set) var stuckHit = false
    // Checks, taps, trace
    private(set) var findings: [Finding] = []
    private(set) var taps: [TapRow] = []
    private(set) var trace: [TraceLine] = []
    // Verdict + actions
    private(set) var verdict = Verdict(state: .ok, headline: "Watching the cursor",
                                       detail: "Collecting the first samples…")
    private(set) var actionResult: String?
    private(set) var probing = false

    var seedAvailable: Bool { SkyLight.currentCursorSeed != nil }

    // MARK: Internal bookkeeping (not observed by any view)

    @ObservationIgnored private var lastSeed: UInt32 = 0
    @ObservationIgnored private var accumulated = 0
    @ObservationIgnored private var windowStart = Date()
    @ObservationIgnored private var windowStill = true
    @ObservationIgnored private var windowFingerprints: Set<Int> = []
    @ObservationIgnored private var lastPointer = CGPoint.zero
    @ObservationIgnored private var lastFingerprint = 0
    @ObservationIgnored private var lastCursorLabel = "unknown"
    // Burst bookkeeping for trace verdict lines
    @ObservationIgnored private var burstCount = 0
    @ObservationIgnored private var burstFingerprints: [Int] = []
    @ObservationIgnored private var lastSeedChange = Date.distantPast
    // Stuck detection
    @ObservationIgnored private var wasEdge = false
    @ObservationIgnored private var pendingCrossingSeed: UInt32?
    @ObservationIgnored private var crossingDeadline = Date.distantPast
    @ObservationIgnored private var failedCrossings = 0
    @ObservationIgnored private var edgeTickCounter = 0
    // Window-under-pointer lookups are not free; cache briefly
    @ObservationIgnored private var cachedContext = PointerContext.desktop
    @ObservationIgnored private var cachedContextAt = Date.distantPast

    @ObservationIgnored private var seedTimer: Timer?
    @ObservationIgnored private var checksTimer: Timer?
    /// Keeps App Nap from throttling the poll timers while the app is in the
    /// background — without this the monitor goes blind the moment another
    /// app is frontmost, which is exactly when the interesting data happens.
    @ObservationIgnored private var activityToken: NSObjectProtocol?

    @ObservationIgnored private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    // MARK: Lifecycle

    func start() {
        guard seedTimer == nil else { return }
        lastSeed = SkyLight.currentCursorSeed?() ?? 0
        let initial = CursorIdentity.sample()
        lastFingerprint = initial.fingerprint
        lastCursorLabel = initial.label
        recentCursors = [CursorGlyph(id: initial.fingerprint, label: initial.label, image: initial.image)]
        appendTrace(TraceLine(time: timeFormatter.string(from: Date()), kind: .info,
                              text: "START — cursor is \(initial.label), \(CursorIdentity.names.count) cursors fingerprinted"))
        refreshChecks()

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Monitoring cursor activity in the background")

        let seedTimer = Timer.scheduledTimer(withTimeInterval: Config.seedPollInterval, repeats: true) { _ in
            MainActor.assumeIsolated { self.pollSeed() }
        }
        seedTimer.tolerance = 0
        RunLoop.main.add(seedTimer, forMode: .common)
        self.seedTimer = seedTimer

        checksTimer = Timer.scheduledTimer(withTimeInterval: Config.checksInterval, repeats: true) { _ in
            MainActor.assumeIsolated { self.refreshChecks() }
        }
    }

    // MARK: Seed polling (20 Hz)

    private func pollSeed() {
        guard let seedFn = SkyLight.currentCursorSeed else { return }

        let pointer = CGEvent(source: nil)?.location ?? .zero
        if hypot(pointer.x - lastPointer.x, pointer.y - lastPointer.y) > 3 {
            windowStill = false
        }
        lastPointer = pointer

        let seed = seedFn()
        if seed != lastSeed {
            let delta = seed >= lastSeed ? Int(seed &- lastSeed) : 1
            lastSeed = seed
            accumulated += delta
            registerChange(delta: delta, pointer: pointer)
        } else {
            finishBurstIfQuiet()
        }

        edgeTickCounter += 1
        if edgeTickCounter >= 5 {
            edgeTickCounter = 0
            trackEdges(pointer: pointer)
        }

        if Date().timeIntervalSince(windowStart) >= 1 {
            closeWindow()
        }
    }

    private func registerChange(delta: Int, pointer: CGPoint) {
        lastSeedChange = Date()
        let sample = CursorIdentity.sample()
        windowFingerprints.insert(sample.fingerprint)

        burstCount += delta
        burstFingerprints.append(sample.fingerprint)
        if burstFingerprints.count > 40 { burstFingerprints.removeFirst() }

        let changed = sample.fingerprint != lastFingerprint
        let context = contextThrottled(at: pointer)
        appendTrace(TraceLine(
            time: timeFormatter.string(from: Date()),
            kind: changed ? .change : .reset,
            text: changed ? "\(lastCursorLabel) → \(sample.label)" : "\(sample.label) (again)",
            context: "\(context.owner) [\(context.zone)]"))

        if changed {
            var glyphs = recentCursors.filter { $0.id != sample.fingerprint }
            glyphs.append(CursorGlyph(id: sample.fingerprint, label: sample.label, image: sample.image))
            if glyphs.count > 3 { glyphs.removeFirst(glyphs.count - 3) }
            recentCursors = glyphs
            lastCursorChange = Date()
        }
        lastFingerprint = sample.fingerprint
        lastCursorLabel = sample.label

        // Any landed change while a crossing is pending means delivery works.
        if pendingCrossingSeed != nil {
            pendingCrossingSeed = nil
            failedCrossings = 0
            if stuckHit { stuckHit = false; deriveVerdict() }
        }
    }

    private func finishBurstIfQuiet() {
        guard burstCount > 0, Date().timeIntervalSince(lastSeedChange) > 0.6 else { return }
        let unique = Set(burstFingerprints).count
        let text: String
        if burstCount >= 3 && unique == 1 {
            text = "burst end: REDUNDANT — \(burstCount) sets, all the same cursor (an app is calling set() unconditionally)"
        } else if burstCount >= Config.flickerThreshold && unique <= 2 {
            text = "burst end: ALTERNATING — \(burstCount) sets between \(unique) cursors (two setters fighting, or push/pop imbalance)"
        } else {
            text = "burst end: \(burstCount) set\(burstCount == 1 ? "" : "s") across \(unique) cursor\(unique == 1 ? "" : "s") — normal"
        }
        appendTrace(TraceLine(time: timeFormatter.string(from: Date()),
                              kind: burstCount >= Config.flickerThreshold && unique <= 2 ? .verdict : .info,
                              text: text))
        burstCount = 0
        burstFingerprints.removeAll()
    }

    private func closeWindow() {
        rate = accumulated
        history = Array(history.dropFirst()) + [accumulated]
        let flicker = windowStill && accumulated >= Config.flickerThreshold
            && !windowFingerprints.isEmpty && windowFingerprints.count <= 2
        if accumulated > 0 {
            totalSets += accumulated
            let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
            lastActivity = "\(accumulated) sets/s while “\(frontmost)” was frontmost"
                + (windowStill ? " (pointer still)" : "")
        }
        if flicker != flickerHit {
            flickerHit = flicker
            deriveVerdict()
        } else if flicker {
            deriveVerdict() // keep the live rate in the headline fresh
        }
        accumulated = 0
        windowFingerprints.removeAll()
        windowStill = true
        windowStart = Date()
    }

    // MARK: Stuck detection (4 Hz)

    private func trackEdges(pointer: CGPoint) {
        let context = contextThrottled(at: pointer, maxAge: 0.2)
        let isEdge = context.isEdge && !context.isOwnWindow
        if isEdge && !wasEdge {
            pendingCrossingSeed = lastSeed
            crossingDeadline = Date().addingTimeInterval(0.5)
        }
        wasEdge = isEdge

        if let pendingSeed = pendingCrossingSeed, Date() > crossingDeadline {
            pendingCrossingSeed = nil
            if lastSeed == pendingSeed {
                failedCrossings += 1
                if failedCrossings >= Config.stuckCrossings && !stuckHit {
                    stuckHit = true
                    appendTrace(TraceLine(time: timeFormatter.string(from: Date()), kind: .verdict,
                                          text: "STALLED — \(failedCrossings) edge crossings, 0 cursor changes"))
                    deriveVerdict()
                }
            } else {
                failedCrossings = 0
                if stuckHit { stuckHit = false; deriveVerdict() }
            }
        }
    }

    private func contextThrottled(at point: CGPoint, maxAge: TimeInterval = 0.1) -> PointerContext {
        if Date().timeIntervalSince(cachedContextAt) > maxAge {
            cachedContext = pointerContext(at: point)
            cachedContextAt = Date()
        }
        return cachedContext
    }

    // MARK: Checks (0.5 Hz)

    func refreshChecks() {
        let currentTaps = fetchTaps()
        taps = currentTaps

        var collected: [Finding] = []
        if flickerHit {
            collected.append(Finding(
                check: "Idle cursor churn", severity: .fail,
                detail: "\(rate) cursor changes per second with no pointer movement, alternating between \(recentCursors.suffix(2).map(\.label).joined(separator: " ⇄ ")).",
                remedy: "Watch the live trace below — the window owner named there is one of the fighters."))
        }
        if stuckHit {
            collected.append(Finding(
                check: "No change on edge crossing", severity: .fail,
                detail: "The pointer entered a window's resize band \(max(failedCrossings, Config.stuckCrossings)) times with zero cursor changes. A healthy crossing ticks the counter exactly once.",
                remedy: "Run Unstick, then quit any disabled-tap process listed below."))
        }
        collected += PassiveChecks.taps(currentTaps)
        collected += PassiveChecks.visibility()
        collected += PassiveChecks.position()
        collected += PassiveChecks.secureInput()
        collected += PassiveChecks.scale()
        // Keep any probe results from the last full diagnostic at the end.
        collected += findings.filter { $0.check.hasPrefix("Probe:") }
        findings = collected.sorted { $0.severity < $1.severity }
        deriveVerdict()
    }

    // MARK: Verdict

    var modes: [ModeStatus] {
        [ModeStatus(name: "Flicker", hit: flickerHit,
                    description: "Two owners assert different cursors in turn, so each one is immediately overwritten by the other.",
                    signature: "≥\(Config.flickerThreshold) changes/s across ≤2 cursors, pointer still"),
         ModeStatus(name: "Stuck", hit: stuckHit,
                    description: "The cursor is asserted once and never corrected — an unbalanced push, a hide leak, or lost ownership.",
                    signature: "0 changes while crossing a resize edge")]
    }

    private func deriveVerdict() {
        guard seedAvailable else {
            verdict = Verdict(state: .unavailable, headline: "Cursor-seed monitoring unavailable",
                              detail: "The SkyLight cursor-seed SPI could not be resolved on this system. Event-tap analysis still works.")
            return
        }
        let fails = findings.filter { $0.severity == .fail && !$0.check.hasPrefix("Probe:") }
        let warns = findings.filter { $0.severity == .warn }
        if flickerHit {
            let pair = recentCursors.suffix(2).map(\.label).joined(separator: " ⇄ ")
            verdict = Verdict(
                state: .fail, headline: "Two processes are fighting over the cursor",
                detail: "The cursor changed \(rate) times per second while the pointer was not moving"
                    + (pair.isEmpty ? "." : ", alternating \(pair).")
                    + " Redundant sets are coalesced by WindowServer, so a genuine alternation means two different setters, not one noisy app.")
        } else if stuckHit {
            verdict = Verdict(
                state: .fail, headline: "Cursor updates are not being delivered",
                detail: "Crossing a resize edge produced zero cursor changes, so the cursorUpdate never reached the owning app — or an app pushed a cursor and never popped it.")
        } else if let firstFail = fails.first {
            verdict = Verdict(
                state: .fail,
                headline: fails.count == 1 ? firstFail.check : "\(fails.count) faults found",
                detail: firstFail.detail)
        } else if let firstWarn = warns.first {
            verdict = Verdict(
                state: .warn,
                headline: "\(warns.count) warning\(warns.count == 1 ? "" : "s"), no outright faults",
                detail: "\(firstWarn.check): \(firstWarn.detail)")
        } else {
            verdict = Verdict(
                state: .ok, headline: "Cursor machinery is healthy",
                detail: "Nothing churns while the pointer is still, the cursor is visible and tracks the pointer, and no event tap in the pointer path looks problematic. Nothing here explains a stall.")
        }
    }

    private func appendTrace(_ line: TraceLine) {
        var lines = trace
        lines.insert(line, at: 0)
        if lines.count > Config.traceLimit { lines.removeLast(lines.count - Config.traceLimit) }
        trace = lines
    }

    // MARK: Unstick

    func unstick() async {
        var steps: [String] = []

        let display = CGMainDisplayID()
        for _ in 0..<8 { CGDisplayShowCursor(display) }
        steps.append("drained the cursor-hide count")

        CGAssociateMouseAndMouseCursorPosition(1)
        steps.append("re-associated the pointer with the cursor")

        if let connection = SkyLight.mainConnectionID,
           let getScale = SkyLight.getCursorScale,
           let setScale = SkyLight.setCursorScale {
            let cid = connection()
            var scale: Float = 1
            if getScale(cid, &scale) == 0, scale > 0 {
                let nudged = scale > 1.5 ? scale - 0.25 : scale + 0.25
                _ = setScale(cid, nudged)
                try? await Task.sleep(for: .milliseconds(150))
                _ = setScale(cid, scale)
                steps.append("cycled the cursor scale so WindowServer rebuilt its cursor state")
            }
        }

        NSCursor.arrow.set()
        steps.append("reset the cursor image to the arrow")

        let location = CGEvent(source: nil)?.location ?? .zero
        if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                              mouseCursorPosition: location, mouseButton: .left) {
            move.post(tap: .cghidEventTap)
            let trusted = AXIsProcessTrusted()
            steps.append("posted a synthetic mouse-move to re-trigger cursor tracking"
                         + (trusted ? "" : " (grant Accessibility permission if this step seems ignored)"))
        }

        actionResult = "Done: " + steps.joined(separator: "; ") + "."
    }

    // MARK: Full diagnostic (active probes, each restores what it touches)

    func runFullDiagnostic() async {
        guard !probing else { return }
        probing = true
        actionResult = nil
        var probeFindings: [Finding] = []
        probeFindings += await probeVisibilityBalance()
        probeFindings += await probeScaleCycle()
        probeFindings += await probeOwnership()
        findings = (findings.filter { !$0.check.hasPrefix("Probe:") } + probeFindings)
            .sorted { $0.severity < $1.severity }
        probing = false
        actionResult = "Full diagnostic finished — \(probeFindings.count) probe results added to the checks."
        deriveVerdict()
    }

    private func probeVisibilityBalance() async -> [Finding] {
        guard let isVisible = SkyLight.cursorIsVisible else { return [] }
        let display = CGMainDisplayID()
        let before = isVisible()
        CGDisplayHideCursor(display)
        try? await Task.sleep(for: .milliseconds(120))
        CGDisplayShowCursor(display)
        try? await Task.sleep(for: .milliseconds(120))
        let restored = isVisible()
        return [Finding(
            check: "Probe: hide/show balance", severity: restored == before ? .ok : .fail,
            detail: restored == before
                ? "A hide followed by a show returned to the starting state, so the visibility counter is not corrupted."
                : "The visibility counter did NOT return to its starting value after a balanced hide/show.",
            remedy: restored == before ? nil : "Run Unstick — it drains the count with repeated CGDisplayShowCursor.")]
    }

    private func probeScaleCycle() async -> [Finding] {
        guard let connection = SkyLight.mainConnectionID,
              let getScale = SkyLight.getCursorScale,
              let setScale = SkyLight.setCursorScale,
              let seedFn = SkyLight.currentCursorSeed else { return [] }
        let cid = connection()
        var scale: Float = 0
        guard getScale(cid, &scale) == 0, scale > 0 else { return [] }
        let before = seedFn()
        _ = setScale(cid, scale + 0.25)
        try? await Task.sleep(for: .milliseconds(150))
        _ = setScale(cid, scale)
        try? await Task.sleep(for: .milliseconds(150))
        var restored: Float = 0
        _ = getScale(cid, &restored)
        let ticks = seedFn() &- before
        return [Finding(
            check: "Probe: scale cycle (the unstick lever)", severity: restored == scale ? .ok : .warn,
            detail: String(format: "Cycling the cursor scale %.2f → %.2f → %.2f moved the change counter by %d, forcing WindowServer to re-register every cursor image.", scale, scale + 0.25, restored, ticks))]
    }

    /// The definitive ownership test: a cursor set only lands if the pointer
    /// is over YOUR window, so this puts a real window under the pointer and
    /// measures what each API actually does.
    private func probeOwnership() async -> [Finding] {
        guard let seedFn = SkyLight.currentCursorSeed else { return [] }
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .milliseconds(300))

        let pointer = CGEvent(source: nil)?.location ?? .zero
        // CoreGraphics is top-left origin; AppKit flips against the PRIMARY
        // display's height — not whichever screen the pointer is on.
        guard let primary = NSScreen.screens.first else { return [] }
        let flippedY = primary.frame.maxY - pointer.y
        let frame = NSRect(x: pointer.x - 90, y: flippedY - 60, width: 180, height: 120)

        let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.level = .popUpMenu
        window.backgroundColor = .systemIndigo
        window.isOpaque = true
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()

        let label = NSTextField(labelWithString: "Unstuck\nownership probe")
        label.alignment = .center
        label.textColor = .white
        label.frame = NSRect(x: 0, y: 42, width: 180, height: 40)
        window.contentView?.addSubview(label)

        try? await Task.sleep(for: .milliseconds(500))
        let windowIsUnderPointer = window.frame.contains(NSPoint(x: pointer.x, y: flippedY))

        func measure(_ body: () -> Void) async -> Int {
            let before = seedFn()
            body()
            try? await Task.sleep(for: .milliseconds(250))
            return Int(seedFn() &- before)
        }

        let firstSet = await measure { NSCursor.resizeLeftRight.set() }
        let redundant = await measure { for _ in 0..<20 { NSCursor.resizeLeftRight.set() } }
        let changed = await measure { NSCursor.pointingHand.set() }
        let pushed = await measure { NSCursor.crosshair.push() }
        let popped = await measure { NSCursor.pop() }
        NSCursor.arrow.set()

        window.orderOut(nil)
        window.close()

        let owned = firstSet > 0 || changed > 0
        if owned {
            return [
                Finding(check: "Probe: cursor ownership", severity: .ok,
                        detail: "With a window under the pointer, this process could set the cursor (initial set moved the counter by \(firstSet), a genuine change by \(changed)). Ownership arbitration works normally."),
                Finding(check: "Probe: redundant direct set()", severity: redundant == 0 ? .ok : .warn,
                        detail: "Re-setting the SAME cursor 20 times moved the counter by \(redundant), against \(changed) for one real change. "
                            + (redundant == 0
                               ? "WindowServer coalesces redundant sets, so an app calling set() on every mouse move is wasteful but cannot itself flicker."
                               : "Redundant sets are NOT coalesced, so an app calling set() on every mouse move produces real churn and will fight any other setter.")),
                Finding(check: "Probe: push() / pop() balance", severity: .info,
                        detail: "push() moved the counter by \(pushed) and pop() by \(popped). Every push needs exactly one pop; an app that pushes on mouse-enter and misses the pop strands the wrong cursor until something else sets one."),
            ]
        }
        if !windowIsUnderPointer {
            return [Finding(check: "Probe: cursor ownership", severity: .info,
                            detail: "Probe skipped: the pointer was not over the probe window, so ownership could not be tested. Keep the pointer still on the main display and rerun.")]
        }
        return [Finding(check: "Probe: cursor ownership", severity: .warn,
                        detail: "The probe window WAS under the pointer, yet no cursor set took effect. Either another process holds cursor ownership, or this app is not permitted to set it.",
                        remedy: "Check for remote-control or pointer utilities that set the cursor in the background.")]
    }

    // MARK: Report

    func copyReport() {
        var lines: [String] = []
        lines.append("Unstuck report — macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Verdict: \(verdict.headline). \(verdict.detail)")
        lines.append("Cursor changes/s: \(rate) (flicker threshold \(Config.flickerThreshold)), \(totalSets) total since launch")
        if let lastActivity { lines.append("Last activity: \(lastActivity)") }
        lines.append("Modes: " + modes.map { "\($0.name)=\($0.hit ? "DETECTED" : "not seen")" }.joined(separator: ", "))
        lines.append("")
        lines.append("Checks (\(findings.count)):")
        for finding in findings {
            lines.append("  [\(finding.severity.label)] \(finding.check): \(finding.detail)")
            if let remedy = finding.remedy { lines.append("         → \(remedy)") }
        }
        lines.append("")
        lines.append("Event taps (\(taps.count)):")
        for tap in taps {
            var line = "  \(tap.process) (pid \(tap.pid)) — \(tap.point), \(tap.mode), "
            line += tap.enabled ? "enabled" : "DISABLED"
            line += ", latency \(tap.latency), watches: \(tap.watches)"
            lines.append(line)
        }
        let recentTrace = trace.prefix(40).reversed()
        if !recentTrace.isEmpty {
            lines.append("")
            lines.append("Trace (last \(recentTrace.count) lines):")
            for line in recentTrace {
                lines.append("  \(line.time)  \(line.text)" + (line.context.isEmpty ? "" : "   over: \(line.context)"))
            }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
        actionResult = "Report copied to the clipboard."
    }
}
