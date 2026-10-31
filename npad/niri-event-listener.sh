#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
runtime_dir="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}/npad-${UID}}"
pid_file="${runtime_dir}/npad-niri-event-stream.pid"

if [[ ! -d "$runtime_dir" ]]; then
    mkdir -p "$runtime_dir"
    chmod 700 "$runtime_dir"
fi

case "$mode" in
    start)
        script="${2:?missing listener script}"
        if [[ -f "$pid_file" ]]; then
            read -r existing_pid < "$pid_file" || true
            if [[ "${existing_pid:-}" =~ ^[0-9]+$ ]] && kill -0 "$existing_pid" 2>/dev/null; then
                cmdline="$(tr '\0' ' ' < "/proc/$existing_pid/cmdline" 2>/dev/null || true)"
                if [[ "$cmdline" == *"npad-niri-event-listener"* ]]; then
                    exit 0
                fi
            fi
        fi

        nohup bash -c "$script" npad-niri-event-listener listen "$script" \
            </dev/null >/dev/null 2>&1 &
        printf '%s\n' "$!" > "$pid_file"
        ;;
    stop)
        if [[ ! -f "$pid_file" ]]; then
            exit 0
        fi

        read -r listener_pid < "$pid_file" || true
        if [[ "${listener_pid:-}" =~ ^[0-9]+$ ]] && kill -0 "$listener_pid" 2>/dev/null; then
            cmdline="$(tr '\0' ' ' < "/proc/$listener_pid/cmdline" 2>/dev/null || true)"
            if [[ "$cmdline" == *"npad-niri-event-listener"* ]]; then
                kill "$listener_pid"
            fi
        fi
        rm -f "$pid_file"
        ;;
    listen)
        listener_error() {
            noctalia msg plugin ffngs/npad:manager all niri-listener-error || true
        }
        trap listener_error ERR

        work_dir="$(mktemp -d "${runtime_dir}/npad-events.XXXXXX")"
        fifo="${work_dir}/events"
        mkfifo "$fifo"

        cleanup() {
            trap - EXIT TERM INT
            kill "$stream_pid" 2>/dev/null || true
            wait "$stream_pid" 2>/dev/null || true
            rm -f "$fifo"
            rm -f "${work_dir}/niri.stderr"
            rmdir "$work_dir"
            if [[ -f "$pid_file" ]]; then
                read -r current_pid < "$pid_file" || true
                if [[ "${current_pid:-}" == "$$" ]]; then
                    rm -f "$pid_file"
                fi
            fi
        }
        trap cleanup EXIT
        trap 'exit 0' TERM INT

        niri msg --json event-stream > "$fifo" 2> "${work_dir}/niri.stderr" &
        stream_pid="$!"
        while IFS= read -r event; do
            case "$event" in
                *'"WorkspacesChanged"'*|*'"WorkspaceActivated"'*|*'"WindowsChanged"'*|*'"WindowOpenedOrChanged"'*|*'"WindowClosed"'*|*'"WindowFocusChanged"'*)
                    if ! noctalia msg plugin ffngs/npad:manager all niri-event; then
                        printf 'Could not deliver a Niri event to the npad panel.\n' >&2
                        exit 1
                    fi
                    ;;
            esac
        done < "$fifo"

        set +e
        wait "$stream_pid"
        stream_status="$?"
        set -e
        if [[ "$stream_status" -ne 0 ]]; then
            noctalia msg plugin ffngs/npad:manager all niri-listener-error
        fi
        ;;
    *)
        printf 'Usage: %s {start|stop|listen}\n' "$0" >&2
        exit 2
        ;;
esac
