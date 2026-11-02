import SwiftUI

// MARK: - Payload

/// A dragged list row. A prefixed string keeps this to the built-in `String`
/// transfer type, so no new UTType or Info.plist entry is needed.
enum PaneDragPayload {
    static let prefix = "herdcats-pane:"

    static func encode(_ ref: PaneRef) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(ref) else { return prefix }
        return prefix + String(decoding: data, as: UTF8.self)
    }

    static func decode(_ string: String) -> PaneRef? {
        guard string.hasPrefix(prefix) else { return nil }
        return try? JSONDecoder().decode(PaneRef.self, from: Data(string.dropFirst(prefix.count).utf8))
    }
}

// MARK: - Drop zones

enum PaneDropZone {
    /// The half of the detail column a drop landed in.
    static func slot(atX x: CGFloat, width: CGFloat) -> PaneLayout.Slot {
        guard width > 0 else { return .left }
        return x < width / 2 ? .left : .right
    }
}

extension PaneLayout {
    /// Opens a dropped row in `half`. With one pane, the left half replaces it
    /// and the right half splits. Returns false for a payload that isn't a row.
    @discardableResult
    mutating func drop(_ payload: String, onHalf half: Slot) -> Bool {
        guard let ref = PaneDragPayload.decode(payload) else { return false }
        open(ref, in: half)
        return true
    }
}

extension PaneRef {
    /// The agent's title when the ref names one, else the space's name.
    func displayTitle(in spaces: [Space]) -> String {
        guard let space = spaces.first(where: { $0.id == spaceID }) else { return spaceID }
        if let paneID, let agent = space.agents.first(where: { $0.paneId == paneID }) {
            return agent.displayTitle
        }
        return space.label
    }
}

// MARK: - Drop target

extension View {
    /// Accepts dragged rows on the detail column, with a zone per half.
    func paneDropTarget(layout: Binding<PaneLayout>) -> some View {
        modifier(PaneDropTargetModifier(layout: layout))
    }

    /// A row's drag handle on regular width.
    @ViewBuilder
    func paneDraggable(_ ref: PaneRef, title: String, enabled: Bool) -> some View {
        if enabled {
            draggable(PaneDragPayload.encode(ref)) { PaneDragPreview(title: title) }
        } else {
            self
        }
    }
}

private struct PaneDragPreview: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.jost(14, weight: .semibold))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.cardBackground, in: RoundedRectangle.continuous(DesignSystem.CornerRadius.md))
            .overlay(
                RoundedRectangle.continuous(DesignSystem.CornerRadius.md)
                    .strokeBorder(Theme.accent, lineWidth: 1)
            )
    }
}

private struct PaneDropTargetModifier: ViewModifier {
    @Binding var layout: PaneLayout
    @State private var isTargeted = false
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .dropDestination(for: String.self) { items, location in
                let half = PaneDropZone.slot(atX: location.x, width: width)
                for item in items where layout.drop(item, onHalf: half) { return true }
                return false
            } isTargeted: { isTargeted = $0 }
            .overlay {
                if isTargeted {
                    HStack(spacing: 12) {
                        zone("Open on left")
                        zone("Open on right")
                    }
                    .padding(12)
                    .allowsHitTesting(false)
                }
            }
    }

    private func zone(_ title: LocalizedStringKey) -> some View {
        let shape = RoundedRectangle.continuous(DesignSystem.CornerRadius.lg)
        return Text(title)
            .font(.jost(.subheadline, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.accent.opacity(0.08), in: shape)
            .overlay(shape.strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
    }
}
