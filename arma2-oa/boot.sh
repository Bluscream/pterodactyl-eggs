#!/usr/bin/env bash
# Startup wrapper for the Arma 2: Operation Arrowhead egg.
#
# Same single-command reasoning as the sibling eggs: the runtime builds the start command inside
# a backtick `eval`, so a ";"-chained startup line silently loses a segment. Everything that has
# to happen before the engine runs happens here, and the panel's startup line stays one command.
#
# Four jobs, none of which the startup line can do on its own:
#   1. re-lowercase anything uploaded since install
#   2. sync mod .bikey files into keys/ so verifySignatures actually passes
#   3. write or remove the BattlEye RCON config, per DISABLE_BATTLEYE
#   4. drop -mod entries whose folders are missing
set -u

cd /home/container || exit 1

SERVER_CFG="./server.cfg"

# --- 1. Lowercase ------------------------------------------------------------------------
# The engine resolves every path lowercase internally. A mission or mod uploaded through the
# file manager keeps its original casing, and ANY uppercase letter in a filename makes the
# server fail to load it -- so this runs every boot, not just at install.
if [ -x ./tolower ]; then
    ./tolower > /dev/null 2>&1 || true
elif [ -f ./tolower.c ] && command -v gcc > /dev/null 2>&1; then
    gcc -O -o tolower tolower.c 2>/dev/null && ./tolower > /dev/null 2>&1 || true
else
    echo "[boot] WARNING: no tolower binary and no gcc -- filenames were not normalised."
    echo "[boot]   An uppercase letter in a mission or mod filename will break loading."
fi

# --- 2. Mod signature keys ----------------------------------------------------------------
# verifySignatures = 2 rejects any addon whose .bikey is not in keys/. Mods ship theirs in
# their own keys/ (occasionally key/) directory, so collect them. Without this step, adding a
# mod and setting VERIFY_SIGNATURES=2 silently rejects every client that loads it.
if [ "${SYNC_MOD_KEYS:-1}" = "1" ]; then
    mkdir -p ./keys
    synced=0
    for dir in ./@*; do
        [ -d "${dir}" ] || continue
        for keydir in "${dir}/keys" "${dir}/key" "${dir}/Keys" "${dir}/Key"; do
            [ -d "${keydir}" ] || continue
            for key in "${keydir}"/*.bikey "${keydir}"/*.biKey; do
                [ -f "${key}" ] || continue
                base="$(basename "${key}" | tr '[:upper:]' '[:lower:]')"
                if [ ! -f "./keys/${base}" ]; then
                    cp "${key}" "./keys/${base}" && synced=$((synced+1))
                fi
            done
        done
    done
    [ "${synced}" -gt 0 ] && echo "[boot] Synced ${synced} mod signature key(s) into keys/."
fi

# --- 3. BattlEye ---------------------------------------------------------------------------
# DISABLE_BATTLEYE is the SOLE decider, matching the dayz-standalone egg:
#   1 -> BattlEye = 0 in server.cfg, beserver.cfg removed. No BattlEye, no RCON.
#   0 -> BattlEye = 1, beserver.cfg written from ADMIN_PASSWORD/RCON_PORT. BattlEye + RCON.
# Anything other than an explicit 0 counts as 1.
#
# Note there is no binary patching here, unlike dayz-standalone: this is a 2010 engine with no
# BattlEye global-ban network to hide from. The switch exists because BattlEye on A2OA is an
# extra moving part that frequently breaks modded servers, not to evade bans.
if [ "${DISABLE_BATTLEYE:-1}" != "0" ]; then
    DISABLE_BATTLEYE=1
fi

set_cfg() { # key, value -- replace or append in server.cfg
    [ -f "${SERVER_CFG}" ] || return 0
    if grep -qi "^[[:space:]]*$1[[:space:]]*=" "${SERVER_CFG}"; then
        sed -i "s|^[[:space:]]*$1[[:space:]]*=.*|$1 = $2;|I" "${SERVER_CFG}"
    else
        echo "$1 = $2;" >> "${SERVER_CFG}"
    fi
}

# BattlEye's own directory must be lowercase like everything else the engine touches.
BE_DIR="./battleye"
mkdir -p "${BE_DIR}"

if [ "${DISABLE_BATTLEYE}" = "1" ]; then
    set_cfg BattlEye 0
    # Delete rather than skip: a leftover beserver.cfg reads as though RCON were available on a
    # server where BattlEye never loads.
    rm -f "${BE_DIR}/beserver.cfg" "${BE_DIR}/BEServer.cfg"
    echo "[boot] BattlEye disabled (DISABLE_BATTLEYE=1). RCON unavailable by design."
else
    set_cfg BattlEye 1
    cat > "${BE_DIR}/beserver.cfg" <<EOF
// Managed by boot.sh. DISABLE_BATTLEYE=0 wrote this file.
RConPassword ${ADMIN_PASSWORD:-changeme}
RConPort ${RCON_PORT:-2306}
RestrictRCon 0
EOF
    echo "[boot] BattlEye enabled. RCON on port ${RCON_PORT:-2306}."
    if [ -z "${ADMIN_PASSWORD:-}" ]; then
        echo "[boot] WARNING: ADMIN_PASSWORD is empty -- RCON password defaulted to 'changeme'."
    fi
fi

BIN="./${SERVER_BINARY:-server}"
if [ ! -f "${BIN}" ]; then
    echo "[boot] FATAL: server binary ${BIN} not found."
    echo "[boot]   Expected the ELF from the Linux server package, not the arma2oaserver wrapper."
    exit 1
fi
chmod +x "${BIN}" 2>/dev/null || true

# --- 4. Mod arguments ----------------------------------------------------------------------
# Drop entries whose folders are absent, and omit the flag entirely when nothing is left --
# passing a bare -mod="" makes the engine parse an empty modlist entry.
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
            [ -n "${kept}" ] && ARGS+=("${prefix}=${kept}")
            ;;
        *)
            ARGS+=("${arg}")
            ;;
    esac
done

echo "[boot] Starting: ${BIN} ${ARGS[*]}"
exec "${BIN}" "${ARGS[@]}"
