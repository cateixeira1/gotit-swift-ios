import SwiftUI
import UIKit

/// What a horizontal swipe on a row ends in.
enum SwipeOutcome: Equatable {
    case close, open, delete

    /// Width of the red area when the row stays open.
    static let openWidth: CGFloat = 88

    /// Past half the row the item is deleted on release (the phone tapped lightly when the finger
    /// crossed that point). A shorter swipe, or a quick flick, leaves the trash open to tap.
    static func decide(offset: CGFloat, width: CGFloat, velocity: CGFloat) -> SwipeOutcome {
        let distance = -offset
        if distance > width / 2 { return .delete }
        if distance > openWidth * 0.6 || (velocity < -400 && distance > 12) { return .open }
        return .close
    }

    static func pastHalf(offset: CGFloat, width: CGFloat) -> Bool { -offset > width / 2 }
}

/// A list row that deletes in one swipe to the left: red with a trash can follows the finger;
/// beyond half the row a light haptic says "release to delete". Releasing earlier leaves the trash
/// showing; tapping it deletes, tapping the row closes it.
struct SwipeToDeleteRow<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var resting: CGFloat = 0
    @State private var width: CGFloat = 320
    @State private var armed = false
    @State private var deleting = false
    /// The row fades out when it is let go past half (or the trash is tapped), then leaves the list.
    @State private var fading = false
    static var fadeDuration: Double { 0.2 }
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        ZStack(alignment: .trailing) {
            Button { delete() } label: {
                Image(systemName: "trash.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .scaleEffect(armed ? 1.25 : 1)
                    .frame(width: max(0, -offset), alignment: armed ? .leading : .center)
                    .padding(.leading, armed ? 22 : 0)
                    .frame(maxHeight: .infinity)
                    .background(Color.red)
            }
            .buttonStyle(.plain)
            .opacity(offset < 0 ? 1 : 0)
            .accessibilityHidden(true)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8).padding(.horizontal, 16)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .offset(x: offset)
                .overlay {
                    // While open, a tap on the row closes it instead of opening the note.
                    if resting < 0 { Color.clear.contentShape(Rectangle()).onTapGesture { settle(.close) }.offset(x: offset) }
                }
        }
        .clipped()
        .opacity(fading ? 0 : 1)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max(1, $0) }
        .gesture(HorizontalPan(onBegan: { haptic.prepare() }, onChange: { dx in
            guard !deleting else { return }
            offset = min(0, resting + dx)
            let past = SwipeOutcome.pastHalf(offset: offset, width: width)
            if past != armed {
                if past { haptic.impactOccurred(intensity: 0.6) }
                withAnimation(.snappy(duration: 0.15)) { armed = past }
            }
        }, onEnd: { dx, velocity in
            guard !deleting else { return }
            settle(SwipeOutcome.decide(offset: min(0, resting + dx), width: width, velocity: velocity))
        }))
        .accessibilityAction(named: "Apagar") { onDelete() }
    }

    private func settle(_ outcome: SwipeOutcome) {
        switch outcome {
        case .delete: delete()
        case .open: withAnimation(.snappy) { offset = -SwipeOutcome.openWidth; resting = offset; armed = false }
        case .close: withAnimation(.snappy) { offset = 0; resting = 0; armed = false }
        }
    }

    /// A quick fade where the row is (no slide, no jump back): it stays invisible until the list
    /// drops it, so it never flashes back while the note moves to the Lixeira.
    private func delete() {
        guard !deleting else { return }
        deleting = true
        withAnimation(.easeOut(duration: Self.fadeDuration)) { fading = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeDuration) {
            withAnimation(.easeOut(duration: 0.2)) { onDelete() }
            // Still here a while later (the move failed): show the row again, closed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard deleting else { return }
                offset = 0; resting = 0; armed = false; deleting = false
                withAnimation(.easeOut(duration: 0.2)) { fading = false }
            }
        }
    }
}

/// A pan that only starts for a mostly horizontal movement, so vertical scrolling of the list is
/// untouched.
struct HorizontalPan: UIGestureRecognizerRepresentable {
    var onBegan: () -> Void
    var onChange: (CGFloat) -> Void
    var onEnd: (CGFloat, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let dx = recognizer.translation(in: nil).x
        switch recognizer.state {
        case .began: onBegan(); onChange(dx)
        case .changed: onChange(dx)
        case .ended: onEnd(dx, recognizer.velocity(in: nil).x)
        case .cancelled, .failed: onEnd(0, 0)
        default: break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: nil)
            return abs(velocity.x) > abs(velocity.y) * 1.3
        }
    }
}
