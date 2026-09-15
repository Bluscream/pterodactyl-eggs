#!/bin/bash
# Pterodactyl install script -- BattleBit Remastered dedicated server (Wine)
#
# BattleBit has no separate Linux or anonymous server appid: the server binary is delivered
# through beta branches of the GAME appid (671860), which means an account that OWNS the game.
# The binary is Windows-only, so steamcmd is told to fetch the Windows platform and the server
# runs under Wine.

set -e

# Install-time dependencies only -- this runs in a throwaway installer container, so nothing
# apt-installed here reaches the runtime image. curl only; the previous version used wget for the
# 2FA fetch, which is not guaranteed to exist in the installer image.
apt -y update
apt -y --no-install-recommends install curl ca-certificates

if [[ -z "${STEAM_USER}" ]]; then
    echo "INSTALLATION ERROR: STEAM_USER is empty."
    echo "  BattleBit's server files live on a beta branch of appid ${STEAMCMD_APPID}, so an"
    echo "  account that owns BattleBit Remastered is required. There is no anonymous download."
    exit 1
fi
if [[ "${STEAM_USER}" == "anonymous" ]]; then
    echo "WARNING: STEAM_USER is 'anonymous'. The ${STEAM_BRANCH} branch requires game"
    echo "  ownership, so this will almost certainly fail. Continuing in case Valve has"
    echo "  published an anonymous server appid since this egg was written."
fi

cd /tmp
mkdir -p /mnt/server/steamcmd
# steamapps must exist up front or steamcmd reports a disk write failure.
mkdir -p /mnt/server/steamapps
curl --fail -sSL -o steamcmd.tar.gz https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz
tar -xzf steamcmd.tar.gz -C /mnt/server/steamcmd
cd /mnt/server/steamcmd

# steamcmd misbehaves otherwise, even as root. Pterodactyl fixes ownership after install.
chown -R root:root /mnt
# HOME on the persistent volume deliberately: the Steam sentry written by a successful Guard
# login (Steam/config/ssfn*) then survives the throwaway installer container, so later
# reinstalls can often log in with no code at all.
export HOME=/mnt/server

# --- Steam Guard / 2FA ---------------------------------------------------------------------
# STEAM_AUTH holds EITHER a literal 5-character Guard code OR a URL that returns one. One
# variable, mode inferred from the value.
#
#   literal  "K4J9P"                                   -- used as-is, single-use
#   URL      "https://asf.host/api/bot/x/twoFactor..."  -- fetched fresh before every attempt
#
# A URL is strongly preferable: a TOTP is single-use and lives about 30 seconds, and there is an
# apt install plus a steamcmd bootstrap ahead of the login, so a hand-pasted literal is a race.
#
# The file .steam_auth in the server root is honoured too. Prefer it for a URL that embeds an
# ASF IPC password -- panel variables are stored in the database in plain text and are visible to
# any panel admin, whereas the file can be chmod 600 and never leaves the volume.
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
    # ArchiSteamFarm's IPC wants its password as an Authentication header on newer builds and as
    # ?password= on older ones. Sending both means either vintage answers.
    local ipc_pw=""
    case "${src}" in *password=*) ipc_pw="${src##*password=}"; ipc_pw="${ipc_pw%%&*}" ;; esac
    local response
    response="$(curl --fail -sSL --max-time 15 -H "Authentication: ${ipc_pw}" "${src}" 2>/dev/null)"
    [[ -z "${response}" ]] && response="$(curl --fail -sSL --max-time 15 "${src}" 2>/dev/null)"
    if [[ -z "${response}" ]]; then
        echo "  2FA endpoint returned nothing (auth rejected or unreachable)." >&2
        return 0
    fi
    # Most specific first: ASF's {"Result":{"bot":{"Result":"ABC12"}}} (last match -- the outer
    # wrapper reuses the key), then a bare 5-character body, then any uppercase 5-char token.
    # Step one matters because the generic pattern would happily return a 5-character uppercase
    # BOT NAME in preference to the code.
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

# --- Download ------------------------------------------------------------------------------
# @sSteamCmdForcePlatformType windows is unconditional: the only server build is the Windows one,
# and this egg runs it under Wine. The old egg gated this behind a WINDOWS_INSTALL variable that
# had no meaningful "off" setting.
steam_download() {
    local attempt code log=/tmp/steamcmd.log
    local -a branch_args=()
    [[ -n "${STEAM_BRANCH}" ]] && branch_args+=(-beta "${STEAM_BRANCH}")
    [[ -n "${STEAM_BRANCH_PASSWORD}" ]] && branch_args+=(-betapassword "${STEAM_BRANCH_PASSWORD}")

    for attempt in 1 2; do
        code="$(mint_2fa_code)"
        if [[ -n "${code}" ]]; then
            echo "Downloading appid ${STEAMCMD_APPID} (attempt ${attempt}, using a Guard code)..."
        else
            echo "Downloading appid ${STEAMCMD_APPID} (attempt ${attempt}, no code -- relying on the sentry)..."
        fi
        # Credentials are arguments and never echoed. Unquoted ${code}: steamcmd takes the Guard
        # code as +login's third positional argument, and an empty value must vanish rather than
        # become an empty argument. stdin is /dev/null and the call is time-boxed, because when
        # steamcmd wants a code it was not given it prompts, and would otherwise block forever on
        # a tty that does not exist.
        timeout 3600 ./steamcmd.sh +force_install_dir /mnt/server \
            +login "${STEAM_USER}" "${STEAM_PASS}" ${code} \
            +@sSteamCmdForcePlatformType windows \
            +app_update "${STEAMCMD_APPID}" "${branch_args[@]}" validate +quit < /dev/null 2>&1 | tee "${log}"

        # Success is judged by the app manifest, NOT steamcmd's exit status, which returns
        # non-zero on perfectly good runs. Note also that a pipeline's status is the LAST
        # command's -- tee's -- so testing the pipeline directly always reports success.
        if [[ -f "/mnt/server/steamapps/appmanifest_${STEAMCMD_APPID}.acf" ]] \
           && ! grep -qiE 'Login Failure|two-factor|Invalid Password|Rate Limit' "${log}"; then
            return 0
        fi
        if [[ "${attempt}" == "1" ]]; then
            echo "  Login or download failed."
            if is_url "${STEAM_AUTH}"; then
                # A TOTP only rolls over every 30s, so minting again immediately hands back the
                # same rejected code. Wait out the window before the retry.
                echo "  Waiting 31s for a new TOTP window, then retrying once..."
                sleep 31
            else
                echo "  Retrying once. A literal code is single-use, so this only helps if the"
                echo "  first failure was not the code itself."
            fi
        fi
    done
    echo "FATAL: could not download appid ${STEAMCMD_APPID}."
    echo "  Check STEAM_USER/STEAM_PASS, that the account owns BattleBit Remastered, that it has"
    echo "  access to the ${STEAM_BRANCH} branch, and that STEAM_AUTH is a valid code or a"
    echo "  reachable endpoint."
    return 1
}

steam_download

# Never leave a stale single-use code behind: it cannot work twice, and keeping it makes the next
# reinstall look like it had a code when it did not. A URL is kept -- it stays valid.
if [[ -f "${GUARD_FILE}" ]] && ! is_url "$(tr -d ' \r\n' < "${GUARD_FILE}")"; then
    rm -f "${GUARD_FILE}"
    echo "Consumed and removed .steam_auth (single-use)."
fi

# The manifest can exist while the payload is wrong (wrong branch, or a branch the account has no
# access to, which Steam serves as the base game). Check for the binary itself.
if [[ ! -f "/mnt/server/${SERVER_BINARY}" ]]; then
    echo "FATAL: the download completed but /mnt/server/${SERVER_BINARY} is missing."
    echo "  This usually means the account has no access to the '${STEAM_BRANCH}' branch and"
    echo "  Steam served the base game instead. Refusing to finish a broken install."
    exit 1
fi

# Steam client libraries, both word sizes -- Wine may load either.
mkdir -p /mnt/server/.steam/sdk32 /mnt/server/.steam/sdk64
cp -v linux32/steamclient.so /mnt/server/.steam/sdk32/steamclient.so || true
cp -v linux64/steamclient.so /mnt/server/.steam/sdk64/steamclient.so || true

# --- Egg companion script -------------------------------------------------------------------
# Pinned to a ref so reinstalls are reproducible. Bump RAW_REF when boot.sh changes.
RAW_REF="master"
RAW_BASE="https://raw.githubusercontent.com/bluscream/pterodactyl-eggs/${RAW_REF}/battlebit"

echo "Fetching boot.sh..."
# --fail is mandatory: without it curl exits 0 on a 404 and writes the error page into the file.
curl --fail -sSL -o /mnt/server/boot.sh.tmp "${RAW_BASE}/boot.sh" || {
    echo "FATAL: could not download boot.sh from ${RAW_BASE}"
    rm -f /mnt/server/boot.sh.tmp
    exit 1
}
mv /mnt/server/boot.sh.tmp /mnt/server/boot.sh
chmod +x /mnt/server/boot.sh

# BattlEye-style admin list the game reads at startup.
touch /mnt/server/Permissions.txt

echo "-----------------------------------------"
echo "Installation completed."
echo "  binary : ${SERVER_BINARY} (Windows, runs under Wine)"
echo "  branch : ${STEAM_BRANCH}"
echo "-----------------------------------------"
