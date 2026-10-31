# MX Mouse

Configure Logitech MX Master 3/3S thumb-button gestures and per-window presets for Niri using `nnmxd` and a Noctalia settings panel.

## Plugin

| Field | Value |
| --- | --- |
| ID | `ffngs/mxmouse` |
| Entries | Panel: `manager`; bar widget: `modifier` |

## Requirements

- Niri and `niri` on `PATH`.
- For the optional installation wizard: `git`, `make`, and Go.
- The user running Noctalia must have access to the mouse's evdev node and `/dev/uinput`. See the nnmxd source repository's setup instructions; adding a user to the `input` group grants access to all input devices.
- A user systemd manager. The wizard installs and enables `nnmxd.service` without root privileges.

## Installation

The panel checks whether `nnmxd` is installed. If it is missing, it offers an installation wizard that:

1. Clones the nnmxd source into `~/.local/src/nnmxd`.
2. Runs `make install`, which builds the daemon locally and installs it to `~/.local/bin`.
3. Installs, enables, and starts the `nnmxd.service` user unit.

The wizard displays command output and errors. It does not use `sudo`; Go modules are downloaded by Go during the local build. Review the source and ensure input-device permissions are configured before starting the service.

The source is hosted at `https://github.com/uheplm/nnmxd`. It can also be installed manually from a checkout with `make install`.

## Usage

Install this plugin from the community catalog, then open its panel:

```sh
noctalia msg panel-toggle ffngs/mxmouse:manager
```

The panel is organized into **Overview**, **Gestures**, **Applications**, **Device**, and **Logs** pages. Overview shows daemon/device status and your profiles; gesture controls are grouped by direction and mode; application assignments use Niri's exact `app_id` and show icons resolved by Noctalia; and device/service options are kept separate from everyday gesture editing. **Save changes** validates and atomically applies the configuration. Preset and app mapping changes take effect on the next thumb-button press; save device changes and use **Redetect** to restart nnmxd and scan for an accessible Logitech device. If no compatible mouse is connected, the panel reports **No MX mouse connected** rather than presenting the daemon as connected; the panel does not automatically restart the service. In this case nnmxd remains running and checks for a device, while **Retry detection** is a manual action. While the panel is open, it refreshes nnmxd service and device status every second, so restart and redetection results appear without reopening the panel. The Logs page starts a live `journalctl` stream for `nnmxd.service` when opened and keeps the latest 250 lines in the panel for troubleshooting.

Each gesture has its own tab in a cross-shaped directional selector, with separate tabs for tap and scroll. A selected gesture can run a Niri action, a Noctalia `msg` command, or a custom shell command. Niri and Noctalia choices are loaded from their installed CLI help. The optional arguments field is appended after the selected action, allowing parameters such as a workspace number or panel ID. Custom shell commands run as the user and can execute arbitrary programs, so only bind commands you trust. Movement threshold and escalation are in evdev relative-motion counts. Meta-toggle presets latch a supported modifier key on each press and release held virtual keys when the service exits.

The action pickers load options from `niri msg action` and `noctalia msg --help`. Noctalia media sub-actions (such as `media next` and `media volume-up`) are loaded from `noctalia msg media --help`; add any required parameters, such as a volume step, in **Arguments (optional)**.

## Configuration and status

The panel writes `$XDG_CONFIG_HOME/mxmouse/config.json`, falling back to `~/.config/mxmouse/config.json`. It reads runtime status from `$XDG_RUNTIME_DIR/mxmouse/status.json`. The nnmxd daemon validates a staged config and atomically replaces the live file; invalid edits are reported in the panel without replacing the prior valid config.

Per-window matching uses Niri's exact `app_id`. Titles are displayed only to help identify windows; title matching is not used.

## Settings

The `modifier` bar widget can be configured to **Hide when inactive**. When visible, it shows `META` while the modifier is latched; clicking it opens the MX Mouse panel.

## Notes

- The service grabs the physical mouse while running and forwards ordinary pointer events through a virtual uinput clone. Gesture input is consumed while the thumb button is held.
- nnmxd is a user service and does not use or launch the old `mxmoused` executable.
- There is no LogiOps/logid integration or HID++ support.
- The `modifier` bar widget reads `$XDG_RUNTIME_DIR/mxmouse/status.json` and displays the latched modifier state; it can be configured to hide while no modifier is active.
- After installation, device access and Niri action dispatch happen locally. The installation wizard needs network access to clone the source and download Go modules.
