# npad

Manage dynamic windows created by [`niri-scratchpad`](https://github.com/Vizkid04/niri-scratchpad) from a Noctalia panel. Browse marked windows and add windows from the focused workspace to the dynamic scratchpad.

## Plugin

| Field | Value |
| --- | --- |
| ID | `ffngs/npad` |
| Entries | Bar widget: `hidden`; panel: `manager`; service: `config-manager` |

## Requirements

Install `nscratch` from [niri-scratchpad](https://github.com/Vizkid04/niri-scratchpad) and ensure its executable is on `PATH`. The `niri`, `sleep`, `bash`, and `python3` commands are also required. This plugin is intended for a Niri session.

## Usage

Open the panel with:

```sh
noctalia msg panel-toggle ffngs/npad:manager
```

Press **Escape** to close the panel.

The **hidden** bar widget polls Niri once per second and shows an eye icon and the number of hidden marked windows originating from the currently focused workspace. When the configured scratchpad workspace is focused, it counts hidden windows from all origin workspaces. It prefers Niri's `is_focused` workspace flag, falling back to the `is_active` workspace marker shown as `*` by `niri msg workspaces`. If multiple outputs have active workspaces, it keeps using the last known active workspace where possible. Its **Hide when zero** setting controls whether it disappears when none are hidden there. Click it to open the manager panel. In the **Marked** section, windows are scoped to their original workspace by default; the panel automatically switches to **Show all hidden** while the scratchpad workspace is focused. Each cross-workspace row prefixes its app name with its origin workspace, keeping the same two-line layout and icon alignment.

While the panel is open, a Bash helper listens to `niri msg --json event-stream` and refreshes the panel on Niri workspace, focus, and window events. It stops listening when the panel closes. The **Marked** section lists dynamic scratchpads from `nscratch` state. Each row has a context-aware **Hide** or **Restore** action and a **Remove** action. Hidden rows use muted text and a dimmed app icon. Buttons include icons for their actions. On the scratchpad workspace, marked and unmarked windows also have a **Float**/**Tile** button to toggle their Niri layout. While on the scratchpad workspace, **Restore** moves a window directly to its saved original workspace; elsewhere it uses `nscratch --index` to restore to the current workspace. Windows moved to the scratchpad workspace manually without being marked appear separately as **Unmarked**; **Restore** moves them to the next workspace on that output, or the previous workspace if there is no next one. On other workspaces, the **Workspace** section lists windows that are not in the dynamic marked list. Click **Mark** to briefly close the panel, focus that specific window in Niri, run `nscratch --mark`, and reopen the panel with the updated lists.

## Settings

The plugin has a **Scratchpad workspace name** setting, defaulting to `scratch`; change it if your Niri scratch workspace has a different name. **Prevent selecting scratch** is off by default. When enabled, npad manages an `npad.kdl` override next to the selected Niri config and appends a marked `include` block to that config. It wraps active `focus-workspace-up/down` and `focus-window-or-workspace-up/down` keybindings, preserving their chords and options. Navigation skips the scratch workspace when another workspace is available in that direction, and stops at the edge otherwise. Window-to-window focus remains available for `focus-window-or-workspace` bindings. Direct workspace selection and other actions are unchanged. The panel header shows **Open Scratch** while this setting is enabled, and hides the button while already on the scratch workspace. Set **Niri config file** to the exact config path to manage, or leave it blank to use `NIRI_CONFIG` or the default `$XDG_CONFIG_HOME/niri/config.kdl` (falling back to `~/.config/niri/config.kdl`). Turning the setting off removes only npad's marked include block and generated override; disabling or uninstalling the plugin also removes npad's changes. Npad validates the resulting config with `niri validate` before changing the active config.

The **hidden** bar widget also has a **Hide when zero** option, enabled by default. Turn it off to keep the eye icon and a `0` visible when the focused workspace has no hidden marked windows.

## Notes

The **Marked** list is read directly from `nscratch`'s JSON state file, the same source used by `nscratch --list`. The plugin follows `dirs::cache_dir()` on Linux: `$XDG_CACHE_HOME/nscratch/state.json` when `XDG_CACHE_HOME` is an absolute path, otherwise `$HOME/.cache/nscratch/state.json`, with `/tmp/nscratch/state.json` as the final fallback. `nscratch --list` displays a desktop notification rather than machine-readable stdout, so the plugin reads the JSON file instead. Niri's `windows` and `workspaces` IPC queries provide live window and workspace details after an event. The listener writes a temporary PID file and FIFO under `$XDG_RUNTIME_DIR` (or a private temporary directory fallback) and removes them when stopped. The **Prevent selecting scratch** helper reads the active keybindings in the selected config and its includes, then generates overrides in the same config directory. It does not rewrite existing keybinding definitions; Niri merges the npad include last. Each generated binding invokes `prevent-scratch.sh`, which asks the Python helper to decide whether to focus a neighboring workspace or window. Workspace Mark actions use the Niri window id to focus the exact selected window before calling `nscratch --mark`, avoiding app-id ambiguity. The plugin makes no network requests.
