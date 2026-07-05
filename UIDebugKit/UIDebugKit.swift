//
//  UIDebugKit.swift
//  A drop-in, zero-dependency visual debugging overlay for SwiftUI.
//
//  WHAT IT GIVES YOU (no need to read code to measure your UI):
//    • A floating 📏 button (DEBUG builds only) that opens a control panel.
//    • Inspect       – tap any component to see its size AND the spacing on all
//                      4 sides (to its neighbour, or to the screen edge). Tap a
//                      second component to measure the gap between the two.
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

// MARK: - Models

/// One measured gap on a side of the inspected element — to the nearest
/// neighbouring element, or (when there is none) to the safe-area / screen edge.
struct EdgeGap: Identifiable {
    let id = UUID()
    let from: CGPoint       // point on the selected element's edge
    let to: CGPoint         // point on the boundary it was measured to
    let value: CGFloat      // distance in points
    let horizontal: Bool    // true = left/right gap, false = top/bottom gap
    let toScreen: Bool      // measured to the screen / safe-area edge (no neighbour)
    let targetRect: CGRect? // the neighbour it measured to, if any
}

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
    // The spacing on each of the 4 sides of pinned A — to the nearest element,
    // or the safe-area / screen edge when there is no neighbour. Shown
    // automatically while only A is selected.
    @Published var edgeGaps: [EdgeGap] = []
    // Current safe-area rectangle in window coordinates (target for edge gaps).
    @Published var safeRectInWindow: CGRect = .zero

    // Nesting: re-tapping the same spot steps A through the elements stacked
    // under that point (smallest → parent → … → wrap).
    var selectionAnchor: CGPoint? = nil
    var selectionStack: [(rect: CGRect, name: String)] = []
    var selectionIndex = 0

    func clearPins() {
        pinnedA = nil; pinnedAName = ""
        pinnedB = nil; pinnedBName = ""
        edgeGaps = []
        selectionAnchor = nil; selectionStack = []; selectionIndex = 0
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
            // While Inspect is on, freeze the app underneath: a tap should
            // measure, not flip a toggle / push a button / scroll the screen.
            // Our own overlays (floating button, panel, tape measure) are added
            // after this and stay live; the window-level inspector still reads
            // the touch location, so selection keeps working.
            .allowsHitTesting(!state.showInspect)
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
                    bullet("Inspect", "Tap any element to see its size and the spacing on all 4 sides — to its neighbour, or to the screen edge when nothing is beside it. Tap a second element to measure the exact gap between the two. Tap the same element again to grow the selection to its parent box (handy when a tap lands on the text instead of the card). Tap empty space to reset.")
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
                    ? "Tap any element → its size + the spacing on all 4 sides (to a neighbour, or the screen edge). Tap a 2nd element to measure the gap between them."
                    : (state.pinnedB == nil
                       ? (state.selectionStack.count > 1
                          ? "Selected \(state.pinnedAName) — tap the SAME spot again to grow to its parent box (\(state.selectionIndex + 1)/\(state.selectionStack.count)). Tap another element to measure A↔B, empty space to reset."
                          : "Size + 4-side spacing shown. Tap another element to measure A↔B, or empty space to reset.")
                       : "Gap between A and B shown. Tap another element to re-measure, or empty space to reset."))
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
                // Live preview: a thin outline of whatever is under the finger,
                // with no numbers, so it's obvious what a release will select.
                if let p = state.inspectRect, p.width > 0, p.height > 0 {
                    previewOutline(p)
                }

                // A selected, no B yet → its size + the gap on all 4 sides.
                if let a = state.pinnedA, state.pinnedB == nil {
                    ForEach(state.edgeGaps) { g in
                        if let t = g.targetRect { neighborOutline(t) }
                        dimension(g.from, g.to, g.value, horizontal: g.horizontal)
                    }
                    outline(a, .blue)
                    // Size sits in the centre so it never collides with the four
                    // edge-gap labels hugging the sides.
                    pill(label(state.pinnedAName, a), .blue)
                        .position(x: a.midX, y: a.midY)
                }

                // A and B selected → the focused gap between the two.
                if let a = state.pinnedA, let b = state.pinnedB {
                    outline(a, .blue)
                    badge(a, label(state.pinnedAName, a), .blue, above: true)
                    outline(b, .green)
                    badge(b, label(state.pinnedBName, b), .green, above: false)
                    gapLines(a, b)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: pieces

    /// Thin dashed outline of the element under the finger (preview, no numbers).
    private func previewOutline(_ r: CGRect) -> some View {
        Rectangle()
            .stroke(Color.pink.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
    }

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
            case .began, .changed:
                preview(at: point, in: window)            // thin outline follows the finger
            case .ended, .cancelled:
                UIDebugState.shared.inspectRect = nil     // drop the preview…
                handleTap(at: point, in: window)          // …release = select / measure
            default:
                break
            }
        }

        /// While the finger is down, outline whatever is under it (no numbers).
        private func preview(at point: CGPoint, in window: UIWindow) {
            UIDebugState.shared.inspectRect = UIDebugInspector.hit(at: point, in: window)?.rect
        }

        /// Tap = pin A, then B (gap), then reset. Re-tapping the same spot while
        /// choosing A steps up through the nested elements stacked under it.
        private func handleTap(at point: CGPoint, in window: UIWindow) {
            let s = UIDebugState.shared

            // Re-tap (almost) the same spot while only A is selected → grow the
            // selection to its parent box (smallest → parent → … → wrap). This is
            // how you grab the container instead of the text sitting inside it.
            if s.pinnedA != nil, s.pinnedB == nil,
               let anchor = s.selectionAnchor,
               hypot(point.x - anchor.x, point.y - anchor.y) < 22,
               s.selectionStack.count > 1 {
                s.selectionIndex = (s.selectionIndex + 1) % s.selectionStack.count
                let sel = s.selectionStack[s.selectionIndex]
                s.pinnedA = sel.rect; s.pinnedAName = sel.name
                s.edgeGaps = UIDebugInspector.edges(of: sel.rect, in: window)
                return
            }

            let stack = UIDebugInspector.stack(at: point, in: window)
            guard let smallest = stack.first else { s.clearPins(); return }  // empty space → reset

            func selectAsA() {
                s.selectionAnchor = point; s.selectionStack = stack; s.selectionIndex = 0
                s.pinnedA = smallest.rect; s.pinnedAName = smallest.name
                s.pinnedB = nil; s.pinnedBName = ""
                s.edgeGaps = UIDebugInspector.edges(of: smallest.rect, in: window)
            }

            if s.pinnedA == nil {
                selectAsA()                                    // 1st tap → inspect A
            } else if s.pinnedB == nil {
                if smallest.rect == s.pinnedA { return }       // same element — ignore
                s.pinnedB = smallest.rect; s.pinnedBName = smallest.name
                s.edgeGaps = []                                // focus the A↔B gap
            } else {
                selectAsA()                                    // 3rd tap → start over
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

    /// Every accessibility element stacked under a point — leaves *and* their
    /// container groups — sorted smallest → largest. Lets the caller step from
    /// a child element up through its parents. (Atomic controls like Button
    /// expose only one element, so there is nothing smaller to step into.)
    static func stack(at windowPoint: CGPoint, in window: UIWindow) -> [(rect: CGRect, name: String)] {
        let screenSpace = window.screen.coordinateSpace
        let screenPoint = window.coordinateSpace.convert(windowPoint, to: screenSpace)
        let root: NSObject = window.rootViewController?.view ?? window
        let screenArea = window.bounds.width * window.bounds.height
        var hits: [(rect: CGRect, name: String)] = []
        func visit(_ e: NSObject) {
            let f = e.accessibilityFrame
            if !f.isEmpty, f.contains(screenPoint), f.width * f.height < 0.95 * screenArea {
                hits.append((window.coordinateSpace.convert(f, from: screenSpace), name(for: e)))
            }
            childrenOf(e).forEach(visit)
        }
        visit(root)
        let sorted = hits.sorted { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
        var result: [(rect: CGRect, name: String)] = []
        for item in sorted where !result.contains(where: { $0.rect == item.rect }) { result.append(item) }
        return result
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

    /// The spacing on each of the 4 sides of `a` — to the nearest neighbouring
    /// element, or (when nothing is on that side) to the safe-area / screen edge.
    /// Measuring to the edge is what makes "how far from the screen edge?" work,
    /// and including container frames (not just text leaves) lets a box's edge
    /// win over the text inside it.
    static func edges(of a: CGRect, in window: UIWindow) -> [EdgeGap] {
        let safe = window.bounds.inset(by: window.safeAreaInsets)
        UIDebugState.shared.safeRectInWindow = safe

        let candidates = allFrames(in: window).filter { c in
            !approxEqual(c, a) && !c.intersects(a.insetBy(dx: 1, dy: 1))  // not self / parent / child
        }
        var gaps: [EdgeGap] = []

        // TOP — nearest element above (sharing horizontal extent) vs the safe top.
        let above = candidates
            .filter { $0.maxY <= a.minY + 0.5 && overlaps($0.minX, $0.maxX, a.minX, a.maxX) }
            .max(by: { $0.maxY < $1.maxY })
        if let g = pickEdge(neighbor: above.map { a.minY - $0.maxY }, edge: a.minY - safe.minY) {
            let x = g.fromElement ? overlapMid(a.minX, a.maxX, above!.minX, above!.maxX, fallback: a.midX)
                                  : clamp(a.midX, safe.minX + 4, safe.maxX - 4)
            gaps.append(EdgeGap(from: CGPoint(x: x, y: a.minY),
                                to: CGPoint(x: x, y: g.fromElement ? above!.maxY : safe.minY),
                                value: g.value, horizontal: false,
                                toScreen: !g.fromElement, targetRect: g.fromElement ? above : nil))
        }

        // BOTTOM
        let below = candidates
            .filter { $0.minY >= a.maxY - 0.5 && overlaps($0.minX, $0.maxX, a.minX, a.maxX) }
            .min(by: { $0.minY < $1.minY })
        if let g = pickEdge(neighbor: below.map { $0.minY - a.maxY }, edge: safe.maxY - a.maxY) {
            let x = g.fromElement ? overlapMid(a.minX, a.maxX, below!.minX, below!.maxX, fallback: a.midX)
                                  : clamp(a.midX, safe.minX + 4, safe.maxX - 4)
            gaps.append(EdgeGap(from: CGPoint(x: x, y: a.maxY),
                                to: CGPoint(x: x, y: g.fromElement ? below!.minY : safe.maxY),
                                value: g.value, horizontal: false,
                                toScreen: !g.fromElement, targetRect: g.fromElement ? below : nil))
        }

        // LEFT
        let left = candidates
            .filter { $0.maxX <= a.minX + 0.5 && overlaps($0.minY, $0.maxY, a.minY, a.maxY) }
            .max(by: { $0.maxX < $1.maxX })
        if let g = pickEdge(neighbor: left.map { a.minX - $0.maxX }, edge: a.minX - safe.minX) {
            let y = g.fromElement ? overlapMid(a.minY, a.maxY, left!.minY, left!.maxY, fallback: a.midY)
                                  : clamp(a.midY, safe.minY + 4, safe.maxY - 4)
            gaps.append(EdgeGap(from: CGPoint(x: a.minX, y: y),
                                to: CGPoint(x: g.fromElement ? left!.maxX : safe.minX, y: y),
                                value: g.value, horizontal: true,
                                toScreen: !g.fromElement, targetRect: g.fromElement ? left : nil))
        }

        // RIGHT
        let right = candidates
            .filter { $0.minX >= a.maxX - 0.5 && overlaps($0.minY, $0.maxY, a.minY, a.maxY) }
            .min(by: { $0.minX < $1.minX })
        if let g = pickEdge(neighbor: right.map { $0.minX - a.maxX }, edge: safe.maxX - a.maxX) {
            let y = g.fromElement ? overlapMid(a.minY, a.maxY, right!.minY, right!.maxY, fallback: a.midY)
                                  : clamp(a.midY, safe.minY + 4, safe.maxY - 4)
            gaps.append(EdgeGap(from: CGPoint(x: a.maxX, y: y),
                                to: CGPoint(x: g.fromElement ? right!.minX : safe.maxX, y: y),
                                value: g.value, horizontal: true,
                                toScreen: !g.fromElement, targetRect: g.fromElement ? right : nil))
        }

        return gaps
    }

    /// Picks between the neighbour gap and the safe-area edge gap — the nearer
    /// one wins. Returns nil for non-positive / negligible gaps.
    private struct EdgePick { let value: CGFloat; let fromElement: Bool }
    private static func pickEdge(neighbor: CGFloat?, edge: CGFloat) -> EdgePick? {
        var best: EdgePick?
        if let n = neighbor, n >= -0.5 { best = EdgePick(value: max(n, 0), fromElement: true) }
        if edge >= -0.5, best == nil || edge < best!.value - 0.01 {
            best = EdgePick(value: max(edge, 0), fromElement: false)
        }
        if let b = best, b.value < 0.5 { return nil }   // ignore zero / flush edges
        return best
    }

    private static func overlaps(_ lo1: CGFloat, _ hi1: CGFloat, _ lo2: CGFloat, _ hi2: CGFloat) -> Bool {
        max(lo1, lo2) < min(hi1, hi2)
    }

    private static func overlapMid(_ lo1: CGFloat, _ hi1: CGFloat, _ lo2: CGFloat, _ hi2: CGFloat, fallback: CGFloat) -> CGFloat {
        let lo = max(lo1, lo2), hi = min(hi1, hi2)
        return hi > lo ? (lo + hi) / 2 : fallback
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        lo <= hi ? min(max(v, lo), hi) : v
    }

    private static func approxEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 &&
        abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    /// Every accessibility frame in the app (containers *and* leaves), in window
    /// coordinates. Including containers lets a box's edge win over the text
    /// inside it when picking the nearest neighbour.
    private static func allFrames(in window: UIWindow) -> [CGRect] {
        let screenSpace = window.screen.coordinateSpace
        let root: NSObject = window.rootViewController?.view ?? window
        let screenArea = window.bounds.width * window.bounds.height
        var out: [CGRect] = []
        func visit(_ e: NSObject) {
            let f = e.accessibilityFrame
            if !f.isEmpty, f.width * f.height < 0.9 * screenArea {   // drop full-screen containers
                out.append(window.coordinateSpace.convert(f, from: screenSpace))
            }
            childrenOf(e).forEach(visit)
        }
        visit(root)
        var result: [CGRect] = []
        for r in out where !result.contains(where: { approxEqual($0, r) }) { result.append(r) }
        return result
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
        var result: [NSObject] = []
        if let els = element.accessibilityElements as? [NSObject], !els.isEmpty {
            result += els
        } else {
            let count = element.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                result += (0..<count).compactMap { element.accessibilityElement(at: $0) as? NSObject }
            }
        }
        // Also descend the UIView tree: in NavigationStack / ScrollView apps the
        // content's accessibility elements live under intermediate UIViews whose
        // own `accessibilityElements` are empty. Skip our own hidden overlays.
        if let view = element as? UIView {
            for sub in view.subviews where !sub.accessibilityElementsHidden && !sub.isHidden && sub.alpha > 0.01 {
                result.append(sub)
            }
        }
        return result
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
