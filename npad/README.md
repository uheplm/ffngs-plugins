# Npad

Manage dynamic windows created by [`niri-scratchpad`](https://github.com/Vizkid04/niri-scratchpad) from a Noctalia panel. Browse marked windows and add windows from the focused workspace to the dynamic scratchpad.

## Plugin

| Field | Value |
| --- | --- |
| ID | `ffngs/npad` |
| Entries | Panel: `manager` |

## Requirements

Install `nscratch` from [niri-scratchpad](https://github.com/Vizkid04/niri-scratchpad) and ensure its executable is on `PATH`. The `niri` and `sleep` commands are also required. This plugin is intended for a Niri session.

## Usage

Open the panel with:

```sh
noctalia msg panel-toggle ffngs/npad:manager
```

The **Marked** section lists dynamic scratchpads from `nscratch` state. Each row has a context-aware **Hide** or **Restore** action and a **Remove** action. Hidden rows use muted text and a monochrome window icon. Buttons include icons for their actions. The **Workspace** section lists windows on the focused workspace that are not in the dynamic marked list. Click **Mark** to briefly close the panel, focus that specific window in Niri, run `nscratch --mark`, and reopen the panel with the updated lists.

## Notes

The **Marked** list is read directly from `nscratch`'s JSON state file, the same source used by `nscratch --list`. The plugin follows `dirs::cache_dir()` on Linux: `$XDG_CACHE_HOME/nscratch/state.json` when `XDG_CACHE_HOME` is an absolute path, otherwise `$HOME/.cache/nscratch/state.json`, with `/tmp/nscratch/state.json` as the final fallback. `nscratch --list` displays a desktop notification rather than machine-readable stdout, so the plugin reads the JSON file instead. Niri's `windows` and `workspaces` IPC queries provide live visibility and the focused-workspace list. The plugin runs `nscratch` for scratchpad actions and asks `niri` to move visible marked windows to the scratch workspace when hiding them. The workspace name is `scratch` by default, matching `nscratch`; if `NS_WORKSPACE` is set for the Noctalia process, that value is used instead. Workspace Mark actions use the Niri window id to focus the exact selected window before calling `nscratch --mark`, avoiding app-id ambiguity. The plugin itself makes no network requests and writes no files.
