//
//  UIDebugKit.swift
//  A drop-in, zero-dependency visual debugging overlay for SwiftUI.
//
//  WHAT IT GIVES YOU (no need to read code to measure your UI):
//    • A floating 📏 button (DEBUG builds only) that opens a control panel.
//    • Inspect       – touch any component and see its name + exact size, with
//                      no per-view code. Works straight on any screen.
//    • Tape Measure  – drag two handles to read distance, horizontal (dx)
//                      and vertical (dy) spacing in points between ANY two
//                      points on screen. Perfect for "how much space is this?".
//    • Grid Overlay  – 8pt (or any) grid + major lines to eyeball alignment.
//    • Safe Area     – shows the safe-area insets and their exact values.
//
//  HOW TO USE (2 steps):
//    1. Copy this ONE file into your project.
//    2. Add `.uiDebugKit()` to your root view (e.g. ContentView in the
//       WindowGroup, or any screen you want to inspect).
//
//  Everything compiles to a no-op in RELEASE builds, so it is App Store safe.
//
//  Requires iOS 15+ / SwiftUI. No external dependencies.
//

import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Public API

public extension View {

    /// Attach the debug toolkit to a root view. Adds a floating 📏 button
    /// (DEBUG only) that opens the measuring tools. No-op in release builds.
    func uiDebugKit() -> some View {
        #if DEBUG
        modifier(UIDebugKitModifier())
        #else
        self
        #endif
    }
}

#if DEBUG

// MARK: - Shared State

/// Holds the on/off state of every tool. Single shared instance so the
/// floating button, the panel and all overlays stay in sync.
final class UIDebugState: ObservableObject {
    static let shared = UIDebugState()
    private init() {}

    @Published var panelOpen = false

    /// When true the floating 📏 button is hidden. Shake the device (or
    /// relaunch the app) to bring it back.
    @Published var buttonHidden = false

    // Tools
    @Published var showRuler = false
    @Published var showGrid = false
    @Published var showSafeArea = false
    @Published var showInspect = false

    // Live result of Inspect mode (the element currently under the finger),
    // in window/global coordinates.
    @Published var inspectRect: CGRect? = nil
    @Published var inspectName: String = ""

    // Two pinned elements for gap measurement (tap one, then another).
    @Published var pinnedA: CGRect? = nil
    @Published var pinnedAName: String = ""
    @Published var pinnedB: CGRect? = nil
    @Published var pinnedBName: String = ""
    // Nearest neighbor in each direction, shown automatically when only A is pinned.
    @Published var neighbors: [CGRect] = []

    func clearPins() {
        pinnedA = nil; pinnedAName = ""
        pinnedB = nil; pinnedBName = ""
        neighbors = []
    }

    // Spacing check: flag gaps that aren't a multiple of the design grid unit.
    @Published var checkGrid = true
    @Published var gridBaseUnit: CGFloat = 8

    /// Returns whether a measured gap sits on the grid, and the nearest on-grid value.
    func gridStatus(_ value: CGFloat) -> (onGrid: Bool, nearest: CGFloat) {
        guard gridBaseUnit > 0 else { return (true, value) }
        let nearest = (value / gridBaseUnit).rounded() * gridBaseUnit
        return (abs(value - nearest) <= 0.75, nearest)
    }

    // Grid settings
    @Published var gridSpacing: CGFloat = 8
    @Published var majorEvery: Int = 5
    @Published var snapToGrid = false

    /// Small on-screen key explaining what the numbers mean.
    @Published var showLegend = true

    // Captured from the root view
    @Published var safeInsets = EdgeInsets()

    var anyToolOn: Bool { showRuler || showGrid || showSafeArea || showInspect }
}

// MARK: - Root Modifier

struct UIDebugKitModifier: ViewModifier {
    @ObservedObject private var state = UIDebugState.shared

    func body(content: Content) -> some View {
        content
            // Capture the real safe-area insets before we ignore them below.
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: InsetsKey.self, value: geo.safeAreaInsets)
                }
            )
            .onPreferenceChange(InsetsKey.self) { state.safeInsets = $0 }
            // Shake to summon the button back after it's been hidden.
            .background(
                ShakeToSummon(isActive: state.buttonHidden) {
                    state.buttonHidden = false
                    state.panelOpen = true
                }
            )
            // Inspect mode: watches touches on the window and reports the
            // element under the finger. No per-view annotation needed.
            .background(InspectorInstaller(isActive: state.showInspect))
            // Measuring overlays (full screen, mostly pass-through).
            // accessibilityHidden keeps our own overlays out of the tree that
            // Inspect walks, so they never show up as measurable elements.
            .overlay {
                ZStack {
                    if state.showGrid { DebugGrid() }
                    if state.showSafeArea { SafeAreaOverlay() }
                    if state.showRuler { TapeMeasure() }
                    if state.showInspect { InspectHighlight() }
                }
                .ignoresSafeArea()
                .accessibilityHidden(true)
            }
            // A short key explaining the units / readouts.
            .overlay(alignment: .top) {
                if state.showLegend && state.anyToolOn { LegendOverlay().accessibilityHidden(true) }
            }
            // The entry point — hideable via the panel, brought back by a shake.
            .overlay(alignment: .bottomTrailing) {
                if !state.buttonHidden { FloatingButton().accessibilityHidden(true) }
            }
            .sheet(isPresented: $state.panelOpen) {
                ControlPanel()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
    }
}

// MARK: - Floating Button

private struct FloatingButton: View {
    @ObservedObject private var state = UIDebugState.shared
    @State private var anchor: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        Image(systemName: "ruler.fill")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 52, height: 52)
            .background(
                Circle().fill(state.anyToolOn ? Color.accentColor : Color.black.opacity(0.75))
            )
            .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
            .shadow(radius: 4, y: 2)
            .offset(x: anchor.width + drag.width, y: anchor.height + drag.height)
            .padding(20)
            .gesture(
                DragGesture()
                    .updating($drag) { value, st, _ in st = value.translation }
                    .onEnded { value in
                        anchor.width += value.translation.width
                        anchor.height += value.translation.height
                    }
            )
            .onTapGesture { state.panelOpen = true }
            .accessibilityLabel("Open UI Debug Kit")
    }
}

// MARK: - Control Panel

private struct ControlPanel: View {
    @ObservedObject private var state = UIDebugState.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Tools") {
                    Toggle(isOn: $state.showRuler) {
                        Label("Tape measure", systemImage: "ruler")
                    }
                    Toggle(isOn: $state.showInspect) {
                        Label("Inspect (touch any element)", systemImage: "hand.tap")
                    }
                    Toggle(isOn: $state.showGrid) {
                        Label("Grid overlay", systemImage: "grid")
                    }
                    Toggle(isOn: $state.showSafeArea) {
                        Label("Safe area", systemImage: "rectangle.inset.filled")
                    }
                    Toggle(isOn: $state.showLegend) {
                        Label("Legend (what the numbers mean)", systemImage: "text.bubble")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        state.buttonHidden = true
                        dismiss()
                    } label: {
                        Label("Hide floating button", systemImage: "eye.slash")
                    }
                } header: {
                    Text("Floating button")
                } footer: {
                    Text("Hides the 📏 button for clean screenshots. Shake the device to bring it back (Simulator: Device ▸ Shake, or ⌃⌘Z). Relaunching the app also restores it.")
                }

                Section("Grid") {
                    Stepper(value: $state.gridSpacing, in: 2...64, step: 2) {
                        HStack {
                            Text("Spacing")
                            Spacer()
                            Text("\(Int(state.gridSpacing)) pt").foregroundStyle(.secondary)
                        }
                    }
                    Stepper(value: $state.majorEvery, in: 2...12) {
                        HStack {
                            Text("Major line every")
                            Spacer()
                            Text("\(state.majorEvery)").foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Snap measure to grid", isOn: $state.snapToGrid)
                }

                Section {
                    Toggle(isOn: $state.checkGrid) {
                        Label("Flag off-grid spacing", systemImage: "ruler")
                    }
                    Stepper(value: $state.gridBaseUnit, in: 2...32, step: 1) {
                        HStack {
                            Text("Base unit")
                            Spacer()
                            Text("\(Int(state.gridBaseUnit)) pt").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Spacing check")
                } footer: {
                    Text("In Inspect mode, gaps that aren't a multiple of the base unit are shown in red (with the nearest on-grid value), on-grid gaps in green.")
                }

                Section("Safe area insets") {
                    insetRow("Top", state.safeInsets.top)
                    insetRow("Bottom", state.safeInsets.bottom)
                    insetRow("Leading", state.safeInsets.leading)
                    insetRow("Trailing", state.safeInsets.trailing)
                }

                Section("How to use") {
                    bullet("Inspect", "Drag a finger to size one element. Tap an element then tap a second to measure the exact gap between them; tap empty space to reset.")
                    bullet("Tape measure", "Drag the two circles to the edges you care about. Read distance, dx (horizontal) and dy (vertical) in points.")
                    bullet("Move me", "Drag the floating 📏 button anywhere it gets in the way.")
                }
            }
            .navigationTitle("UI Debug Kit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func insetRow(_ name: String, _ value: CGFloat) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(fmt(value) + " pt").foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func bullet(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Tape Measure

/// Two draggable handles. Shows straight-line distance plus the horizontal
/// and vertical gap, drawn as an L so it's obvious which is which.
private struct TapeMeasure: View {
    @ObservedObject private var state = UIDebugState.shared
    @State private var a = CGPoint(x: 80, y: 220)
    @State private var b = CGPoint(x: 300, y: 460)
    @State private var didInit = false

    private var corner: CGPoint { CGPoint(x: b.x, y: a.y) }
    private var dx: CGFloat { abs(b.x - a.x) }
    private var dy: CGFloat { abs(b.y - a.y) }
    private var dist: CGFloat { hypot(b.x - a.x, b.y - a.y) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Horizontal leg (orange) + vertical leg (green) forming an L.
                Path { p in p.move(to: a); p.addLine(to: corner) }
                    .stroke(Color.orange, lineWidth: 1)
                Path { p in p.move(to: corner); p.addLine(to: b) }
                    .stroke(Color.green, lineWidth: 1)
                // Direct line (blue dashed).
                Path { p in p.move(to: a); p.addLine(to: b) }
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))

                // Leg labels
                if dx >= 1 {
                    pill(fmt(dx), color: .orange)
                        .position(x: (a.x + b.x) / 2, y: a.y - 12)
                }
                if dy >= 1 {
                    pill(fmt(dy), color: .green)
                        .position(x: b.x + 22, y: (a.y + b.y) / 2)
                }
                // Distance label at the midpoint
                pill("⟷ " + fmt(dist) + " pt", color: .blue)
                    .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 + 14)
            }
            .allowsHitTesting(false)
            // Handles capture touches; everything above passes through.
            .overlay { handle($a, color: .blue) }
            .overlay { handle($b, color: .green) }
            .onAppear {
                guard !didInit else { return }
                didInit = true
                a = CGPoint(x: geo.size.width * 0.22, y: geo.size.height * 0.32)
                b = CGPoint(x: geo.size.width * 0.72, y: geo.size.height * 0.60)
            }
        }
    }

    private func handle(_ point: Binding<CGPoint>, color: Color) -> some View {
        ZStack {
            Circle().fill(color.opacity(0.25))
            Circle().stroke(color, lineWidth: 2)
            Circle().fill(color).frame(width: 5, height: 5) // center dot
        }
        .frame(width: 30, height: 30)
        .contentShape(Circle())
        .position(point.wrappedValue)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    var loc = value.location
                    if state.snapToGrid {
                        let g = state.gridSpacing
                        loc.x = (loc.x / g).rounded() * g
                        loc.y = (loc.y / g).rounded() * g
                    }
                    point.wrappedValue = loc
                }
        )
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold)).monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule().fill(color))
            .fixedSize()
    }
}

// MARK: - Grid

private struct DebugGrid: View {
    @ObservedObject private var state = UIDebugState.shared

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let minor = state.gridSpacing
            let major = minor * CGFloat(max(1, state.majorEvery))
            ZStack {
                lines(in: size, step: minor, lineWidth: 0.5, color: .red.opacity(0.18))
                lines(in: size, step: major, lineWidth: 1, color: .red.opacity(0.45))
            }
        }
        .allowsHitTesting(false)
    }

    private func lines(in size: CGSize, step: CGFloat, lineWidth: CGFloat, color: Color) -> some View {
        Path { p in
            guard step > 0 else { return }
            var x: CGFloat = 0
            while x <= size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y: CGFloat = 0
            while y <= size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += step }
        }
        .stroke(color, lineWidth: lineWidth)
    }
}

// MARK: - Safe Area

private struct SafeAreaOverlay: View {
    @ObservedObject private var state = UIDebugState.shared

    var body: some View {
        GeometryReader { geo in
            let i = state.safeInsets
            Rectangle()
                .stroke(Color.purple, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .padding(EdgeInsets(top: i.top, leading: i.leading, bottom: i.bottom, trailing: i.trailing))
                .overlay(alignment: .top) {
                    pill("top \(fmt(i.top))").padding(.top, max(i.top - 18, 2))
                }
                .overlay(alignment: .bottom) {
                    pill("bottom \(fmt(i.bottom))").padding(.bottom, max(i.bottom - 18, 2))
                }
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold)).monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.purple))
    }
}

// MARK: - Legend

/// A small key that explains the units and what each readout means, so the
/// numbers on screen are never ambiguous.
private struct LegendOverlay: View {
    @ObservedObject private var state = UIDebugState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if state.showGrid {
                row(.red, "Grid",
                    "1 small square = \(Int(state.gridSpacing)) pt · bold line every \(Int(state.gridSpacing) * state.majorEvery) pt")
            }
            if state.showRuler {
                row(.blue, "Tape measure",
                    "⟷ = straight distance · dx = horizontal gap · dy = vertical gap")
            }
            if state.showInspect {
                row(.pink, "Inspect",
                    state.pinnedA == nil
                    ? "Tap an element to see gaps to its neighbors. Tap a second element to measure between the two. Drag = size."
                    : (state.pinnedB == nil
                       ? "Gaps to neighbors shown. Tap a second element to measure A↔B, or empty space to reset."
                       : "Gap between the two shown. Tap another element to re-measure, or empty space to reset."))
                if state.checkGrid {
                    row(.green, "Spacing check",
                        "green = on the \(Int(state.gridBaseUnit)) pt grid · red = off-grid (→ shows the nearest on-grid value).")
                }
            }
            Text("All values are in pt (points) — the same unit you write in .padding() / .frame(). 1 pt ≈ 2–3 px.")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.15)))
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .allowsHitTesting(false)
    }

    private func row(_ color: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8).padding(.top, 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                Text(text).font(.system(size: 10)).foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Inspect Highlight

/// Renders Inspect mode:
///  • drag a finger  → live size of the element under it (pink).
///  • tap an element  → pin A (blue); tap another → pin B (green) and draw the
///    exact gap between their edges with dimension lines. Tap empty space resets.
/// Coordinates come from the accessibility hit-test in window space, which lines
/// up with SwiftUI's global coordinate space for a full-screen app.
private struct InspectHighlight: View {
    @ObservedObject private var state = UIDebugState.shared

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                // Neighbor gaps: shown around A until a second element is tapped.
                if let a = state.pinnedA, state.pinnedB == nil {
                    ForEach(Array(state.neighbors.enumerated()), id: \.offset) { _, n in
                        ZStack(alignment: .topLeading) {
                            neighborOutline(n)
                            gapLines(a, n)
                        }
                    }
                }
                if let a = state.pinnedA {
                    outline(a, .blue)
                    // In neighbor-overview mode the gap labels are the focus, so
                    // hide A's size badge to avoid colliding with them.
                    if state.pinnedB != nil || state.neighbors.isEmpty {
                        badge(a, label(state.pinnedAName, a), .blue, above: true)
                    }
                }
                if let b = state.pinnedB {
                    outline(b, .green)
                    badge(b, label(state.pinnedBName, b), .green, above: false)
                }
                if let a = state.pinnedA, let b = state.pinnedB {
                    gapLines(a, b)                       // focused A↔B measurement
                } else if state.pinnedA == nil,
                          let r = state.inspectRect, r.width > 0, r.height > 0 {
                    outline(r, .pink)                    // live hover (drag = size)
                    badge(r, label(state.inspectName, r), .pink, above: true)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: pieces

    private func outline(_ r: CGRect, _ color: Color) -> some View {
        ZStack {
            Rectangle().fill(color.opacity(0.16))
            Rectangle().stroke(color, lineWidth: 1.5)
        }
        .frame(width: r.width, height: r.height)
        .position(x: r.midX, y: r.midY)
    }

    private func neighborOutline(_ r: CGRect) -> some View {
        Rectangle()
            .stroke(Color.gray.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
    }

    private func badge(_ r: CGRect, _ text: String, _ color: Color, above: Bool) -> some View {
        pill(text, color)
            .position(x: r.midX, y: above ? max(r.minY - 12, 14) : r.maxY + 12)
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold)).monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule().fill(color))
            .fixedSize()
    }

    private func label(_ name: String, _ r: CGRect) -> String {
        let prefix = name.isEmpty ? "" : name + " · "
        return "\(prefix)\(fmt(r.width)) × \(fmt(r.height)) pt"
    }

    // MARK: gap dimension lines

    @ViewBuilder private func gapLines(_ a: CGRect, _ b: CGRect) -> some View {
        if let seg = verticalGap(a, b) { dimension(seg.0, seg.1, seg.2, horizontal: false) }
        if let seg = horizontalGap(a, b) { dimension(seg.0, seg.1, seg.2, horizontal: true) }
    }

    private func verticalGap(_ a: CGRect, _ b: CGRect) -> (CGPoint, CGPoint, CGFloat)? {
        let x = overlapMid(a.minX, a.maxX, b.minX, b.maxX, fallback: (a.midX + b.midX) / 2)
        if b.minY > a.maxY { return (CGPoint(x: x, y: a.maxY), CGPoint(x: x, y: b.minY), b.minY - a.maxY) }
        if a.minY > b.maxY { return (CGPoint(x: x, y: b.maxY), CGPoint(x: x, y: a.minY), a.minY - b.maxY) }
        return nil
    }

    private func horizontalGap(_ a: CGRect, _ b: CGRect) -> (CGPoint, CGPoint, CGFloat)? {
        let y = overlapMid(a.minY, a.maxY, b.minY, b.maxY, fallback: (a.midY + b.midY) / 2)
        if b.minX > a.maxX { return (CGPoint(x: a.maxX, y: y), CGPoint(x: b.minX, y: y), b.minX - a.maxX) }
        if a.minX > b.maxX { return (CGPoint(x: b.maxX, y: y), CGPoint(x: a.minX, y: y), a.minX - b.maxX) }
        return nil
    }

    private func overlapMid(_ lo1: CGFloat, _ hi1: CGFloat, _ lo2: CGFloat, _ hi2: CGFloat, fallback: CGFloat) -> CGFloat {
        let lo = max(lo1, lo2), hi = min(hi1, hi2)
        return hi > lo ? (lo + hi) / 2 : fallback
    }

    private func dimension(_ p1: CGPoint, _ p2: CGPoint, _ value: CGFloat, horizontal: Bool) -> some View {
        let cap: CGFloat = 6
        // Color & label reflect the off-grid check.
        let status = state.gridStatus(value)
        let onGrid = !state.checkGrid || status.onGrid
        let color: Color = !state.checkGrid ? .orange : (status.onGrid ? .green : .red)
        let text = (state.checkGrid && !status.onGrid)
            ? "\(fmt(value)) pt → \(fmt(status.nearest))"   // suggest the on-grid value
            : "\(fmt(value)) pt"
        return ZStack(alignment: .topLeading) {
            Path { p in
                p.move(to: p1); p.addLine(to: p2)
                if horizontal {
                    p.move(to: CGPoint(x: p1.x, y: p1.y - cap)); p.addLine(to: CGPoint(x: p1.x, y: p1.y + cap))
                    p.move(to: CGPoint(x: p2.x, y: p2.y - cap)); p.addLine(to: CGPoint(x: p2.x, y: p2.y + cap))
                } else {
                    p.move(to: CGPoint(x: p1.x - cap, y: p1.y)); p.addLine(to: CGPoint(x: p1.x + cap, y: p1.y))
                    p.move(to: CGPoint(x: p2.x - cap, y: p2.y)); p.addLine(to: CGPoint(x: p2.x + cap, y: p2.y))
                }
            }
            .stroke(color, lineWidth: 1.5)

            HStack(spacing: 3) {
                if state.checkGrid { Image(systemName: onGrid ? "checkmark" : "exclamationmark.triangle.fill") }
                Text(text)
            }
            .font(.caption2.weight(.bold)).monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule().fill(color))
            .fixedSize()
            .position(x: (p1.x + p2.x) / 2 + (horizontal ? 0 : 26),
                      y: (p1.y + p2.y) / 2 + (horizontal ? -12 : 0))
        }
    }
}

// MARK: - Shake To Summon

#if canImport(UIKit)
/// Invisible helper that calls `action` when the device is shaken. It only
/// listens for shakes while `isActive` is true (i.e. while the floating button
/// is hidden), so it never competes with text fields the rest of the time.
private struct ShakeToSummon: UIViewControllerRepresentable {
    var isActive: Bool
    var action: () -> Void

    func makeUIViewController(context: Context) -> ShakeViewController {
        let vc = ShakeViewController()
        vc.onShake = action
        vc.wantsShakeDetection = isActive
        return vc
    }

    func updateUIViewController(_ vc: ShakeViewController, context: Context) {
        vc.onShake = action
        vc.wantsShakeDetection = isActive
    }

    final class ShakeViewController: UIViewController {
        var onShake: () -> Void = {}
        var wantsShakeDetection = false { didSet { syncResponder() } }

        override var canBecomeFirstResponder: Bool { true }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            syncResponder()
        }

        private func syncResponder() {
            guard isViewLoaded, view.window != nil else { return }
            if wantsShakeDetection {
                if !isFirstResponder { becomeFirstResponder() }
            } else if isFirstResponder {
                resignFirstResponder()
            }
        }

        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            if motion == .motionShake { onShake() }
            super.motionEnded(motion, with: event)
        }
    }
}
#else
/// Non-UIKit fallback (e.g. macOS): shake isn't available; relaunching the
/// app restores the button instead.
private struct ShakeToSummon: View {
    var isActive: Bool
    var action: () -> Void
    var body: some View { Color.clear.frame(width: 0, height: 0) }
}
#endif

// MARK: - Inspector (touch any element)

#if canImport(UIKit)
/// Installs a gesture recognizer on the window that reports the deepest UIKit
/// view under the finger while Inspect mode is active. Because SwiftUI renders
/// into a UIKit layer tree, this lets us measure components without annotating
/// them — accurate for real views (controls, scroll views, images, rows) and
/// approximate for content SwiftUI draws into a shared layer (plain text/shapes).
private struct InspectorInstaller: UIViewRepresentable {
    var isActive: Bool

    func makeUIView(context: Context) -> AnchorView {
        let v = AnchorView()
        v.isUserInteractionEnabled = false
        v.coordinator = context.coordinator
        return v
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        context.coordinator.update(isActive: isActive, anchor: uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Zero-interaction view used only to reach the host window.
    final class AnchorView: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.windowDidChange(window)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var window: UIWindow?
        private var recognizer: UILongPressGestureRecognizer?
        private var wantsActive = false
        private var touchStart: CGPoint = .zero
        private var didDrag = false

        func update(isActive: Bool, anchor: AnchorView) {
            wantsActive = isActive
            sync(window: anchor.window)
        }

        func windowDidChange(_ window: UIWindow?) { sync(window: window) }

        private func sync(window: UIWindow?) {
            if wantsActive, let window {
                UIDebugInspector.enableAutomation()
                if recognizer == nil || self.window !== window {
                    teardown()
                    let r = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
                    r.minimumPressDuration = 0
                    r.allowableMovement = .greatestFiniteMagnitude
                    r.cancelsTouchesInView = false   // let the app keep working
                    r.delegate = self
                    window.addGestureRecognizer(r)
                    recognizer = r
                    self.window = window
                }
            } else {
                teardown()
                UIDebugState.shared.inspectRect = nil
                UIDebugState.shared.clearPins()
            }
        }

        private func teardown() {
            if let r = recognizer { r.view?.removeGestureRecognizer(r) }
            recognizer = nil
            window = nil
        }

        @objc private func handle(_ g: UILongPressGestureRecognizer) {
            guard let window else { return }
            let point = g.location(in: window)
            switch g.state {
            case .began:
                touchStart = point
                didDrag = false
                report(at: point, in: window)
            case .changed:
                if hypot(point.x - touchStart.x, point.y - touchStart.y) > 10 { didDrag = true }
                report(at: point, in: window)
            case .ended:
                if !didDrag { handleTap(at: point, in: window) }  // a tap pins for gap measurement
            default:
                break
            }
        }

        /// Drag = live size readout of the element under the finger.
        private func report(at point: CGPoint, in window: UIWindow) {
            if let hit = UIDebugInspector.hit(at: point, in: window) {
                UIDebugState.shared.inspectRect = hit.rect
                UIDebugState.shared.inspectName = hit.name
            }
        }

        /// Tap = pin element A, then B (to measure the gap), then reset.
        private func handleTap(at point: CGPoint, in window: UIWindow) {
            let s = UIDebugState.shared
            guard let hit = UIDebugInspector.hit(at: point, in: window) else { s.clearPins(); return }
            // Tapping (almost) the whole screen = empty space → reset.
            let screenArea = window.bounds.width * window.bounds.height
            if hit.rect.width * hit.rect.height > 0.8 * screenArea { s.clearPins(); return }

            if s.pinnedA == nil {
                s.pinnedA = hit.rect; s.pinnedAName = hit.name
                s.pinnedB = nil; s.pinnedBName = ""
                s.neighbors = UIDebugInspector.neighbors(of: hit.rect, in: window)
            } else if s.pinnedB == nil {
                if hit.rect == s.pinnedA { return }            // same element — ignore
                s.pinnedB = hit.rect; s.pinnedBName = hit.name
                s.neighbors = []                               // focused A↔B measurement
            } else {
                s.pinnedA = hit.rect; s.pinnedAName = hit.name // start a new measurement
                s.pinnedB = nil; s.pinnedBName = ""
                s.neighbors = UIDebugInspector.neighbors(of: hit.rect, in: window)
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// Finds the smallest on-screen element under a point by walking SwiftUI's
/// accessibility tree (every Text / Button / Image / row exposes an
/// `accessibilityFrame`). This is what makes Inspect mode work for SwiftUI,
/// where the whole view tree is flattened into a single UIKit hosting view.
enum UIDebugInspector {
    static func hit(at windowPoint: CGPoint, in window: UIWindow) -> (rect: CGRect, name: String)? {
        let screenSpace = window.screen.coordinateSpace
        let screenPoint = window.coordinateSpace.convert(windowPoint, to: screenSpace)
        let root: NSObject = window.rootViewController?.view ?? window
        var best: (rect: CGRect, name: String, area: CGFloat)?
        search(root, point: screenPoint, best: &best)
        guard let best else { return nil }
        let rectInWindow = window.coordinateSpace.convert(best.rect, from: screenSpace)
        return (rectInWindow, best.name)
    }

    /// SwiftUI only builds its accessibility tree (which carries the element
    /// frames we read) when an assistive service is active. This flips the
    /// in-process accessibility switch so the tree exists for us to walk.
    ///
    /// NOTE: `_AXSSetAutomationEnabled` is a private symbol. The entire kit is
    /// inside `#if DEBUG`, so this is compiled out of release builds and never
    /// reaches the App Store — but Inspect mode therefore only works in DEBUG.
    private static var automationEnabled = false
    static func enableAutomation() {
        guard !automationEnabled else { return }
        automationEnabled = true
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let sym = dlsym(handle, "_AXSSetAutomationEnabled") else { return }
        typealias Fn = @convention(c) (Bool) -> Void
        unsafeBitCast(sym, to: Fn.self)(true)
    }

    /// Nearest neighbor element of `target` in each direction (up/down/left/right),
    /// used to show all surrounding gaps at once when one element is pinned.
    static func neighbors(of target: CGRect, in window: UIWindow) -> [CGRect] {
        let screenArea = window.bounds.width * window.bounds.height
        let candidates = allLeafFrames(in: window).filter { c in
            c != target
            && c.width * c.height < 0.8 * screenArea          // not the full-screen container
            && !c.intersects(target.insetBy(dx: 1, dy: 1))    // not self / parent / child
        }
        var result: [CGRect] = []
        // below & above must share horizontal extent; left & right share vertical.
        if let below = candidates
            .filter({ $0.minY >= target.maxY - 0.5 && overlaps($0.minX, $0.maxX, target.minX, target.maxX) })
            .min(by: { $0.minY < $1.minY }) { result.append(below) }
        if let above = candidates
            .filter({ $0.maxY <= target.minY + 0.5 && overlaps($0.minX, $0.maxX, target.minX, target.maxX) })
            .max(by: { $0.maxY < $1.maxY }) { result.append(above) }
        if let right = candidates
            .filter({ $0.minX >= target.maxX - 0.5 && overlaps($0.minY, $0.maxY, target.minY, target.maxY) })
            .min(by: { $0.minX < $1.minX }) { result.append(right) }
        if let left = candidates
            .filter({ $0.maxX <= target.minX + 0.5 && overlaps($0.minY, $0.maxY, target.minY, target.maxY) })
            .max(by: { $0.maxX < $1.maxX }) { result.append(left) }
        return result
    }

    private static func overlaps(_ lo1: CGFloat, _ hi1: CGFloat, _ lo2: CGFloat, _ hi2: CGFloat) -> Bool {
        max(lo1, lo2) < min(hi1, hi2)
    }

    /// Every leaf accessibility frame in the app, in window coordinates.
    private static func allLeafFrames(in window: UIWindow) -> [CGRect] {
        let screenSpace = window.screen.coordinateSpace
        let root: NSObject = window.rootViewController?.view ?? window
        var leaves: [CGRect] = []
        collectLeaves(root, into: &leaves)
        return leaves.map { window.coordinateSpace.convert($0, from: screenSpace) }
    }

    private static func collectLeaves(_ element: NSObject, into leaves: inout [CGRect]) {
        let children = childrenOf(element)
        if children.isEmpty {
            let f = element.accessibilityFrame
            if !f.isEmpty { leaves.append(f) }
        } else {
            for child in children { collectLeaves(child, into: &leaves) }
        }
    }

    private static func search(_ element: NSObject, point: CGPoint,
                               best: inout (rect: CGRect, name: String, area: CGFloat)?) {
        let children = childrenOf(element)
        if children.isEmpty {
            let f = element.accessibilityFrame
            guard !f.isEmpty, f.contains(point) else { return }
            let area = f.width * f.height
            if best == nil || area < best!.area {
                best = (f, name(for: element), area)
            }
        } else {
            for child in children { search(child, point: point, best: &best) }
        }
    }

    private static func childrenOf(_ element: NSObject) -> [NSObject] {
        if let els = element.accessibilityElements as? [NSObject], !els.isEmpty { return els }
        let count = element.accessibilityElementCount()
        guard count > 0, count != NSNotFound else { return [] }
        return (0..<count).compactMap { element.accessibilityElement(at: $0) as? NSObject }
    }

    private static func name(for element: NSObject) -> String {
        let t = element.accessibilityTraits
        if t.contains(.button) { return "Button" }
        if t.contains(.image) { return "Image" }
        if t.contains(.header) { return "Header" }
        if t.contains(.link) { return "Link" }
        if let label = element.accessibilityLabel, !label.isEmpty {
            return label.count > 18 ? String(label.prefix(18)) + "…" : label
        }
        return "Element"
    }
}
#else
private struct InspectorInstaller: View {
    var isActive: Bool
    var body: some View { Color.clear.frame(width: 0, height: 0) }
}
#endif

// MARK: - Preference Keys

private struct InsetsKey: PreferenceKey {
    static let defaultValue = EdgeInsets()
    static func reduce(value: inout EdgeInsets, nextValue: () -> EdgeInsets) { value = nextValue() }
}

// MARK: - Formatting

/// Compact point formatting: whole numbers stay whole, otherwise 1 decimal.
private func fmt(_ v: CGFloat) -> String {
    let r = (v * 10).rounded() / 10
    return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
}

#endif
