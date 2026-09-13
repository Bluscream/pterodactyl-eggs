#!/usr/bin/env bash
# Single startup command for the DayZ Mod egg. Same reasoning as dayz-standalone/boot.sh: the
# runtime builds the start command inside a backtick `eval`, so a ";"-chained startup line
# silently loses a segment. Everything that needs to happen before the server runs happens
# here instead, and the panel's startup line stays one command.
#
# This wrapper also exists for a second reason specific to DayZ Mod: the server's stdout has
# to be piped into ./writer.pl, which is what actually performs Hive database writes. A pipe
# in the panel startup field is fragile; a pipe in a script is not.
set -u

cd /home/container || exit 1

# 1. Lowercase anything newly added.
# The engine resolves every path lowercase internally. A mission or mod uploaded through the
# file manager keeps its original casing, and ANY uppercase letter in a filename crashes the
# server on load -- so this runs on every boot, not just install.
if [ -x ./tolower ]; then
    ./tolower > /dev/null 2>&1 || true
elif [ -f ./tolower.c ] && command -v gcc > /dev/null 2>&1; then
    gcc -O -o tolower tolower.c 2>/dev/null && ./tolower > /dev/null 2>&1 || true
else
    echo "[boot] WARNING: no tolower binary and no gcc -- filenames were not normalised."
    echo "[boot]   An uppercase letter in any mission or mod filename will crash the server."
fi

# 2. Windows leftovers. A 32-bit ELF cannot load a PE DLL, and BattlEye in particular trips
# over the stray .dll files Steam delivers into battleye/ and expansion/battleye/.
find ./battleye ./expansion -maxdepth 2 -name '*.dll' -delete 2>/dev/null || true

# 3. Hive database reachability. Without a Hive the server still starts and is playable, but
# nothing persists -- players respawn fresh every join. That is a confusing failure to debug
# from inside the game, so say it plainly here instead.
if [ "${HIVE_ENABLED:-1}" = "1" ]; then
    if [ ! -f ./writer.pl ]; then
        echo "[boot] WARNING: HIVE_ENABLED=1 but ./writer.pl is missing. Starting WITHOUT"
        echo "[boot]   persistence -- no player or vehicle state will be saved."
        HIVE_ENABLED=0
    elif ! command -v perl > /dev/null 2>&1; then
        echo "[boot] WARNING: HIVE_ENABLED=1 but perl is not installed in this image."
        echo "[boot]   Starting WITHOUT persistence."
        HIVE_ENABLED=0
    fi
fi

BIN="./${SERVER_BINARY:-server}"
if [ ! -f "${BIN}" ]; then
    echo "[boot] FATAL: server binary ${BIN} not found."
    exit 1
fi
chmod +x "${BIN}" 2>/dev/null || true

# The 32-bit engine needs the 32-bit loader path; "." covers the libs shipped beside the
# binary, /usr/lib32 the distro ones.
export LD_LIBRARY_PATH=".:/usr/lib32:${LD_LIBRARY_PATH:-}"

# Drop -mod entries whose folders are absent. Borrowed from dayz-standalone: the engine refuses to
# start when -mod names a directory that does not exist, and starting without one mod beats
# not starting at all.
ARGS=()
for arg in "$@"; do
    case "${arg}" in
        -mod=*|-serverMod=*)
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
            fi
            ARGS+=("${prefix}=${kept}")
            ;;
        *)
            ARGS+=("${arg}")
            ;;
    esac
done

echo "[boot] Starting: ${BIN} ${ARGS[*]}"
if [ "${HIVE_ENABLED:-1}" = "1" ]; then
    chmod +x ./writer.pl 2>/dev/null || true
    exec "${BIN}" "${ARGS[@]}" 2>&1 | ./writer.pl
else
    exec "${BIN}" "${ARGS[@]}"
fi
