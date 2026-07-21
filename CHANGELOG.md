# Changelog

All notable Y-Dock release changes are tracked here.

## v1.1.19 - 2026-07-22

- Updated the release pipeline to produce separate thin Apple Silicon (`arm64`) and Intel (`x86_64`) DMGs, with independent build directories, signing, notarization, stapling, Gatekeeper checks, final DMG mounts, and strict architecture assertions.
- Changed automatic updates to require the exact architecture-specific asset name instead of selecting the first DMG in a GitHub release.
- Added a strict thin-binary check for the mounted update App's main executable before replacement, so wrong-architecture or universal downloads stop without deleting the installed App.
- Missing architecture assets now fail safely and direct users to the GitHub Release page; standalone tests cover ordering, unrelated DMGs, missing matches, and executable architecture validation.

## v1.1.18 - 2026-07-21

- Added a hover-only close control to each `Option+Tab` window card, rendered as a neutral translucent overlay directly over the app icon.
- Closing a card now closes only that window without activating it, keeps the switcher session open, and preserves the selected window whenever possible.
- Prevented asynchronously collected minimized windows from re-adding a window that was already closed during the current switcher session.

## v1.1.17 - 2026-07-21

- Stabilized Dock hover detection with trailing-edge mouse resolution, short Accessibility hit-test retries, transient-miss tolerance, and a larger auto-hidden or magnified Dock detection region.
- Made Dock preview panels appear on schedule with lightweight cached or placeholder cards while thumbnails load in the background.
- Changed wrapped Dock preview rows to place fewer cards above and fuller rows below.
- Restored Windows-style `Option+Tab` startup selection: the second MRU window is selected when available, with a safe single-window fallback.
- Filtered `Esc` key-down, auto-repeat, and matching key-up while the switcher is open so cancellation does not reach the underlying app.

## v1.1.16 - 2026-07-20

- Rebuilt the drag-to-install DMG with a light high-contrast 2x Retina background, keeping Finder's black app labels crisp and readable in light and dark system appearances.
- Removed visible `.background` and `.fseventsd` folders from the final image, hid Finder's toolbar, status bar, path bar, and tab bar, and aligned the installation arrow from the saved Y-Dock and Applications icon coordinates.

## v1.1.15 - 2026-07-20

- Redesigned the menu bar template icon as two offset window outlines above a light rounded Dock line, replacing the heavy solid mark with a clearer window-preview symbol that adapts to light and dark menu bars.

## v1.1.14 - 2026-07-19

- Notarizes and staples the signed Y-Dock app bundle before packaging it into the DMG, then validates the embedded app ticket again after the final image is mounted.
- Treats a missing stapled ticket as a release failure even when `stapler validate` returns a successful process status with a diagnostic message.

## v1.1.13 - 2026-07-19

- Unified first-launch and later Accessibility and Screen Recording guidance through the shared Y-Project permission prompt framework while preserving the app-specific missing, restart-required, and active states.
- Added the shared Y-Project DMG presentation framework to the release pipeline, including a dynamically rendered Y-Dock background, validated Finder layout, Applications link, and final read-only remount checks.
- Relaunches now use LaunchServices without forcing a second app instance.

## v1.1.12 - 2026-07-18

- Constrained the shared settings window to the active display so controls remain reachable on compact or scaled screens.
- Validated settings preview section identifiers before changing navigation state.
- Added runtime diagnostics that distinguish the verified signed `/Applications` copy from development copies and can switch directly to the installed app.
- Split Screen Recording into missing, restart-required, and active states; opening System Settings no longer implies authorization, and restart-required is set only after a granted request still needs process reload.
- Disabled the development-copy restart/switch action unless a valid signed `/Applications/Y-Dock.app` is available.
- Scoped Accessibility and Screen Capture TCC refreshes to Y-Dock's bundle identifier.
- Hardened direct updates by rejecting symlinked or wrong-identity app bundles before replacing the installed copy, while retaining code-signing and Gatekeeper checks.
- Kept the shared Y-Project settings framework as the sole settings component system.

## v1.1.11 - 2026-07-13

- Fixed the first `Option+Tab` invocation selecting the second card; it now starts on the first card in the displayed list.
- Changed switcher ordering from visible-window Z-order to strict most-recently-focused window order for both visible and minimized windows.
- Added event-driven Accessibility focus tracking with the existing lightweight polling path retained as a fallback.
- Added ellipsis-aware AX/CG title matching so Chromium windows remain attached to the correct focus-history entry.

## v1.1.10 - 2026-07-13

- Fixed Edge/Chromium multi-window activation when CGWindow titles are truncated with ellipses but AXWindow titles are full browser titles.
- Avoided reusing stale geometry-only AX window cache entries, which could focus the previous browser window when two windows share the same frame.
- Strengthened the Accessibility focus sequence with repeated raise/focused-window/main-window updates for stubborn same-app windows.
- Ensured the shared Y-Project settings framework remains in the Xcode target sources.

## v1.1.9 - 2026-06-28

- Reworked settings from the menu bar popover into an independent sidebar settings window using the shared Y-Project settings shell.
- Simplified the menu bar item to open settings, reserve a More Y-Project entry, and quit the app.
- Preserved existing preview tuning, permission, update, launch-at-login, and debug controls inside the new settings window.
- Vendored the shared Y-Project settings framework so the repository can be built independently from GitHub source checkouts.

## v1.1.8 - 2026-06-27

- Changed Dock right-click handling to immediately close the hover preview and keep previews suppressed until the context-menu interaction ends, avoiding menu misclicks and lower-layer preview stalls.

## v1.1.7 - 2026-06-27

- Kept Dock hover previews below the Dock context menu for the full right-click menu session, even if the mouse moves away and returns before the menu is dismissed.

## v1.1.6 - 2026-06-27

- Kept Dock hover state intact when right-clicking Dock icons, while temporarily deferring the preview panel below the Dock context menu.
- Restored the preview panel's normal level after the Dock context menu closes, so app-name tooltip coverage still works during regular hover.

## v1.1.5 - 2026-06-27

- Hide the Dock hover preview immediately when right-clicking in the Dock so the system Dock context menu is not covered.

## v1.1.4 - 2026-06-25

- Enlarged the menu bar template icon so the solid hollow-window mark reads more clearly at status-bar size.

## v1.1.3 - 2026-06-25

- Redesigned the menu bar icon as a simpler solid template mark with a hollow window shape and compact Dock base.

## v1.1.2 - 2026-06-25

- Made Dock hover preview cards use near-opaque adaptive gray or white backgrounds so window names stay readable on bright desktops.
- Added a subtle AppKit visual-effect backdrop behind Dock hover preview cards without letting the desktop content bleed through the title row.

## v1.1.1 - 2026-06-25

- Reworked `Option+Tab` ordering to follow the Windows Alt+Tab model more closely: visible windows keep current front-to-back Z-order, while minimized windows stay behind visible windows and use focus history only as a fallback.
- Darkened Dock hover preview card backgrounds and borders so their outer edges remain visible on bright or busy desktops.
- Increased the Dock hover preview title row by about 20% for more legible window names.
- Prepared a signed and notarized DMG for updating local installations.

## v1.1.0 - 2026-06-25

- Changed `Option+Tab` ordering to follow recent focus history, so pressing it once returns to the previously focused window.
- Kept the `Option+Tab` hotkey path faster by showing visible windows immediately and loading minimized windows and thumbnails in the background.
- Added direct in-app updating from GitHub releases: Y-Dock can download the notarized DMG, replace the installed app, and relaunch without manual drag-and-drop.
- Prepared a signed and notarized DMG for updating local installations.

## v1.0.9 - 2026-06-24

- Fixed `Option+Tab` switcher cards being stretched across the full panel by locking each card to its computed proportional thumbnail size.
- Improved the Dock-to-preview hover protection path so the gap between the Dock and preview panel no longer schedules an early close when Dock hit-testing briefly fails.
- Prepared a signed and notarized DMG for updating local installations.

## v1.0.8 - 2026-06-24

- Fixed `Option+Tab` thumbnails preserving the wrong captured image aspect ratio, which could make narrow windows such as WeChat look flattened.
- Kept cached and minimized-window thumbnail redraws proportional when they are fitted into narrow cards.
- Prepared a signed and notarized DMG for updating local installations.

## v1.0.7 - 2026-06-24

- Added a wider Dock-to-preview hover protection bridge so moving from the Dock into the preview panel no longer closes the panel through the visual gap.
- Removed the fixed minimum width from `Option+Tab` window cards so narrow windows keep their proportional scaled width at the shared thumbnail height.
- Prepared a signed DMG for updating local installations.

## v1.0.6 - 2026-06-24

- Replaced the menu bar status icon with a simpler line-only template icon.
- Kept the icon taller and more balanced at small menu bar sizes.
- Prepared a signed DMG for updating local installations.

## v1.0.5 - 2026-06-24

- Resized the `Option+Tab` switcher back toward the `v1.0.3` scale, keeping it only 10% larger than that baseline.
- Increased the `Option+Tab` panel wrapping width from 80% to 90% of the current screen.
- Added held-Tab repeat cycling while `Option+Tab` is open, with `Tab` release stopping the repeat.
- Added outside-click cancellation for the `Option+Tab` switcher without activating a window.
- Tightened switcher card layout so thumbnails sit flush to the left, right, and bottom edges while the title row is smaller.
- Improved minimized-window first-frame placeholders in the switcher so minimized items are visibly marked before cached thumbnails load.

## v1.0.4 - 2026-06-24

- Enlarged the `Option+Tab` switcher cards and acrylic panel by another 30% for easier window recognition.
- Changed the `Option+Tab` first render to include minimized windows immediately when Accessibility permission is available.
- Fixed minimized-window collection so separate windows with similar titles and sizes are no longer incorrectly filtered out.

## v1.0.3 - 2026-06-23

- Enlarged the `Option+Tab` switcher cards by 15% for easier scanning.
- Removed the redundant app-name subtitle from switcher cards so each card keeps one clear window title.
- Added `Esc` cancellation while the `Option+Tab` switcher is open, allowing users to back out without activating a window.

## v1.0.2 - 2026-06-23

- Redesigned the `Option+Tab` switcher as a single acrylic panel containing independent rounded window cards.
- Changed the switcher layout to wrap rows at 80% of the current screen width and center each row.
- Fixed long window titles in the switcher so they truncate inside the card width instead of stretching the layout.
- Kept Dock hover previews on the compact joined-card design introduced in `v1.0.1`.

## v1.0.1 - 2026-06-22

- Reduced `Option+Tab` startup lag by showing a lightweight switcher immediately, then loading thumbnails asynchronously.
- Added a fast visible-window path for the switcher and lazy background completion for minimized windows.
- Moved Dock hover thumbnail prewarming off the main thread to reduce stutter while sweeping across Dock icons.
- Reworked Dock previews and the `Option+Tab` switcher into joined Windows-style cards with no outer container frame.
- Added thread-safe thumbnail cache access for background prewarming and asynchronous thumbnail updates.

## v1.0.0 - 2026-06-22

- Added a Windows-style `Option+Tab` window switcher built with public Carbon hotkey APIs.
- Shows a centered AppKit thumbnail switcher panel, cycles while `Option` is held, and activates the selected window when `Option` is released.
- Reuses the existing CoreGraphics window collector, thumbnail provider, minimized-window fallback, and Accessibility-based window activation.
- Added the shortcut state to the menu bar settings popover.
- Marked the app as the first complete `1.0.0` release.

## v0.5.0 - 2026-06-22

- Renamed the user-facing app from DockWindowPreview to Y-Dock.
- Updated the app bundle display name, settings UI, menus, permission prompts, logs, README, and release packaging name.
- Kept the existing bundle identifier and GitHub repository name to preserve permissions, update checks, and project continuity.

## v0.4.8 - 2026-06-22

- Adjusted the app icon artwork scale so it no longer appears oversized in Launchpad.
- Regenerated the bundled `.icns` and README logo assets from the inset icon source.
- Documented the icon inset requirement for future maintainers.

## v0.4.7 - 2026-06-22

- Replaced the app icon with the new supplied logo and regenerated the bundled `.icns`.
- Updated the GitHub README logo asset and release/download links.
- Added `AI_MAINTENANCE.me` for future AI maintainers, including project architecture, build verification, packaging, and GitHub release flow.
- Added this changelog and linked it from the README.

## v0.4.6 - 2026-06-22

- Made DockWindowPreview a true menu bar/background utility by hiding it from Dock and Cmd-Tab.
- Added cancellable preview prewarming while hovering Dock candidates.
- Increased short-term thumbnail cache lifetime and capacity for smoother repeated Dock sweeps.
- Invalidated preview caches when target apps terminate.
- Redesigned the menu bar template icon with a taller stacked-window silhouette.
