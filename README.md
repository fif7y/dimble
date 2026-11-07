<p align="center">
  <img src="docs/assets/hero.svg" alt="Dimble, a calm menu bar for macOS" width="800">
</p>

<p align="center">
  <a href="https://dimble.fif7y.com"><img src="https://img.shields.io/badge/website-dimble.fif7y.com-6841ED" alt="Website: dimble.fif7y.com"></a>
  <a href="https://github.com/fif7y/dimble/releases/latest"><img src="https://img.shields.io/github/v/release/fif7y/dimble?label=download&color=2ea44f" alt="Download latest release"></a>
  <a href="#install"><img src="https://img.shields.io/badge/requirements-macOS_27%2B-E8A33D" alt="Requires macOS 27 or later"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/fif7y/dimble" alt="License: GPL-3.0"></a>
  <a href="https://alternativeto.net/software/pelmet/about/"><img src="https://img.shields.io/badge/AlternativeTo-Pelmet-1f6feb" alt="Pelmet on AlternativeTo"></a>
  <a href="https://github.com/sponsors/fif7y"><img src="https://img.shields.io/badge/sponsor-%E2%9D%A4-ea4aaa" alt="Sponsor Dimble"></a>
</p>

Dimble hides the icons you don't need until you do. Hover, click or press a
shortcut and they slide back in, or open in a panel. Small on purpose (three
sections, an editor, ⌘-drag in the bar) and native all the way down. macOS does
the hiding. Built for the menu bar Apple rebuilt in macOS 27. Free, open source,
no account, no analytics.

> [!TIP]
> **Beta channel.** Fixes and new features land there first, a stable release
> rolls them up every week or two. Turn on "Get beta releases" in
> Settings › About, or download the latest beta:
>
> [![Latest beta](https://img.shields.io/github/v/release/fif7y/dimble?include_prereleases&filter=*beta*&label=latest%20beta&color=6841ED)](https://github.com/fif7y/dimble/releases?q=prerelease%3Atrue)

<p align="center">
  <img src="https://dimble.fif7y.com/assets/bar-reveal.svg" alt="The menu bar on a hover. Hidden icons slide out from behind the chevron, then tuck back in" width="575"><br>
  <sub>Collapsed, and a hover later.</sub>
</p>

## Choose what stays

Three sections, one rule: **Visible** is always there, **Hidden** comes back
on a hover or a click, and **Always Hidden** only appears when you ask for it
(double-click or ⌥-click the chevron). Arrange them in the layout editor
(real app-icon previews, drag-and-drop ordering): the editor is a drawing
the bar follows, and **Apply** lays the bar out to match it in one pass. Or
skip the window entirely and ⌘-drag icons across the chevron right in the
menu bar. Dimble records that move in
the editor and leaves the rest where they are. And when macOS or an app
shifts an icon out of that order, Dimble puts it back on its own the next
time you pause.

<p align="center">
  <img src="https://dimble.fif7y.com/assets/apply-loop.gif" alt="The layout editor under the menu bar: Spotify is dragged from Hidden to Visible, nothing moves in the bar, Apply lights up, one press and Spotify appears in the bar" width="640"><br>
  <sub>The layout editor is a drawing the bar follows. Drag Spotify to Visible and nothing moves yet. Press Apply and it's there. Or leave it, and Dimble does it the next time you pause.</sub>
</p>

Apply reveals what it needs, lays the whole bar out in one pass with the
pointer hidden for a moment, and reports what it did next to the button. On a
full bar it opens macOS's own « for an icon drawn behind it, moves it, and
closes the « again. A "New items" tile shows where icons Dimble has never seen
will land. Updating leaves your bar alone. The first time Dimble sees a
section out of order, it takes that section's order from the bar instead of
moving anything. And a pending update shows as a banner on every Settings
pane, with a daily reminder until you install it.

System icons hide too. Sound, Battery and friends behave like any
other icon. The few macOS protects (Clock, Control Center) are shown
locked in the editor rather than pretended away, and anything macOS groups together
gets an honest badge instead of a fake handle. Siri and Time Machine, which
macOS only hides as a pair, come as Dimble's own items so each can go
wherever you like.

## Reveal on your terms

Every way back in is a setting: hover (with a delay from 0.1 to 0.5 seconds),
a click on empty menu bar space, a double-click for the always-hidden section,
or the chevron itself. The keyboard works too, from any app. ⌥⌘, shows the
hidden icons and ⌃⌥⌘, brings the always-hidden ones with them (you can change
both in Settings › General). Pick how it looks (**Instant**, **Smooth** or **Fade**)
and how it ends, either auto-rehide after a delay you set (instant to 5
seconds) or the moment you click somewhere else.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: light)" srcset="docs/assets/screenshot-settings-light.png">
    <img src="docs/assets/screenshot-settings.png" alt="Behavior pane: Instant, Smooth and Fade animation cards with a live preview, the icon spacing slider with its Apply button, Reveal on hover with a delay menu, reveal on click in empty space and double-click for Always Hidden, Hide again after a delay you pick or when you click elsewhere, and the Notification Center clock click" width="640">
  </picture><br>
  <sub>Your rules for revealing, and for putting everything back.</sub>
</p>

## Hidden icons in a panel

Hidden icons don't have to slide back into the bar. Turn on Panel and they open as tiles in a panel under the menu bar, and the bar stays put. Each tile is a picture of the real icon, and a click opens that icon's real menu. Settings › Panel has the switch, with Menu bar as the default and Row as the same tiles in one strip. It's the big new feature in 0.3.2 (#26).

- **Always Hidden sits behind a fold.** Click the fold at the end of the panel to open it.
- **Type to find.** Start typing and press Return. The top match's menu opens, and Esc closes the panel.
- **Drag tiles around.** Reorder a tile in its section, or drop it on another one. Drag it up onto the bar to show it there.
- **⌘-drag from the bar.** Drop an icon on the panel and it's filed in the section under the pointer.

<p align="center">
  <img src="https://dimble.fif7y.com/assets/panel.gif" alt="The hidden icons in a panel: a hover opens the panel under the menu bar, a click on the +3 fold opens Always Hidden, typing ta narrows it to Tailscale, Return closes the panel and Tailscale's menu drops from its own icon" width="640"><br>
  <sub>Hover, open the fold, type "ta", Return. Tailscale's menu drops from its own icon.</sub>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: light)" srcset="https://dimble.fif7y.com/assets/settings-panel-light.png">
    <img src="https://dimble.fif7y.com/assets/settings-panel-dark.png" alt="Panel pane: the Menu bar, Panel and Row choice for where hidden icons open, a live preview of the panel, and the columns, fold style, Always Hidden, show names, closed apps and separator options" width="640">
  </picture><br>
  <sub>Where hidden icons open, and how the panel looks.</sub>
</p>

## Search the menu bar

Press ⌥⌘K, type a few letters, press Return, and that icon's menu opens right
from its real icon, hidden or not. The arrow keys work in the menu like they
normally do. Search knows the short names people type (bt, wifi) and puts the
icons you open most first. It finds Dimble's settings too, and ⌘K on a result
moves it to another section or gives it its own shortcut. What it learns
stays on your Mac. New in 0.3.1.

<p align="center">
  <img src="https://dimble.fif7y.com/assets/search.gif" alt="Dimble Search: ⌥⌘K opens a search panel under the menu bar, typing bt finds Bluetooth, Return opens Bluetooth's menu from its own icon and the arrow keys move down it" width="640"><br>
  <sub>⌥⌘K, "bt", Return. Bluetooth's menu drops from its own icon.</sub>
</p>

## Keep your Live Activities

A game's score, a Shortcut running: macOS shows those in a pill beside the
clock, and it takes the pill off the bar while your icons are hidden. Dimble
keeps it there. The pill sits next to the chevron for as long as the activity
runs, a click opens its card, and the system icons come back alongside it.
It's on by default, and it needs Screen Recording.
Settings › Menu Bar › "Show Live Activities" turns it off. New in 0.3.4.

<p align="center">
  <img src="https://dimble.fif7y.com/assets/live-bar.gif" alt="A hockey game's Live Activity next to the chevron while Dimble hides the rest of the icons: the pill comes out of the bar, a click opens its card, the score rolls from 2 to 3, a second click closes the card, and the pill goes away at the final buzzer" width="640"><br>
  <sub>The game's pill stays on the bar. A click opens its card.</sub>
</p>

## And the rest

- **Per-display behavior.** Set a display to always show everything or to
  collapse. Whichever display your pointer is on wins.
- **Built-in replacements.** Media controls, AirDrop, camera/mic indicator,
  a timer, Focus, fast user switching and Shortcuts items that survive hiding, since macOS temporarily removes
  its own extras while hiding is active. Media controls, Time Machine and Focus
  show when active or always, and a ⌘-drag off the bar turns any of them off.
- **App launchers.** A Dimble icon for any app: click opens it, and it hides
  like everything else. The fix for apps whose own icon can't be hidden (see
  the [FAQ](docs/FAQ.md#app-launchers)), and a handy launcher for the rest.
- **Separators.** Visual dividers that behave like icons, with adjustable
  opacity, edited on their tiles. A new one is part of the drawing until Apply
  places it. ⌘-drag them anywhere in the bar.
- **Nothing to phone home about.** No account, no analytics, no server.
  The only connection Dimble ever makes is checking for its own updates.
- **Signed updates.** Sparkle with EdDSA signatures, checked against a
  signed appcast.
- **Your icon, or none.** Seven menu bar icon styles (chevron, arrow, eye,
  dots, grid, panel, dot), or turn the icon off entirely and reach Settings by
  shortcut or right-click.
- **Tighter icons.** One slider for the gap macOS leaves between menu bar
  icons, down to 1 point. Dimble relaunches itself and the system icons so the
  clock and Control Center follow at once, other apps pick it up the next time
  they open.
- **Speaks your language.** English, German, French, Spanish, Italian,
  Portuguese (Brazil), Japanese, Simplified Chinese, Korean and Russian.
  Dimble follows your system language, or pick one in Settings › General ›
  Language. Translations are machine-drafted for now, corrections are welcome
  in `scripts/gen-xcstrings.py`.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: light)" srcset="docs/assets/screenshot-general-light.png">
    <img src="docs/assets/screenshot-general.png" alt="General settings: launch at login, the menu bar icon toggle with seven icon styles, the right-click menu, a Shortcuts card (show hidden icons, show Always Hidden too, search the menu bar, open Notification Center, open Settings), the display language picker and the Accessibility and Screen Recording permission status" width="640">
  </picture><br>
  <sub>General. Pick the icon Dimble wears, or your language.</sub>
</p>

## How it works

macOS 27's menu bar can hide items natively. It's the mechanism behind the
system's assessment (exam lockdown) mode. Dimble drives that mechanism directly.
It asserts a configuration listing what should stay visible, and macOS itself
hides the rest and reflows the bar. That's why hiding feels like part of the
system. It *is* the system.

The catch: this API lives in a **private Apple framework**
(`MenuBarClientCore`). It isn't documented or guaranteed, so a macOS update
could change or remove it. Dimble resolves it at runtime and fails soft. If the
API ever disappears, Dimble simply reports hiding as unavailable rather than
breaking your menu bar. Everything else (item positions, clicks, previews)
uses public APIs: Accessibility and ScreenCaptureKit.

## Install

Download the latest DMG from [Releases](https://github.com/fif7y/dimble/releases),
drag Dimble to Applications, and launch it. Or with Homebrew:

```sh
brew install --cask fif7y/tap/dimble
```

Requires **macOS 27 (Golden Gate)**. Earlier versions of macOS use a
different menu bar architecture that Dimble doesn't target.

On first launch Dimble asks for one permission:

- **Accessibility** (required). How Dimble sees the menu bar's items and
  positions, and how clicking a hidden item works without revealing
  everything.

Screen Recording is optional, offered next to Accessibility in onboarding
and skippable. The animation styles use it: macOS shows and hides icons
with an animation of its own, and Dimble's Instant, Smooth and Fade play
over it using two stills of the menu bar. Nothing is recorded or kept.
Without it, icons show and hide the way macOS does it.

Dimble is notarized by Apple and ships with the hardened runtime. It isn't
sandboxed, managing the menu bar requires APIs the App Store sandbox
forbids.

More in the [FAQ](docs/FAQ.md).

## Build from source

Requires Xcode with the macOS 27 SDK and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```sh
git clone https://github.com/fif7y/dimble.git
cd dimble
xcodegen
xcodebuild -project Pelmet.xcodeproj -scheme Pelmet -configuration Release build
```

The engine logic lives in two local Swift packages, `Packages/PelmetCore`
(section model, rehide state machine) and `Packages/PelmetEngine` (menu bar
convergence), each with its own test suite:

```sh
swift test --package-path Packages/PelmetCore
swift test --package-path Packages/PelmetEngine
```

UI strings live in `Pelmet/Resources/Localizable.xcstrings`, generated from
the translation table in `scripts/gen-xcstrings.py`. Edit the script, re-run
it, commit both. English keys must match the code literals exactly.

## Why "Dimble"

*dimble* (n.), a secluded hollow, a hiding place. Now also the same thing, for
your menu bar's icons. It was called Pelmet up to 0.3.1, and Pliss for one beta.

## Licenses & acknowledgements

Dimble's macOS 27 approach is based on the work of [Thaw](https://github.com/thaw-app/Thaw),
whose maintainers worked out how the rebuilt menu bar can be managed, in public, during
the macOS 27 betas ([thaw-app/Thaw#687](https://github.com/thaw-app/Thaw/issues/687)).
Thaw is a fork of [Ice](https://github.com/jordanbaird/Ice), the open-source menu bar
manager for earlier versions of macOS, which is what got Dimble started in the first place.

Dimble's only third-party dependency is
[Sparkle](https://github.com/sparkle-project/Sparkle) (in-app updates), used
under the [MIT-style Sparkle license](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE).
Everything else is custom code on top of Apple's system frameworks.

## License

© 2026 Gabriel Faucon. Licensed under the
[GNU General Public License v3.0](LICENSE). Use it, fork it.
Distributed derivatives must remain open under the same license.

Dimble is an independent project, not affiliated with or endorsed by Apple Inc.
Apple, macOS, and the Mac are trademarks of Apple Inc.
