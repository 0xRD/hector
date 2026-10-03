# Hexorcist design brief

Hexorcist is a small, all-in-one security app for macOS: network monitor and blocking,
persistence scan, process explorer, VirusTotal lookups. **Netbite** is the name of its network
module (the live map and list of connections, and blocking). Until the rename lands, the app,
the bundle and the menus are still called Netbite; this brief already describes Hexorcist.

The code lives in `Sources/NetbiteApp/Design/` (tokens, components, brand marks). Network-only
pieces (status of a destination, country badge, sparkline) stay in `Views/Theme.swift`.

## 1. The idea

*A calm exorcist for your Mac.* Security tools tend to shout: red dashboards, alarm icons,
gauges. Hexorcist is the opposite. It is a quiet, well-lit study: warm paper, soft colors,
clear verdicts, and a small friendly ghost that gets shown the door. Calm by default, very
clear when something deserves a look, never alarmist.

- **Friendly but serious.** The personality lives in the mark, the empty states and a few small
  details (the spark, the hexagon ward). Verdicts, warnings and destructive actions stay plain.
- **Calm and refined.** Warm neutrals, generous whitespace, soft rounded shapes, a serif for
  titles, as in Claude's own interface.
- **Native first.** It must feel like a Mac app: standard sidebars, toolbars, inspectors,
  search, menus, keyboard and VoiceOver. We restyle content, never the system chrome.

### How the modules sit together

| Module | What it is | Glyph |
|---|---|---|
| Hexorcist (the app) | Brand, app icon, About, onboarding | `HexorcistMark`: ghost in a hexagon seal |
| Netbite (network) | Map, list of destinations, Blocklists | `NetbiteLogo`: globe with a bite |
| Persistence | What starts by itself | SF Symbol on a hexagon `SymbolTile` |
| Processes | What runs now | SF Symbol on a hexagon `SymbolTile` |

Each module is one sidebar section or entry, one `ScreenHeader`, and uses the same verdict
language (section 7). The Netbite glyph appears where the network module is named (the map
header today; its sidebar section after the rename).

## 2. Principles

1. **Clarity before charm.** Every screen answers "is something wrong, and what can I do?" in
   the first glance. Charm never costs a click or hides information.
2. **One verdict language.** Five status kinds, each with its own color *and* symbol shape, used
   identically in every module.
3. **Calm by default.** Most things are fine, so most of the interface is neutral. Color is
   spent on verdicts and on the one primary action of a view.
4. **Explain the consequence.** Next to every action that changes the system: what it does,
   whether it can be undone, and when it takes effect ("Nothing changes until you apply").
5. **Hierarchy through type and space**, not boxes. Cards group related facts; they are not
   wrapped around everything.
6. **Respect the platform.** Sidebar → content → inspector, toolbar search, context menus,
   standard shortcuts, Reduce Motion, Increase Contrast, Dynamic colors, VoiceOver labels.

## 3. Tone of voice

- **Plain and short.** Sentence case, verbs first: "Block This Destination", "Download Again".
  Button titles in title case (macOS convention); everything else in sentence case.
- **Calm, never alarmist.** "3 items to review", not "3 THREATS DETECTED". Say what was found
  and what it means.
- **Honest about limits.** "Blocking is for the whole Mac" explains why, in one sentence.
- **A wink, in the right places only.** Empty states and success moments may be light:
  "Nothing lurking here", "All quiet". Never in warnings, errors, or anything destructive.
- **No jargon without a gloss.** "pf (the macOS firewall)", "SHA-256 (a fingerprint of the
  file, never the file itself)".
- Ellipsis (…) on any command that asks for more (a password, a confirmation).

## 4. Palette

Warm pastels on a cream canvas (light) and a warm charcoal, never pure black (dark). Every color
is defined twice, in `Design/Tokens.swift`, and follows the appearance automatically.

Colors come in three grades:

- **Ink**: text and icons. Deep in light mode, pastel in dark mode.
- **Wash**: pastel fill behind an ink (pills, banners, selected tiles).
- **Tint**: fill of a control that carries a white label (prominent buttons, switches).

### Surfaces

| Token | Light | Dark | Use |
|---|---|---|---|
| `surfaceCanvas` | `#F8F4EE` cream | `#221F1D` warm charcoal | Window content behind every screen |
| `surfaceCard` | `#FFFDFA` | `#2D2A27` | Cards, panels, tiles, tooltips |
| `surfaceInset` | `#F1ECE4` sand | `#1B1917` | Wells: map plate, file lists, code |
| `surfaceStroke` | `#3D3326` at 10 % | `#FFF2E0` at 9 % | Hairline borders |
| `surfaceShadow` | `#4C3824` at 7 % | black at 30 % | Card shadow (radius 6, y 2) |

The sidebar keeps the system sidebar material; the toolbar keeps the system toolbar.

### Status inks and washes

| Kind | Meaning | Ink light | Ink dark | Wash light | Wash dark | Token |
|---|---|---|---|---|---|---|
| ok (sage) | safe, allowed, live, verified | `#3D7054` | `#8CC79E` | `#DEEBDB` | `#304036` | `hexOK`, `hexOKWash` |
| danger (clay) | blocked, malicious, destructive | `#A84230` | `#F29985` | `#F7E0D6` | `#4C302B` | `hexDanger`, `hexDangerWash` |
| warning (honey) | needs a look, pending | `#875E0D` | `#EBC475` | `#FAEBC9` | `#473B24` | `hexWarning`, `hexWarningWash` |
| info (lavender) | information, brand | `#6954A3` | `#C2B2F2` | `#EBE6FA` | `#3B364F` | `hexInfo`, `hexInfoWash` |
| neutral (stone) | unknown, inactive, not checked | `#6B665E` | `#B2ABA1` | `#EBE6DE` | `#3D3B38` | `hexNeutral`, `hexNeutralWash` |

Control tints: `hexTint` (sage, `#3D7054` / `#5C9475`) is the app-wide tint (selection,
prominent buttons). `hexDangerTint` (clay, `#A84230` / `#B2614F`) is for destructive prominent
buttons and "block" switches.

Legacy names kept until the rename: `netbiteAccent` = `hexOK`, `netbiteBlock` = `hexDanger`.

### Contrast (WCAG 2.1, computed)

| Ink | on canvas (L / D) | on card (L / D) | on own wash (L / D) |
|---|---|---|---|
| sage | 5.3 / 8.4 | 5.7 / 7.3 | 4.6 / 5.7 |
| clay | 5.5 / 7.5 | 5.9 / 6.6 | 4.8 / 5.5 |
| honey | 5.3 / 9.9 | 5.7 / 8.6 | 4.9 / 6.6 |
| lavender | 5.6 / 8.6 | 6.1 / 7.5 | 5.1 / 6.1 |
| stone | 5.2 / 7.2 | 5.6 / 6.3 | 4.6 / 4.9 |

All inks pass AA for normal text (4.5:1) everywhere they are used. White on the tints: 5.8
(sage) and 6.0 (clay) in light mode; 3.5 and 4.5 in dark mode, which passes AA for the bold,
large labels of prominent buttons (3:1) and is better than most system accent colors in dark
mode. Pastel washes are never used for text.

Rules:
- Text is `.primary` or `.secondary` unless it states a verdict; then it uses the kind's ink.
- A verdict is never color alone: pills and banners always carry the kind's symbol.
- At most one prominent (tinted) button per view.

### Map

`mapLand` (`#D9D1C7` / `#45403B`) for land dots, `mapLandContacted` (`#B8CCB8` / `#4A6152`, a
sage tint) for countries the Mac talks to. Arcs: sage solid (live), sage dashed (recent), clay
dashed (blocked). The hovered arc gets a soft halo.

## 5. Typography

System fonts only, no font files.

| Role | Font | Token |
|---|---|---|
| Screen title | New York (system serif), Title, semibold | `Font.displayTitle` |
| Hero title (sheets, wordmark) | New York, Large Title, semibold | `Font.displayLarge` |
| Section title | New York, Title 3, semibold | `Font.sectionTitle` |
| Group label ("eyebrow") | SF Pro, Caption, semibold, uppercase, tracking 0.6 | `Font.eyebrow` |
| Body, controls | SF Pro, Body / Callout | system |
| Secondary info | SF Pro, Caption, `.secondary` | system |
| Numbers in summaries | SF Pro Rounded, Title 2, semibold, tabular digits | `Font.metricValue` |
| Technical data (IP, port, hash, path, team ID) | SF Mono, Body / Callout / Caption | `Font.dataMono`, `.dataMonoCallout`, `.dataMonoCaption` |

The serif carries the calm, editorial feel; SF Pro keeps the body native; SF Mono marks what can
be copied and compared; Rounded makes numbers friendly. Every text style is a Dynamic Type style,
so it follows the user's text size.

## 6. Space, shape, elevation

**Spacing** (`Spacing`, 4-pt grid): `xxs` 2, `xs` 4, `sm` 8, `md` 12, `lg` 16, `xl` 24, `xxl` 32.
Screen margins 28 (`xl + 4`), between sections 24, card padding 16, rows inside a card 9 to 12.

**Corner radii** (`Radius`, always `.continuous`): `xs` 4 (tags), `sm` 7 (row highlights),
`md` 10 (banners, tiles, tooltips), `lg` 14 (cards, map plate), `xl` 20 (heroes).

**Elevation**, three levels only:
1. Canvas: `surfaceCanvas`.
2. Card: `surfaceCard`, hairline `surfaceStroke`, soft shadow (`cardSurface()`).
3. Floating: tooltips and popovers, a card plus a deeper shadow (black 18 %, radius 12, y 6).

Recessed wells (`insetSurface()`) hold content that is "inside" a card: the map, file lists.
System materials stay where macOS puts them (sidebar, toolbar, sheets' chrome).

## 7. Status language

| Kind | Symbol | Typical labels |
|---|---|---|
| ok | `checkmark.circle.fill` (or `circle.fill` for "live") | Live, Allowed, Notarized, Apple, 0/72 |
| warning | `exclamationmark.triangle.fill` (or `clock` for pending) | Not applied, Ad hoc, 2/70 suspicious, To review |
| danger | `xmark.octagon.fill` (or `nosign` for blocked) | Blocked · CN, Unsigned, Invalid, 5/70 malicious |
| neutral | `circle.dashed` | Unknown, Not checked, Inactive |
| info | `info.circle.fill` | Checking…, Cached, informational notes |

Suggested mapping for the security screens: `TrustLevel` apple, App Store, notarized → ok;
Developer ID, other certificate → neutral; ad hoc → warning; unsigned, invalid → danger.
VirusTotal: malicious > 0 → danger; suspicious > 0 → warning; known and clean → ok; unknown →
neutral. Use `Color.hexWarning` instead of `.orange`.

## 8. Iconography

- **SF Symbols** everywhere, in their filled variant for verdicts and their outline variant for
  navigation and actions. No custom bitmap icons.
- **Hexagon tiles** (`SymbolTile`) give screens and sidebar entries their identity: a symbol in
  the module's ink on its 16 % wash, inside a rounded hexagon. Rounded squares and circles exist
  for secondary uses (avatars, inline list icons).
- App bundles keep their real icon (`AppIcon`, `PathIcon`); tools and daemons get a symbol on a
  stone tile.
- On a selected row, tiles and pills switch to white automatically (`backgroundProminence`).

### Logo and app icon

- **Mark** (`HexorcistMark`): a rounded, pointy-top hexagon seal stroked with a lavender → sage
  gradient; inside, a small ghost (dome, three-scallop hem, two eyes glancing up and to the right,
  toward the exit); a honey four-point spark breaks through the seal's top-right edge, where the
  stroke is cut. The cut is the Netbite bite, kept as a family resemblance.
- **App icon** (`AppIconArtwork`): plum squircle on the macOS icon grid (412 pt body in 512 pt,
  continuous corners), plum → night gradient, a faint cream hexagon lattice, a lavender glow
  behind the mark, a cream ghost with plum eyes. Drawn in code at launch.
- **Wordmark** (`HexorcistWordmark`): the mark and "Hexorcist" in New York semibold, slightly
  tight tracking. For About, onboarding, the top of the sidebar after the rename.
- **Netbite glyph** (`NetbiteLogo`): the bitten globe, sage, for the network module.

## 9. Motion

- Short and functional: hover 0.12 s (`Motion.quick`), selection and appearance 0.25 s snappy
  (`Motion.standard`), layout 0.4 s smooth (`Motion.gentle`).
- Always through `.motion(_:value:)`, which drops the animation under **Reduce Motion**.
- One ambient animation only: the "live" dot of the status bar breathes slowly (`StatusDot`
  with `pulsing: true`, off under Reduce Motion and while paused). Nothing else loops.
- Numbers change with a numeric content transition (`Metric`).

## 10. Components

All in `Sources/NetbiteApp/Design/Components.swift`, documented with `///` comments.

| Component | Spec |
|---|---|
| `ScreenHeader(title, subtitle:, systemImage:, tint:, pinned:) { trailing }` | 44 pt hexagon tile, `displayTitle`, secondary subtitle, trailing actions. `pinned: true` makes a compact bar (34 pt tile, `sectionTitle`, canvas background, bottom hairline) to sit above a `List`/`Table`. |
| `SectionHeader(title, subtitle:, systemImage:, style:) { trailing }` | `.title`: serif Title 3 with optional symbol and subtitle. `.eyebrow`: uppercase caption for groups in cards and inspectors. Marked as a header for VoiceOver. |
| `Card(padding:, spacing:, tint:) { … }` | Full-width VStack on `cardSurface`: radius 14, padding 16. `tint` for a selected / blocked state. |
| `.cardSurface(cornerRadius:, tint:)`, `.insetSurface(cornerRadius:)`, `.canvasBackground()` | The three surfaces as modifiers. |
| `StatusKind` | `.ok`, `.warning`, `.danger`, `.neutral`, `.info` with `color`, `wash`, `symbol`. |
| `StatusPill(text, kind:, systemImage:, showsIcon:, size:)` | Capsule, wash fill, ink text and icon, caption semibold, tabular digits, `.small` variant. White on selected rows. |
| `StatusDot(kind:, pulsing:, size:)` | 8 pt status light; optional slow halo. |
| `Banner(title, message:, kind:, systemImage:, actionsBelow:) { actions }` | Radius 10, wash fill, 22 % ink hairline, title semibold, selectable message, actions trailing (or below in narrow columns). |
| `EmptyStateView(title, systemImage:, message:, tint:, compact:) { actions }` | Symbol tile inside a dashed hexagon ward rotated 30°, serif title, one-line message, optional actions. Fills its container unless compact. |
| `DetailRow(label, value:, monospaced:)` / `DetailRow(label) { view }` | Label in a 104 pt secondary column, value selectable; combined for VoiceOver. |
| `Metric(value, label:, tint:)` | Rounded tabular number over a caption. |
| `SymbolTile(systemImage, tint:, size:, shape:)` | Hexagon (default), rounded square or circle tile. |
| `SidebarLabel(title, subtitle:, systemImage:, tint:) { accessory }` | 26 pt hexagon tile, medium title, caption subtitle, trailing accessory (count pill, sparkline). |
| `CodeTag(text, tint:)` | Monospaced 10.5 pt tag with hairline, radius 4. |
| `Hexagon(cornerRadius:)` | The ward shape. |
| `.hoverHighlight(id, cornerRadius:)` | Soft hover wash for rows and tiles outside a `List`. |
| `.motion(animation, value:)` | Animation that respects Reduce Motion. |

Network-specific: `StatusBadge` (destination verdict), `CountryBadge`, `Sparkline`, `AppIcon`,
`PendingBar`, `ProtectionStatusFooter` (the sidebar verdict: "Blocking on" / "Observe only").
`BadgeLabelStyle` and `SectionTitle` remain as legacy wrappers.

### Screen recipe

```
ScrollView {
    VStack(alignment: .leading, spacing: Spacing.xl) {
        ScreenHeader("Persistence", subtitle: "…", systemImage: "arrow.triangle.2.circlepath") { … }
        Banner(…)                     // only when something needs attention
        SectionHeader("Launch agents", subtitle: "…")
        Card { … rows … }
    }
    .padding(Spacing.xl + 4)
}
.canvasBackground()
```

For table screens: `ScreenHeader(…, pinned: true)` above the `Table` or `List`, with
`.scrollContentBackground(.hidden).canvasBackground()` on the list; inspector content in `Card`s
with `SectionHeader(style: .eyebrow)` and `DetailRow`s; `EmptyStateView` when nothing matches.

## 11. What we borrowed, and why

- **Objective-See (LuLu, KnockKnock, BlockBlock):** one item per row with its signature verdict
  and VirusTotal score side by side, and "only the hash is sent". Proof that a security tool can
  be honest and small. We kept the row anatomy and the plain wording.
- **Little Snitch:** the map with one line per connection, and hover linking the map, the list and
  the owning process. We kept the linking and calmed the map down (pastel land, halo on hover).
- **1Password (Watchtower):** verdicts as calm cards with one clear next action, never a wall of
  red. Our banners and the "pending changes" bar follow that pattern.
- **Malwarebytes:** a single protection verdict that is always visible. That is the sidebar
  footer ("Blocking on" / "Observe only"), one click from where it is managed.
- **CleanMyMac:** friendly illustrations in empty and finished states. We use a lighter touch: a
  symbol inside a dashed hexagon ward, and a one-line wink at most.
- **Claude:** warm neutrals, cream canvas, serif titles, generous whitespace, soft radii.

## 12. Accessibility checklist

- Every interactive control has a label; icon-only buttons have `.help` and an accessibility label.
- Verdicts carry a symbol and text, not just a color; contrast numbers above.
- Decorative shapes (tiles, marks, sparklines, legend lines) are hidden from VoiceOver; rows are
  combined into one element; titles are marked as headers.
- Reduce Motion removes every animation; the pulsing dot stops.
- Everything follows Dynamic Type text styles except tiny tags (fixed 10.5 pt, always paired with
  readable text).
- Destructive actions are never the default button; sheets have a Cancel bound to Escape.
- Context menus duplicate row actions (block, copy) for keyboard and VoiceOver users.
