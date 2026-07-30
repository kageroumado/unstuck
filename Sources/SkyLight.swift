import AppKit
import CoreGraphics

// MARK: - Constants

enum Config {
    static let seedPollInterval: TimeInterval = 0.05
    static let checksInterval: TimeInterval = 2.0
    /// Sparkline window, in one-second samples.
    static let historyLength = 30
    /// Changes per second (pointer still, ≤2 distinct cursors) that count as a fight.
    static let flickerThreshold = 8
    /// Consecutive edge crossings with zero cursor changes before "stuck" is declared.
    static let stuckCrossings = 3
    /// Average callback latency (µs) above which an active tap is flagged.
    static let slowTapMicros: Float = 5000
    /// Distance from a window edge (pt) that counts as the resize band.
    static let edgeBand: CGFloat = 2
    static let traceLimit = 250
}

// MARK: - SkyLight SPI (resolved at runtime; every feature degrades gracefully)

enum SkyLight {
    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    private static func symbol(_ names: [String]) -> UnsafeMutableRawPointer? {
        guard let handle else { return nil }
        for name in names {
            if let sym = dlsym(handle, name) { return sym }
        }
        return nil
    }

    typealias SeedFn = @convention(c) () -> UInt32
    typealias ConnectionFn = @convention(c) () -> Int32
    typealias BoolFn = @convention(c) () -> Bool
    typealias GetScaleFn = @convention(c) (Int32, UnsafeMutablePointer<Float>) -> Int32
    typealias SetScaleFn = @convention(c) (Int32, Float) -> Int32
    typealias GetPointFn = @convention(c) (Int32, UnsafeMutablePointer<CGPoint>) -> Int32

    /// Global counter incremented every time any process sets the cursor.
    static let currentCursorSeed: SeedFn? =
        symbol(["SLSCurrentCursorSeed", "CGSCurrentCursorSeed"]).map { unsafeBitCast($0, to: SeedFn.self) }
    static let mainConnectionID: ConnectionFn? =
        symbol(["SLSMainConnectionID", "_CGSDefaultConnection"]).map { unsafeBitCast($0, to: ConnectionFn.self) }
    /// WindowServer's own view of cursor visibility. CGCursorIsVisible is
    /// hard-unavailable to Swift, so read the scoreboard flag SkyLight exposes.
    static let cursorIsVisible: BoolFn? =
        symbol(["SLCursorIsVisible"]).map { unsafeBitCast($0, to: BoolFn.self) }
    static let getCursorScale: GetScaleFn? =
        symbol(["SLSGetCursorScale", "CGSGetCursorScale"]).map { unsafeBitCast($0, to: GetScaleFn.self) }
    static let setCursorScale: SetScaleFn? =
        symbol(["SLSSetCursorScale", "CGSSetCursorScale"]).map { unsafeBitCast($0, to: SetScaleFn.self) }
    static let getCurrentCursorLocation: GetPointFn? =
        symbol(["SLSGetCurrentCursorLocation"]).map { unsafeBitCast($0, to: GetPointFn.self) }
}

// MARK: - Process names (NSRunningApplication first, libproc fallback for daemons)

private typealias ProcNameFn = @convention(c) (Int32, UnsafeMutableRawPointer, UInt32) -> Int32
private let procName: ProcNameFn? =
    dlsym(dlopen(nil, RTLD_NOW), "proc_name").map { unsafeBitCast($0, to: ProcNameFn.self) }

func nameForProcess(_ pid: pid_t) -> String {
    if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
        return name
    }
    var buffer = [CChar](repeating: 0, count: 256)
    if let procName, procName(pid, &buffer, 256) > 0 {
        return String(cString: buffer)
    }
    return "pid \(pid)"
}
