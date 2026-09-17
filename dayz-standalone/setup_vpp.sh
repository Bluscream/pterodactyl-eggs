#!/usr/bin/env bash
# VPP Admin Tools, Community Framework (CF), Server-Side Admin Commands & BattlEye RCON Setup Script
# Automatically manages keys, provisions SuperAdmin permissions, and syncs shared passwords

set -e

SERVER_ROOT="/home/container"
SERVER_PROFILE="${SERVER_ROOT}/serverprofile"
KEYS_DIR="${SERVER_ROOT}/keys"
BATTLEYE_DIR="${SERVER_ROOT}/battleye"
VPP_BASE="${SERVER_PROFILE}/VPPAdminTools"
VPP_SUPERADMINS_DIR="${VPP_BASE}/Permissions/SuperAdmins"
SERVER_CFG="${SERVER_ROOT}/serverDZ.cfg"

# Mission directory is read from serverDZ.cfg's Missions->DayZ->template rather than
# hardcoded: a server that switches to dayzOffline.enoch or .sakhal would otherwise
# silently write the custom init into a mission that is not being loaded.
MISSION_NAME="$(sed -n 's/^[[:space:]]*template[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${SERVER_CFG}" 2>/dev/null | head -1)"
MISSION_NAME="${MISSION_NAME:-dayzOffline.chernarusplus}"
MISSION_INIT="${SERVER_ROOT}/mpmissions/${MISSION_NAME}/init.c"

# 0. Steam Workshop mods with Steam Guard support
WORKSHOP_APPID="221100"
WORKSHOP_COLLECTION_ID="${WORKSHOP_COLLECTION_ID:-3800469441}"
STEAMCLI_BIN="${SERVER_ROOT}/steamcli"
STEAMCLI_URL="https://github.com/Bluscream/steam-cli/releases/latest/download/steamcli-linux-amd64"

# On-demand download of steamcli if missing from container
if [ ! -x "${STEAMCLI_BIN}" ] && ! command -v steamcli >/dev/null 2>&1; then
    echo "[Setup] steamcli not found; downloading latest binary from GitHub..."
    if curl --fail -sSL -o "${STEAMCLI_BIN}.tmp" "${STEAMCLI_URL}" 2>/dev/null; then
        mv "${STEAMCLI_BIN}.tmp" "${STEAMCLI_BIN}"
        chmod +x "${STEAMCLI_BIN}"
        echo "[Setup] Successfully downloaded steamcli."
    else
        rm -f "${STEAMCLI_BIN}.tmp"
        echo "[Setup] WARNING: Failed to download steamcli; falling back to legacy tools."
    fi
fi

# The value may also live in .steam_auth in the server root, which outlives the panel
# variable and can be chmod 600 -- worth preferring when the URL embeds an IPC password, since
# panel variables are stored in the database in plain text.
GUARD_FILE="${SERVER_ROOT}/.steam_auth"
[ -z "${STEAM_AUTH}" ] && [ -f "${GUARD_FILE}" ] && \
    STEAM_AUTH="$(tr -d ' \r\n' < "${GUARD_FILE}")"
[ -f "${GUARD_FILE}" ] && chmod 600 "${GUARD_FILE}" 2>/dev/null || true

is_url() { case "${1}" in http://*|https://*) return 0 ;; *) return 1 ;; esac; }

steam_guard_code() {
    [ -z "${STEAM_AUTH}" ] && return 0
    if ! is_url "${STEAM_AUTH}"; then
        echo "${STEAM_AUTH}"
        return 0
    fi
    local ipc_pw=""
    case "${STEAM_AUTH}" in
        *password=*)
            ipc_pw="${STEAM_AUTH##*password=}"
            ipc_pw="${ipc_pw%%&*}"
            ;;
    esac

    local response
    response="$(curl --fail -sSL --max-time 15 -H "Authentication: ${ipc_pw}" "${STEAM_AUTH}" 2>/dev/null)"
    if [ -z "${response}" ]; then
        response="$(curl --fail -sSL --max-time 15 "${STEAM_AUTH}" 2>/dev/null)"
    fi
    if [ -z "${response}" ]; then
        echo "[Mods] 2FA endpoint returned nothing (auth rejected or unreachable)." >&2
        return 0
    fi

    local code bare
    code="$(echo "${response}" | grep -oE '"Result"[[:space:]]*:[[:space:]]*"[A-Za-z0-9]{5}"' \
            | tail -1 | grep -oE '[A-Za-z0-9]{5}"$' | tr -d '"')"
    if [ -z "${code}" ]; then
        bare="$(echo "${response}" | tr -d ' \r\n')"
        case "${bare}" in [A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) code="${bare}" ;; esac
    fi
    [ -z "${code}" ] && code="$(echo "${response}" | grep -oE '[A-Z0-9]{5}' | head -1)"
    echo "${code}" | tr '[:lower:]' '[:upper:]'
}

sync_workshop_collection() {
    [ -z "${WORKSHOP_COLLECTION_ID}" ] && return 0

    local coll_ids=""
    if [ -x "${STEAMCLI_BIN}" ]; then
        echo "[Mods] Fetching mods from Workshop collection ${WORKSHOP_COLLECTION_ID} via steamcli..."
        coll_ids="$("${STEAMCLI_BIN}" workshop collection "${WORKSHOP_COLLECTION_ID}" --ids-only 2>/dev/null || true)"
    elif command -v steamcli >/dev/null 2>&1; then
        echo "[Mods] Fetching mods from Workshop collection ${WORKSHOP_COLLECTION_ID} via system steamcli..."
        coll_ids="$(steamcli workshop collection "${WORKSHOP_COLLECTION_ID}" --ids-only 2>/dev/null || true)"
    else
        echo "[Mods] Fetching mods from Workshop collection ${WORKSHOP_COLLECTION_ID} via Steam API..."
        local resp
        resp="$(curl --fail -sSL --max-time 15 -X POST "https://api.steampowered.com/ISteamRemoteStorage/GetCollectionDetails/v1/" \
            -d "collectioncount=1" -d "publishedfileids[0]=${WORKSHOP_COLLECTION_ID}" 2>/dev/null || true)"
        coll_ids="$(echo "${resp}" | grep -oE '"publishedfileid"[[:space:]]*:[[:space:]]*"[0-9]+"' | grep -oE '[0-9]+' || true)"
    fi

    if [ -n "${coll_ids}" ]; then
        local coll_count
        coll_count=$(echo "${coll_ids}" | wc -w)
        echo "[Mods] Discovered ${coll_count} mod(s) in collection ${WORKSHOP_COLLECTION_ID}."

        local replaced_mods=""
        for cid in ${coll_ids}; do
            [ -z "${cid}" ] && continue
            replaced_mods="${replaced_mods};@${cid}"
        done
        replaced_mods="$(echo "${replaced_mods}" | sed -e 's/^;//' -e 's/;$//' -e 's/;;*/;/g')"
        [ -n "${replaced_mods}" ] && replaced_mods="${replaced_mods};"

        if [ "${replaced_mods}" != "${MODIFICATIONS}" ]; then
            echo "[Mods] Replaced MODIFICATIONS with exact Workshop collection ${WORKSHOP_COLLECTION_ID} mods:"
            echo "[Mods]   Old: ${MODIFICATIONS}"
            echo "[Mods]   New: ${replaced_mods}"
            export MODIFICATIONS="${replaced_mods}"
        else
            echo "[Mods] Server mods already match Workshop collection exactly."
        fi

        echo "${MODIFICATIONS}" > "${SERVER_ROOT}/.active_mods" 2>/dev/null || true
    else
        echo "[Mods] WARNING: Could not fetch collection ${WORKSHOP_COLLECTION_ID} details; retaining existing MODIFICATIONS."
    fi
}

install_workshop_mods() {
    sync_workshop_collection

    [ -z "${MODIFICATIONS}" ] && return 0
    [ -z "${STEAM_USER}" ] && return 0
    [ "${STEAM_USER}" = "anonymous" ] && return 0

    local content="${SERVER_ROOT}/steamapps/workshop/content/${WORKSHOP_APPID}"

    # Clean up stale legacy steamcmd folder if steamcli is present
    if [ -x "${STEAMCLI_BIN}" ] && [ -d "${SERVER_ROOT}/steamcmd" ]; then
        echo "[Cleanup] steamcli is active; removing redundant legacy steamcmd/ directory to reclaim space..."
        rm -rf "${SERVER_ROOT}/steamcmd" 2>/dev/null || true
    fi

    # Check which mods are missing from workshop content or need linking
    local missing=""
    local id
    for id in $(echo "${MODIFICATIONS}" | tr ';' ' ' | tr -d '@'); do
        [ -z "${id}" ] && continue
        # If real directory or symlink exists and workshop directory is present, verify link
        if [ ! -d "${content}/${id}" ] && [ ! -d "${SERVER_ROOT}/@${id}" ]; then
            missing="${missing} ${id}"
        fi
    done

    if [ -n "${missing}" ]; then
        echo "[Mods] Missing workshop mods:${missing}"

        local code
        code="$(steam_guard_code)"
        if [ -n "${code}" ]; then
            echo "[Mods] Using a Steam Guard code (not logged here)."
        else
            echo "[Mods] No Steam Guard code available -- relying on the stored sentry file."
        fi

        local fails=0
        for id in ${missing}; do
            if [ "${fails}" -ge 2 ]; then
                echo "[Mods] Two consecutive failures -- stopping for this boot (Steam is likely"
                echo "[Mods]   rate-limiting logins). Remaining mods retry on the next restart."
                break
            fi
            if [ -z "${code}" ] || is_url "${STEAM_AUTH}"; then
                code="$(steam_guard_code)"
            fi
            echo "[Mods] Downloading ${id}..."
            if [ -x "${STEAMCLI_BIN}" ] || command -v steamcli >/dev/null 2>&1; then
                local cli_bin="${STEAMCLI_BIN}"
                [ ! -x "${cli_bin}" ] && cli_bin="steamcli"
                local auth_flag=()
                [ -n "${code}" ] && auth_flag=(--auth-code "${code}")
                timeout 900 "${cli_bin}" cmd workshop "${WORKSHOP_APPID}" "${id}" \
                    --dir "${SERVER_ROOT}" \
                    --user "${STEAM_USER}" \
                    --password "${STEAM_PASS}" \
                    "${auth_flag[@]}" \
                    < /dev/null > "${SERVER_ROOT}/.steamcmd_mods.log" 2>&1 || true
            else
                timeout 900 "${SERVER_ROOT}/steamcmd/steamcmd.sh" +force_install_dir "${SERVER_ROOT}" \
                    +login "${STEAM_USER}" "${STEAM_PASS}" ${code} \
                    +workshop_download_item "${WORKSHOP_APPID}" "${id}" +quit \
                    < /dev/null > "${SERVER_ROOT}/.steamcmd_mods.log" 2>&1 || true
            fi

            if grep -qi "check your email\|Steam Guard code" "${SERVER_ROOT}/.steamcmd_mods.log" 2>/dev/null; then
                echo "[Mods] Steam asked for a Guard code that this login did not satisfy."
                echo "[Mods]   steamcmd's prompt text mentions email, but it says that for any"
                echo "[Mods]   unauthenticated machine -- it is not evidence of the Guard type."
                echo "[Mods]   A fresh code is minted per mod when STEAM_AUTH is a URL."
            fi

            if [ ! -d "${content}/${id}" ]; then
                echo "[Mods] FAILED: ${id} did not download. Check STEAM_USER/STEAM_PASS, that the"
                echo "[Mods]   account owns DayZ, and that Steam Guard is satisfied."
                fails=$((fails+1))
                continue
            fi
            fails=0
        done
    fi

    # Link workshop downloads into @<id> (Zero drive space duplication)
    for id in $(echo "${MODIFICATIONS}" | tr ';' ' ' | tr -d '@'); do
        [ -z "${id}" ] && continue
        local mod_target="${content}/${id}"
        local mod_link="${SERVER_ROOT}/@${id}"

        if [ -d "${mod_target}" ]; then
            # Ensure filenames in source workshop folder are lowercase
            if [ "${MODS_LOWERCASE:-1}" = "1" ]; then
                find "${mod_target}" -depth -name '*[A-Z]*' -exec bash -c \
                    'for f; do d=$(dirname "$f"); b=$(basename "$f"); n=$(echo "$b" | tr "[:upper:]" "[:lower:]"); [ "$b" != "$n" ] && mv -T "$f" "$d/$n"; done' _ {} + 2>/dev/null || true
            fi

            # If it is a real duplicate directory (not a symlink), remove it to save drive space
            if [ -d "${mod_link}" ] && [ ! -L "${mod_link}" ]; then
                echo "[Mods] Replacing duplicate directory @${id} with symlink..."
                rm -rf "${mod_link}"
            fi

            # 1. Primary approach: Relative symbolic link (0 extra bytes)
            if [ ! -e "${mod_link}" ]; then
                ln -sf "steamapps/workshop/content/${WORKSHOP_APPID}/${id}" "${mod_link}" 2>/dev/null || true
            fi

            # 2. Fallback if symlinks unsupported: Btrfs reflink copy (0 extra extents)
            if [ ! -e "${mod_link}" ]; then
                echo "[Mods] Symlink failed; falling back to reflink copy for @${id}..."
                cp -r --reflink=auto "${mod_target}" "${mod_link}" 2>/dev/null || true
            fi

            # 3. Last-resort fallback: Standard copy
            if [ ! -e "${mod_link}" ]; then
                echo "[Mods] Reflink failed; falling back to standard copy for @${id}..."
                cp -r "${mod_target}" "${mod_link}" 2>/dev/null || true
            fi

            echo "[Mods] Ready @${id}."
        fi
    done

    if [ -f "${GUARD_FILE}" ] && ! is_url "$(tr -d ' \r\n' < "${GUARD_FILE}")"; then
        rm -f "${GUARD_FILE}"
        echo "[Mods] Consumed and removed $(basename "${GUARD_FILE}") (single-use)."
    fi
}

# Opt-out via DOWNLOAD_WORKSHOP_MODS rather than by commenting out this call, so a deployed
# server can turn downloads off from the panel instead of by editing the script.
if [ "${DOWNLOAD_WORKSHOP_MODS:-1}" = "1" ]; then
    install_workshop_mods
else
    echo "[Mods] DOWNLOAD_WORKSHOP_MODS=0 -- skipping workshop downloads."
fi

# 0. BattlEye master switch
#
# DISABLE_BATTLEYE is the SOLE decider. Nothing else in this egg may set, infer or override
# BattlEye state:
#   1 -> binary patched, battleye=0, BEServer_x64.cfg removed. No BattlEye, no RCON.
#   0 -> stock binary restored, battleye=1, BEServer_x64.cfg written. BattlEye + RCON.
#
if [ "${DISABLE_BATTLEYE}" = "1" ]; then
    echo "[BattlEye] Master switch: DISABLE_BATTLEYE=1 -> BattlEye DISABLED (no RCON, no bans/kicks)."
    if [ -f "${SERVER_ROOT}/patch_be.pl" ]; then
        perl "${SERVER_ROOT}/patch_be.pl" disable || true
    fi
    if [ -f "${SERVER_CFG}" ]; then
        sed -i 's/^[[:space:]]*battleye[[:space:]]*=.*/battleye = 0;/' "${SERVER_CFG}" 2>/dev/null || true
    fi
else
    echo "[BattlEye] Master switch: DISABLE_BATTLEYE=0 -> BattlEye ENABLED (RCON active, bans/kicks enforced)."
    if [ -f "${SERVER_ROOT}/patch_be.pl" ]; then
        perl "${SERVER_ROOT}/patch_be.pl" enable || true
    fi
    if [ -f "${SERVER_CFG}" ]; then
        sed -i 's/^[[:space:]]*battleye[[:space:]]*=.*/battleye = 1;/' "${SERVER_CFG}" 2>/dev/null || true
    fi
fi

# 1. Password Auto-Resolution / Generation
# Uses ADMIN_PASSWORD from egg config if set; otherwise uses/generates a persistent secret in .admin_secret
PASS_FILE="${SERVER_ROOT}/.admin_secret"
if [ -n "${ADMIN_PASSWORD}" ] && [ "${ADMIN_PASSWORD}" != "changeme" ] && [ "${ADMIN_PASSWORD}" != "default" ]; then
    echo "[Security] Using Admin & RCON Passphrase configured in Egg."
    echo -n "${ADMIN_PASSWORD}" > "${PASS_FILE}"
elif [ -f "${PASS_FILE}" ] && [ -s "${PASS_FILE}" ]; then
    export ADMIN_PASSWORD="$(cat "${PASS_FILE}" | tr -d '\r\n')"
    echo "[Security] Loaded persistent Admin & RCON Passphrase from .admin_secret."
else
    WORDS=("Alpha" "Brave" "Delta" "Eagle" "Falcon" "Ghost" "Hunter" "Kodiak" "Nova" "Omega" "Phantom" "Shadow" "Tiger" "Viper" "Wolf")
    COLORS=("Blue" "Gold" "Iron" "Jade" "Onyx" "Ruby" "Silver" "Steel")
    R_W=${WORDS[$((RANDOM % ${#WORDS[@]}))]}
    R_C=${COLORS[$((RANDOM % ${#COLORS[@]}))]}
    R_N=$((RANDOM % 900 + 100))
    SECURE_PASS="${R_W}-${R_C}-${R_N}"
    export ADMIN_PASSWORD="${SECURE_PASS}"
    echo -n "${ADMIN_PASSWORD}" > "${PASS_FILE}"
    echo "[Security] Generated a persistent admin passphrase -> .admin_secret (not printed here)."
fi
chmod 600 "${PASS_FILE}" 2>/dev/null || true

# 2. Sync BattlEye RCON Configuration (BEServer_x64.cfg)
if [ "${DISABLE_BATTLEYE}" != "1" ]; then
    mkdir -p "${BATTLEYE_DIR}"
    RCON_FILE="${BATTLEYE_DIR}/BEServer_x64.cfg"
    RCON_PORT="${RCON_PORT:-2304}"
    cat <<EOF > "${RCON_FILE}"
// Managed by setup_vpp.sh. DISABLE_BATTLEYE=0 wrote this file.
RConPassword ${ADMIN_PASSWORD}
RestrictRCon 0
RConPort ${RCON_PORT}
EOF
    echo "[RCON] Configured BattlEye RCON on port ${RCON_PORT} (RestrictRCon 0)."
else
    rm -f "${BATTLEYE_DIR}/BEServer_x64.cfg"
    echo "[RCON] BattlEye disabled (DISABLE_BATTLEYE=1) -- removed BEServer_x64.cfg."
    echo "[RCON] Admin access: VPPAdminTools in-game and the init.c ! commands."
fi

# 2.1 Make the resolved passphrase authoritative in serverDZ.cfg
if [ -f "${SERVER_CFG}" ]; then
    if grep -q '^[[:space:]]*passwordAdmin[[:space:]]*=' "${SERVER_CFG}"; then
        sed -i "s|^[[:space:]]*passwordAdmin[[:space:]]*=.*|passwordAdmin = \"${ADMIN_PASSWORD}\";|" "${SERVER_CFG}"
    else
        echo "passwordAdmin = \"${ADMIN_PASSWORD}\";" >> "${SERVER_CFG}"
    fi
    echo "[Config] Synced passwordAdmin in serverDZ.cfg with the resolved passphrase."
    if [ -n "${WORKSHOP_COLLECTION_ID}" ]; then
        coll_url="https://steamcommunity.com/sharedfiles/filedetails/?id=${WORKSHOP_COLLECTION_ID}"
        if ! grep -q "${coll_url}" "${SERVER_CFG}"; then
            sed -i '/motd\[\] = {/a \    "Required Mods Collection: '"${coll_url}"'",' "${SERVER_CFG}" 2>/dev/null || true
            echo "[Config] Injected Workshop collection link into serverDZ.cfg motd."
        fi
    fi
fi

# 3. VPP Admin Tools Setup
if [ "${ENABLE_VPP_ADMIN}" = "1" ]; then
    echo "[VPP-Setup] Initializing VanillaPlusPlus Admin Tools & Community Framework Setup..."

    # Sync bikeys from all downloaded mods (resolving symlinks with find -follow/-L)
    mkdir -p "${KEYS_DIR}"
    count=0
    for key in $(find -L "${SERVER_ROOT}" -maxdepth 4 -name "*.bikey" 2>/dev/null); do
        keyname=$(basename "${key}")
        if [ ! -f "${KEYS_DIR}/${keyname}" ]; then
            # Use symlink for bikey if possible, else copy
            ln -sf "${key}" "${KEYS_DIR}/${keyname}" 2>/dev/null || cp "${key}" "${KEYS_DIR}/${keyname}"
            echo "[VPP-Setup] Installed key: ${keyname}"
            count=$((count+1))
        fi
    done
    if [ $count -gt 0 ]; then
        echo "[VPP-Setup] Installed ${count} mod key(s)."
    fi

    # Provision SuperAdmins (Default: 76561198022446661 - bluscream)
    mkdir -p "${VPP_SUPERADMINS_DIR}"
    SUPERADMIN_IDS="${VPP_SUPERADMINS:-76561198022446661}"
    superadmins_main="${VPP_SUPERADMINS_DIR}/SuperAdmins.txt"
    > "${superadmins_main}"

    for sid in $(echo "${SUPERADMIN_IDS}" | tr ',' ' '); do
        if [ -n "${sid}" ]; then
            admin_file="${VPP_SUPERADMINS_DIR}/${sid}.txt"
            echo "${sid}" > "${admin_file}"
            echo "${sid}" >> "${superadmins_main}"
            echo "[VPP-Setup] Provisioned SuperAdmin for SteamID: ${sid}"
        fi
    done

    # Sync VPP credentials with shared admin password
    mkdir -p "${VPP_BASE}/Permissions"
    echo "${ADMIN_PASSWORD}" > "${VPP_BASE}/Permissions/credentials.txt"
    echo "${ADMIN_PASSWORD}" > "${VPP_BASE}/credentials.txt"
    echo "[VPP-Setup] VPPAdminTools credentials synced with ADMIN_PASSWORD."
fi

# 3.1 Provision Server-Side Script Admins ($profile:admins.txt)
ADMINS_TXT="${SERVER_PROFILE}/admins.txt"
mkdir -p "${SERVER_PROFILE}"
SUPERADMIN_IDS="${VPP_SUPERADMINS:-76561198022446661}"
cat <<'EOF' > "${ADMINS_TXT}"
// This file contains SteamID64 of all server admins for server-side init.c commands.
// Managed automatically by setup_vpp.sh. Lines starting with // are comments.
EOF
for sid in $(echo "${SUPERADMIN_IDS}" | tr ',' ' '); do
    if [ -n "${sid}" ]; then
        echo "${sid}" >> "${ADMINS_TXT}"
    fi
done
echo "[Server-Scripts] Synced admin SteamID(s) to ${ADMINS_TXT} for server-side chat commands."

# 4. Server-Side Custom Init Auto-Installer (sinipelto/dayz-scripts)
SINIPELTO_RAW_URL="https://raw.githubusercontent.com/bluscream/pterodactyl-eggs/master/dayz-standalone/dayz_init_server.c"
UPSTREAM_SINIPELTO_URL="https://raw.githubusercontent.com/sinipelto/dayz-scripts/master/init.c"

if [ -f "${MISSION_INIT}" ]; then
    SOURCE_INIT=""
    if [ -f "${SERVER_ROOT}/dayz_init_server.c" ]; then
        SOURCE_INIT="${SERVER_ROOT}/dayz_init_server.c"
    else
        echo "[Server-Scripts] Fetching sinipelto/dayz-scripts from repository..."
        if curl --fail -sSL -o "${SERVER_ROOT}/dayz_init_server.c.tmp" "${SINIPELTO_RAW_URL}" 2>/dev/null; then
            mv "${SERVER_ROOT}/dayz_init_server.c.tmp" "${SERVER_ROOT}/dayz_init_server.c"
            SOURCE_INIT="${SERVER_ROOT}/dayz_init_server.c"
            echo "[Server-Scripts] Downloaded enhanced sinipelto/dayz-scripts."
        elif curl --fail -sSL -o "${SERVER_ROOT}/dayz_init_server.c.tmp" "${UPSTREAM_SINIPELTO_URL}" 2>/dev/null; then
            mv "${SERVER_ROOT}/dayz_init_server.c.tmp" "${SERVER_ROOT}/dayz_init_server.c"
            SOURCE_INIT="${SERVER_ROOT}/dayz_init_server.c"
            echo "[Server-Scripts] Downloaded upstream sinipelto/dayz-scripts."
        else
            rm -f "${SERVER_ROOT}/dayz_init_server.c.tmp"
            echo "[Server-Scripts] WARNING: Could not fetch sinipelto/dayz-scripts from network."
        fi
    fi

    if [ -n "${SOURCE_INIT}" ] && [ -f "${SOURCE_INIT}" ]; then
        if ! grep -q "DAYZ_NOBE_CUSTOM_INIT" "${MISSION_INIT}" || ! cmp -s "${SOURCE_INIT}" "${MISSION_INIT}"; then
            echo "[Server-Scripts] Installing custom server-side init.c (sinipelto/dayz-scripts) into ${MISSION_INIT}..."
            cp "${MISSION_INIT}" "${MISSION_INIT}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
            cp "${SOURCE_INIT}" "${MISSION_INIT}"
            echo "[Server-Scripts] Applied sinipelto/dayz-scripts to ${MISSION_INIT}."
        else
            echo "[Server-Scripts] Custom init.c (sinipelto/dayz-scripts) is up to date."
        fi
    fi
fi
