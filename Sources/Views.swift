import SwiftUI

// MARK: - Shared styling

extension Verdict.State {
    var color: Color {
        switch self {
        case .ok: .green
        case .warn: .orange
        case .fail: .red
        case .unavailable: .gray
        }
    }

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warn: "exclamationmark.circle.fill"
        case .fail: "exclamationmark.triangle.fill"
        case .unavailable: "questionmark.circle.fill"
        }
    }
}

extension Finding.Severity {
    var color: Color {
        switch self {
        case .ok: .green
        case .warn: .orange
        case .fail: .red
        case .info: .secondary
        }
    }
}

// MARK: - Verdict hero

struct VerdictHero: View {
    let verdict: Verdict

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: verdict.state.symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(verdict.state.color)
                .frame(width: 46, height: 46)
                .background(verdict.state.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(verdict.headline)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(verdict.state.color)
                Text(verdict.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .animation(.default, value: verdict)
    }
}

// MARK: - Live strip (rate, sparkline, current cursors)

struct LiveStrip: View {
    let rate: Int
    let history: [Int]
    let totalSets: Int
    let lastActivity: String?
    let glyphs: [CursorGlyph]
    let lastCursorChange: Date?

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(rate)")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.default, value: rate)
                    Text("cursor changes / second · last \(Config.historyLength) s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(totalSets) since launch")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                SparklineView(values: history)
                    .frame(height: 54)
                if let lastActivity {
                    Text("Last activity: \(lastActivity)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            CursorGlyphStrip(glyphs: glyphs, lastCursorChange: lastCursorChange)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

struct SparklineView: View {
    let values: [Int]

    var body: some View {
        ZStack {
            SparklineShape(values: values, closed: true)
                .fill(Color.accentColor.opacity(0.12))
            SparklineShape(values: values, closed: false)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .animation(.default, value: values)
    }
}

struct SparklineShape: Shape {
    let values: [Int]
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let maxValue = CGFloat(max(4, values.max() ?? 4))
        let pad: CGFloat = 3
        let step = rect.width / CGFloat(values.count - 1)
        func y(_ value: Int) -> CGFloat {
            rect.height - pad - (CGFloat(value) / maxValue) * (rect.height - pad * 2)
        }
        path.move(to: CGPoint(x: 0, y: y(values[0])))
        for (index, value) in values.enumerated().dropFirst() {
            path.addLine(to: CGPoint(x: CGFloat(index) * step, y: y(value)))
        }
        if closed {
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: 0, y: rect.height))
            path.closeSubpath()
        }
        return path
    }
}

struct CursorGlyphStrip: View {
    let glyphs: [CursorGlyph]
    let lastCursorChange: Date?

    var body: some View {
        VStack(alignment: .trailing, spacing: 7) {
            HStack(spacing: 7) {
                ForEach(glyphs) { glyph in
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quinary)
                            .strokeBorder(.separator)
                        if let image = glyph.image {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "cursorarrow")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 34, height: 34)
                    .help(glyph.label)
                }
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(glyphs.map(\.label).joined(separator: " · "))
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                if let lastCursorChange {
                    Text("last change \(lastCursorChange, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - Section container

struct DiagnosticSection<Content: View>: View {
    let title: String
    let annotation: String?
    @ViewBuilder let content: Content

    init(_ title: String, annotation: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.annotation = annotation
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .kerning(0.7)
                    .foregroundStyle(.secondary)
                Spacer()
                if let annotation {
                    Text(annotation)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

// MARK: - Mode cards

struct ModeCards: View {
    let modes: [ModeStatus]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(modes, id: \.name) { mode in
                ModeCard(mode: mode)
            }
        }
    }
}

struct ModeCard: View {
    let mode: ModeStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(mode.name)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(mode.hit ? Color.red : .primary)
                Spacer()
                Text(mode.hit ? "DETECTED" : "NOT SEEN")
                    .font(.caption2.weight(.bold))
                    .kerning(0.5)
                    .foregroundStyle(mode.hit ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
            }
            Text(mode.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("signature · \(mode.signature)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(mode.hit ? Color.red.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(mode.hit ? Color.red.opacity(0.5) : Color(nsColor: .separatorColor)))
        .animation(.default, value: mode.hit)
    }
}

// MARK: - Checks

struct ChecksList: View {
    let findings: [Finding]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(findings) { finding in
                FindingRow(finding: finding)
                if finding.id != findings.last?.id { Divider() }
            }
        }
        .background(.quinary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator))
    }
}

struct FindingRow: View {
    let finding: Finding

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(finding.severity.label.uppercased())
                .font(.caption2.weight(.bold))
                .kerning(0.5)
                .foregroundStyle(finding.severity.color)
                .frame(width: 46)
                .padding(.vertical, 3)
                .background(finding.severity.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.check)
                    .font(.callout.weight(.medium))
                Text(finding.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let remedy = finding.remedy {
                    Label(remedy, systemImage: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

// MARK: - Event taps

struct TapsGrid: View {
    let taps: [TapRow]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
            GridRow {
                Text("PROCESS")
                Text("PID").gridColumnAlignment(.trailing)
                Text("POINT")
                Text("MODE")
                Text("LATENCY AVG/MAX").gridColumnAlignment(.trailing)
                Text("WATCHES")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.vertical, 6)
            Divider()
            ForEach(taps) { tap in
                TapGridRow(tap: tap)
                if tap.id != taps.last?.id { Divider() }
            }
        }
        .padding(.horizontal, 12)
        .background(.quinary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator))
    }
}

struct TapGridRow: View {
    let tap: TapRow

    var body: some View {
        GridRow {
            Text(tap.process)
                .fontWeight(tap.isSuspect ? .semibold : .regular)
                .foregroundStyle(tap.isSuspect ? Color.red : .primary)
            Text("\(tap.pid)").monospacedDigit().foregroundStyle(.secondary)
            Text(tap.point).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(tap.mode)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(tap.isActive ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(tap.isActive ? Color.accentColor : .secondary)
                if !tap.enabled {
                    Text("disabled")
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(Color.red)
                }
            }
            Text(tap.latency)
                .monospacedDigit()
                .foregroundStyle(tap.avgMicros > Config.slowTapMicros ? Color.red : .secondary)
            Text(tap.watches).foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.vertical, 7)
    }
}

// MARK: - Live trace

struct TraceView: View {
    let lines: [TraceLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("cursor changes, named — newest first")
                Spacer()
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text("recording")
                    .foregroundStyle(Color.green)
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider()
            if lines.isEmpty {
                Text("no cursor changes observed yet — move the pointer around")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(lines) { line in
                            TraceLineView(line: line)
                        }
                    }
                    .padding(10)
                }
                .frame(height: 190)
            }
        }
        .background(.quinary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator))
    }
}

struct TraceLineView: View {
    let line: TraceLine

    var body: some View {
        Text(composed)
            .font(.system(size: 11, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var composed: AttributedString {
        var time = AttributedString(line.time + "  ")
        time.foregroundColor = .secondary
        var text = AttributedString(line.text)
        switch line.kind {
        case .change: text.foregroundColor = .primary
        case .reset: text.foregroundColor = .orange
        case .verdict:
            text = AttributedString("── " + line.text)
            text.foregroundColor = .red
        case .info: text.foregroundColor = .secondary
        }
        var result = time + text
        if !line.context.isEmpty {
            var context = AttributedString("   over: " + line.context)
            context.foregroundColor = .secondary
            result += context
        }
        return result
    }
}

// MARK: - Actions bar

struct ActionsBar: View {
    let monitor: Monitor

    var body: some View {
        HStack(spacing: 10) {
            Button("Unstick Cursor") {
                Task { await monitor.unstick() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            Button("Run Full Diagnostic") {
                Task { await monitor.runFullDiagnostic() }
            }
            .disabled(monitor.probing)
            Button("Copy Report") { monitor.copyReport() }
            if monitor.probing {
                ProgressView().controlSize(.small)
            }
            if let result = monitor.actionResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .animation(.default, value: monitor.actionResult)
    }
}

// MARK: - Explainer

struct UnstickExplainer: View {
    private static let steps: [(String, String)] = [
        ("Drains the hide count.", "Repeated CGDisplayShowCursor, because hide/show is a counter and a process that crashed between the two leaves it negative."),
        ("Re-associates pointer and cursor", "via CGAssociateMouseAndMouseCursorPosition(true), undoing a game or remote-control tool that dissociated them."),
        ("Cycles the cursor scale", "through SLSSetCursorScale — the programmatic form of nudging the Accessibility pointer-size slider, which forces WindowServer to re-register every cursor image. This is the step that fixes a genuinely wedged cursor."),
        ("Resets to the arrow and posts a synthetic mouse-move,", "so the app under the pointer receives a fresh cursorUpdate and re-asserts the correct cursor."),
    ]

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1).  \(Text(step.0).fontWeight(.semibold)) \(step.1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("What “Unstick Cursor” actually does — four steps, no WindowServer restart")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - Root

struct ContentView: View {
    let monitor: Monitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VerdictHero(verdict: monitor.verdict)
                Divider()
                LiveStrip(rate: monitor.rate,
                          history: monitor.history,
                          totalSets: monitor.totalSets,
                          lastActivity: monitor.lastActivity,
                          glyphs: monitor.recentCursors,
                          lastCursorChange: monitor.lastCursorChange)
                Divider()
                DiagnosticSection("Diagnosis", annotation: modeAnnotation) {
                    ModeCards(modes: monitor.modes)
                    Text("This counts cursor changes, not mouse movement — 0/s while moving inside a window is normal. To catch the bug, rest the pointer on a window's resize edge and hold it still: a healthy system ticks once and stops.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                DiagnosticSection("Checks", annotation: checkAnnotation) {
                    ChecksList(findings: monitor.findings)
                }
                Divider()
                DiagnosticSection("Event taps in the pointer path", annotation: "\(monitor.taps.count) shown") {
                    TapsGrid(taps: monitor.taps)
                }
                Divider()
                DiagnosticSection("Live trace", annotation: "cursortrace") {
                    TraceView(lines: monitor.trace)
                }
                Divider()
                UnstickExplainer()
            }
        }
        .frame(minWidth: 760, minHeight: 620)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                ActionsBar(monitor: monitor)
            }
        }
    }

    private var modeAnnotation: String {
        let hits = monitor.modes.filter(\.hit).count
        return hits == 0 ? "neither mode matched" : "\(hits) of \(monitor.modes.count) modes matched"
    }

    private var checkAnnotation: String {
        let fails = monitor.findings.filter { $0.severity == .fail }.count
        let warns = monitor.findings.filter { $0.severity == .warn }.count
        if fails == 0 && warns == 0 { return "all clear" }
        return "\(fails) fault\(fails == 1 ? "" : "s"), \(warns) warning\(warns == 1 ? "" : "s")"
    }
}
