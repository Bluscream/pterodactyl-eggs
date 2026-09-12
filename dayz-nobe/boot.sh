#!/usr/bin/env bash
# Single startup command for this egg. Do NOT go back to a ";"-chained startup line.
#
# The runtime image (ghcr.io/parkervcp/games:dayz) builds the start command like this:
#
#   modifiedStartup=`eval echo $(echo ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g')`
#   ${modifiedStartup}
#
# Two consequences:
#   * Inside that backtick eval, ";" IS a shell separator, so every segment after the
#     first is executed right there, during variable assignment.
#   * The first segment is only an argument to `echo` -- it never runs.
#
# So "a; b; ./server" silently skips exactly one segment, and which one depends on how
# many there are. That is why setup_vpp.sh stopped running when the startup line went
# from three segments to two. Keeping everything in this wrapper makes the startup line
# a single command, immune to that parsing.
set -u

cd /home/container || exit 1

if [ -f ./setup_vpp.sh ]; then
    bash ./setup_vpp.sh || echo "[boot] WARNING: setup_vpp.sh exited non-zero -- continuing to server start."
else
    echo "[boot] WARNING: setup_vpp.sh missing -- no BattlEye patching, RCON config or init.c install."
fi

BIN="./${SERVER_BINARY:-DayZServer}"
if [ ! -f "${BIN}" ]; then
    echo "[boot] FATAL: server binary ${BIN} not found."
    exit 1
fi

echo "[boot] Starting: ${BIN} $*"
exec "${BIN}" "$@"
