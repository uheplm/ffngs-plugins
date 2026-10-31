# Zen Mode

Hide the Noctalia bar only while a window you marked for Zen Mode is active, while keeping the bar reachable from the screen edge.

## Plugin

`ffngs/zenmode` provides the `zen` bar widget and a headless Noctalia service named `service`. The service tracks zen-modded Niri window IDs and applies the bar mode per output based on the active window.

## Usage

Zen Mode tracks windows marked through the plugin IPC and changes the Noctalia bar only while one of those windows is active on its output. Other windows keep the normal bar behavior. Toggling a window keeps the existing `maximize-window-to-edges` action. The bar is moved to the overlay layer, auto-hide is enabled, and configured reserve space is toggled off while a zen window is active, so the bar can still be revealed by moving the pointer to the top edge.

The **Zen** bar widget is normally visible only while the focused window is in Zen Mode; click it to exit Zen Mode. Enable the widget's **Toggle zen** setting to keep it visible and use it to toggle the focused window into or out of Zen Mode instead.

Toggle the currently focused window into or out of Zen Mode from any shell or keybinding:

```sh
noctalia msg plugin ffngs/zenmode:service all toggle
```

The plugin monitors Niri's event stream to restore the normal bar state whenever focus changes, reasserts the correct bar layer and auto-hide mode during reconciliation, and persists its zen-window list plus current and normal reserve-space state for each targeted bar on each output. Reserve space is toggled only when its tracked state differs from the intended state. On first startup, it imports window IDs and the old bar state for `TopBar` from files left by the earlier `zen-mode.fish` script when those files are present.

On exit, the service stops its event listener and attempts to restore any bar it changed on connected outputs. When an output disappears (for example, when a laptop lid is closed), its saved bar state is dropped without sending restore commands to the disconnected output; if an in-flight command completes after removal, its result is ignored. Similarly, when a bar is removed from Noctalia's `bar.order`, Zen Mode drops its saved state and ignores late command errors instead of trying to restore an unknown bar. Noctalia exposes reserve-space changes only as a toggle and provides no runtime query, so Zen Mode tracks its current and normal reserve state per bar and output and persists both. It assumes reserve space is enabled by default on first management; the separate `bar.enableExclusionZoneInset` setting controls an extra inset and is not the reservation state. Avoid toggling reserve space independently while Zen Mode is managing an output: an external toggle cannot be detected and will desynchronize the saved state. Auto-hide defaults come from `bar.displayMode` and per-screen `screenOverrides` in Noctalia's `settings.json`. Layer restoration uses Noctalia's normal `top` layer.

### Recovering reserve-space desynchronization

If a non-Zen window has no reserved bar space, or a Zen window still has space reserved, the actual toggle state may differ from Zen Mode's saved state. Tell the service which state is currently active on the affected output. It will update its saved state and reconcile the reservation to the expected mode (reserved for non-Zen, unreserved for Zen). For the common desync, use `reserve-disabled` when a non-Zen window has no reserved space, or `reserve-enabled` when a Zen window still has reserved space:

```sh
# Replace DP-3 with the affected output. This applies to every target bar.
# If space is currently reserved:
noctalia msg plugin ffngs/zenmode:service all reserve-enabled DP-3

# If space is currently not reserved:
noctalia msg plugin ffngs/zenmode:service all reserve-disabled DP-3
```

If only one of several target bars is desynchronized, pass `BAR|OUTPUT` instead, quoting the payload so the shell does not treat `|` as a pipe. For example: `noctalia msg plugin ffngs/zenmode:service all reserve-disabled "Bar|DP-3"`. The payload reports the **current** state; it does not set the bar state directly. If you cannot tell which state is active, inspect whether a normal window leaves a gap for the bar or whether a Zen window extends beneath it. Avoid using `bar-reserve-toggle` as a blind repair: changing the bar without also reporting the resulting state can create another desync.

## Settings

The plugin's **Target bars** setting is a list of Noctalia bar names to manage. Leave it empty to follow Noctalia's configured `bar.order`; set one or more exact names to override that list. Only selected bars are modified. Reservation state is tracked independently for each bar/output pair. When changing the target bars or Noctalia's bar order while following it, the plugin restores bars that are no longer selected before managing the new selection.

The widget's `toggle_zen` setting is off by default. When off, it appears only on a zen-modded focused window and clicking it exits Zen Mode. When on, it remains visible and clicking it toggles Zen Mode for the focused window.

## Requirements

- `niri` for focused window/workspace information and event notifications.
- `bash` for the event-stream listener.
