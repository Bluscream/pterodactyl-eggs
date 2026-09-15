#!/usr/bin/env bash
# Startup wrapper for the BattleBit Remastered egg.
#
# The launch arguments are assembled here rather than in the panel's startup line, for three
# reasons the old one-liner got wrong:
#
#   1. Quoting. The startup line is expanded and then `eval`-ed by the image entrypoint, so a
#      value containing spaces has to survive two rounds of word splitting. The previous line
#      wrote -Name="{{SERVER_NAME}}"" -- which left the value UNQUOTED after expansion, so the
#      default server name split into six arguments.
#   2. Empty optionals. -Password= and -apitoken= with nothing after them are not the same as
#      omitting the flag. Built here, empty values drop out entirely.
#   3. ";" chaining. The old line chained cd/winetricks/export/wine with semicolons, which only
#      works because the wine image's entrypoint expands with $(echo ...). The games:* images use
#      `eval echo $(...)` instead, where every segment after the first executes during variable
#      assignment -- the trap documented in dayz-standalone/boot.sh. One command is immune.
set -u

cd /home/container || exit 1

BIN="${SERVER_BINARY:-BattleBit.exe}"
if [ ! -f "./${BIN}" ]; then
    echo "[boot] FATAL: ./${BIN} not found."
    echo "[boot]   The install downloads it from Steam appid ${STEAMCMD_APPID:-671860} on the"
    echo "[boot]   ${STEAM_BRANCH:-community-server} branch, which requires an account that OWNS"
    echo "[boot]   BattleBit Remastered. Reinstall and check the install log."
    exit 1
fi

# BattleBit reads server admin/permission entries from this file. Create it empty rather than
# letting the game fail to open it.
[ -f ./Permissions.txt ] || touch ./Permissions.txt

# WINEARCH and WINEPREFIX are deliberately NOT set here. The image entrypoint creates the prefix
# before this script runs, and WINEARCH only has any effect at creation time -- exporting it here
# (as the old startup line did) is always too late. Both are egg variables so the entrypoint sees
# them. Same for WINETRICKS_RUN: the entrypoint already loops `winetricks -q` over it, so verbs
# like sound=disabled belong in that variable, not in a per-boot winetricks call here.

ARGS=(-batchmode -nographics)

add() { # flag, value -- append "flag=value" only when value is non-empty
    [ -n "${2}" ] && ARGS+=("${1}=${2}")
    return 0
}

add -Name           "${SERVER_NAME:-}"
add -Port           "${SERVER_PORT:-}"
add -Hz             "${SERVER_HZ:-}"
add -AntiCheat      "${SERVER_ANTICHEAT:-}"
add -MaxPing        "${SERVER_MAXPING:-}"
add -VoxelMode      "${SERVER_VOXELMODE:-}"
add -ApiEndPoint    "${SERVER_APIENDPOINT:-}"
add -apitoken       "${SERVER_APITOKEN:-}"
add -FirstMap       "${SERVER_FIRSTMAP:-}"
add -FirstGamemode  "${SERVER_FIRSTGAMEMODE:-}"
add -FixedSize      "${SERVER_FIXEDSIZE:-}"
add -FirstSize      "${SERVER_FIRSTSIZE:-}"
add -MaxSize        "${SERVER_MAXSIZE:-}"
add -MaxPlayers     "${MAX_PLAYERS:-}"
add -Password       "${SERVER_PASSWORD:-}"

# STARTUP_PARAMS is split on whitespace on purpose -- it is a place to pass additional flags, so it
# cannot be quoted as a single argument. Values containing spaces are not supported here.
if [ -n "${STARTUP_PARAMS:-}" ]; then
    # shellcheck disable=SC2206
    ARGS+=(${STARTUP_PARAMS})
fi

if [ -n "${SERVER_APIENDPOINT:-}" ] && [ -z "${SERVER_APITOKEN:-}" ]; then
    echo "[boot] NOTE: an API endpoint is set but no API token. If your endpoint requires"
    echo "[boot]   authentication the server will be refused; leave both empty for no API."
fi

# The password is the one argument worth hiding: the console output is visible to anyone with
# panel access, and it is echoed on every boot.
printed=()
for a in "${ARGS[@]}"; do
    case "${a}" in -Password=*) printed+=("-Password=<hidden>") ;; *) printed+=("${a}") ;; esac
done
echo "[boot] Starting: wine ./${BIN} ${printed[*]}"

exec wine "./${BIN}" "${ARGS[@]}"
