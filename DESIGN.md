# DESIGN.md — "Moonlit"

A night-time, limited-palette pixel-art theme: a cool teal-green world lit by a mint moon, with one small lacquer-red accent. It feels like a Game Boy–era village at dusk: calm, nostalgic, a little mysterious. A matching day variant inverts the value ramp (§7).

---

## 1. Design principles

1. **Few colours, used strictly.** Nine colours make up the whole world. Depth comes from stepping through tones of one teal ramp, not from new hues.
2. **Value builds depth.** Darker means closer to the viewer: foreground silhouettes are almost black, the far sky is mid-teal, and the light source is pale mint.
3. **One warm accent.** Lacquer red appears only on small, meaningful elements (signage, pillars, a key call to action). If it shows up everywhere, it stops working.
4. **Crisp pixels, soft UI.** Illustrations are hard-edged pixel art with no anti-aliasing or gradients. The UI chrome around them (nav, toggles, cards) uses a clean geometric sans and gentle rounded corners.
5. **Quiet chrome.** The navigation floats directly on the scene with no bar, background or shadow. The illustration is the hero.

---

## 2. Colour palette

### 2.1 Core tokens

| Token | Hex | Role in the scene | Typical UI use |
|---|---|---|---|
| `night-950` | `#1B282E` | Foreground silhouettes, deep forest, darkest shadow | App background (dark), body text on light |
| `night-900` | `#26343D` | Building shadows, mid-ground structures | Raised surface / card (dark) |
| `night-800` | `#325156` | Near mountains, tree layers | Secondary surface, borders, dividers |
| `teal-600` | `#4C777D` | **Sky. The dominant colour (~32% of the frame)** | Hero/page background, primary brand field |
| `teal-400` | `#63988E` | Lit surfaces: roof, ground, path | Hover states, secondary buttons, muted icons |
| `mint-200` | `#ABE0B6` | The moon, logo badges, nav links, toggle track | **Primary accent**: links, active toggles, highlights, focus rings |
| `paper-50` | `#F8F8F8` | Active nav item, toggle knob | High-emphasis text on dark, knobs, chips |
| `ink-700` | `#383B3F` | Brush-lettered logo | Display wordmarks on teal / mint |
| `lacquer-900` | `#4B221C` | Gate posts and signage | Rare accent: badges, "sale"/"new", destructive or primary CTA text on mint |

### 2.2 Approximate usage ratio

```
teal-600   ████████████████  ~32%   sky / page
night-950  █████████          ~18%   foreground
night-800  ████████           ~16%   mid layers
teal-400   ██████             ~13%   lit surfaces
night-900  ██████             ~12%   shadows
mint-200   █                   ~2%   light / accent
paper-50   █                   ~2%   UI text
ink-700    ▌                   ~1%   wordmark
lacquer    ▌                   <1%   warm accent
```

Keep to roughly this balance. Mint and red work because they are rare.

### 2.3 Contrast (WCAG 2.x)

| Foreground on background | Ratio | OK for |
|---|---|---|
| `paper-50` on `night-950` | 14.2 : 1 | Body text ✅ AAA |
| `paper-50` on `night-900` | 12.1 : 1 | Body text ✅ AAA |
| `mint-200` on `night-950` | 10.1 : 1 | Body text ✅ AAA |
| `night-950` on `mint-200` | 10.1 : 1 | Button labels ✅ AAA |
| `lacquer-900` on `mint-200` | 9.1 : 1 | Badge / sign text ✅ AAA |
| `mint-200` on `night-800` | 5.8 : 1 | Body text ✅ AA |
| `paper-50` on `teal-600` | 4.7 : 1 | Nav / body text ✅ AA |
| `teal-400` on `night-950` | 4.6 : 1 | Secondary text ✅ AA |
| `mint-200` on `teal-600` | 3.3 : 1 | ⚠️ Large text (≥24px) and icons only |
| `ink-700` on `teal-600` | 2.3 : 1 | ⚠️ Decorative wordmark only, never body copy |

Mint nav links on the teal sky are fine at 18–20px. For anything smaller, use `paper-50`.

---

## 3. Typography

| Role | Typeface | Notes |
|---|---|---|
| Display / logo | Hand-lettered brush, chunky and slightly irregular | Custom artwork. Do not set it in a font. Use an SVG or PNG wordmark in `ink-700`. |
| UI / body | **Jost** (Google Fonts). Fallbacks: Futura, Century Gothic, system-ui | Geometric, friendly, legible at nav sizes |
| Pixel accents (optional) | Silkscreen, Press Start 2P or DotGothic16 | Tiny labels, scores, tags only. Never paragraphs. |
| Japanese accent | DotGothic16 or a pixel kana | Vertical badges, signage |

### Type scale

| Token | Size / line-height | Weight | Use |
|---|---|---|---|
| `display` | 56 / 1.0 | artwork | Hero wordmark |
| `h1` | 40 / 1.15 | 600 | Page titles |
| `h2` | 28 / 1.2 | 600 | Section titles |
| `h3` | 20 / 1.3 | 500 | Card titles |
| `nav` | 18 / 1.0 | 400 | Top navigation (active item 500) |
| `body` | 16 / 1.6 | 400 | Paragraphs |
| `small` | 14 / 1.5 | 400 | Captions, meta |
| `pixel` | 10 or 12 / 1.0 | 400 | Pixel-font labels at integer multiples only |

Letter-spacing is 0 for Jost and `0.05em` for pixel fonts.

---

## 4. Layout & spacing

- **Spacing scale (4px base):** 4 · 8 · 12 · 16 · 24 · 32 · 48 · 64 · 96.
- **Hero:** full-bleed illustration with the wordmark centred in the upper third. The light source (moon) sits just off-centre beside it.
- **Nav:** sits directly on the hero, about 24px from the top. Logo badge on the far left, text links left-aligned beside it, socials and theme toggle on the right. Gap between links is 36px.
- **Vertical logo badge:** tall rounded rectangle (radius about 16px) with a 3px `mint-200` outline and vertical kana inside. It's a strong identity mark, so reuse it as the app icon or favicon motif.
- **Content width:** 1120px max, with a 16px side gutter on mobile.

---

## 5. Shape, borders & effects

| Property | Value |
|---|---|
| Radius (UI) | `8px` default, `16px` badges/cards, `999px` toggles/pills |
| Radius (pixel art) | `0`. Pixel art never gets rounded. |
| Border | `2–3px solid mint-200` for outlined badges; `1px solid night-800` for dividers |
| Shadows | **None.** Show depth by stepping up a surface tone (`night-950` → `night-900` → `night-800`). |
| Glow (sparingly) | `0 0 24px rgba(171,224,182,0.35)` on moon-like focal points only |
| Gradients | None in illustrations. If needed in UI, use only one step between adjacent ramp tones. |

### Pixel-art rendering rules

```css
img.pixel, canvas.pixel {
  image-rendering: pixelated;      /* crisp scaling */
  image-rendering: crisp-edges;
}
```
- Scale sprites by whole numbers only (2×, 3×, 4×).
- Dithering (checkerboard between two adjacent tones) is the only allowed way to blend, as in the clouds and the roof seams.
- Outlines use `night-950`, never pure black.

---

## 6. Components

### Nav link
- Default: `mint-200`, Jost 18/400.
- Hover: `paper-50`.
- Active: `paper-50`, weight 500. No underline, no pill.

### Theme toggle
- Track 52×28, `mint-200`, fully rounded. Knob 22px, `paper-50`.
- Moon icon on the left and sun icon on the right, both `mint-200`.

### Primary button
- Background `mint-200`, text `night-950`, radius 8, padding 12×20.
- Hover: background `paper-50`. Pressed: shift the button down 1px (pixel "press") with no shadow.

### Secondary button
- Transparent background, 2px border `mint-200`, text `mint-200`.
- Hover: fill `night-800`.

### Accent / "sign" badge
- Background `mint-200` or `paper-50`, text and 2px border `lacquer-900`. Optionally set the text vertically.

### Card
- Background `night-900`, 1px border `night-800`, radius 16, padding 24.
- Title `paper-50`, body `mint-200` or `teal-400` for secondary text.

### Circular emblem
- Mascot icon inside a circle with a 3px `mint-200` stroke and a transparent fill.

---

## 7. Light mode ("day")

Night is the default. Day keeps the same hues and inverts the value ramp: lighter is now further away, and a paper-white sun replaces the moon. The site's toggle stores the choice in `localStorage` (`herdcats-theme`) and applies it as `<html data-theme="light">` before first paint.

### Semantic tokens

Pages use these tokens, never the raw ramp, so both themes come from one stylesheet.

| Token | Night (default) | Day | Use |
|---|---|---|---|
| `--sky` | `#4C777D` | `#D3EBDD` | Sky behind the hero and headers |
| `--sky-text` | `#F8F8F8` | `#1B282E` | Titles and copy over the sky |
| `--sky-link` | `#ABE0B6` | `#325156` | Nav links and toggle over the sky |
| `--bg` | `#26343D` | `#EEF6F1` | Page body |
| `--bg-deep` | `#1B282E` | `#DCEBE2` | Footer, code blocks |
| `--surface` | `#26343D` | `#F8FBF9` | Cards (always with a `--border` outline) |
| `--raised` / `--border` | `#325156` | `#C5DCCF` | Active rows, chips, dividers |
| `--text` | `#F8F8F8` | `#1B282E` | Body text |
| `--text-muted` | paper at 72% | night-950 at 72% | Secondary text |
| `--accent` | `#ABE0B6` | `#325156` | Links, labels, icons |
| `--accent-fill` / `--on-accent` | `#ABE0B6` / `#1B282E` | `#325156` / `#F8F8F8` | Primary buttons |
| `--accent-fill-hover` | `#F8F8F8` | `#1B282E` | Primary button hover |
| `--warm` | `#4B221C` | `#8A3324` | Sign badges (brightened by day so it reads on light grounds) |
| `--sign-bg` | `#ABE0B6` | `#ABE0B6` | Sign badge fill |
| `--focus` | `#F8F8F8` | `#1B282E` | Focus rings |
| `--overlay` | night-950 at 88% | `#EEF6F1` at 90% | Modal and menu scrims |

All day pairs pass WCAG AA: body text 13.7:1, links 7.8:1, buttons 8.1:1, warm on mint 5.5:1.

### Scenery

| Layer | Night | Day |
|---|---|---|
| Sky | `#4C777D` | `#D3EBDD` |
| Moon / sun | `#ABE0B6` | `#F8F8F8` |
| Clouds | `#63988E` | `#F8F8F8` |
| Far hills | `#325156` | `#ABE0B6` |
| Treeline | `#26343D` | `#63988E` |
| Ground | `#325156` | `#A9CFBB` |
| Foreground foliage | `#1B282E` | `#4C777D` |

---

## 8. Implementation tokens

### CSS custom properties

```css
:root {
  --night-950: #1B282E;
  --night-900: #26343D;
  --night-800: #325156;
  --teal-600:  #4C777D;
  --teal-400:  #63988E;
  --mint-200:  #ABE0B6;
  --paper-50:  #F8F8F8;
  --ink-700:   #383B3F;
  --lacquer-900: #4B221C;

  /* semantic: night (default). Pages use these, never the raw ramp. */
  --sky:               var(--teal-600);
  --sky-text:          var(--paper-50);
  --sky-link:          var(--mint-200);
  --bg:                var(--night-900);
  --bg-deep:           var(--night-950);
  --surface:           var(--night-900);
  --raised:            var(--night-800);
  --border:            var(--night-800);
  --text:              var(--paper-50);
  --text-muted:        rgba(248, 248, 248, 0.72);
  --accent:            var(--mint-200);
  --accent-fill:       var(--mint-200);
  --accent-fill-hover: var(--paper-50);
  --on-accent:         var(--night-950);
  --warm:              var(--lacquer-900);
  --sign-bg:           var(--mint-200);
  --focus:             var(--paper-50);
  --overlay:           rgba(27, 40, 46, 0.88);

  --radius-sm: 8px;
  --radius-md: 16px;
  --radius-pill: 999px;
  --font-sans: "Jost", Futura, "Century Gothic", system-ui, sans-serif;
  --font-pixel: "Silkscreen", "DotGothic16", monospace;
}

/* Day: same hues, value ramp inverted (§7). */
:root[data-theme="light"] {
  --sky:               #D3EBDD;
  --sky-text:          var(--night-950);
  --sky-link:          var(--night-800);
  --bg:                #EEF6F1;
  --bg-deep:           #DCEBE2;
  --surface:           #F8FBF9;
  --raised:            #C5DCCF;
  --border:            #C5DCCF;
  --text:              var(--night-950);
  --text-muted:        rgba(27, 40, 46, 0.72);
  --accent:            var(--night-800);
  --accent-fill:       var(--night-800);
  --accent-fill-hover: var(--night-950);
  --on-accent:         var(--paper-50);
  --warm:              #8A3324;
  --sign-bg:           var(--mint-200);
  --focus:             var(--night-950);
  --overlay:           rgba(238, 246, 241, 0.9);
}
```

### Tailwind (`theme.extend.colors`)

```js
colors: {
  night:   { 950: '#1B282E', 900: '#26343D', 800: '#325156' },
  teal:    { 600: '#4C777D', 400: '#63988E' },
  mint:    { 200: '#ABE0B6' },
  paper:   { 50:  '#F8F8F8' },
  ink:     { 700: '#383B3F' },
  lacquer: { 900: '#4B221C' },
},
fontFamily: {
  sans:  ['Jost', 'Futura', 'Century Gothic', 'system-ui', 'sans-serif'],
  pixel: ['Silkscreen', 'DotGothic16', 'monospace'],
},
```

### SwiftUI

```swift
extension Color {
    static let night950   = Color(hex: 0x1B282E)
    static let night900   = Color(hex: 0x26343D)
    static let night800   = Color(hex: 0x325156)
    static let teal600    = Color(hex: 0x4C777D)
    static let teal400    = Color(hex: 0x63988E)
    static let mint200    = Color(hex: 0xABE0B6)
    static let paper50    = Color(hex: 0xF8F8F8)
    static let ink700     = Color(hex: 0x383B3F)
    static let lacquer900 = Color(hex: 0x4B221C)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8)  & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255)
    }
}
```
For sprites, use `Image("sprite").interpolation(.none).resizable()` to keep pixels crisp.

The app bundles the same Jost (variable) and Silkscreen files as the site, from `ios/Herdcats/Resources/Fonts`. Use `Font.jost(.caption, weight:)` for text styles (scales with Dynamic Type), `Font.jost(14, weight:)` for fixed sizes, and `Font.pixel(10)` for pixel labels. Navigation titles, tab labels and segmented controls get Jost from `AppTypeface.installUIKitAppearance()`. Terminal output stays in the system monospaced font.

---

## 9. Do / Don't

✅ Build depth with the teal ramp, darkest in front.
✅ Keep mint as the one "light" and red as the one "warmth".
✅ Scale pixel art by whole numbers with `pixelated` rendering.
✅ Let the illustration carry the page, with UI floating on top of it.

❌ Add new hues (blues, purples, oranges).
❌ Use drop shadows, blur or glossy gradients.
❌ Use pure black `#000` or pure white `#FFF` for large areas.
❌ Put `ink-700` or `mint-200` body text on `teal-600`, because contrast is too low.
❌ Round the corners of pixel art or scale it to fractional sizes.
