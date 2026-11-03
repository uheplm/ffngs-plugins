#!/usr/bin/env python3
"""Maintain a Cast connection and publish playback changes for the plugin UI."""

from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import signal
import sys
import threading
import time
from uuid import UUID


class ConnectionListener:
    def __init__(self, bridge: StatusBridge, selected_uuid: str) -> None:
        self.bridge = bridge
        self.selected_uuid = selected_uuid

    def new_cast_status(self, status) -> None:
        self.bridge.update_cast_status(status, self.selected_uuid)

    def new_media_status(self, status) -> None:
        self.bridge.update_media_status(status, self.selected_uuid)

    def load_media_failed(self, _queue_item_id, error_code) -> None:
        self.bridge.report_media_error(self.selected_uuid, error_code)


class StatusBridge:
    def __init__(self, data_dir: Path) -> None:
        self.settings_path = data_dir / "settings.json"
        self.status_path = data_dir / "cast-status.json"
        self.stop_event = threading.Event()
        self.lock = threading.Lock()
        self.publish_lock = threading.Lock()
        self.cast = None
        self.cast_key = None
        self.next_connect_attempt = 0.0
        self.snapshot: dict = {
            "player_state": "UNKNOWN",
            "volume_level": 0,
            "volume_muted": False,
            "current_time": 0,
            "duration": 0,
            "stream_type": "NONE",
            "content_type": "",
            "playback_rate": 1,
            "display_name": "",
            "device_name": "",
            "status_text": "",
            "media_metadata": {},
            "icon_url": "",
            "selected_uuid": "",
        }

    def publish(self) -> None:
        temporary_path = self.status_path.with_suffix(".tmp")
        with self.publish_lock:
            with self.lock:
                data = dict(self.snapshot)
            try:
                temporary_path.write_text(json.dumps(data), encoding="utf-8")
                os.replace(temporary_path, self.status_path)
            except OSError as error:
                print(f"Could not write Cast status: {error}", file=sys.stderr, flush=True)

    def update_cast_status(self, status, expected_uuid: str | None = None) -> None:
        with self.lock:
            if expected_uuid is not None and self.snapshot["selected_uuid"] != expected_uuid:
                return
            if status is not None:
                self.snapshot["volume_level"] = status.volume_level
                self.snapshot["volume_muted"] = status.volume_muted
                self.snapshot["display_name"] = status.display_name or ""
                self.snapshot["icon_url"] = status.icon_url or ""
                self.snapshot["status_text"] = status.status_text or ""
        self.publish()

    def update_media_status(self, status, expected_uuid: str | None = None) -> None:
        if status is None:
            return
        metadata = status.media_metadata or {}
        if not isinstance(metadata, dict):
            metadata = {}
        raw_images = metadata.get("images", [])
        images = []
        if isinstance(raw_images, list):
            for image in raw_images:
                if isinstance(image, dict) and isinstance(image.get("url"), str):
                    images.append({
                        "url": image["url"],
                        "width": image.get("width", 0),
                        "height": image.get("height", 0),
                    })
        with self.lock:
            if expected_uuid is not None and self.snapshot["selected_uuid"] != expected_uuid:
                return
            self.snapshot.update({
                "player_state": status.player_state or "UNKNOWN",
                "volume_level": status.volume_level,
                "volume_muted": status.volume_muted,
                "current_time": status.adjusted_current_time or 0,
                "duration": status.duration or 0,
                "stream_type": status.stream_type or "NONE",
                "content_type": status.content_type or "",
                "playback_rate": status.playback_rate or 1,
                "status_text": self.snapshot.get("status_text", ""),
                "media_metadata": {
                    "title": metadata.get("title", ""),
                    "artist": metadata.get("artist", ""),
                    "albumName": metadata.get("albumName", ""),
                    "seriesTitle": metadata.get("seriesTitle", ""),
                    "season": metadata.get("season"),
                    "episode": metadata.get("episode"),
                    "images": images,
                },
            })
        self.publish()

    def read_settings(self) -> tuple[tuple[str, str, str, str, int] | None, int]:
        try:
            settings = json.loads(self.settings_path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return None, 2
        except (OSError, json.JSONDecodeError) as error:
            print(f"Could not read saved Cast selection: {error}", file=sys.stderr, flush=True)
            return None, 2
        if not isinstance(settings, dict):
            return None, 2
        if settings.get("connected") is not True:
            return None, 2
        selected_uuid = settings.get("selectedUuid")
        devices = settings.get("devices")
        try:
            poll_interval = max(1, min(60, int(settings.get("pollInterval", 2))))
        except (TypeError, ValueError):
            poll_interval = 2
        if not isinstance(selected_uuid, str) or not isinstance(devices, list):
            return None, poll_interval
        for device in devices:
            if not isinstance(device, dict) or device.get("uuid") != selected_uuid:
                continue
            name, host, model = device.get("name"), device.get("host"), device.get("model")
            port = device.get("port", 32000 if model == "Google Cast Group" else 8009)
            if (
                all(isinstance(value, str) and value for value in (name, host, model))
                and isinstance(port, int)
                and not isinstance(port, bool)
                and 1 <= port <= 65535
            ):
                return (selected_uuid, name, host, model, port), poll_interval
        return None, poll_interval

    def disconnect(self) -> None:
        cast, self.cast = self.cast, None
        self.cast_key = None
        if cast is not None:
            cast.disconnect()

    def connect_selection(self, selection: tuple[str, str, str, str, int] | None) -> None:
        key = (selection[0], selection[2], selection[4]) if selection is not None else None
        if key == self.cast_key and (self.cast is not None or time.monotonic() < self.next_connect_attempt):
            return
        self.disconnect()
        with self.lock:
            self.snapshot["selected_uuid"] = selection[0] if selection is not None else ""
            self.snapshot.update({
                "player_state": "UNKNOWN",
                "volume_level": 0,
                "volume_muted": False,
                "current_time": 0,
                "duration": 0,
                "stream_type": "NONE",
                "content_type": "",
                "playback_rate": 1,
                "display_name": "",
                "device_name": selection[1] if selection is not None else "",
                "status_text": "",
                "media_metadata": {},
                "icon_url": "",
            })
        self.publish()
        if selection is None:
            return
        selected_uuid, _name, host, model, port = selection
        self.cast_key = key
        self.next_connect_attempt = time.monotonic() + 10
        cast = None
        try:
            from pychromecast import Chromecast
            from pychromecast.const import CAST_TYPE_AUDIO, CAST_TYPE_GROUP
            from pychromecast.error import PyChromecastError
            from pychromecast.models import CastInfo, HostServiceInfo

            cast_type = CAST_TYPE_GROUP if model == "Google Cast Group" else CAST_TYPE_AUDIO
            listener = ConnectionListener(self, selected_uuid)
            cast_info = CastInfo(
                services={HostServiceInfo(host, port)},
                uuid=UUID(selected_uuid),
                model_name=model,
                friendly_name=None,
                host=host,
                port=port,
                cast_type=cast_type,
                manufacturer="Google Inc.",
            )
            cast = Chromecast(cast_info, tries=1)
            cast.register_status_listener(listener)
            cast.media_controller.register_status_listener(listener)
            cast.wait(timeout=10)
            self.cast = cast
            self.next_connect_attempt = 0
            cast.socket_client.receiver_controller.update_status()
            cast.media_controller.update_status()
        except (OSError, ValueError, TimeoutError, PyChromecastError) as error:
            if cast is not None:
                cast.disconnect()
            print(f"Could not connect to {host}: {error}", file=sys.stderr, flush=True)
            with self.lock:
                self.snapshot["player_state"] = "UNKNOWN"
                self.snapshot["status_text"] = f"Could not connect to speaker: {error}"
            self.publish()

    def report_media_error(self, expected_uuid: str, error_code) -> None:
        with self.lock:
            if self.snapshot["selected_uuid"] != expected_uuid:
                return
            self.snapshot["status_text"] = f"Cast could not load media (error {error_code})."
        self.publish()

    def run(self) -> None:
        try:
            from pychromecast.error import PyChromecastError
        except ImportError as error:
            selection, _ = self.read_settings()
            with self.lock:
                self.snapshot["selected_uuid"] = selection[0] if selection is not None else ""
                self.snapshot["status_text"] = "PyChromecast is not installed for this Python interpreter."
            self.publish()
            print(f"Could not load PyChromecast: {error}", file=sys.stderr, flush=True)
            return

        last_status_request = 0.0
        while not self.stop_event.is_set():
            selection, poll_interval = self.read_settings()
            self.connect_selection(selection)
            now = time.monotonic()
            if self.cast is not None and now - last_status_request >= poll_interval:
                try:
                    self.cast.socket_client.receiver_controller.update_status()
                    self.cast.media_controller.update_status()
                except (OSError, TimeoutError, PyChromecastError) as error:
                    with self.lock:
                        self.snapshot["status_text"] = f"Could not request speaker status: {error}"
                    self.publish()
                last_status_request = now
            self.stop_event.wait(0.5)
        self.disconnect()

    def stop(self, _signal_number=None, _frame=None) -> None:
        self.stop_event.set()


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: cast-status.py DATA_DIR", file=sys.stderr)
        return 2
    data_dir = Path(sys.argv[1])
    data_dir.mkdir(parents=True, exist_ok=True)
    pid_path = data_dir / "cast-status.pid"

    lock_file = pid_path.open("a+", encoding="ascii")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return 0
    lock_file.seek(0)
    lock_file.truncate()
    lock_file.write(str(os.getpid()))
    lock_file.flush()

    bridge = StatusBridge(data_dir)
    signal.signal(signal.SIGTERM, bridge.stop)
    signal.signal(signal.SIGINT, bridge.stop)
    try:
        bridge.run()
    finally:
        bridge.disconnect()
        try:
            pid_path.unlink()
        except FileNotFoundError:
            pass
        lock_file.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
