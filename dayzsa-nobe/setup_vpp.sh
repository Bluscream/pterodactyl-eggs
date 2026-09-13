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
#
# Why this exists: the runtime image's /entrypoint.sh downloads workshop mods with a bare
#   steamcmd.sh "+login \"${STEAM_USER}\" \"${STEAM_PASS}\"" +workshop_download_item ...
# and has no way to pass a Steam Guard code. On a Guard-protected account every download
# fails with "two-factor" / "Failure", the mod folders never appear, and DayZ then refuses
# to start because -mod names a directory that does not exist. We cannot patch the image,
# so this retries the downloads ourselves, with a code, before the server is launched.
#
# STEAM_2FA_CODE - a one-shot code. Only needed until Steam trusts this machine: the first
#                  successful login writes a sentry (Steam/config/ssfn*) into the server
#                  volume and later logins need no code at all.
# STEAM_2FA_URL  - optional endpoint returning a fresh code, for accounts where the sentry
#                  keeps getting invalidated. Any ArchiSteamFarm 2FA endpoint works, e.g.
#                  https://asf.host/api/bot/<bot>/twoFactorAuthentication/token?password=...
#                  The response may be plain text or ASF's JSON; both are handled.
# The older STEAM_GUARD / STEAM_GUARD_URL names still work as fallbacks.
WORKSHOP_APPID="221100"

# Both settings also work as files in the server root, so a panel that still has an older
# egg imported needs no re-import: Pterodactyl's application API cannot import or edit eggs
# (POST to the eggs endpoint answers 405), but any file can be dropped in with `ptero write`.
#   .steam_2fa_code - a one-shot code. Consumed and deleted after use, since it is single-use.
#   .steam_2fa_url  - endpoint returning a fresh code.
# The older .steam_guard / .steam_guard_url names are still honoured.
GUARD_FILE="${SERVER_ROOT}/.steam_2fa_code"
GUARD_URL_FILE="${SERVER_ROOT}/.steam_2fa_url"
[ ! -f "${GUARD_FILE}" ] && [ -f "${SERVER_ROOT}/.steam_guard" ] && GUARD_FILE="${SERVER_ROOT}/.steam_guard"
[ ! -f "${GUARD_URL_FILE}" ] && [ -f "${SERVER_ROOT}/.steam_guard_url" ] && GUARD_URL_FILE="${SERVER_ROOT}/.steam_guard_url"

steam_guard_code() {
    STEAM_2FA_CODE="${STEAM_2FA_CODE:-${STEAM_GUARD}}"
    STEAM_2FA_URL="${STEAM_2FA_URL:-${STEAM_GUARD_URL}}"
    if [ -n "${STEAM_2FA_CODE}" ]; then
        echo "${STEAM_2FA_CODE}"
        return 0
    fi
    if [ -f "${GUARD_FILE}" ] && [ -s "${GUARD_FILE}" ]; then
        tr -d ' \r\n' < "${GUARD_FILE}"
        return 0
    fi
    if [ -z "${STEAM_2FA_URL}" ] && [ -f "${GUARD_URL_FILE}" ]; then
        # This URL usually embeds an IPC password, so keep it owner-readable only. The panel
        # file manager can still read it -- treat it as a secret that lives on the server.
        chmod 600 "${GUARD_URL_FILE}" 2>/dev/null || true
        STEAM_2FA_URL="$(tr -d ' \r\n' < "${GUARD_URL_FILE}")"
    fi
    [ -z "${STEAM_2FA_URL}" ] && return 0
    # Newer ArchiSteamFarm builds reject ?password= on IPC and want the secret in an
    # "Authentication" header instead -- that combination answers 401 with a correct
    # password, which is exactly what this server saw. Send both so either vintage works.
    local ipc_pw=""
    case "${STEAM_2FA_URL}" in
        *password=*)
            ipc_pw="${STEAM_2FA_URL##*password=}"
            ipc_pw="${ipc_pw%%&*}"
            ;;
    esac

    # Extract the first 5-character alphanumeric token: matches ASF's {"Result":{"bot":
    # {"Result":"ABC12"}}} as well as a bare code, without needing a JSON parser.
    local response
    response="$(curl --fail -sSL --max-time 15 -H "Authentication: ${ipc_pw}" "${STEAM_2FA_URL}" 2>/dev/null)"
    if [ -z "${response}" ]; then
        response="$(curl --fail -sSL --max-time 15 "${STEAM_2FA_URL}" 2>/dev/null)"
    fi
    if [ -z "${response}" ]; then
        echo "[Mods] 2FA URL returned nothing (auth rejected or unreachable)." >&2
        return 0
    fi
    echo "${response}" | grep -oE '[A-Z0-9]{5}' | head -1
}

install_workshop_mods() {
    STEAM_2FA_URL="${STEAM_2FA_URL:-${STEAM_GUARD_URL}}"
    [ -z "${STEAM_2FA_URL}" ] && [ -f "${GUARD_URL_FILE}" ] && STEAM_2FA_URL="$(tr -d ' \r\n' < "${GUARD_URL_FILE}")"
    [ -z "${MODIFICATIONS}" ] && return 0
    [ -z "${STEAM_USER}" ] && return 0
    [ "${STEAM_USER}" = "anonymous" ] && return 0

    local missing=""
    local id
    for id in $(echo "${MODIFICATIONS}" | tr ';' ' ' | tr -d '@'); do
        [ -z "${id}" ] && continue
        [ -d "${SERVER_ROOT}/@${id}" ] && continue
        missing="${missing} ${id}"
    done
    [ -z "${missing}" ] && return 0

    echo "[Mods] Missing workshop mods:${missing}"

    local code
    code="$(steam_guard_code)"
    if [ -n "${code}" ]; then
        echo "[Mods] Using a Steam Guard code (not logged here)."
    else
        echo "[Mods] No Steam Guard code available -- relying on the stored sentry file."
    fi

    local content="${SERVER_ROOT}/steamapps/workshop/content/${WORKSHOP_APPID}"
    local fails=0
    for id in ${missing}; do
        # Steam rate-limits repeated logins, and each attempt can then sit in "Retrying..."
        # until the timeout. Downloading mods must never hold the server down, so give up for
        # this boot after two consecutive failures and start with whatever is installed.
        if [ "${fails}" -ge 2 ]; then
            echo "[Mods] Two consecutive failures -- stopping for this boot (Steam is likely"
            echo "[Mods]   rate-limiting logins). Remaining mods retry on the next restart."
            break
        fi
        # Re-mint a code for every mod. A successful login does not reliably leave a sentry
        # behind here (observed: the first mod downloaded, every later one hit the Guard
        # prompt again), and a TOTP is single-use anyway. When the code comes from a URL this
        # is free; when it came from a file or variable there is only ever the one.
        if [ -z "${code}" ] || [ -n "${STEAM_2FA_URL}" ]; then
            code="$(steam_guard_code)"
        fi
        echo "[Mods] Downloading ${id}..."
        # Credentials are passed as arguments to steamcmd and never echoed.
        # stdin is /dev/null and the call is time-boxed: when Steam wants a code it has not
        # got, steamcmd prompts ("enter the Steam Guard code") and would otherwise block the
        # boot forever waiting on a tty that does not exist.
        timeout 900 "${SERVER_ROOT}/steamcmd/steamcmd.sh" +force_install_dir "${SERVER_ROOT}" \
            +login "${STEAM_USER}" "${STEAM_PASS}" ${code} \
            +workshop_download_item "${WORKSHOP_APPID}" "${id}" +quit \
            < /dev/null > "${SERVER_ROOT}/.steamcmd_mods.log" 2>&1 || true

        if grep -qi "check your email\|Steam Guard code" "${SERVER_ROOT}/.steamcmd_mods.log" 2>/dev/null; then
            echo "[Mods] Steam asked for a Guard code that this login did not satisfy."
            echo "[Mods]   steamcmd's prompt text mentions email, but it says that for any"
            echo "[Mods]   unauthenticated machine -- it is not evidence of the Guard type."
            echo "[Mods]   A fresh code is minted per mod when STEAM_2FA_URL is set."
        fi

        if [ ! -d "${content}/${id}" ]; then
            echo "[Mods] FAILED: ${id} did not download. Check STEAM_USER/STEAM_PASS, that the"
            echo "[Mods]   account owns DayZ, and that Steam Guard is satisfied."
            fails=$((fails+1))
            continue
        fi

        cp -r "${content}/${id}" "${SERVER_ROOT}/@${id}"
        if [ "${MODS_LOWERCASE}" = "1" ]; then
            find "${SERVER_ROOT}/@${id}" -depth -name '*[A-Z]*' -exec bash -c \
                'for f; do d=$(dirname "$f"); b=$(basename "$f"); n=$(echo "$b" | tr "[:upper:]" "[:lower:]"); [ "$b" != "$n" ] && mv -T "$f" "$d/$n"; done' _ {} + 2>/dev/null || true
        fi
        echo "[Mods] Installed @${id}."
        fails=0
    done

    # Never leave a stale one-shot code behind: it cannot work twice, and keeping it would
    # make the next boot look like it had a code when it did not.
    if [ -f "${GUARD_FILE}" ]; then
        rm -f "${GUARD_FILE}"
        echo "[Mods] Consumed and removed $(basename "${GUARD_FILE}") (single-use)."
    fi
}

install_workshop_mods

# 0. BattlEye master switch
# DISABLE_BATTLEYE=1 -> binary patched, battleye=0, no BEServer cfg. No BattlEye, no RCON.
# DISABLE_BATTLEYE=0 -> stock binary restored, battleye=1, BEServer cfg written. BattlEye + RCON.
# Falls back to the inverse of the older ENABLE_BATTLEYE variable so servers whose panel
# still has the old egg imported keep working.
if [ -z "${DISABLE_BATTLEYE}" ]; then
    if [ "${ENABLE_BATTLEYE}" = "1" ]; then DISABLE_BATTLEYE=0; else DISABLE_BATTLEYE=1; fi
fi

SERVER_BIN="${SERVER_ROOT}/${SERVER_BINARY:-DayZServer}"
STOCK_BIN="${SERVER_BIN}.orig"

set_cfg() { # key, value -- replace or append in serverDZ.cfg
    [ -f "${SERVER_CFG}" ] || return 0
    if grep -q "^[[:space:]]*$1[[:space:]]*=" "${SERVER_CFG}"; then
        sed -i "s|^[[:space:]]*$1[[:space:]]*=.*|$1 = $2;|" "${SERVER_CFG}"
    else
        echo "$1 = $2;" >> "${SERVER_CFG}"
    fi
}

if [ -f "${SERVER_BIN}" ]; then
    if [ "${DISABLE_BATTLEYE}" = "1" ]; then
        [ -f "${STOCK_BIN}" ] || cp "${SERVER_BIN}" "${STOCK_BIN}"
        perl "${SERVER_ROOT}/patch_be.pl" "${SERVER_BIN}" || \
            echo "[BattlEye] WARNING: patch failed -- BattlEye may still be active."
        set_cfg battleye 0
        echo "[BattlEye] Disabled: binary patched, battleye=0. RCON is unavailable by design."
    else
        if [ -f "${STOCK_BIN}" ] && ! cmp -s "${STOCK_BIN}" "${SERVER_BIN}"; then
            cp "${STOCK_BIN}" "${SERVER_BIN}"
            chmod +x "${SERVER_BIN}"
            echo "[BattlEye] Restored stock unpatched binary from $(basename "${STOCK_BIN}")."
        fi
        set_cfg battleye 1
        echo "[BattlEye] Enabled: stock binary, battleye=1. BE RCON available."
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
# Only meaningful when BattlEye actually initializes. patch_be.pl prevents that, so on a
# patched server BE never loads, nothing binds RCON_PORT and BE RCON clients time out --
# writing a BEServer_x64.cfg there would just be a config that nothing ever reads.
if [ "${DISABLE_BATTLEYE}" != "1" ]; then
    mkdir -p "${BATTLEYE_DIR}"
    RCON_FILE="${BATTLEYE_DIR}/BEServer_x64.cfg"
    RCON_PORT="${RCON_PORT:-2304}"
    cat <<EOF > "${RCON_FILE}"
RConPassword ${ADMIN_PASSWORD}
RestrictRCon 0
RConPort ${RCON_PORT}
EOF
    echo "[RCON] Configured BattlEye RCON on port ${RCON_PORT} (RestrictRCon 0)."
else
    echo "[RCON] BattlEye disabled (DISABLE_BATTLEYE=1) -- skipping BEServer_x64.cfg."
    echo "[RCON] Admin access: VPPAdminTools in-game and the init.c ! commands."
fi

# 2.1 Make the resolved passphrase authoritative in serverDZ.cfg
# The panel's config parser rewrites passwordAdmin from the (possibly empty) ADMIN_PASSWORD
# egg variable before every boot. This runs after the parser, so the value written here wins
# and serverDZ.cfg, BEServer_x64.cfg and the VPP credentials all agree.
if [ -f "${SERVER_CFG}" ]; then
    if grep -q '^[[:space:]]*passwordAdmin[[:space:]]*=' "${SERVER_CFG}"; then
        sed -i "s|^[[:space:]]*passwordAdmin[[:space:]]*=.*|passwordAdmin = \"${ADMIN_PASSWORD}\";|" "${SERVER_CFG}"
    else
        echo "passwordAdmin = \"${ADMIN_PASSWORD}\";" >> "${SERVER_CFG}"
    fi
    echo "[Config] Synced passwordAdmin in serverDZ.cfg with the resolved passphrase."
fi

# 3. VPP Admin Tools Setup
if [ "${ENABLE_VPP_ADMIN}" = "1" ]; then
    echo "[VPP-Setup] Initializing VanillaPlusPlus Admin Tools & Community Framework Setup..."

    # Sync bikeys from all downloaded mods
    mkdir -p "${KEYS_DIR}"
    count=0
    for key in $(find "${SERVER_ROOT}" -maxdepth 4 -name "*.bikey" 2>/dev/null); do
        keyname=$(basename "${key}")
        if [ ! -f "${KEYS_DIR}/${keyname}" ]; then
            cp "${key}" "${KEYS_DIR}/${keyname}"
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
# Used by sinipelto/dayz-scripts in init.c for zero-client-mod admin commands
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
# Dynamically installs sinipelto/dayz-scripts into the active mission's init.c.
# If dayz_init_server.c is present, it is used; otherwise setup_vpp.sh fetches the upstream
# init.c directly via curl from GitHub.
SINIPELTO_RAW_URL="https://raw.githubusercontent.com/bluscream/pterodactyl-eggs/master/dayzsa-nobe/dayz_init_server.c"
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



