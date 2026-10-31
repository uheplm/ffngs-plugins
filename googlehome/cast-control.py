#!/usr/bin/env python3
"""Send app, media, and queue commands to the selected Cast device."""

from __future__ import annotations

import sys
from uuid import UUID

from pychromecast import Chromecast
from pychromecast.const import (
    CAST_TYPE_AUDIO,
    CAST_TYPE_GROUP,
    MESSAGE_TYPE,
)
from pychromecast.controllers.media import TYPE_PAUSE, TYPE_PLAY
from pychromecast.error import RequestTimeout
from pychromecast.models import CastInfo, HostServiceInfo


def main() -> int:
    if len(sys.argv) != 6:
        print("Usage: cast-control.py stop|play|pause|previous|next UUID HOST PORT MODEL", file=sys.stderr)
        return 2

    action, selected_uuid, host, port_value, model = sys.argv[1:]
    if action not in {"stop", "play", "pause", "previous", "next"}:
        print(f"Unsupported Cast media action: {action}", file=sys.stderr)
        return 2
    try:
        port = int(port_value)
        device_uuid = UUID(selected_uuid)
    except ValueError as error:
        print(f"Invalid Cast device address: {error}", file=sys.stderr)
        return 2
    if not 1 <= port <= 65535:
        print("Cast device port must be between 1 and 65535.", file=sys.stderr)
        return 2

    cast_type = CAST_TYPE_GROUP if model == "Google Cast Group" else CAST_TYPE_AUDIO
    cast_info = CastInfo(
        services={HostServiceInfo(host, port)},
        uuid=device_uuid,
        model_name=model,
        friendly_name=None,
        host=host,
        port=port,
        cast_type=cast_type,
        manufacturer="Google Inc.",
    )
    cast = Chromecast(cast_info, tries=1)
    try:
        cast.wait(timeout=10)
        if action == "stop":
            cast.quit_app(timeout=10)
            return 0

        media_controller = cast.media_controller
        media_controller.update_status()
        if not media_controller.session_active_event.wait(timeout=10):
            print("The Cast receiver has no active media session.", file=sys.stderr)
            return 1
        if action in {"play", "pause"}:
            status = media_controller.status
            if status is None or status.media_session_id is None:
                print("The Cast receiver has no active media session.", file=sys.stderr)
                return 1
            media_controller.send_message(
                {
                    MESSAGE_TYPE: TYPE_PLAY if action == "play" else TYPE_PAUSE,
                    "mediaSessionId": status.media_session_id,
                },
                inc_session_id=True,
            )
        elif action == "previous":
            media_controller.queue_prev(timeout=10)
        else:
            media_controller.queue_next(timeout=10)
    except RequestTimeout as error:
        print(f"The Cast receiver did not acknowledge {action}: {error}", file=sys.stderr)
        return 1
    finally:
        cast.disconnect()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
