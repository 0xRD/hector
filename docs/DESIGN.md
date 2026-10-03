# Hector design brief

Hector is a small, all-in-one security app for macOS. It watches what your Mac talks to, what
starts by itself and what runs, and it tells you plainly when something is worth a look.
**Netbite** is the name of its network module (the live map and list of connections, and
blocking). The whole app was called Netbite up to 0.3.

The code lives in `Sources/HectorApp/Design/` (tokens, components, brand marks). Network-only
pieces (status of a destination, country badge, sparkline) stay in `Views/Theme.swift`.

## 1. The idea

*The one who holds fast.* Hector is named after the defender of Troy: not a conqueror, the one
who stands on the walls and keeps the city safe. As a character he is warm, calm, a bit vintage
and a little quirky, someone you would trust with your Mac the way you trust a good neighbour
with your keys. He does not shout. He looks, he tells you what he saw, and he lets you decide.

Security tools tend to shout: red dashboards, alarm icons, gauges. Hector is the opposite. It is
a quiet, well-lit study: warm paper, soft colors, clear verdicts, and a friendly face behind a
helmet. Calm by default, very clear when something deserves a look, never alarmist.

- **Friendly but serious.** The personality lives in the mark, the app icon, the empty states and
  a few words of copy. Verdicts, warnings and destructive actions stay plain.
- **Calm and refined.** Warm neutrals, generous whitespace, soft rounded shapes, a serif for
  titles, as in Claude's own interface.
- **Native first.** It must feel like a Mac app: standard sidebars, toolbars, inspectors,
  search, menus, keyboard and VoiceOver. We restyle content, never the system chrome.

### How the modules sit together

Hector is the app and the character; each module is one part of the watch he keeps. A module is
one sidebar section or entry, one `ScreenHeader`, and speaks the same verdict language
(section 7).

| Module | What it watches | Status | Glyph |
|---|---|---|---|
| **Hector** (the app) | Brand, app icon, About, settings, onboarding | shipped | `HectorMark`: the crested helmet |
| **Netbite** (network) | Live connections per app, the world map, Blocklists (pf and `/etc/hosts`) | shipped | `NetbiteLogo`: globe with a bite |
| **Persistence** | What starts by itself: launch agents and daemons, login items, extensions, profiles | shipped | `arrow.triangle.2.circlepath` on a hexagon `SymbolTile` |
| **Processes** | What runs now: tree, signatures, flags, VirusTotal | shipped | `cpu` on a hexagon `SymbolTile` |
| Security checkup | The Mac's own defenses: FileVault, firewall, Gatekeeper, SIP, updates | planned | for example `checklist` on a hexagon tile |
| Keyboard taps | Who can read the keyboard (event taps, input monitoring) | planned | for example `keyboard` on a hexagon tile |
| Camera & microphone | Who is using them now, and who may | planned | for example `video` or `mic` on a hexagon tile |

Only Netbite has its own drawn glyph, because it had a name before Hector did. New modules use an
SF Symbol on a hexagon tile, in lavender (`hectorInfo`) unless their color carries meaning
(Blocklists are clay). The Netbite glyph appears where the network module is named (the map
header today, its sidebar section later).

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
6. **Respect the platform.** Sidebar, content, inspector; toolbar search, context menus,
   standard shortcuts, Reduce Motion, Increase Contrast, Dynamic colors, VoiceOver labels.

## 3. Tone of voice

Hector speaks in short, warm, plain sentences. He reports what he saw, says what it means, and
offers the next step. He is never alarmist, and never cute when something is wrong.

- **Short and plain.** One idea per sentence. Sentence case everywhere, except button titles and
  menu items, which use title case (macOS convention): "Block This Destination", "Download Again".
- **Calm, never alarmist.** "3 items to review", not "3 THREATS DETECTED". No exclamation marks.
- **Hector may speak in the third person**, sparingly, where it makes a message warmer: empty
  states, progress, errors ("Hector is looking around…", "Hector could not finish that").
  Never "I", never "we".
- **Honest about limits.** "Blocking is for the whole Mac" explains why, in one sentence.
- **A little warmth, in the right places only.** Empty states, progress and success may be
  light. Verdicts, warnings, errors and anything destructive stay plain and exact.
- **No jargon without a gloss.** "pf (the macOS firewall)", "SHA-256 (a fingerprint of the file,
  never the file itself)".
- Ellipsis (…) on any command that asks for more (a password, a confirmation), and on progress
  ("Scanning…").

| Do | Don't |
|---|---|
| All quiet. | No threats detected! Your Mac is 100 % safe! |
| Hector found 2 items worth a look. | WARNING: 2 suspicious items found |
| Nothing is blocked yet. | Your blocklist is empty :( |
| Hector is looking around… | Scanning for malware, please wait… |
| Hector could not finish that. *(then the reason, verbatim)* | Oops! Something went wrong. |
| Unsigned | Sketchy, Evil, Nope |
| Uninstall Hector… "There is no undo: rules, helper and data are deleted." | Bye-bye, Hector! |
| Install the helper to block. | You are not protected! |

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
| ok (sage) | safe, allowed, live, verified | `#3D7054` | `#8CC79E` | `#DEEBDB` | `#304036` | `hectorOK`, `hectorOKWash` |
| danger (clay) | blocked, malicious, destructive | `#A84230` | `#F29985` | `#F7E0D6` | `#4C302B` | `hectorDanger`, `hectorDangerWash` |
| warning (honey) | needs a look, pending | `#875E0D` | `#EBC475` | `#FAEBC9` | `#473B24` | `hectorWarning`, `hectorWarningWash` |
| info (lavender) | information, brand | `#6954A3` | `#C2B2F2` | `#EBE6FA` | `#3B364F` | `hectorInfo`, `hectorInfoWash` |
| neutral (stone) | unknown, inactive, not checked | `#6B665E` | `#B2ABA1` | `#EBE6DE` | `#3D3B38` | `hectorNeutral`, `hectorNeutralWash` |

Control tints: `hectorTint` (sage, `#3D7054` / `#5C9475`) is the app-wide tint (selection,
prominent buttons). `hectorDangerTint` (clay, `#A84230` / `#B2614F`) is for destructive prominent
buttons and "block" switches.

The former `netbiteAccent` and `netbiteBlock` became `hectorOK` and `hectorDanger`.

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
neutral. Use `Color.hectorWarning` instead of `.orange`.

## 8. Iconography and brand marks

- **SF Symbols** everywhere, in their filled variant for verdicts and their outline variant for
  navigation and actions. No custom bitmap icons.
- **Hexagon tiles** (`SymbolTile`) give screens and sidebar entries their identity: a symbol in
  the module's ink on its 16 % wash, inside a rounded hexagon, like the badge on a shield.
  Rounded squares and circles exist for secondary uses (avatars, inline list icons).
- App bundles keep their real icon (`AppIcon`, `PathIcon`); tools and daemons get a symbol on a
  stone tile.
- On a selected row, tiles and pills switch to white automatically (`backgroundProminence`).

### The mark: `HectorMark`

Hector seen from the front: a rounded **Corinthian helmet** with a **crest** of horsehair, and a
calm **face** behind the visor. Drawn in code on a 24 × 24 grid (`BrandGeometry`).

- **Helmet**: a soft dome and two cheek guards, one closed contour with a T-shaped opening (the
  visor slot and the gap between the cheek guards). Soft lavender shading downward, lavender
  ink outline.
- **Crest**: a clay fan of horsehair flaring out of the dome, with two combed strands. It **leans about 7° to the left**: the one quirk of
  the mark, the cowlick of a defender who has been up since dawn.
- **Face**: cream, seen through the visor; two round eyes looking straight out, a small closed
  smile in the gap, and the chin peeking just below the cheek guards.
- **Sizes**: below 28 pt the mark drops its small details (eyes, smile, crest strands, the shine
  on the dome) and keeps the silhouette, the visor and the crest, which read at 16 pt. Pass
  `detailed:` to force either way.
- **Colors**: `ink` `hectorInfo`, `helmet` `hectorHelmet` to `hectorHelmetShade`, `crest`
  `hectorCrest` (a brand-only clay, never used for a verdict), `face` `brandCream`. It follows
  light and dark mode; the cream face stays light in both, so the visor always reads.
- Do not give it a sword or a spear, do not make it frown, do not straighten the crest.

### The app icon: `AppIconArtwork`

**Hector on the walls of Troy.** A squircle on the macOS icon grid (412 pt body in a 512 pt
canvas, continuous corners): a lavender-to-cream dawn sky (`brandSky` to `brandCream`), a honey
sun rising behind his shoulder (`brandHoney`), the mark in its fixed brand colors (lavender helmet
shading to a deeper lavender, clay crest, cream face, plum outline), and a sandstone rampart
(`RampartPattern`: a coping over staggered ashlar courses) that he peeks over. Drawn in code at
launch and set as the Dock icon (`AppIconArtwork.render(size:)`).

### Wordmark: `HectorWordmark`

The mark and "Hector" in New York semibold, slightly tight tracking. For About (Settings, About
tab), onboarding, and any place where Hector introduces himself.

### Netbite glyph: `NetbiteLogo`

The bitten globe, sage, for the network module. It keeps its own drawing as a member of the
family: same 24-point grid, similar stroke weight, rounded caps.

### Brand tokens

| Token | Value | Use |
|---|---|---|
| `hectorCrest` | `#CC7357` light, `#E68F73` dark | The crest in the in-app mark |
| `hectorHelmet`, `hectorHelmetShade` | `#CCBFF5` / `#B09EE8` light, `#665994` / `#544775` dark | The helmet in the in-app mark |
| `brandPlum` | `#33293D` | Outlines of the icon artwork |
| `brandCream` | `#FAF2E6` | Face of the mark, bottom of the icon sky |
| `brandSky` | `#E3DEFA` | Top of the icon sky |
| `brandLavender`, `brandLavenderDeep` | `#C7B8F7`, `#9E8CDE` | The helmet on the icon |
| `brandClay` | `#DB785C` | The crest on the icon |
| `brandHoney` | `#FAD180` | The sun on the icon |
| `brandStone`, `brandStoneDeep` | `#E3D1B8`, `#BDA68A` | The rampart and its joints |

## 9. Motion

- Short and functional: hover 0.12 s (`Motion.quick`), selection and appearance 0.25 s snappy
  (`Motion.standard`), layout 0.4 s smooth (`Motion.gentle`).
- Always through `.motion(_:value:)`, which drops the animation under **Reduce Motion**.
- One ambient animation only: the "live" dot of the status bar breathes slowly (`StatusDot`
  with `pulsing: true`, off under Reduce Motion and while paused). Nothing else loops.
- Numbers change with a numeric content transition (`Metric`).

## 10. Components

All in `Sources/HectorApp/Design/Components.swift`, documented with `///` comments.

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
| `EmptyStateView(title, systemImage:, message:, tint:, compact:) { actions }` | Symbol tile inside a dashed hexagon halo rotated 30°, serif title, one-line message, optional actions. Fills its container unless compact. |
| `DetailRow(label, value:, monospaced:)` / `DetailRow(label) { view }` | Label in a 104 pt secondary column, value selectable; combined for VoiceOver. |
| `Metric(value, label:, tint:)` | Rounded tabular number over a caption. |
| `SymbolTile(systemImage, tint:, size:, shape:)` | Hexagon (default), rounded square or circle tile. |
| `SidebarLabel(title, subtitle:, systemImage:, tint:) { accessory }` | 26 pt hexagon tile, medium title, caption subtitle, trailing accessory (count pill, sparkline). |
| `CodeTag(text, tint:)` | Monospaced 10.5 pt tag with hairline, radius 4. |
| `Hexagon(cornerRadius:)` | The badge shape of tiles and of the empty-state halo. |
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
  symbol inside a dashed hexagon halo, and one warm line at most.
- **Claude:** warm neutrals, cream canvas, serif titles, generous whitespace, soft radii, and a
  name that is a person rather than a product: a character you trust, who speaks plainly.

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
