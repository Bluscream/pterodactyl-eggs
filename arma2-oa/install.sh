#!/bin/bash
# Pterodactyl install script -- Arma 2: Operation Arrowhead dedicated server (Linux)
#
# Bohemia never shipped an A2OA Linux server through Steam: appid 33935 is the Windows
# dedicated server. The Linux build is the 1.59.84216 BETA standalone package, mirrored at
# Bluscream/arma2-oa-linux-server. So this install does three things in order:
#
#   1. steamcmd the Windows game data (33930, plus 33900 for Arma 2 base content)
#   2. overlay the Linux server package (the `server` ELF + expansion/battleye/beserver.so)
#   3. run the package's own conversion, which lowercases every filename
#
# Step 3 is not optional. The engine resolves paths lowercase internally, and Steam delivers
# Windows-cased files (Addons/, Expansion/, Dta/). Without the conversion the server starts
# and then fails to find addons. The upstream `install` script compiles tolower.c with gcc and
# runs it; we do the same rather than reimplementing it, so the behaviour matches upstream.

set -e

# Install-time dependencies ONLY.
#
# This runs in the throwaway installer container, NOT the runtime one -- anything apt-installed
# here is discarded when the install finishes. In particular the 32-bit libraries the engine
# needs at RUNTIME (lib32stdc++6, lib32gcc-s1, lib32z1) must be present in the *runtime* image
# and cannot be added from here. Both ghcr.io/parkervcp/games:source and games:dayz ship them
# with i386 multiarch already enabled; a generic Debian yolk does not, and the server will die
# with "No such file or directory" on a binary that plainly exists -- the classic symptom of a
# missing 32-bit loader.
#
# gcc is required here and not optional: the package's own `install` compiles tolower.c with it,
# and without the lowercase pass the server cannot find its addons.
apt -y update
apt -y --no-install-recommends install curl ca-certificates bzip2 gcc

# A2OA is not available to the anonymous Steam user -- ownership of Arma 2 and Operation
# Arrowhead is required on the account used here.
if [[ "${STEAM_USER}" == "" ]] || [[ "${STEAM_USER}" == "anonymous" ]] || [[ "${STEAM_PASS}" == "" ]]; then
    echo "INSTALLATION ERROR: a real Steam account that owns Arma 2 and Arma 2: Operation"
    echo "  Arrowhead is required. The anonymous account cannot download appid 33930."
    exit 1
fi

cd /tmp
mkdir -p /mnt/server/steamcmd /mnt/server/steamapps
curl --fail -sSL -o steamcmd.tar.gz https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz
tar -xzf steamcmd.tar.gz -C /mnt/server/steamcmd
cd /mnt/server/steamcmd

chown -R root:root /mnt
# HOME on the persistent volume, deliberately: the Steam sentry that a successful Guard login
# writes (Steam/config/ssfn*) then survives the throwaway installer container, so later
# reinstalls can log in without a code.
export HOME=/mnt/server

# --- Steam Guard / 2FA ---------------------------------------------------------------------
# STEAM_AUTH holds EITHER a literal 5-character Guard code OR a URL that returns one. It is
# one variable because those are the same thing from the caller's side, and two variables meant
# remembering which took precedence.
#
#   literal  "K4J9P"                                  -- used as-is, single-use
#   URL      "https://asf.host/api/bot/x/twoFactor..." -- fetched fresh before every login
#
# A URL is strongly preferable. A TOTP is single-use and lives about 30 seconds, and there are
# two logins below with an apt install and a steamcmd bootstrap ahead of them, so a hand-pasted
# literal is a race against the clock. A URL is re-minted per login instead.
#
# The file .steam_auth in the server root works too, and outlives the panel variable.
GUARD_FILE="/mnt/server/.steam_auth"
[[ -z "${STEAM_AUTH}" && -f "${GUARD_FILE}" ]] && STEAM_AUTH="$(tr -d ' \r\n' < "${GUARD_FILE}")"

is_url() { [[ "${1}" =~ ^https?:// ]]; }

mint_2fa_code() {
    local src="${STEAM_AUTH}"
    [[ -z "${src}" ]] && return 0
    if ! is_url "${src}"; then
        echo "${src}"
        return 0
    fi
    # ArchiSteamFarm's IPC wants its password as a header on newer builds and as ?password= on
    # older ones. Sending both means either vintage answers, and the secret never reaches a log.
    local ipc_pw=""
    case "${src}" in *password=*) ipc_pw="${src##*password=}"; ipc_pw="${ipc_pw%%&*}" ;; esac
    local response
    response="$(curl --fail -sSL --max-time 15 -H "Authentication: ${ipc_pw}" "${src}" 2>/dev/null)"
    [[ -z "${response}" ]] && response="$(curl --fail -sSL --max-time 15 "${src}" 2>/dev/null)"
    if [[ -z "${response}" ]]; then
        echo "  2FA endpoint returned nothing (auth rejected or unreachable)." >&2
        return 0
    fi
    # Extraction, most specific first, without needing a JSON parser:
    #   1. ASF's shape -- {"Result":{"bot":{"Result":"ABC12"}}}. Take the LAST such match, since
    #      the outer wrapper uses the same key as the inner value.
    #   2. a bare 5-character response.
    #   3. any uppercase 5-character token anywhere.
    # Step 1 exists because step 3 alone would happily return a 5-character uppercase BOT NAME
    # in preference to the code -- fine for a bot called "Bluscream", wrong for one called "ASF01".
    local code bare
    code="$(echo "${response}" | grep -oE '"Result"[[:space:]]*:[[:space:]]*"[A-Za-z0-9]{5}"' \
            | tail -1 | grep -oE '[A-Za-z0-9]{5}"$' | tr -d '"')"
    if [[ -z "${code}" ]]; then
        bare="$(echo "${response}" | tr -d ' \r\n')"
        [[ "${bare}" =~ ^[A-Za-z0-9]{5}$ ]] && code="${bare}"
    fi
    [[ -z "${code}" ]] && code="$(echo "${response}" | grep -oE '[A-Z0-9]{5}' | head -1)"
    echo "${code}" | tr '[:lower:]' '[:upper:]'
}

# 33930 = Arma 2: Operation Arrowhead (game data). 33900 = Arma 2 (base content), needed for
# Combined Operations and by every DayZ Mod build. DOWNLOAD_ARMA2_BASE=0 skips it for a
# standalone OA server that will never load A2 content.
steam_app_update() {
    local appid="${1}" attempt code log="/tmp/steamcmd-${1}.log"
    for attempt in 1 2; do
        code="$(mint_2fa_code)"
        if [[ -n "${code}" ]]; then
            echo "Downloading appid ${appid} (attempt ${attempt}, using a Guard code)..."
        else
            echo "Downloading appid ${appid} (attempt ${attempt}, no code -- relying on the sentry)..."
        fi
        # Credentials are arguments, never echoed. Unquoted ${code} on purpose: steamcmd takes
        # the Guard code as +login's third positional argument, and an empty value must vanish
        # rather than become an empty argument.
        #
        # stdin is /dev/null and the call is time-boxed: when Steam wants a code that was not
        # supplied, steamcmd prompts for one and would otherwise block the install forever on a
        # tty that does not exist.
        timeout 3600 ./steamcmd.sh +force_install_dir /mnt/server \
            +login "${STEAM_USER}" "${STEAM_PASS}" ${code} \
            +app_update "${appid}" ${STEAMCMD_EXTRA_FLAGS} validate +quit < /dev/null 2>&1 | tee "${log}"

        # Success is judged by the app manifest existing, NOT by steamcmd's exit status, which is
        # famously unreliable (it returns non-zero on perfectly good runs). Note also that the
        # status of a pipeline is the LAST command's -- tee's -- so testing the pipeline directly
        # would report success unconditionally.
        if [[ -f "/mnt/server/steamapps/appmanifest_${appid}.acf" ]] \
           && ! grep -qiE 'Login Failure|two-factor|Invalid Password|Rate Limit' "${log}"; then
            return 0
        fi
        if [[ "${attempt}" == "1" ]]; then
            echo "  Login or download failed."
            if is_url "${STEAM_AUTH}"; then
                # A TOTP is only regenerated every 30s, so minting again immediately would hand
                # back the same rejected code. Wait out the window before retrying.
                echo "  Waiting 31s for a new TOTP window, then retrying once..."
                sleep 31
            else
                echo "  Retrying once. A literal code is single-use, so this only helps if the"
                echo "  first failure was not the code itself."
            fi
        fi
    done
    echo "FATAL: could not download appid ${appid}. Check STEAM_USER/STEAM_PASS, that the"
    echo "  account owns Arma 2 and Operation Arrowhead, and that STEAM_AUTH is a valid"
    echo "  code or a reachable endpoint."
    return 1
}

steam_app_update 33930

if [[ "${DOWNLOAD_ARMA2_BASE}" == "1" ]]; then
    steam_app_update 33900
fi

# Never leave a stale single-use code behind: it cannot work twice, and keeping it makes the
# next reinstall look like it had a code when it did not. A URL is kept -- it stays valid.
if [[ -f "${GUARD_FILE}" ]] && ! is_url "$(tr -d ' \r\n' < "${GUARD_FILE}")"; then
    rm -f "${GUARD_FILE}"
    echo "Consumed and removed .steam_auth (single-use)."
fi

mkdir -p /mnt/server/.steam/sdk32
cp -v linux32/steamclient.so /mnt/server/.steam/sdk32/steamclient.so || true

# --- Linux server overlay ----------------------------------------------------------------
# --fail throughout: without it curl exits 0 on a 404 and writes the error page into the
# destination, so a moved release would produce a "tar: unexpected EOF" ten lines later
# instead of naming the actual problem.
cd /mnt/server
echo "Fetching the Linux server package from ${A2OA_SERVER_URL}..."
curl --fail -sSL -o /tmp/a2oa-server.tar.bz2 "${A2OA_SERVER_URL}" || {
    echo "FATAL: could not download the server package from ${A2OA_SERVER_URL}"
    exit 1
}
tar -xjf /tmp/a2oa-server.tar.bz2 -C /mnt/server
rm -f /tmp/a2oa-server.tar.bz2

# Lowercase conversion. Upstream `install` also deletes *.exe *.chm *.dll, which is correct
# here -- a 32-bit ELF cannot load a PE DLL, so the Windows leftovers are dead weight.
if [[ -f /mnt/server/install ]]; then
    chmod +x /mnt/server/install
    cd /mnt/server && ./install
else
    echo "FATAL: the server package contained no 'install' script, so filenames were not"
    echo "  lowercased. The server cannot load its addons in that state -- refusing to"
    echo "  finish and leave a subtly broken install behind."
    exit 1
fi

if [[ ! -f /mnt/server/server ]]; then
    echo "FATAL: ./server not found after extracting the package. The archive layout changed."
    exit 1
fi
chmod +x /mnt/server/server

# --- Egg companion scripts and configs ----------------------------------------------------
# Pinned to a ref so reinstalls are reproducible. Bump RAW_REF when these change.
#
# The configs are shipped by this egg rather than pulled from AMPTemplates: those files are AMP
# templates full of {{placeholder}} tokens that AMP substitutes at runtime. Fetched raw into
# server.cfg they would leave the engine reading a literal hostname = "{{hostname}}".
RAW_REF="master"
RAW_BASE="https://raw.githubusercontent.com/bluscream/pterodactyl-eggs/${RAW_REF}/arma2-oa"

fetch() { # filename, overwrite(0|1)
    if [[ "${2}" == "0" && -f "/mnt/server/${1}" ]]; then
        echo "Keeping existing ${1}."
        return 0
    fi
    echo "Fetching ${1}..."
    curl --fail -sSL -o "/mnt/server/${1}.tmp" "${RAW_BASE}/${1}" || {
        echo "FATAL: could not download ${1} from ${RAW_BASE}"
        rm -f "/mnt/server/${1}.tmp"
        exit 1
    }
    mv "/mnt/server/${1}.tmp" "/mnt/server/${1}"
}

fetch boot.sh 1      # always refreshed -- it is egg logic, not user config
fetch server.cfg 0   # never clobber a live config on reinstall
fetch basic.cfg 0
chmod +x /mnt/server/boot.sh
chmod 644 /mnt/server/server.cfg /mnt/server/basic.cfg

mkdir -p /mnt/server/A2Master /mnt/server/battleye /mnt/server/keys /mnt/server/mpmissions

echo "-----------------------------------------"
echo "Installation completed."
echo "  server binary : ./server (32-bit i386 -- needs a runtime image with i386 libs)"
echo "  profiles      : ./A2Master"
echo "  configs       : server.cfg, basic.cfg"
echo "-----------------------------------------"
