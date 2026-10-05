import SwiftUI
import UIKit

// MARK: - Design System

/// Central design system tokens, themes, typography, shapes, and view modifiers for HerdrCat.
/// Conforms to the visual specification described in `design.md`.
enum DesignSystem {

    // MARK: - Corner Radii

    enum CornerRadius {
        /// 0pt — edge-to-edge raw terminal output
        static let none: CGFloat = 0
        /// 7pt — micro thumbnails, compact badge icons
        static let xs: CGFloat = 7
        /// 10pt — compact drawer buttons, follow-up chips
        static let sm: CGFloat = 10
        /// 12pt — standard text inputs, worktree rows
        static let md: CGFloat = 12
        /// 14pt — action buttons, error banners, pane switcher cards
        static let lg: CGFloat = 14
        /// 19pt — primary workspace cards and agent triage cards
        static let xl: CGFloat = 19
        /// 22pt — recent connection cards, connection setup sheet
        static let xxl: CGFloat = 22
        /// 9999pt — status pills, agent badges, circular action buttons
        static let full: CGFloat = 9999
    }

    // MARK: - Spacing Scale

    enum Spacing {
        /// 4pt — micro gap between icon and text inside a badge
        static let xs: CGFloat = 4
        /// 8pt — standard horizontal spacing in pills, tight vertical stacks
        static let sm: CGFloat = 8
        /// 12pt — chip padding, form field vertical insets, error banner margins
        static let md: CGFloat = 12
        /// 16pt — standard screen margin, card container padding, default spacing
        static let base: CGFloat = 16
        /// 20pt — vertical spacing between sections
        static let lg: CGFloat = 20
        /// 24pt — major group separations
        static let xl: CGFloat = 24
        /// 32pt — screen top/bottom gutters
        static let xxl: CGFloat = 32
    }
}

// MARK: - Theme

enum Theme {
    /// Turquoise brand accent (#0EDCD5).
    static let accent = Color(red: 0.055, green: 0.863, blue: 0.835)

    /// Deep cyan secondary brand accent (#0DB1C5).
    static let accentSecondary = Color(red: 0.051, green: 0.694, blue: 0.773)

    /// Dynamic linear accent gradient (Turquoise to Deep Cyan).
    static let accentGradient = LinearGradient(
        colors: [
            accent,
            accentSecondary,
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Neutral canvas: black in dark mode, system grouped gray in light mode.
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .black
            : UIColor(white: 0.95, alpha: 1)
    })

    static let backgroundGradient = LinearGradient(
        colors: [background, background],
        startPoint: .top,
        endPoint: .bottom
    )

    /// A soft accent glow behind top-level screens.
    static var listBackground: some View {
        ZStack {
            background
            RadialGradient(
                colors: [
                    Color(uiColor: UIColor { traits in
                        traits.userInterfaceStyle == .dark
                            ? UIColor(red: 0.055, green: 0.863, blue: 0.835, alpha: 0.16)
                            : UIColor(red: 0.055, green: 0.863, blue: 0.835, alpha: 0.12)
                    }),
                    .clear,
                ],
                center: .top,
                startRadius: 0,
                endRadius: 430
            )
        }
    }

    /// Solid charcoal (#1C1C1E) cards, inspired by the iOS Health summary.
    static let cardBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)
            : .white
    })

    /// Inset background for text inputs, search fields, and recessed areas.
    static let fieldBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 44 / 255, green: 44 / 255, blue: 46 / 255, alpha: 1)
            : UIColor.black.withAlphaComponent(0.05)
    })

    /// Subtle boundary hairline stroke (0.5pt-1pt).
    static let hairline = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.07)
            : UIColor.black.withAlphaComponent(0.08)
    })

    /// Soft fill for chips, pills, and secondary surfaces.
    static let subtleFill = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.black.withAlphaComponent(0.05)
    })

    /// Rows and pane cards share the solid card surface.
    static let rowBackground = cardBackground

    /// Neutral fill marking the pane selected on this phone, matching iOS
    /// selected cells. Accent stays reserved for Herdr focus.
    static let selectedFill = Color(uiColor: .systemGray4)

    /// Visible control border (selected-state companion).
    static let border = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.12)
            : UIColor.black.withAlphaComponent(0.12)
    })

    /// Unified-diff addition (`+`) line wash.
    static let diffAdditionBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.12, green: 0.42, blue: 0.22, alpha: 0.72)
            : UIColor(red: 0.20, green: 0.70, blue: 0.40, alpha: 0.28)
    })

    /// Unified-diff deletion (`-`) line wash.
    static let diffDeletionBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.42, green: 0.08, blue: 0.10, alpha: 0.85)
            : UIColor(red: 0.85, green: 0.20, blue: 0.22, alpha: 0.28)
    })

    // MARK: - Semantic & Action Colors

    /// Destructive / critical error color (#FF453A / system red).
    static let destructive = Color(red: 1.0, green: 0.27, blue: 0.23)

    /// Warning alert color (#FF9F0A / system orange).
    static let warning = Color(red: 1.0, green: 0.62, blue: 0.04)

    /// Text color on top of primary accent (#003E43, the icon's ink tone; 6.88:1 contrast ratio).
    static let onPrimary = Color(red: 0.0, green: 0.243, blue: 0.263)

    /// Soft heads-up yellow (#FFD60A) when remaining is healthy but burn is
    /// ahead of the even-burn line.
    static let quotaHeadsUp = Color(red: 1.0, green: 214.0 / 255.0, blue: 10.0 / 255.0)

    /// Hybrid quota color: green when remaining ≥ 40% and on pace; yellow when
    /// ≥ 40% but behind pace; orange for 15–39%; red below 15%. A full window
    /// is always green. Outer and inner rings share the same semantic color
    /// (`inner` is ignored for hue). Windows without a schedule use the same
    /// percent bands with no yellow path.
    static func quotaColor(for chip: AgentUsageChip, now: Date = .now, inner: Bool = false) -> Color {
        _ = inner
        let remaining = chip.percentRemaining
        if remaining >= 100 { return successGreen }
        if remaining < 15 { return destructive }
        if remaining < 40 { return warning }
        if chip.expectedPercentRemaining(now: now) != nil, chip.isBehindPace(now: now) {
            return quotaHeadsUp
        }
        return successGreen
    }

    /// Countdown color: yellow when behind pace at ≥ 40% remaining; match
    /// orange/red in the low band; otherwise secondary.
    static func quotaCountdownStyle(for chip: AgentUsageChip, now: Date = .now, inner: Bool = false) -> AnyShapeStyle {
        _ = inner
        if chip.percentRemaining < 40 {
            return AnyShapeStyle(quotaColor(for: chip, now: now))
        }
        if chip.isBehindPace(now: now) {
            return AnyShapeStyle(quotaHeadsUp)
        }
        return AnyShapeStyle(.secondary)
    }

    /// Affirming green used for on-pace / healthy quota chips.
    static let successGreen = Color(red: 0.20, green: 0.78, blue: 0.35)
}

// MARK: - Typography Tokens

extension Font {
    /// 27pt Bold Rounded — connection screen hero ("HerdrCat").
    static let appDisplay = Font.system(size: 27, weight: .bold, design: .rounded)

    /// 17pt Semibold — workspace card titles, modal navigation bars.
    static let appHeadlineMd = Font.system(size: 17, weight: .semibold)

    /// 16pt Semibold Rounded — agent card titles, quota card headers.
    static let appHeadlineSm = Font.system(size: 16, weight: .semibold, design: .rounded)

    /// 10pt Bold Rounded — agent badge labels, stat count tags.
    static let appLabelSm = Font.system(size: 10, weight: .bold, design: .rounded)
}

// MARK: - Shapes

extension RoundedRectangle {
    /// Convenience initializer ensuring continuous Apple corner smoothing.
    static func continuous(_ cornerRadius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

// MARK: - Card View Modifiers

/// Standardizes card surfaces (workspace cards, agent triage cards) with continuous rounding
/// and a stable fill. Cards Herdr reports as focused carry the Herdr focus line.
struct HerdrCardModifier: ViewModifier {
    var isFocused: Bool = false
    var cornerRadius: CGFloat = DesignSystem.CornerRadius.xl

    func body(content: Content) -> some View {
        let shape = RoundedRectangle.continuous(cornerRadius)
        return content
            .background(shape.fill(Theme.cardBackground))
            .herdrFocusLine(isFocused, in: shape)
            .contentShape(shape)
    }
}

/// Marks what Herdr reports as focused on the Mac: an accent line on the bottom
/// edge that follows the view's shape up into the corners, tapering as it goes.
/// It is the shape minus a copy raised by `thickness`, like a CSS bottom border
/// on a rounded box. Selection on the phone uses `Theme.selectedFill` instead,
/// so the two states can appear together.
struct HerdrFocusLineModifier<S: Shape>: ViewModifier {
    var isFocused: Bool
    var shape: S
    var thickness: CGFloat = 3

    func body(content: Content) -> some View {
        content.overlay {
            if isFocused {
                shape.subtracting(shape.offset(y: -thickness))
                    .fill(Theme.accent)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Standardizes input fields with inset fieldBackground and continuous rounding.
struct HerdrFieldModifier: ViewModifier {
    var cornerRadius: CGFloat = DesignSystem.CornerRadius.md

    func body(content: Content) -> some View {
        let shape = RoundedRectangle.continuous(cornerRadius)
        content
            .background(Theme.fieldBackground, in: shape)
            .contentShape(shape)
    }
}

extension View {
    /// Adds the Herdr focus line along the bottom edge when `isFocused`.
    func herdrFocusLine<S: Shape>(_ isFocused: Bool, in shape: S, thickness: CGFloat = 3) -> some View {
        modifier(HerdrFocusLineModifier(isFocused: isFocused, shape: shape, thickness: thickness))
    }

    /// Applies Herdr card styling (19pt continuous rounding and Herdr focus line).
    func herdrCard(
        isFocused: Bool = false,
        cornerRadius: CGFloat = DesignSystem.CornerRadius.xl
    ) -> some View {
        modifier(HerdrCardModifier(isFocused: isFocused, cornerRadius: cornerRadius))
    }

    /// Applies Herdr input field styling (12pt continuous rounding, borderless field background).
    func herdrField(cornerRadius: CGFloat = DesignSystem.CornerRadius.md) -> some View {
        modifier(HerdrFieldModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - Button Styles

/// Primary button style according to HerdrCat design system:
/// 14pt continuous rounded rectangle filled with accent or accent gradient,
/// bold 14pt typography, 12pt vertical padding, and 44pt minimum height.
struct HerdrPrimaryButtonStyle: ButtonStyle {
    var fullWidth: Bool = true
    var cornerRadius: CGFloat = DesignSystem.CornerRadius.lg
    var tint: Color? = nil
    var useGradient: Bool = true

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var effectivePaddingVertical: CGFloat {
        switch controlSize {
        case .mini: 4
        case .small: 6
        case .regular, .large, .extraLarge: DesignSystem.Spacing.md
        @unknown default: DesignSystem.Spacing.md
        }
    }

    private var effectivePaddingHorizontal: CGFloat {
        switch controlSize {
        case .mini: 8
        case .small: 12
        case .regular, .large, .extraLarge: DesignSystem.Spacing.base
        @unknown default: DesignSystem.Spacing.base
        }
    }

    private var minHeight: CGFloat {
        switch controlSize {
        case .mini: 24
        case .small: 32
        case .regular, .large, .extraLarge: 44
        @unknown default: 44
        }
    }

    private var effectiveFont: Font {
        switch controlSize {
        case .mini: .system(size: 11, weight: .bold)
        case .small: .system(size: 12, weight: .semibold)
        case .regular, .large, .extraLarge: .system(size: 14, weight: .bold)
        @unknown default: .system(size: 14, weight: .bold)
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle.continuous(
            controlSize == .small ? DesignSystem.CornerRadius.md : cornerRadius
        )
    }

    @ViewBuilder
    private var backgroundFill: some View {
        if !isEnabled {
            shape.fill(Theme.border)
        } else if let tint {
            shape.fill(tint)
        } else if useGradient {
            shape.fill(Theme.accentGradient)
        } else {
            shape.fill(Theme.accent)
        }
    }

    private var foregroundColor: Color {
        if !isEnabled {
            return .secondary
        }
        if tint == nil {
            return Theme.onPrimary
        }
        return .white
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(effectiveFont)
            .foregroundStyle(foregroundColor)
            .padding(.vertical, effectivePaddingVertical)
            .padding(.horizontal, effectivePaddingHorizontal)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(minHeight: minHeight)
            .background(backgroundFill)
            .contentShape(shape)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : (isEnabled ? 1.0 : 0.6))
            .animation(
                reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7),
                value: configuration.isPressed
            )
    }
}

/// Secondary button style according to HerdrCat design system:
/// 14pt continuous rounded rectangle with borderless Theme.subtleFill,
/// 14pt semibold typography, and 44pt minimum height.
struct HerdrSecondaryButtonStyle: ButtonStyle {
    var fullWidth: Bool = true
    var cornerRadius: CGFloat = DesignSystem.CornerRadius.lg

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var effectivePaddingVertical: CGFloat {
        switch controlSize {
        case .mini: 4
        case .small: 6
        case .regular, .large, .extraLarge: DesignSystem.Spacing.md
        @unknown default: DesignSystem.Spacing.md
        }
    }

    private var effectivePaddingHorizontal: CGFloat {
        switch controlSize {
        case .mini: 8
        case .small: 12
        case .regular, .large, .extraLarge: DesignSystem.Spacing.base
        @unknown default: DesignSystem.Spacing.base
        }
    }

    private var minHeight: CGFloat {
        switch controlSize {
        case .mini: 24
        case .small: 32
        case .regular, .large, .extraLarge: 44
        @unknown default: 44
        }
    }

    private var effectiveFont: Font {
        switch controlSize {
        case .mini: .system(size: 11, weight: .semibold)
        case .small: .system(size: 12, weight: .semibold)
        case .regular, .large, .extraLarge: .system(size: 14, weight: .semibold)
        @unknown default: .system(size: 14, weight: .semibold)
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle.continuous(
            controlSize == .small ? DesignSystem.CornerRadius.md : cornerRadius
        )
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(effectiveFont)
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .padding(.vertical, effectivePaddingVertical)
            .padding(.horizontal, effectivePaddingHorizontal)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(minHeight: minHeight)
            .background(shape.fill(Theme.subtleFill))
            .contentShape(shape)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : (isEnabled ? 1.0 : 0.45))
            .animation(
                reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7),
                value: configuration.isPressed
            )
    }
}

/// Ghost / borderless button style for secondary dismissive actions (e.g. Cancel):
/// Text-only button with secondary foreground style and 44pt touch target.
struct HerdrGhostButtonStyle: ButtonStyle {
    var fullWidth: Bool = true

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.secondary)
            .padding(.vertical, DesignSystem.Spacing.md)
            .padding(.horizontal, DesignSystem.Spacing.base)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.6 : (isEnabled ? 1.0 : 0.4))
            .animation(
                reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7),
                value: configuration.isPressed
            )
    }
}

/// Card button style for interactive cards and rows (recent connections, worktrees, tabs):
/// Provides gentle spring press feedback without plain button highlighting.
struct HerdrCardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.985 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7),
                value: configuration.isPressed
            )
    }
}

// MARK: - ButtonStyle Convenience Extensions

extension ButtonStyle where Self == HerdrPrimaryButtonStyle {
    static var herdrPrimary: HerdrPrimaryButtonStyle { .init() }

    static func herdrPrimary(
        fullWidth: Bool = true,
        cornerRadius: CGFloat = DesignSystem.CornerRadius.lg,
        tint: Color? = nil,
        useGradient: Bool = true
    ) -> HerdrPrimaryButtonStyle {
        HerdrPrimaryButtonStyle(
            fullWidth: fullWidth,
            cornerRadius: cornerRadius,
            tint: tint,
            useGradient: useGradient
        )
    }
}

extension ButtonStyle where Self == HerdrSecondaryButtonStyle {
    static var herdrSecondary: HerdrSecondaryButtonStyle { .init() }

    static func herdrSecondary(
        fullWidth: Bool = true,
        cornerRadius: CGFloat = DesignSystem.CornerRadius.lg
    ) -> HerdrSecondaryButtonStyle {
        HerdrSecondaryButtonStyle(
            fullWidth: fullWidth,
            cornerRadius: cornerRadius
        )
    }
}

extension ButtonStyle where Self == HerdrGhostButtonStyle {
    static var herdrGhost: HerdrGhostButtonStyle { .init() }

    static func herdrGhost(fullWidth: Bool = true) -> HerdrGhostButtonStyle {
        HerdrGhostButtonStyle(fullWidth: fullWidth)
    }
}

extension ButtonStyle where Self == HerdrCardButtonStyle {
    static var herdrCard: HerdrCardButtonStyle { .init() }
}

// MARK: - Previews

#Preview("Standard Buttons") {
    VStack(spacing: 16) {
        Button("Primary (Gradient)") {}
            .buttonStyle(.herdrPrimary())

        Button("Primary (Solid Accent)") {}
            .buttonStyle(.herdrPrimary(useGradient: false))

        Button("Primary (Custom Tint)") {}
            .buttonStyle(.herdrPrimary(tint: Theme.destructive))

        Button("Primary (Disabled)") {}
            .buttonStyle(.herdrPrimary())
            .disabled(true)

        Button("Secondary") {}
            .buttonStyle(.herdrSecondary())

        HStack {
            Button("Small Secondary") {}
                .buttonStyle(.herdrSecondary(fullWidth: false))
                .controlSize(.small)

            Button("Small Primary") {}
                .buttonStyle(.herdrPrimary(fullWidth: false))
                .controlSize(.small)
        }

        Button("Ghost / Cancel") {}
            .buttonStyle(.herdrGhost())
    }
    .padding(20)
    .background(Theme.backgroundGradient)
    .preferredColorScheme(.dark)
}
