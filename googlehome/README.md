# Google Home

Connect to a Cast speaker or group and use a compact Noctalia mini-player for live playback status and controls.

## Plugin

| Field | Value |
| --- | --- |
| ID | `ffngs/googlehome` |
| Entries | Launcher provider: `/gh`; panel: `remote`; bar widget: `mini-player`; service: `cast-status` |

## Requirements

- `catt` installed and available on `PATH`.
- Python 3.11+ with [PyChromecast](https://pypi.org/project/PyChromecast/) installed for the `python3` interpreter.
- The computer running Noctalia and the Cast devices must be able to communicate on the same local network.

## Usage

Type `/gh` in the Noctalia launcher to discover Cast devices. Select a speaker, display, or group to connect. Each device result shows its IP address, device type, and connection/playback state alongside a device-type icon. The discovered device list and last selection are cached in Noctalia's per-plugin data directory. While connected, a **Disconnect** result appears at the top.

When connected, the **Google Home Mini Player** bar widget appears with the album cover, track title, and device-type icon. Hover tooltips show playback status on the cover, elapsed/total time on the title, and device name and volume on the device icon. Click the cover to toggle play/pause, right-click the widget to advance to the next track, or click elsewhere on the widget to open the compact floating player panel. The panel updates from Cast status events and shows the casting application, progress, elapsed/total and remaining time, percentage, current volume, and mute state. Video metadata such as series, season, and episode appears when provided by the Cast receiver. The panel also provides previous, play/pause, next, stop-and-dismiss, volume, and disconnect controls. Playback and listener errors are delivered as notifications rather than shown in the panel. Disconnecting stops the persistent Cast connection and hides the widget; the cached device list and last selected device are retained. Run `/gh` again to connect to another device.

The panel can also be opened directly:

```sh
noctalia msg panel-toggle ffngs/googlehome:remote
```

## Settings

| Setting | Default | Range | Description |
| --- | ---: | ---: | --- |
| Playback polling interval | 2 seconds | 1–60 seconds | Fallback status-check interval used in case a Cast event is missed. |

## Notes

- Device discovery and volume commands use `catt`. Play/pause and previous/next actions use the small `cast-control.py` PyChromecast helper, which waits for an active media session before issuing the command. Play/pause is sent without waiting for the receiver's command acknowledgment, avoiding timeouts from apps that do not acknowledge those requests. `catt skip` jumps to the end of the current content rather than advancing the queue.
- The `cast-status` service starts the persistent PyChromecast listener only while connected, and stops it on disconnect, plugin disable, or Noctalia shutdown. The listener writes snapshots to the plugin data directory; the service publishes changed snapshots to shared plugin state, which drives the widget and panel updates.
- The player displays the largest image in `media_metadata.images`. Track title and artwork update with Cast media-status events; the configured interval provides a periodic fallback check.
- This plugin does not use Google account credentials or call cloud APIs directly.
