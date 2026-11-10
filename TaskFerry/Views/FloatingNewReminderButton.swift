import AppKit
import SwiftUI

/// Click for a new reminder in the list on screen, or drag the button itself onto a list in the
/// sidebar, or onto a list's section, to start one there, like the Magic Plus button in Things.
///
/// The drag is an in-window gesture, not a system drag: the button lifts and follows the pointer,
/// and springs back home unless it was dropped somewhere it can start a reminder.
struct FloatingNewReminderButton: View {
    /// The button's diameter, and its distance from the window's corner.
    static let size: CGFloat = 48
    static let inset: CGFloat = 16
    /// How far the reminder list scrolls past its end, so the last row can clear the button.
    static var clearance: CGFloat { size + inset }

    let lists: [ReminderListRecord]
    let action: () -> Void
    let newReminderInList: (String) -> Void
    /// The pointer moved during a drag, in global coordinates.
    let onDragChanged: (CGPoint) -> Void
    /// The button was let go, in global coordinates. True when that started a reminder.
    let onDragEnded: (CGPoint) -> Bool
    /// The drag is over, whether it ended or was cancelled, so nothing should look targeted.
    let onDragFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var glyph = AccentGlyph.current
    /// Bumped to throw away a drag that can't finish: when the window stops being key mid-drag,
    /// its mouse-up goes elsewhere, and SwiftUI would keep the gesture going forever.
    @State private var gestureGeneration = 0
    @State private var isHovering = false
    /// How far the button has been carried, while it's dragged. Gesture state resets by itself when
    /// the drag ends or the system cancels it, so the button can't be left lifted, and it springs
    /// home as it does.
    @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.4, dampingFraction: 0.72)))
    private var carried: CGSize?
    /// Hidden for a moment after a drop, while it comes back home.
    @State private var isReturning = false
    @State private var dragEndedAt = Date.distantPast

    var body: some View {
        Button {
            // Letting go after a drag also ends the button's click; that one isn't a click.
            guard carried == nil, Date().timeIntervalSince(dragEndedAt) > 0.3 else { return }
            action()
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(RaisedPlusButtonStyle(glyph: glyph, isHovering: isHovering, isLifted: carried != nil))
        .onHover { isHovering = $0 }
        .offset(carried ?? .zero)
        // With Reduce Motion it goes straight home rather than springing there.
        .transaction(value: carried == nil) { if reduceMotion { $0.animation = nil } }
        .opacity(isReturning ? 0 : 1)
        .scaleEffect(isReturning && !reduceMotion ? 0.6 : 1)
        .simultaneousGesture(drag)
        .id(gestureGeneration)
        .help("New Reminder")
        .accessibilityLabel("New Reminder")
        .accessibilityHint("Drag onto a list in the sidebar to add the reminder there.")
        .accessibilityActions { listActions }
        .onReceive(NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)) { _ in
            glyph = AccentGlyph.current
        }
        .onChange(of: carried == nil) { _, finished in
            if finished { onDragFinished() }
        }
        .onChange(of: controlActiveState) { _, state in
            guard state != .key, carried != nil else { return }
            gestureGeneration += 1
            onDragFinished()
        }
    }

    /// One "New Reminder in <List>" action per list, for VoiceOver, which can't drag.
    private var listActions: some View {
        ForEach(lists) { list in
            Button(String(localized: "New Reminder in \(list.title)")) { newReminderInList(list.id) }
        }
    }

    private var drag: some Gesture {
        // A few points of slack, so a click with a slight wobble still clicks.
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .updating($carried) { value, carried, _ in carried = value.translation }
            .onChanged { onDragChanged($0.location) }
            .onEnded { value in
                dragEndedAt = Date()
                guard onDragEnded(value.location) else { return }
                // It became the new reminder: nothing flies back. It's hidden while the gesture
                // state takes it home, then appears there.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { isReturning = true }
                let appear: Animation = reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.8)
                withAnimation(appear.delay(0.4)) { isReturning = false }
            }
    }
}

/// How raised the + button looks. The owner picks between these; `current` is the one that ships.
struct RaisedPlusLook {
    /// How much lighter the top of the fill is than the bottom, as a mix with white.
    let gradient: Double
    /// The faint highlight along the top edge, as white's opacity; zero for none.
    let highlight: Double
    /// The resting shadow.
    let shadowRadius: CGFloat
    let shadowY: CGFloat
    let shadowOpacity: Double
    /// The tight shadow where the button meets the list.
    let contactOpacity: Double

    /// A: subtler than the default.
    static let subtle = RaisedPlusLook(gradient: 0.02, highlight: 0, shadowRadius: 5, shadowY: 1.5,
                                       shadowOpacity: 0.13, contactOpacity: 0.06)
    /// B: the default.
    static let standard = RaisedPlusLook(gradient: 0.04, highlight: 0.08, shadowRadius: 6, shadowY: 2,
                                         shadowOpacity: 0.16, contactOpacity: 0.08)
    /// C: a little stronger than the default.
    static let stronger = RaisedPlusLook(gradient: 0.07, highlight: 0.15, shadowRadius: 8, shadowY: 2.5,
                                         shadowOpacity: 0.2, contactOpacity: 0.1)

    static let current = stronger
}

/// A solid, raised button that sits just above the list, like a system control: an accent fill a
/// few percent lighter at the top and a small, soft shadow. Hover raises it a little, a press
/// pushes it down, and a drag lifts it further still.
private struct RaisedPlusButtonStyle: ButtonStyle {
    let glyph: AccentGlyph
    let isHovering: Bool
    let isLifted: Bool
    var look = RaisedPlusLook.current

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far it sits above the list: pushed down, resting, hovered, or carried, each a step
    /// from the resting shadow.
    private enum Elevation: Int {
        case pressed, resting, hovered, lifted

        var scale: CGFloat { [0.96, 1, 1.03, 1.08][rawValue] }
        var shadowScale: CGFloat { [0.5, 1, 1.4, 2.6][rawValue] }
        var opacityScale: Double { [0.8, 1, 1.15, 1.4][rawValue] }
    }

    func makeBody(configuration: Configuration) -> some View {
        let elevation: Elevation = isLifted ? .lifted
            : configuration.isPressed ? .pressed
            : isHovering ? .hovered : .resting
        // Over a dark list a shadow needs more weight to show; there's no light edge, so it lifts
        // rather than glows.
        let darkBoost = colorScheme == .dark ? 0.15 : 0
        let shadowOpacity = look.shadowOpacity * elevation.opacityScale + darkBoost
        let animation: Animation = reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.72)
        return configuration.label
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(glyph.color)
            .frame(width: FloatingNewReminderButton.size, height: FloatingNewReminderButton.size)
            .background { face }
            .overlay { edge }
            .contentShape(Circle())
            .shadow(color: .black.opacity(look.contactOpacity + darkBoost), radius: 0.5, y: 0.5)
            .shadow(color: .black.opacity(shadowOpacity),
                    radius: look.shadowRadius * elevation.shadowScale,
                    y: look.shadowY * elevation.shadowScale)
            .scaleEffect(reduceMotion ? 1 : elevation.scale)
            // Without the scale, a press still shows, as a slight dimming.
            .opacity(reduceMotion && elevation == .pressed ? 0.85 : 1)
            .animation(animation, value: elevation)
    }

    /// Solid, never glass: a translucent button reads as flat over the list, and a glass rim reads
    /// as a grey halo. So Reduce Transparency has nothing to take away.
    private var face: some View {
        let top = Color.accentColor.mix(with: .white, by: look.gradient)
        return Circle().fill(LinearGradient(colors: [top, .accentColor], startPoint: .top, endPoint: .bottom))
    }

    @ViewBuilder
    private var edge: some View {
        if look.highlight > 0, colorScheme == .light {
            Circle()
                .strokeBorder(LinearGradient(colors: [.white.opacity(look.highlight), .clear],
                                             startPoint: .top, endPoint: .center), lineWidth: 1)
                .allowsHitTesting(false)
        }
        if contrast == .increased {
            Circle()
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.8) : Color.black.opacity(0.6), lineWidth: 1.5)
                .allowsHitTesting(false)
        }
    }
}

/// White on the accent color, as on other prominent buttons, but near-black on a light one like
/// Yellow, where white would wash out.
enum AccentGlyph: Equatable {
    case light, dark

    static var current: Self {
        guard let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return .light }
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(accent.redComponent) + 0.7152 * linear(accent.greenComponent)
            + 0.0722 * linear(accent.blueComponent)
        // macOS puts white on every accent but the light ones, Yellow above all, where it washes out.
        return luminance > 0.45 ? .dark : .light
    }

    var color: Color {
        switch self {
        case .light: .white
        case .dark: Color.black.opacity(0.85)
        }
    }
}
