#!/bin/sh
# theatre-os: recovery channel command handler.
#
# Invoked per-connection by systemd via theatre-os-recovery@.service on
# port 9091. Reads one line of input from the socket (stdin), runs the
# corresponding action, writes one line of response back (stdout).
#
# Protocol (line-oriented text, one round-trip per connection):
#   PING    → PONG                              (health probe)
#   RESTART → OK                                (kodi-gbm cycled cleanly)
#           → FAIL exit=N <systemctl stderr>    (systemctl failed)
#   <other> → FAIL unknown command: <word>
#
# Trust model: anyone on the LAN who can TCP-connect to :9091 can issue
# these commands. Same trust boundary as the dufs PUT endpoint we use for
# image distribution (see AGENTS.md). No auth by design — the LAN is the
# perimeter. If untrusted devices end up on the LAN, the worst they can
# do here is restart Kodi.
#
# See README → Kodi & moonlight session → Recovery channel.

set -u

# Block until the client sends a line. systemd's TimeoutStartSec on the
# spawned service kills us if the client never speaks, so no need for a
# read timeout here.
read -r cmd

case "$cmd" in
    PING)
        echo PONG
        ;;
    RESTART)
        # Capture both stdout and stderr from systemctl so we can surface
        # the failure reason in the response. systemctl is usually silent
        # on success (→ "OK") and emits the error reason on stderr on
        # failure (→ "FAIL exit=N <reason>").
        out=$(systemctl restart kodi-gbm.service 2>&1)
        rc=$?
        if [ "$rc" -eq 0 ]; then
            echo OK
        else
            # Collapse newlines so the response is a single line (HA's
            # input_text is single-line; multi-line responses confuse the
            # consumer). 255 char cap on HA side, so verbose systemctl
            # output may get truncated there — acceptable.
            msg=$(printf '%s' "$out" | tr '\n' ' ')
            echo "FAIL exit=$rc $msg"
        fi
        ;;
    *)
        echo "FAIL unknown command: $cmd"
        ;;
esac
