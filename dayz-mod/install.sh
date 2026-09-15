#!/bin/bash
# Pterodactyl install script -- DayZ Mod (Arma 2: Operation Arrowhead) dedicated server, Linux
#
# DayZ Mod has no dedicated-server appid. A working server is assembled from five pieces:
#
#   1. Arma 2 OA game data       -- appid 33930 (Windows data; the engine binary is separate)
#   2. Arma 2 base content       -- appid 33900 (DayZ Mod loads A2 buildings and vehicles)
#   3. The Linux server engine   -- 1.59.84216 BETA standalone package (mirror)
#   4. @dayz                     -- the mod, from Steam appid 224580 or a URL
#   5. @hive + writer.pl         -- the Linux persistence path, from denisio/Dayz-Linux-Server
#
# Piece 5 is the awkward one. The official Hive is a Windows DLL with no Linux build, so the Linux
# route is @hive plus a Perl writer fed by the engine's stdout. That writer needs JSON::XS, DBI and
# DBD::mysql, none of which are in Debian's perl-base -- and apt-installing them here would be
# pointless, because this runs in a throwaway installer container. They are therefore VENDORED onto
# the persistent volume and reached via PERL5LIB at runtime.
#
# MySQL is not installed and cannot be: Pterodactyl runs one process per container. Point HIVE_DB_*
# at an external server and load database.sql into it once by hand.

set -e

# Install-time dependencies. gcc is not optional: the A2OA package's own `install` compiles
# tolower.c with it, and without the lowercase pass the engine cannot find its addons.
apt -y update
apt -y --no-install-recommends install curl ca-certificates bzip2 unzip gcc file \
    libjson-xs-perl libdbi-perl libdbd-mysql-perl

if [[ "${STEAM_USER}" == "" ]] || [[ "${STEAM_USER}" == "anonymous" ]] || [[ "${STEAM_PASS}" == "" ]]; then
    echo "INSTALLATION ERROR: a real Steam account owning Arma 2 AND Operation Arrowhead is"
    echo "  required. Neither 33900 nor 33930 is available to the anonymous account."
    exit 1
fi

cd /tmp
mkdir -p /mnt/server/steamcmd /mnt/server/steamapps
curl --fail -sSL -o steamcmd.tar.gz https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz
tar -xzf steamcmd.tar.gz -C /mnt/server/steamcmd
cd /mnt/server/steamcmd

chown -R root:root /mnt
# HOME on the persistent volume: the Steam sentry from a successful Guard login
# (Steam/config/ssfn*) then outlives this container, so later reinstalls may need no code.
export HOME=/mnt/server

# --- Steam Guard / 2FA ---------------------------------------------------------------------
# STEAM_AUTH holds EITHER a literal 5-character code OR a URL returning one; the mode is
# inferred from the value. A URL matters more here than in any other egg in this repo: there are
# THREE logins below, and a TOTP is single-use with a ~30 second life.
#
# Prefer the .steam_auth file for a URL that embeds an ASF IPC password -- panel variables are
# stored in the database in plain text and readable by any panel admin.
GUARD_FILE="/mnt/server/.steam_auth"
[[ -z "${STEAM_AUTH}" && -f "${GUARD_FILE}" ]] && STEAM_AUTH="$(tr -d ' \r\n' < "${GUARD_FILE}")"

is_url() { [[ "${1}" =~ ^https?:// ]]; }

mint_2fa_code() {
    local src="${STEAM_AUTH}"
    [[ -z "${src}" ]] && return 0
    if ! is_url "${src}"; then echo "${src}"; return 0; fi
    local ipc_pw=""
    case "${src}" in *password=*) ipc_pw="${src##*password=}"; ipc_pw="${ipc_pw%%&*}" ;; esac
    local response
    response="$(curl --fail -sSL --max-time 15 -H "Authentication: ${ipc_pw}" "${src}" 2>/dev/null)"
    [[ -z "${response}" ]] && response="$(curl --fail -sSL --max-time 15 "${src}" 2>/dev/null)"
    if [[ -z "${response}" ]]; then
        echo "  2FA endpoint returned nothing (auth rejected or unreachable)." >&2
        return 0
    fi
    # ASF's shape first (last match -- the wrapper reuses the key), then a bare body, then any
    # uppercase 5-char token. The first step stops a 5-character uppercase BOT NAME winning.
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

steam_app_update() { # appid, install_dir
    local appid="${1}" dir="${2}" attempt code log="/tmp/steamcmd-${1}.log"
    for attempt in 1 2; do
        code="$(mint_2fa_code)"
        echo "Downloading appid ${appid} (attempt ${attempt})..."
        # Unquoted ${code}: steamcmd takes the Guard code as +login's third positional argument, and
        # an empty value must vanish rather than become an empty argument. stdin is /dev/null and the
        # call is time-boxed, or a Guard prompt would block forever on a tty that does not exist.
        timeout 3600 ./steamcmd.sh +force_install_dir "${dir}" \
            +login "${STEAM_USER}" "${STEAM_PASS}" ${code} \
            +app_update "${appid}" ${STEAMCMD_EXTRA_FLAGS} validate +quit < /dev/null 2>&1 | tee "${log}"
        # Judged by the app manifest, not steamcmd's exit status, which is non-zero on good runs.
        # (A pipeline's status is tee's anyway, so testing it directly always reports success.)
        if [[ -f "${dir}/steamapps/appmanifest_${appid}.acf" ]] \
           && ! grep -qiE 'Login Failure|two-factor|Invalid Password|Rate Limit' "${log}"; then
            return 0
        fi
        if [[ "${attempt}" == "1" ]]; then
            echo "  Login or download failed."
            if is_url "${STEAM_AUTH}"; then
                # A TOTP only rolls over every 30s; minting again now returns the same rejected code.
                echo "  Waiting 31s for a new TOTP window, then retrying once..."
                sleep 31
            fi
        fi
    done
    echo "FATAL: could not download appid ${appid}. Check the credentials, that the account owns"
    echo "  Arma 2 and Operation Arrowhead, and that STEAM_AUTH is valid or reachable."
    return 1
}

# --- 1 + 2. Game data -----------------------------------------------------------------------
steam_app_update 33930 /mnt/server
steam_app_update 33900 /mnt/server

mkdir -p /mnt/server/.steam/sdk32
cp -v linux32/steamclient.so /mnt/server/.steam/sdk32/steamclient.so || true

# --- 3. Linux server engine -----------------------------------------------------------------
cd /mnt/server
curl --fail -sSL -o /tmp/a2oa-server.tar.bz2 "${A2OA_SERVER_URL}" || {
    echo "FATAL: could not download the A2OA Linux server package from ${A2OA_SERVER_URL}"
    exit 1
}
tar -xjf /tmp/a2oa-server.tar.bz2 -C /mnt/server
rm -f /tmp/a2oa-server.tar.bz2

# --- 4. The mod ------------------------------------------------------------------------------
if [[ -n "${DAYZ_MOD_URL}" ]]; then
    echo "Fetching @dayz from ${DAYZ_MOD_URL}..."
    mkdir -p /tmp/dayzmod
    curl --fail -sSL -o /tmp/dayzmod.archive "${DAYZ_MOD_URL}" || {
        echo "FATAL: could not download ${DAYZ_MOD_URL}"
        exit 1
    }
    cd /tmp/dayzmod
    if file /tmp/dayzmod.archive | grep -qi zip; then unzip -oq /tmp/dayzmod.archive
    elif file /tmp/dayzmod.archive | grep -qi bzip2; then tar -xjf /tmp/dayzmod.archive
    else tar -xzf /tmp/dayzmod.archive 2>/dev/null || unzip -oq /tmp/dayzmod.archive; fi
    cp -r /tmp/dayzmod/* /mnt/server/ 2>/dev/null || true
    rm -rf /tmp/dayzmod /tmp/dayzmod.archive
elif [[ "${DAYZ_MOD_FROM_STEAM}" == "1" ]]; then
    cd /mnt/server/steamcmd
    # 224580 is free to own but still needs the real account. Downloaded to a side directory so a
    # client-shaped layout cannot scatter files across the server root.
    steam_app_update 224580 /mnt/server/_dayzmod || \
        echo "WARNING: appid 224580 download failed -- supply DAYZ_MOD_URL instead."
    find /mnt/server/_dayzmod -maxdepth 3 -iname '@dayz*' -type d -exec cp -r {} /mnt/server/ \; 2>/dev/null || true
    rm -rf /mnt/server/_dayzmod
else
    echo "NOTE: no @dayz source configured (DAYZ_MOD_URL empty, DAYZ_MOD_FROM_STEAM=0)."
    echo "  Upload @dayz into the server root before starting."
fi

# --- 5. @hive, writer.pl and the Linux layout ------------------------------------------------
cd /tmp
curl --fail -sSL -o linuxsrv.tar.gz "${HIVE_REPO_URL}" || {
    echo "FATAL: could not download the Hive layout from ${HIVE_REPO_URL}"
    exit 1
}
mkdir -p /tmp/linuxsrv && tar -xzf linuxsrv.tar.gz -C /tmp/linuxsrv --strip-components=1
for item in @hive writer.pl restarter.pl tolower.c install database.sql object_init_data.txt \
            cfgdayz mpmissions expansion cache; do
    [[ -e "/tmp/linuxsrv/${item}" ]] && cp -rn "/tmp/linuxsrv/${item}" /mnt/server/ 2>/dev/null || true
done
rm -rf /tmp/linuxsrv /tmp/linuxsrv.tar.gz

# Vendor the Perl modules writer.pl needs onto the VOLUME. apt cannot help at runtime: this
# container is discarded, and the game images ship only perl-base. Copying the vendor trees works
# because installer and runtime images are both Debian bookworm; boot.sh verifies the modules
# actually load and disables the Hive with a clear message if they do not.
echo "Vendoring Perl modules (JSON::XS, DBI, DBD::mysql) into ./perl5..."
mkdir -p /mnt/server/perl5
for d in /usr/lib/*/perl5/* /usr/share/perl5; do
    [[ -d "${d}" ]] && cp -rn "${d}/." /mnt/server/perl5/ 2>/dev/null || true
done
if [[ ! -f /mnt/server/perl5/JSON/XS.pm ]] || [[ ! -f /mnt/server/perl5/DBI.pm ]]; then
    echo "WARNING: the Perl modules did not land in ./perl5 as expected. Persistence will be"
    echo "  disabled at boot. Check the paths above against this installer image's layout."
fi

# --- Lowercase conversion --------------------------------------------------------------------
# Mandatory, and only meaningful once every piece is in place.
cd /mnt/server
if [[ -f install ]]; then
    chmod +x install && ./install
else
    echo "FATAL: the A2OA package contained no 'install' script, so filenames were not"
    echo "  lowercased. The engine cannot load its addons in that state."
    exit 1
fi
rm -f ./*.exe ./*.chm ./*.dll 2>/dev/null || true
find ./battleye ./expansion -maxdepth 2 -name '*.dll' -delete 2>/dev/null || true

if [[ ! -f /mnt/server/server ]]; then
    echo "FATAL: ./server not found after extracting the A2OA package."
    exit 1
fi
chmod +x /mnt/server/server

# --- Egg companion files ---------------------------------------------------------------------
# Pinned to a ref so reinstalls are reproducible. Bump RAW_REF when these change.
RAW_REF="master"
RAW_BASE="https://raw.githubusercontent.com/bluscream/pterodactyl-eggs/${RAW_REF}/dayz-mod"

fetch() { # source filename, destination path, overwrite(0|1)
    if [[ "${3}" == "0" && -f "/mnt/server/${2}" ]]; then
        echo "Keeping existing ${2}."
        return 0
    fi
    echo "Fetching ${1}..."
    # --fail is mandatory: without it curl exits 0 on a 404 and writes the error page to the file.
    curl --fail -sSL -o "/mnt/server/${2}.tmp" "${RAW_BASE}/${1}" || {
        echo "FATAL: could not download ${1} from ${RAW_BASE}"
        rm -f "/mnt/server/${2}.tmp"
        exit 1
    }
    mv "/mnt/server/${2}.tmp" "/mnt/server/${2}"
}

mkdir -p /mnt/server/cfgdayz /mnt/server/battleye /mnt/server/keys /mnt/server/cache
fetch boot.sh boot.sh 1                  # egg logic -- always refreshed
fetch server.cfg cfgdayz/server.cfg 0    # user config -- never clobbered
chmod +x /mnt/server/boot.sh
chmod 644 /mnt/server/cfgdayz/server.cfg

# Consume a stale single-use code; keep a URL, which stays valid.
if [[ -f "${GUARD_FILE}" ]] && ! is_url "$(tr -d ' \r\n' < "${GUARD_FILE}")"; then
    rm -f "${GUARD_FILE}"
    echo "Consumed and removed .steam_auth (single-use)."
fi

echo "-----------------------------------------"
echo "Installation completed."
echo
echo "REMAINING MANUAL STEP -- the server runs but will NOT persist until this is done:"
echo "  1. Create a MySQL database and user on a host this container can reach."
echo "  2. Load /home/container/database.sql into it."
echo "  3. Import object_init_data.txt into Object_DATA and Object_init_DATA."
echo "  4. Set HIVE_DB_HOST / _PORT / _NAME / _USER / _PASS in the panel."
echo "     boot.sh patches writer.pl to read those -- upstream hardcodes them and connects with"
echo "     no host at all, i.e. a local socket that does not exist in a container."
echo "-----------------------------------------"
