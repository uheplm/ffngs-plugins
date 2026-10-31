# Google Home

Control playback and cast media URLs to Google Home Mini speakers and stereo-paired Cast groups on your local network.

## Plugin

| Field | Value |
| --- | --- |
| ID | `ffngs/googlehome` |
| Entries | Panel: `remote`; bar widget: `mini-player` |

## Requirements

- `catt` installed and available on `PATH`.
- The computer running Noctalia and the Google Home speakers must be able to communicate on the same local network.

## Usage

Open the panel:

```sh
noctalia msg panel-toggle ffngs/googlehome:remote
```

The panel discovers Google Home Mini speakers and Cast groups with `catt scan`; use **Refresh** to scan again and select a speaker or group from the list. The **Playback** tab is a compact mini player with track artwork, title, artist, album, Cast app identity, playback progress and seeking, play/pause, rewind, skip, volume, and mute controls. Progress advances every second while playing, with status polling at the configured interval while the panel is open and in the bar widget. Configure **Playback polling interval** in Settings → Plugins; the default is 5 seconds (1–60 seconds). The **Cast** tab sends a supported HTTP(S) media URL to the selected speaker or group and can attach an optional display title.

Add the **Google Home Mini Player** bar widget for quick access to the current track, play/pause, skip, volume up/down, and mute. Its tooltip includes the available track, album, Cast app, playback, and volume details. Clicking the rest of the widget opens the mini player panel.

The selected device is saved in Noctalia's per-plugin data directory and restored the next time the panel opens. If that device is no longer found, the panel selects the first discovered speaker or group.

## Settings

| Setting | Default | Range | Description |
| --- | ---: | ---: | --- |
| Playback polling interval | 5 seconds | 1–60 seconds | How often the panel and bar widget check playback status. |

## Notes

- Discovery, status queries, playback commands, volume changes, and URL casting are performed by the `catt` CLI over the local network.
- The panel uses bundled `nest-mini.svg` and `chromecast.svg` assets for Mini speakers and Cast groups.
- Cover art is fetched from the largest image in `media_metadata.images` and cached in Noctalia's per-plugin data directory. The separate top-level `icon_url` is used as the Cast app icon, not track artwork. Track title, artist, album, playback time, duration, stream type, volume, mute state, and Cast app details are read from `catt info --json-output`.
- The URL is passed as a separate process argument, not through a shell. The speaker must be able to access the media URL; supported media and streaming sites depend on `catt`.
- Device selection includes devices reported as `Google Home Mini` or `Google Cast Group`; other Chromecast models are not listed.
- This plugin does not use Google account credentials or call cloud APIs directly.
