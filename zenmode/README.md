# Zen Mode

Hide the Noctalia bar while selected Niri windows are active, while keeping the bar reachable from the screen edge. Mark windows manually with the bar widget or automatically by matching their app ID or title.

## Plugin

| Field | Value |
| --- | --- |
| ID | `ffngs/zenmode` |
| Entries | Bar widget: `zen`; service: `service` |

## Requirements

- Install `niri` and `bash` on `PATH`. Niri provides window/workspace information, window actions, and event notifications; Bash runs the event-stream listener.

## Usage

Add the **Zen** bar widget (`zen`) to a Noctalia bar. It appears when the focused window is in Zen Mode; click it to exit Zen Mode. Enable **Toggle zen** to keep the widget visible and let it toggle the focused window into or out of Zen Mode.

Use **Auto Zen app IDs** or **Auto Zen titles** to automatically mark matching windows. Both settings accept optional lists of Lua patterns; a match in either list enables Zen. For example, `^firefox$` matches an app ID exactly, and `.*YouTube.*` matches titles containing “YouTube”. A window stays in Zen after first matching, even if its title later changes. Matching windows are maximized to the screen edges. Manually toggling or exiting Zen for an automatically matched window overrides the automatic rule until the window closes.

While a Zen window is active, the service moves selected bars to the overlay layer, enables auto-hide, and disables reserved bar space so the bar can still be revealed from the screen edge. When focus moves to another window, it restores the normal bar layer, configured auto-hide behavior, and reserved space.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `bar_names` | `string_list` | `[]` | Exact Noctalia bar names to manage. Leave empty to follow Noctalia's configured `bar.order`. |
| `auto_zen_app_ids` | `string_list` | `[]` | Lua patterns matched against window app IDs. A match starts that window in Zen Mode. |
| `auto_zen_titles` | `string_list` | `[]` | Lua patterns matched against window titles. A match starts that window in Zen Mode. A match in either automatic list is sufficient. |
| `toggle_zen` | `bool` | `false` | Keep the Zen widget visible and let it toggle the focused window into or out of Zen Mode. When off, it appears only for a Zen window and clicking exits Zen Mode. |

## IPC

Toggle the focused window, optionally targeting the focused window on a named output:

```sh
noctalia msg plugin ffngs/zenmode:service all toggle [output]
```

Exit Zen Mode for the focused window, optionally targeting a named output:

```sh
noctalia msg plugin ffngs/zenmode:service all exit [output]
```

The service also accepts `reconcile` to refresh state from Niri:

```sh
noctalia msg plugin ffngs/zenmode:service all reconcile
```

## Notes

- The service persists manually marked window IDs, automatic-rule opt-outs, and the bar/output pairs it currently manages in its plugin data directory. On first startup, it imports legacy window IDs from `/tmp/noctalia_zen_windows.txt` and Zen bar state for `TopBar` from `/tmp/noctalia_bar_state_*.txt` when present; hyphens in output names are replaced with underscores.
- The service starts and stops a Bash listener for Niri's event stream. On exit it restores bars it changed; disconnected outputs and bars removed from Noctalia's `bar.order` are not sent restore commands.
- Reservation is set idempotently with `bar-reserve-set`. Reserve space is assumed enabled outside Zen Mode. The separate `bar.enableExclusionZoneInset` setting controls an extra inset and is not the reservation state.
- Auto-hide defaults come from `bar.displayMode` and per-screen `screenOverrides` in Noctalia's `settings.json`. Normal layer restoration uses Noctalia's `top` layer.
- Automatic matching uses Lua patterns, not regular expressions. Invalid patterns are reported as plugin errors.
