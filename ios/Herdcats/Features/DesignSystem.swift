import SwiftUI
import UIKit

// MARK: - Design System

/// Central design system tokens, themes, typography, shapes, and view modifiers for HerdrCat.
/// Conforms to the visual specification described in `design.md`.
enum DesignSystem {

    // MARK: - Corner Radii

    /// DESIGN.md §5 uses three UI radii: 8pt controls, 16pt cards, and pills.
    /// The named steps below map onto those so call sites keep their intent.
    enum CornerRadius {
        /// 0pt — edge-to-edge raw terminal output
        static let none: CGFloat = 0
        /// 7pt — app-icon logo thumbnails, echoing the iOS icon mask
        static let xs: CGFloat = 7
        /// 8pt — compact drawer buttons, follow-up chips
        static let sm: CGFloat = 8
        /// 8pt — standard text inputs, worktree rows
        static let md: CGFloat = 8
        /// 16pt — error banners, code blocks, pane switcher cards
        static let lg: CGFloat = 16
        /// 16pt — primary workspace cards and agent triage cards
        static let xl: CGFloat = 16
        /// 16pt — recent connection cards, connection setup sheet
        static let xxl: CGFloat = 16
        /// 8pt — primary and secondary buttons
        static let button: CGFloat = 8
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

/// Raw "Moonlit" ramp from `DESIGN.md` §2. Views use the semantic `Theme`
/// tokens below, never these directly, so night and day come from one place.
enum Palette {
    static let night950: UInt32 = 0x1B282E
    static let night900: UInt32 = 0x26343D
    static let night800: UInt32 = 0x325156
    static let teal600: UInt32 = 0x4C777D
    static let teal400: UInt32 = 0x63988E
    static let mint200: UInt32 = 0xABE0B6
    static let paper50: UInt32 = 0xF8F8F8
    static let lacquer900: UInt32 = 0x4B221C
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

enum Theme {
    /// A color that resolves to `night` in dark mode and `day` in light mode,
    /// matching the website's semantic tokens (`DESIGN.md` §7).
    private static func moonlit(night: UIColor, day: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? night : day
        })
    }

    private static func moonlit(night: UInt32, day: UInt32) -> Color {
        moonlit(night: UIColor(hex: night), day: UIColor(hex: day))
    }

    /// `--accent`: links, labels, icons, Herdr focus (mint by night, night-800 by day).
    static let accent = moonlit(night: Palette.mint200, day: Palette.night800)

    /// `--accent-fill`: primary button fill.
    static let accentFill = moonlit(night: Palette.mint200, day: Palette.night800)

    /// `--sky`: hero and header field behind top-level screens.
    static let sky = moonlit(night: Palette.teal600, day: 0xD3EBDD)

    /// `--bg-deep`: the app canvas. Cards sit one step lighter on `surface`
    /// with a `hairline` outline, so structure needs no shadows.
    static let background = moonlit(night: Palette.night950, day: 0xDCEBE2)

    static let backgroundGradient = LinearGradient(
        colors: [background, background],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Flat canvas behind top-level screens. Moonlit uses no glows or gradients.
    static var listBackground: some View {
        background
    }

    /// `--surface`: cards (with a `hairline` outline, see `HerdrCardModifier`)
    /// and native Settings rows.
    static let cardBackground = moonlit(night: 0x31464E, day: 0xF8FBF9)

    /// Inset background for text inputs, search fields, and recessed areas
    /// (`--bg-deep` at night).
    static let fieldBackground = moonlit(night: Palette.night950, day: 0xEEF6F1)

    /// `--border`: 1pt dividers and card outlines.
    static let hairline = moonlit(night: Palette.night800, day: 0xC5DCCF)

    /// `--raised`: chips, pills, and secondary surfaces.
    static let subtleFill = moonlit(night: 0x446670, day: 0xC5DCCF)

    /// Rows and pane cards share the solid card surface.
    static let rowBackground = cardBackground

    /// `--raised` fill marking the pane selected on this phone, like the
    /// website's active rows. Accent stays reserved for Herdr focus.
    static let selectedFill = subtleFill

    /// `--border`: visible control border and disabled fill.
    static let border = hairline

    /// `--text`: body text (paper by night, night-950 by day).
    static let text = moonlit(night: Palette.paper50, day: Palette.night950)

    /// `--text-muted`: secondary text at 72% of `text`.
    static let textMuted = moonlit(
        night: UIColor(hex: Palette.paper50, alpha: 0.72),
        day: UIColor(hex: Palette.night950, alpha: 0.72)
    )

    /// `--warm`: rare lacquer accent for sign badges.
    static let warm = moonlit(night: Palette.lacquer900, day: 0x8A3324)

    // MARK: - Status Colors
    //
    // Moonlit-tuned status set: the teal ramp and lacquer, plus one muted amber,
    // so blocked / working / done / idle stay distinct at a glance. Each passes
    // WCAG AA (4.5:1) as text on `cardBackground`; `onPrimary` reads on each fill.

    /// Idle: lifted teal-400 by night, teal-600 by day.
    static let statusIdle = moonlit(night: 0x8CC2B6, day: Palette.teal600)

    /// Done: mint-200 by night, a deep mint by day.
    static let statusDone = moonlit(night: Palette.mint200, day: 0x2F7148)

    /// Working: muted amber, the one hue outside the ramp.
    static let statusWorking = moonlit(night: 0xE0B866, day: 0x865C0E)

    /// Blocked: lacquer brightened enough to read as an alert.
    static let statusBlocked = moonlit(night: 0xF29A86, day: 0xA8432F)

    /// Unified-diff addition (`+`) line wash: mint.
    static let diffAdditionBackground = moonlit(
        night: UIColor(hex: Palette.mint200, alpha: 0.22),
        day: UIColor(hex: Palette.mint200, alpha: 0.6)
    )

    /// Unified-diff deletion (`-`) line wash: lacquer.
    static let diffDeletionBackground = moonlit(
        night: UIColor(hex: 0xF29A86, alpha: 0.24),
        day: UIColor(hex: 0xA8432F, alpha: 0.18)
    )

    // MARK: - Semantic & Action Colors

    /// Destructive / critical error color.
    static let destructive = statusBlocked

    /// Warning alert color.
    static let warning = statusWorking

    /// `--on-accent`: text on `accentFill` (night-950 on mint, paper on night-800).
    static let onPrimary = moonlit(night: Palette.night950, day: Palette.paper50)

    /// Heads-up when remaining is healthy but burn is ahead of the even-burn line.
    static let quotaHeadsUp = statusWorking

    /// Hybrid quota color: mint when remaining ≥ 40% and on pace; amber when
    /// ≥ 40% but behind pace or at 15–39%; blocked red below 15%. A full window
    /// is always green. Outer and inner rings share the same semantic color
    /// (`inner` is ignored for hue). Windows without a schedule use the same
    /// percent bands with no heads-up path.
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

    /// Countdown color: amber when behind pace at ≥ 40% remaining; match
    /// amber/red in the low band; otherwise secondary.
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

    /// Affirming mint used for on-pace / healthy quota chips.
    static let successGreen = statusDone
}

// MARK: - Typography Tokens

/// Bundled typefaces from `DESIGN.md` §3: Jost for UI and body text, Silkscreen
/// for tiny pixel labels. Jost ships as the unmodified variable font, whose named
/// instances CoreText exposes as `JostRoman-<Weight>`; the default instance keeps
/// the font's own name, `Jost-Regular`.
enum AppTypeface {
    static func jostName(_ weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight: "JostRoman-ExtraLight"
        case .thin: "JostRoman-Thin"
        case .light: "JostRoman-Light"
        case .medium: "JostRoman-Medium"
        case .semibold: "JostRoman-SemiBold"
        case .bold: "JostRoman-Bold"
        case .heavy: "JostRoman-ExtraBold"
        case .black: "JostRoman-Black"
        default: "Jost-Regular"
        }
    }

    static func silkscreenName(bold: Bool) -> String {
        bold ? "Silkscreen-Bold" : "Silkscreen-Regular"
    }

    /// iOS default (Large) point size and weight for each text style, so
    /// `Font.jost(.caption)` lines up with the system style it replaces.
    static func metrics(for style: Font.TextStyle) -> (size: CGFloat, weight: Font.Weight) {
        switch style {
        case .largeTitle: (34, .regular)
        case .title: (28, .regular)
        case .title2: (22, .regular)
        case .title3: (20, .regular)
        case .headline: (17, .semibold)
        case .callout: (16, .regular)
        case .subheadline: (15, .regular)
        case .footnote: (13, .regular)
        case .caption: (12, .regular)
        case .caption2: (11, .regular)
        default: (17, .regular)
        }
    }

    /// UIKit Jost for navigation bars and segmented controls.
    static func uiJost(_ size: CGFloat, weight: Font.Weight = .regular) -> UIFont {
        UIFont(name: jostName(weight), size: size) ?? .systemFont(ofSize: size)
    }

    /// SwiftUI draws navigation titles, tab labels, and segmented pickers with
    /// UIKit, so they take Jost from appearance proxies rather than `.font`.
    static func installUIKitAppearance() {
        func scaled(_ size: CGFloat, _ weight: Font.Weight, _ style: UIFont.TextStyle) -> UIFont {
            UIFontMetrics(forTextStyle: style).scaledFont(for: uiJost(size, weight: weight))
        }
        let navigationBar = UINavigationBar.appearance()
        navigationBar.titleTextAttributes = [.font: scaled(17, .semibold, .headline)]
        navigationBar.largeTitleTextAttributes = [.font: scaled(34, .semibold, .largeTitle)]

        UITabBarItem.appearance().setTitleTextAttributes([.font: uiJost(10, weight: .medium)], for: .normal)

        let segmented = UISegmentedControl.appearance()
        segmented.setTitleTextAttributes([.font: scaled(13, .regular, .footnote)], for: .normal)
        segmented.setTitleTextAttributes([.font: scaled(13, .semibold, .footnote)], for: .selected)
    }
}

extension Font {
    /// Jost at a fixed point size, replacing `.system(size:weight:)`.
    static func jost(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(AppTypeface.jostName(weight), fixedSize: size)
    }

    /// Jost sized like a system text style and scaled with Dynamic Type.
    static func jost(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        let metrics = AppTypeface.metrics(for: style)
        return .custom(AppTypeface.jostName(weight ?? metrics.weight), size: metrics.size, relativeTo: style)
    }

    /// Silkscreen pixel label. Use only at 10 or 12pt for tags and counts, never paragraphs.
    static func pixel(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(AppTypeface.silkscreenName(bold: bold), fixedSize: size)
    }

    /// 27pt Bold Jost — connection screen hero ("HerdrCat").
    static let appDisplay = Font.jost(27, weight: .bold)

    /// 17pt Semibold Jost — workspace card titles, modal navigation bars.
    static let appHeadlineMd = Font.jost(17, weight: .semibold)

    /// 16pt Semibold Jost — agent card titles, quota card headers.
    static let appHeadlineSm = Font.jost(16, weight: .semibold)

    /// 10pt Silkscreen — agent badge labels, stat count tags.
    static let appLabelSm = Font.pixel(10)
}

// MARK: - Shapes

extension RoundedRectangle {
    /// Convenience initializer ensuring continuous Apple corner smoothing.
    static func continuous(_ cornerRadius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

// MARK: - Card View Modifiers

/// Standardizes card surfaces (workspace cards, agent triage cards) with continuous rounding,
/// a stable fill, and a 1pt `--border` outline, as on the website. Cards Herdr reports as
/// focused carry the Herdr focus line.
struct HerdrCardModifier: ViewModifier {
    var isFocused: Bool = false
    var cornerRadius: CGFloat = DesignSystem.CornerRadius.xl

    func body(content: Content) -> some View {
        let shape = RoundedRectangle.continuous(cornerRadius)
        return content
            .background(shape.fill(Theme.cardBackground))
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1).allowsHitTesting(false))
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

    /// Applies Herdr card styling (16pt continuous rounding, border, and Herdr focus line).
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

/// Primary button style according to DESIGN.md: 8pt rounded rectangle with a solid
/// `accentFill` and `onPrimary` label, bold 14pt typography, 12pt vertical padding,
/// and 44pt minimum height. Pressing shifts it down 1pt (pixel "press"), no shadow.
struct HerdrPrimaryButtonStyle: ButtonStyle {
    var fullWidth: Bool = true
    var cornerRadius: CGFloat = DesignSystem.CornerRadius.button
    var tint: Color? = nil

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

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
        case .mini: .jost(11, weight: .bold)
        case .small: .jost(12, weight: .semibold)
        case .regular, .large, .extraLarge: .jost(14, weight: .bold)
        @unknown default: .jost(14, weight: .bold)
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle.continuous(cornerRadius)
    }

    @ViewBuilder
    private var backgroundFill: some View {
        if !isEnabled {
            shape.fill(Theme.border)
        } else if let tint {
            shape.fill(tint)
        } else {
            shape.fill(Theme.accentFill)
        }
    }

    private var foregroundColor: Color {
        if !isEnabled {
            return Theme.textMuted
        }
        return Theme.onPrimary
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
            .offset(y: configuration.isPressed ? 1 : 0)
            .opacity(isEnabled ? 1.0 : 0.6)
    }
}

/// Secondary button style according to DESIGN.md: 8pt rounded rectangle with a
/// transparent fill, 2pt `accent` outline and `accent` label, 14pt semibold typography,
/// and 44pt minimum height. Pressing fills it with `--raised` and shifts it down 1pt.
struct HerdrSecondaryButtonStyle: ButtonStyle {
    var fullWidth: Bool = true
    var cornerRadius: CGFloat = DesignSystem.CornerRadius.button

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

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
        case .mini: .jost(11, weight: .semibold)
        case .small: .jost(12, weight: .semibold)
        case .regular, .large, .extraLarge: .jost(14, weight: .semibold)
        @unknown default: .jost(14, weight: .semibold)
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle.continuous(cornerRadius)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(effectiveFont)
            .foregroundStyle(isEnabled ? Theme.accent : Theme.textMuted)
            .padding(.vertical, effectivePaddingVertical)
            .padding(.horizontal, effectivePaddingHorizontal)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(minHeight: minHeight)
            .background(shape.fill(configuration.isPressed ? Theme.subtleFill : .clear))
            .overlay(shape.strokeBorder(isEnabled ? Theme.accent : Theme.border, lineWidth: 2))
            .contentShape(shape)
            .offset(y: configuration.isPressed ? 1 : 0)
            .opacity(isEnabled ? 1.0 : 0.45)
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
            .font(.jost(14, weight: .medium))
            .foregroundStyle(Theme.textMuted)
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
        cornerRadius: CGFloat = DesignSystem.CornerRadius.button,
        tint: Color? = nil
    ) -> HerdrPrimaryButtonStyle {
        HerdrPrimaryButtonStyle(
            fullWidth: fullWidth,
            cornerRadius: cornerRadius,
            tint: tint
        )
    }
}

extension ButtonStyle where Self == HerdrSecondaryButtonStyle {
    static var herdrSecondary: HerdrSecondaryButtonStyle { .init() }

    static func herdrSecondary(
        fullWidth: Bool = true,
        cornerRadius: CGFloat = DesignSystem.CornerRadius.button
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
        Button("Primary") {}
            .buttonStyle(.herdrPrimary())

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
