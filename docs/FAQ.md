# Pelmet FAQ

**Which macOS versions does Pelmet support?**
macOS 27 ("Golden Gate") only. Pelmet is built natively on macOS 27's new menu
bar architecture rather than the window-juggling tricks older managers use.
That's why it's smooth, and why it can't run on macOS 26 or earlier.

**Why do some icons hide or move together?**
macOS hides items per *app*, not per icon. If an app puts several icons in the
menu bar, they share one visibility setting. The layout editor shows these as
a grouped "moves together" badge.

**An icon I didn't hide disappeared (AirDrop, Focus, a running Timer, fast user switching).**
While hiding is active, macOS itself temporarily removes a few of its own
extras. Pelmet can't exempt them individually, they come back the moment hiding
is off. Pelmet ships its own replacements for the common ones (media controls,
AirDrop, camera/mic indicator, Shortcuts, a timer, Focus, fast user switching).
Add them in Settings → Menu Bar. The timer is Pelmet's own: it counts down in
the bar and rings, but it can't show a timer started in Clock or with Siri,
since macOS keeps that one to itself. The Focus item follows the real thing:
it shows the Focus that is on, with its own icon, and a click opens the Focus
panel in Control Center. Media controls, Time Machine and Focus can sit in the
bar only while active or all the time, the choice is beside each toggle. To
turn any Pelmet item off from the bar, ⌘-drag it off.

**Stage Manager is the one with no Pelmet twin.**
Its menu bar icon is a Control Center control, and macOS takes every control
off the bar while hiding is on, whatever Pelmet allows. Unlike the others it
doesn't come back when Pelmet quits, so you have to add it again. Keep Stage
Manager in Control Center instead and toggle it from there, where hiding can't
reach it. Control Center → Edit Controls puts it in.

**How does clicking the clock open Notification Center?**
That's Pelmet working around macOS. While any icon is hidden, the system
refuses the clock's click to open Notification Center (the same lockdown exam
mode relies on), and nothing else can open it from outside. So Pelmet lets
everything show for the blink it takes the click to land, then hides again,
with a picture of the empty bar held over the strip so the hidden icons never
paint. The two-finger swipe from the right edge of the trackpad always works too.

**Why does Pelmet ask for Accessibility?**
It's how Pelmet sees the menu bar's items and their positions, and how clicking
a hidden item works without revealing everything. Required.

**Pelmet isn't in the Accessibility list. Do I add it by hand?**
It should appear on its own, toggled off, when Pelmet opens the pane. If the
row is missing, first check Pelmet is running from Applications, not from the
disk image or Downloads: macOS runs those copies from a temporary path, and a
grant recorded there dies with it. Move it, relaunch, and press Grant access
again. Adding the row with the + button works too.

**Why does Pelmet ask for Screen Recording? Do I need it?**
Only for the animation styles. macOS shows and hides menu bar icons with an
animation of its own that no app can turn off, so Pelmet's Instant, Smooth
and Fade styles play over it using two stills of the menu bar: one empty,
one with the icons. Nothing is recorded or kept. It's optional. Without it,
icons show and hide the way macOS does it. Onboarding offers it next to
Accessibility, and Settings > General > Permissions shows whether it's on.
macOS re-confirms Screen Recording roughly monthly for all apps. If the nag
bothers you, turn the permission off and keep going.

**Icon spacing.**
Settings → Behavior → Icon spacing is macOS's own gap between menu bar icons
(the same two preferences people set by hand), one slider, Apply to write it.
Pelmet relaunches itself and the system icons so the clock, Control Center and
its own items follow at once; every other app keeps the old spacing until it
next opens, or log out and back in to get them all. The setting is macOS's, so
it stays after Pelmet is removed: press Reset then Apply before uninstalling if
you want the default back.

**Some system icons can't be moved.**
Control Center and the clock hide like any system icon but never move and get
no launcher (icons macOS hosts itself share one bundle, so a launcher for one
would draw nothing); their tiles say so.
Siri and Time Machine are a special case: macOS draws them from one process, so they hide together
as one tile, and macOS pins their spot, so the editor can't move them. To
manage them one by one, turn on Pelmet's own Time Machine and Siri items in
Settings → Menu Bar: each gets its own tile, moves and hides like any icon,
and Apple's icon switches off in System Settings → Menu Bar while Pelmet's is
on (it comes back when you turn Pelmet's off). Pelmet's Time Machine item
shows the latest backup, backs up now, skips a running backup and opens the
backup browser, the same menu as Apple's.

<a name="app-launchers"></a>
**One app's icon won't hide, and the editor marks it with a "!".**
A few apps draw their menu bar icon from a helper program that isn't a
registered app (ChatGPT Classic, Little Snitch's monitor, some iStat helpers).
macOS hides icons by the app that owns them, and a helper like that has no app
identity to hide, so Pelmet can move the icon but never conceal it. The fix is
an app launcher: turn the icon off in the app's own settings (usually a "Show in
menu bar" switch), then go to Settings → Menu Bar → App launchers and add the
app. Pelmet draws its own icon for it, which hides like anything else, and a
click opens the app. "Always shows" keeps the icon in the bar whether or not the app
is open; "Only while app is running" mirrors what the app's own icon did. Right-click a launcher to quit the
app. Shortcut: right-click the marked icon in the editor and choose "Add a
launcher", it lands in the same section of the drawing and Apply places it.

App launchers work for any app, not only problem ones — a launcher parked in
a hidden section is a tidy way to reach an app you use now and then.

**Why doesn't the bar change when I move an icon in the editor?**
The editor is a drawing the bar follows. Reorder icons or move them between
sections, then press Apply. It lays the whole bar out in one pass and reports
what it did next to the button. Or leave it, and Dimble does it the next time
you pause. A new separator waits for Apply. If you change your mind, drag the
icon back. An icon dragged to another section hides with that section at once,
and its tile says so until it's in place.

**After updating, Apply shows a pending change I didn't make.**
0.2.x stored an order for each section and moved icons to match it. 0.3.0 only
records where your icons are. If the stored order differs from what's on
screen, it shows up once as a pending edit. Press Apply to put that order
back, or leave it and your next pause keeps the bar as it stands.

**My bar is full and an icon sits behind macOS's «. Can Pelmet move it?**
Apply opens the « for an icon drawn behind it, moves it, and closes the «
again. It only clicks the « while you press Apply, never on its own. An edit
for an icon it could not reach stays pending.

**Can I have different layouts on each display?**
macOS mirrors the same items on every display, so layouts are global. What
*is* per-display is behavior. Set a display to "always show" or "collapse",
and whichever display your pointer is on wins.

**Does Pelmet use private APIs?**
One, deliberately: the hide/show mechanism itself. macOS 27 can hide menu bar
items natively (it's how the system's assessment/exam mode works), but the API
lives in a private framework (`MenuBarClientCore`) with no public equivalent.
Pelmet resolves it at runtime and fails soft. If a macOS update changes or
removes it, Pelmet reports hiding as unavailable instead of misbehaving, and
macOS restores the bar on its own (the hide assertion is process-bound).
Everything else uses public APIs. This is also why Pelmet can't be on the App
Store.

**Could a macOS update break Pelmet?**
It could, see above. The failure mode is graceful (icons just stay visible),
and updates ship through Sparkle, so a fix arrives without you doing anything.

**Is Pelmet sandboxed?**
No. Managing the menu bar requires APIs the App Store sandbox forbids. Pelmet
is notarized by Apple, ships with the hardened runtime, and updates are signed
(Sparkle, EdDSA).

**How do updates work?**
Pelmet checks a signed appcast and offers updates in-app (Sparkle). You can
check manually in Settings → About.

**How do I get fixes sooner?**
Turn on "Get beta releases" in Settings → About (0.2.41 or later). Betas are
smaller updates, more often; a stable release rolls them up every week or
two. Turning it off keeps you on your current build until the next stable
passes it.

**Is there a keyboard shortcut?**
A few, and they work from any app. ⌥⌘, shows the hidden icons and puts them
back on the next press (with auto-rehide set to Instant, they also go back
once the pointer leaves the bar or you click elsewhere). ⌃⌥⌘, does the same
with the always-hidden ones too. ⌥⌘K opens Pelmet Search. ⇧⌥⌘, opens Pelmet
Settings, so it's the way in when the Pelmet icon is off. Change any of them
in Settings → General: click the shortcut, press the new keys. The × next to
a custom shortcut, or ⌫ while recording, brings the default back. ⌥⌘N opens
Notification Center and lives in Settings → Behavior, under the clock setting.

**How do I open Settings if I turned the Pelmet icon off?**
Any of: press ⇧⌥⌘, (or the shortcut you recorded), right-click a Pelmet
separator, right-click empty menu bar space, or launch Pelmet again from
Finder/Spotlight.

**Right-clicking the menu bar opens Pelmet's menu and I don't want it to.**
Settings → General → "Right-click menu". Turn it off
and an empty-space right-click is left to whatever else wants it — an app that
draws its own surface across the bar, say. Right-clicking a Pelmet separator
still opens the menu, and the shortcut still works. The switch is locked on
while the Pelmet icon is hidden, because then it is the way back to Settings.

**Can I change the Pelmet icon?**
Settings → General → Icon. Seven styles: chevron, arrow, eye, dots, grid,
panel and dot. Chevron, arrow, eye and panel flip to a revealed face while the
bar is open, so the icon keeps pointing at what a click will do. The dot is
filled while the icons are hidden and an outline while they're shown.

**How short can the hover delay be?**
0.1 to 0.5 seconds, in 0.1 steps. Auto-rehide runs from instant to 5 seconds
in half-second steps. Both live in Settings → Behavior.

**Hovering the left side of the menu bar doesn't reveal anything. Neither does the clock.**
On purpose. The hover and click reveals listen on one stretch of the bar: from
the middle of the screen to Pelmet's icon, where the hidden icons land.
Reaching for an app's menus on the left leaves the bar alone, and so does
anything right of Pelmet's icon: your visible icons, Control Center, the clock.
Pelmet's icon itself toggles on click.

**I'm developing an app in Xcode and its menu bar icon disappears while Pelmet runs.**
A macOS limitation with no setting for it. The system's menu-bar hiding mechanism
matches apps by their LaunchServices registration, and apps running out of
Xcode's DerivedData never match, so they get hidden no matter which section
they're in. Run your development build from /Applications (copy it there, or
archive-export), or quit Pelmet while iterating. Everything behaves normally
for the same app once it runs from a stable location.
