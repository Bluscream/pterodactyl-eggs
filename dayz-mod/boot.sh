#!/usr/bin/env bash
# Startup wrapper for the DayZ Mod egg.
#
# Single command by design: the games:* image entrypoints build the start command inside a
# backtick `eval`, where every ";"-separated segment after the first executes during variable
# assignment. See dayz-standalone/boot.sh for the full autopsy.
#
# Beyond that, this script exists because DayZ Mod persistence is a pipeline. The engine's stdout
# has to be fed to ./writer.pl, which performs the Hive database writes -- there is no Linux build
# of the official Hive extension.
set -u

cd /home/container || exit 1

SERVER_CFG="./cfgdayz/server.cfg"
BE_DIR="./battleye"

# --- 1. Lowercase ---------------------------------------------------------------------------
# The engine resolves every path lowercase internally. Anything uploaded through the file manager
# keeps its casing, and one uppercase letter is enough to break loading.
if [ -x ./tolower ]; then
    ./tolower > /dev/null 2>&1 || true
elif [ -f ./tolower.c ] && command -v gcc > /dev/null 2>&1; then
    gcc -O -o tolower tolower.c 2>/dev/null && ./tolower > /dev/null 2>&1 || true
else
    echo "[boot] WARNING: no tolower binary and no gcc -- filenames were not normalised."
    echo "[boot]   An uppercase letter in any mission or mod filename will break loading."
fi

# --- 2. Windows leftovers -------------------------------------------------------------------
# A 32-bit ELF cannot load a PE DLL, and BattlEye trips over the stray .dll files Steam delivers.
find ./battleye ./expansion -maxdepth 2 -name '*.dll' -delete 2>/dev/null || true

# --- 3. Mod signature keys ------------------------------------------------------------------
# verifySignatures = 2 rejects any addon whose .bikey is missing from keys/.
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
                [ -f "./keys/${base}" ] || { cp "${key}" "./keys/${base}" && synced=$((synced+1)); }
            done
        done
    done
    [ "${synced}" -gt 0 ] && echo "[boot] Synced ${synced} mod signature key(s) into keys/."
fi

set_cfg() { # key, value -- replace or append in cfgdayz/server.cfg
    [ -f "${SERVER_CFG}" ] || return 0
    if grep -qi "^[[:space:]]*$1[[:space:]]*=" "${SERVER_CFG}"; then
        sed -i "s|^[[:space:]]*$1[[:space:]]*=.*|$1 = $2;|I" "${SERVER_CFG}"
    else
        echo "$1 = $2;" >> "${SERVER_CFG}"
    fi
}

# --- 4. BattlEye ----------------------------------------------------------------------------
# DISABLE_BATTLEYE is the sole decider, as in the sibling eggs. Nothing is patched here: a 2010
# engine has no BattlEye global-ban network to hide from. The switch exists because BattlEye is an
# extra moving part that frequently breaks modded A2 servers.
if [ "${DISABLE_BATTLEYE:-1}" != "0" ]; then
    DISABLE_BATTLEYE=1
fi
mkdir -p "${BE_DIR}"
if [ "${DISABLE_BATTLEYE}" = "1" ]; then
    set_cfg BattlEye 0
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
    [ -z "${ADMIN_PASSWORD:-}" ] && \
        echo "[boot] WARNING: ADMIN_PASSWORD empty -- RCON password defaulted to 'changeme'."
fi

# --- 5. Hive -------------------------------------------------------------------------------
# Three things have to be true for persistence to work, and all three fail silently if unchecked:
#   a. writer.pl is present
#   b. perl can load JSON::XS, DBI and DBD::mysql -- none of which are in Debian's perl-base, so
#      they are vendored into ./perl5 at install time and reached via PERL5LIB
#   c. writer.pl is patched to read credentials from the environment AND to put a host in its DSN.
#      Upstream hardcodes DB_NAME/DB_LOGIN/DB_PASSWD as Perl constants and connects with
#      'dbi:mysql:'.DB_NAME -- no host at all, i.e. a local socket. A Pterodactyl container has no
#      local MySQL, so unpatched it can never reach a database.
export PERL5LIB="/home/container/perl5:/home/container/perl5/lib/perl5:${PERL5LIB:-}"

hive_ready=1
if [ "${HIVE_ENABLED:-1}" != "1" ]; then
    hive_ready=0
elif [ ! -f ./writer.pl ]; then
    echo "[boot] WARNING: HIVE_ENABLED=1 but ./writer.pl is missing."
    hive_ready=0
elif ! command -v perl > /dev/null 2>&1; then
    echo "[boot] WARNING: HIVE_ENABLED=1 but perl is not installed in this image."
    hive_ready=0
elif ! perl -MJSON::XS -MDBI -MDBD::mysql -e1 > /dev/null 2>&1; then
    echo "[boot] WARNING: perl is present but JSON::XS / DBI / DBD::mysql are not loadable."
    echo "[boot]   These are vendored into ./perl5 during install. If that directory is empty or"
    echo "[boot]   was built against a different Debian release than this runtime image, reinstall"
    echo "[boot]   or install libjson-xs-perl, libdbi-perl and libdbd-mysql-perl into the image."
    hive_ready=0
fi

if [ "${hive_ready}" = "1" ]; then
    # Idempotent patch, guarded by a marker so restarts do not stack edits.
    if ! grep -q 'HIVE_ENV_PATCHED' ./writer.pl; then
        cp ./writer.pl ./writer.pl.orig
        sed -i \
            -e "s|DB_NAME   => 'dayz',|DB_NAME   => \$ENV{'HIVE_DB_NAME'} \|\| 'dayz',|" \
            -e "s|DB_LOGIN  => 'dayz',|DB_LOGIN  => \$ENV{'HIVE_DB_USER'} \|\| 'dayz',|" \
            -e "s|DB_PASSWD => 'dayz',|DB_PASSWD => \$ENV{'HIVE_DB_PASS'} \|\| 'dayz',|" \
            -e "s|'dbi:mysql:'\.DB_NAME|'dbi:mysql:'.DB_NAME.';host='.(\$ENV{'HIVE_DB_HOST'} \|\| '127.0.0.1').';port='.(\$ENV{'HIVE_DB_PORT'} \|\| 3306)|" \
            ./writer.pl
        echo '# HIVE_ENV_PATCHED' >> ./writer.pl
        if perl -c ./writer.pl > /dev/null 2>&1; then
            echo "[boot] Patched writer.pl to read HIVE_DB_* from the environment."
        else
            echo "[boot] WARNING: patching writer.pl produced a syntax error -- restoring the"
            echo "[boot]   original and starting WITHOUT persistence. Upstream's layout changed."
            mv ./writer.pl.orig ./writer.pl
            hive_ready=0
        fi
    fi
fi

if [ "${hive_ready}" = "1" ] && [ -z "${HIVE_DB_HOST:-}" ]; then
    echo "[boot] WARNING: HIVE_DB_HOST is empty, so writer.pl will try 127.0.0.1 -- and nothing"
    echo "[boot]   but the game server runs in this container. Set it to a reachable MySQL host."
fi

if [ "${HIVE_ENABLED:-1}" = "1" ] && [ "${hive_ready}" != "1" ]; then
    echo "[boot] Starting WITHOUT persistence: players and vehicles will NOT be saved."
fi

BIN="./${SERVER_BINARY:-server}"
if [ ! -f "${BIN}" ]; then
    echo "[boot] FATAL: server binary ${BIN} not found."
    echo "[boot]   Expected the ELF from the A2OA Linux server package, not the arma2oaserver wrapper."
    exit 1
fi
chmod +x "${BIN}" 2>/dev/null || true

# The 32-bit engine needs the 32-bit loader path; "." covers libs shipped beside the binary,
# /usr/lib32 the distro ones.
export LD_LIBRARY_PATH=".:/usr/lib32:${LD_LIBRARY_PATH:-}"

# --- 6. Mod arguments -----------------------------------------------------------------------
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
                case "${dropped}" in
                    *@dayz*|*@hive*) echo "[boot]   NOTE: that is a core DayZ Mod component -- the mod will not load." ;;
                esac
            fi
            # Omit the flag entirely when nothing survives: a bare -mod="" makes the engine parse
            # an empty modlist entry.
            [ -n "${kept}" ] && ARGS+=("${prefix}=${kept}")
            ;;
        *)
            ARGS+=("${arg}")
            ;;
    esac
done

echo "[boot] Starting: ${BIN} ${ARGS[*]}"

if [ "${hive_ready}" = "1" ]; then
    # A named pipe rather than `exec server | writer.pl`.
    #
    # In a pipeline each side runs in its own subshell, so `exec` replaces the SUBSHELL, not this
    # script -- the shell stays alive as PID 1 holding the pipeline. Signals from Wings then land
    # on the shell, which does not forward them, so a stop request is ignored until Wings gives up
    # and SIGKILLs. Killing the pipeline's $! is no better: that is writer.pl, not the server.
    #
    # With a FIFO both processes are addressable, so SIGTERM/SIGINT can be forwarded to the engine
    # and it gets to shut down cleanly and flush to the Hive.
    PIPE="./.hivepipe"
    rm -f "${PIPE}"
    mkfifo "${PIPE}" || { echo "[boot] FATAL: could not create ${PIPE}"; exit 1; }
    chmod +x ./writer.pl 2>/dev/null || true

    ./writer.pl < "${PIPE}" &
    writer_pid=$!
    "${BIN}" "${ARGS[@]}" > "${PIPE}" 2>&1 &
    server_pid=$!

    trap 'echo "[boot] Forwarding shutdown to the server..."; kill -INT "${server_pid}" 2>/dev/null' INT TERM
    wait "${server_pid}"
    rc=$?
    # Let the writer drain the pipe before it disappears.
    wait "${writer_pid}" 2>/dev/null || true
    rm -f "${PIPE}"
    exit "${rc}"
else
    exec "${BIN}" "${ARGS[@]}"
fi
