# MX Mouse

Configure Logitech MX Master 3/3S thumb-button gestures and per-window profiles for Niri using the Noctalia settings panel and the `nnmxd` service.

## Plugin

| Field | Value |
| --- | --- |
| ID | `ffngs/mxmouse` |
| Entries | Panel: `manager`; bar widgets: `modifier`, `gesture-columns`, `gesture-workspaces` |

## Requirements

- Niri and `niri` on `PATH`. This plugin currently supports Niri for window focus and action dispatch.
- The `noctalia` CLI from Noctalia Shell, which hosts the settings panel, status display, and notifications.
- The [`nnmxd` service](https://github.com/uheplm/nnmxd), required to read mouse input and apply profiles. Install it manually using the instructions below and in the [nnmxd README](https://github.com/uheplm/nnmxd#readme). MX Mouse checks the installed version against [`NNMXD_VERSION_TARGET`](./NNMXD_VERSION_TARGET) and notifies you when an update is required.
- `install`, `systemctl`, and `journalctl` for installing the locally built service files, controlling the `nnmxd` user service, and viewing its logs.
- A user systemd manager and access for your user to the mouse's evdev device and `/dev/uinput`. DPI control also needs access to the receiver's HID++ `/dev/hidraw*` node. See [nnmxd input permissions](https://github.com/uheplm/nnmxd#input-permissions).

Other compositors and shells are not supported by this plugin. `nnmxd` can run with custom configuration and shell commands, but integrations other than Niri and Noctalia have not been implemented.

## Installation

Install the plugin from the Noctalia community catalog. The plugin checks nnmxd's `--version` output against `NNMXD_VERSION_TARGET` and notifies you if it is missing or too old. The update notice lists the installed and required versions separately, displays each build command in its own card, and provides a copy button for each command. Review and run those commands in a terminal:

```sh
mkdir -p ~/.local/src
git clone https://github.com/uheplm/nnmxd.git ~/.local/src/nnmxd
make -C ~/.local/src/nnmxd build
```

If you already cloned the repository to that location, update the reviewed checkout and build it:

```sh
git -C ~/.local/src/nnmxd pull --ff-only
make -C ~/.local/src/nnmxd build
```

The manual build requires Git, Make, and Go. Review the [nnmxd source](https://github.com/uheplm/nnmxd) before building. Once the local build meets the target version, choose **Configure service** in the panel: it copies the built binary and service unit into your user directories, reloads systemd, enables and starts `nnmxd.service`, then restarts it to run the updated binary. This does not use elevated privileges. Configure device permissions before running the service.

For alternative install methods and service details, see the [nnmxd installation guide](https://github.com/uheplm/nnmxd#install).

## Usage

Open the panel from the plugin entry or run:

```sh
noctalia msg panel-toggle ffngs/mxmouse:manager
```

### Overview

- Shows service state, connected mouse, focused app, and its active profile.
- The `gesture-columns` bar widget shows the tiled columns on the active workspace, with pills sized by their Niri tile widths and small app icons. `gesture-workspaces` shows every workspace on the output as equal-sized pills with a distinct name badge. The badge shows the uppercase first character of the workspace name (or its index when unnamed); optional name-to-glyph mappings can replace it, for example `Home=home, Work=briefcase`. Each pill lays out its icon or badge beside a direction-aligned progress strip: X fills left/right, while Y fills up/down. The progress strip is sized to fit alongside or below the icon/badge according to the selected widget layout. The focused pill follows gesture progress with responsive cubic easing and completes at the trigger threshold before the refreshed focus is rendered; when a gesture points beyond the first or last item, a short warning-orange marker indicates the blocked edge while the normal progress remains visible. Click a column pill to focus its representative window, or a workspace pill to switch workspaces. Both widgets require the nnmxd version listed in [`NNMXD_VERSION_TARGET`](./NNMXD_VERSION_TARGET).
- Provides mouse-map shortcuts to the profile controls. The shortcuts open the corresponding section for the focused app's profile.
- Includes controls to refresh the window list and restart the input service.

### Profiles

Profiles are selected based on the focused window's exact Niri `app_id`; windows without an explicit assignment use the default profile. Window titles are displayed for identification and are not used for matching.

Each profile has the following sections:

- **Profile** — Set its name, glyph, mode, or make it the default profile.
- **Gestures** — In Gesture mode, assign directional actions and a tap action. Movement threshold controls the first directional action; retrigger distance controls later actions, and escalation increases the distance after each retrigger. Choose shared distances or configure the threshold, retrigger distance, and escalation independently for horizontal (X) and vertical (Y) gestures. **Account for window dimensions** scales selected horizontal distances by focused-window width ÷ output width and vertical distances by focused-window height ÷ output height. The service tracks focus during a gesture and updates the multipliers as you switch between windows. This setting requires the nnmxd version listed in [`NNMXD_VERSION_TARGET`](./NNMXD_VERSION_TARGET).
- **Thumb Chords** — Assign actions to thumb + left, middle, or right click. An assigned chord runs on click-down and consumes that click and release; an unassigned chord passes through as a normal click. Available in Gesture mode.
- **Side buttons** — Assign actions to the back (`BTN_SIDE`) and front (`BTN_EXTRA`) side buttons. An assigned action runs on press; unassigned buttons pass through. Available in either profile mode. The under-wheel button is not configurable.
- **Wheel actions** — Configure vertical scrollwheel actions while holding the thumb button, and thumbwheel left/right actions with independent bindings for normal use and while holding the thumb button. Unassigned thumbwheel directions preserve horizontal scrolling.
- **DPI and Scroll speed** — Override DPI and vertical/horizontal scroll scales per profile. A profile value of `0` inherits the matching Device-page value. Profile DPI changes follow app focus without requiring another thumb-button press; scroll scales take effect on the next wheel event.

Actions can invoke Niri actions, Noctalia `msg` commands, or custom shell commands. Niri and Noctalia choices are populated from their installed command-line help. Optional arguments are appended to the selected action. Shell commands run as your user and can execute arbitrary programs; only bind commands you trust.

### Applications

Assign a profile to a Niri `app_id`. **Next preset** cycles through the available profiles for that app. Other windows continue to use the default profile.

### Device

Configure device detection, the input-device path, thumb trigger, default DPI, and default vertical/horizontal scroll scale. **Modify horizontal scroll by window's relative width** can be disabled, set directly proportional (narrower windows scroll more slowly), or reverse proportional (narrower windows scroll faster). The relative width is focused-window width ÷ output width and modifies the horizontal scroll multiplier for all profiles. `BTN_FORWARD` is the usual MX Master thumb button. Changing detection, device path, or trigger button requires restarting the service.

Device and profile scroll scales are percentages from 10 to 500; `100` preserves the input. DPI `0` leaves the device setting unchanged at the Device level and inherits the Device setting at the profile level. DPI control depends on the mouse and receiver supporting HID++ adjustable DPI and on the user having hidraw access.

### Logs

Shows the live `journalctl` stream for `nnmxd.service` while the page is open, retaining the latest 250 lines.

### Saving changes

**Save changes** validates the staged configuration through `nnmxd` and atomically replaces the live configuration only when valid. After saving, press the thumb button once to apply it. That press is consumed and will not run the assigned gesture or toggle action; the panel confirms the applied generation with a notification that includes a static image highlighting the button.

## Configuration and status

The plugin stores configuration in `$XDG_CONFIG_HOME/mxmouse/config.json`, falling back to `~/.config/mxmouse/config.json`. Runtime status is read from `$XDG_RUNTIME_DIR/mxmouse/status.json`.

For the complete configuration schema, service lifecycle, runtime status fields, and troubleshooting instructions, see the [nnmxd README](https://github.com/uheplm/nnmxd#readme).

## Settings

The Y-axis workspace map uses fixed pill dimensions configured by **Workspace pill width** and **Workspace pill height** (16–200 px each; defaults 28×40 px). With **Shrink inactive workspace pills** enabled, inactive workspace pills become square; **Animate workspace pill resizing** enables a smooth transition between focused and inactive sizes, and **Workspace pill resize duration** controls the duration from 100 to 1000 ms (default 280 ms). Workspace index/glyph badges have no separate background in shrink mode.

The **Widget layout size** and **Target pill minimum size** settings apply to the dynamically sized X-axis column map; Y-axis workspace dimensions are controlled directly by the width and height settings above.

The `modifier` bar widget can be configured to **Hide when inactive**. When visible, it shows `META` while a modifier is latched; clicking the widget opens the MX Mouse panel. Add the `profile` bar widget to show only the current profile's configured glyph. Configure **Workspace name-to-glyph mappings** in the plugin settings as comma-separated `name-or-index=glyph` pairs, such as `Home=home, 1=briefcase`; use glyph names supported by Noctalia. Name mappings take precedence over index mappings. Unmapped named workspaces show the uppercase first character of their name, and unnamed workspaces show their index. Add `gesture-columns` and/or `gesture-workspaces` to a bar to display the interactive X and Y maps separately. The X map can optionally show a plus button on an empty workspace that opens the configured **Launcher opening command** (default `noctalia msg panel-open launcher`). **Open Launcher on focus** runs that command when Niri focuses an empty workspace; **Close launcher leaving empty workspace** sends Noctalia's `panel-close launcher` IPC when focus leaves it. **Open Launcher at workspace edge** opens the same launcher when an X-axis gesture reaches beyond the first or last column. **Launcher workspace edge** selects the start (left) or end (right) edge; its configured glyph (default `apps`) appears at that edge of the progress bar and follows the bar's dynamic opacity. The opening command is executed by the shell as the current user; only enter commands you trust. The Niri layout refresh interval is 100 ms to keep focus and workspace changes responsive. The Y widget can hide workspaces with no windows, configure the workspace badge corner radius, and optionally **Shrink inactive workspace pills** to square pills containing only the icon or index. Progress remains available when gesturing from an empty focused workspace, including at the boundary where the next workspace target is invalid. **Show progress only for the dominant axis** suppresses progress on a map when movement is more strongly aligned with the other axis; enable it on both maps to prevent simultaneous X and Y progress (X wins ties). This affects visualization only, not gesture detection or actions. **Dynamic progress opacity** fades the progress bar from transparent to fully opaque as gesture progress increases. **Show progress when inactive** keeps the progress tracks visible when no gesture is in progress (enabled by default); when disabled, the active axis's track animates beside the target icon on the gesture-facing side (left/right or above/below), then retracts when the gesture ends. During a gesture, only the current target pill expands, and it smoothly shrinks back afterward. Each gesture map has an independent horizontal or vertical layout setting; horizontal layout uses a row arrangement, while vertical layout uses a column arrangement. The configured layout size is 60–600 px along the layout direction, and minimum target size (1–50% of that size) applies to pill width in horizontal layout or pill height in vertical layout. Other settings include pill corner radius (0–24 px), icon/index size (25–150% of the pill's smaller dimension), horizontal start/end and vertical top/bottom target-pill padding (0–16 px), progress thickness (10–100% of icon/index size), and icon-progress gap (0–24 px).

When **Hide empty workspaces** is enabled, the active/focused workspace remains visible even if it has no windows. During workspace gestures, progress stays on the active workspace pill, including when aiming at an adjacent empty workspace; hidden empty workspaces remain valid gesture destinations rather than showing a blocked warning.

## Notes

- `nnmxd` grabs the physical mouse while running and forwards ordinary pointer events through a virtual uinput clone. Gesture input is consumed while the thumb button is held.
- DPI is set using the mouse's native HID++ adjustable-DPI feature; Solaar, LogiOps, and logid are not required. Device support varies, and onboard profile settings can override a host-set DPI.
- The `modifier` widget reads the daemon's runtime status file. `nnmxd` itself has no Waybar-specific output or integration.
- The `gesture-columns` and `gesture-workspaces` widgets read gesture progress and trigger state from the daemon status file and Niri's window/workspace data.
- The plugin does not clone or build nnmxd. It installs the binary and service unit from the local source/build paths after you build them yourself. The manual commands above require network access to clone the repository and download Go modules.

## License

MIT
