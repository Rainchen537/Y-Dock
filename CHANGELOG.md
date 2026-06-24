# Changelog

All notable Y-Dock release changes are tracked here.

## v1.0.8 - 2026-06-24

- Fixed `Option+Tab` thumbnails preserving the wrong captured image aspect ratio, which could make narrow windows such as WeChat look flattened.
- Kept cached and minimized-window thumbnail redraws proportional when they are fitted into narrow cards.
- Prepared a signed DMG for updating local installations.

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
