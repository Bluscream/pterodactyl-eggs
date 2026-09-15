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

# Drop mods whose folders are not actually present. DayZ refuses to start when -mod names a
# directory that does not exist, so one failed workshop download would otherwise take the
# whole server down (observed: adding 8 mods with no Steam credentials -> OFFLINE). Starting
# with the mods we have, and saying loudly which are missing, beats not starting at all.
ARGS=()
for arg in "$@"; do
    case "${arg}" in
        -mod=*)
            prefix="${arg%%=*}"
            kept=""
            dropped=""
            raw_mods="${arg#*=}"
            if [ -f "/home/container/.active_mods" ] && [ -s "/home/container/.active_mods" ]; then
                raw_mods="$(tr -d '\r\n' < /home/container/.active_mods)"
                echo "[boot] Using synced collection mods from .active_mods: ${raw_mods}"
            fi
            IFS=';' read -ra entries <<< "${raw_mods}"
            for entry in "${entries[@]}"; do
                [ -z "${entry}" ] && continue
                if [ -d "/home/container/${entry#@}" ] || [ -d "/home/container/${entry}" ]; then
                    kept="${kept}${entry};"
                else
                    dropped="${dropped} ${entry}"
                fi
            done
            if [ -n "${dropped}" ]; then
                echo "[boot] WARNING: ${prefix} entries not installed, dropping:${dropped}"
                echo "[boot]   Server will start without them. Check the [Mods] lines above."
            fi
            ARGS+=("${prefix}=${kept}")
            ;;
        -serverMod=*)
            prefix="${arg%%=*}"
            kept=""
            dropped=""
            IFS=';' read -ra entries <<< "${arg#*=}"
            for entry in "${entries[@]}"; do
                [ -z "${entry}" ] && continue
                if [ -d "/home/container/${entry#@}" ] || [ -d "/home/container/${entry}" ]; then
                    kept="${kept}${entry};"
                else
                    dropped="${dropped} ${entry}"
                fi
            done
            if [ -n "${dropped}" ]; then
                echo "[boot] WARNING: ${prefix} entries not installed, dropping:${dropped}"
                echo "[boot]   Server will start without them. Check the [Mods] lines above."
            fi
            ARGS+=("${prefix}=${kept}")
            ;;
        *)
            ARGS+=("${arg}")
            ;;
    esac
done

echo "[boot] Starting: ${BIN} ${ARGS[*]}"
exec "${BIN}" "${ARGS[@]}"
