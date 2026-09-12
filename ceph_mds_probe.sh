#!/bin/sh

#
# CephFS MDS tuning probe: continuous timestamped sampling for
# mds_max_caps_per_client / max_mds sizing decisions.
#
# Centralized: run on any admin node; samples active MDS ranks via
# `ceph tell`. Methodology: see CephFS-MDS-Profiling-Guide.md.
#
# Run >= 24h for a baseline; re-run with a different --tag after config
# changes so the two collections can be compared.
#
# Every stream runs in its own background worker, so a slow or hung
# `ceph tell` on one stream (or on one rank) never delays the others.
# The set of sampled MDSs is re-discovered every --discovery-interval
# seconds, so ranks that fail over to another daemon during a long run
# keep being sampled.
#
# Output layout (<out-dir>/mds-probe_<tag>_<ts>_XXXXXX/):
#
#   run/                        pid, running flag, internal state
#   meta/                       run info, active mdss, fs dump, mds metadata,
#                               effective MDS options, perf schemas, errors,
#                               quality-report
#   fs-perf-stats.<day>.jsonl   per-client workload snapshots (30s)
#   fs-status.<day>.jsonl       per-rank req/s, cache and standby list (60s)
#   health.<day>.jsonl          cluster health detail (300s)
#   perf-<mds>.<day>.jsonl      raw perf counters (5s)
#   objecter-<mds>.<day>.jsonl  MDS -> OSD requests in flight (60s)
#   session-<mds>.<day>.jsonl   per-session caps (180s)
#   loads-<mds>.<day>.jsonl     balancer / subtree load (300s)
#   mempools-<mds>.<day>.jsonl  cache memory accounting (300s)
#   cache-<mds>.<day>.log       cache status snapshots (60s)
#   histops-<mds>.<day>.log     historic ops by duration + ops in flight (300s)
#   osd-perf-<osd>.<day>.jsonl  metadata pool OSDs, filtered perf (300s)
#   osd-histops-<osd>.<day>.log metadata pool OSDs, slow/blocked ops (300s)
#   host-<mds>.<day>.log        per-thread CPU on the MDS host (--ssh)
#   daemonperf-<mds>.<day>.log  daemonperf on the MDS host (--daemonperf)
#
# Data files carry the local date and roll over at midnight. A sample
# that fails is recorded as {"ts","t","mds","rc","error"} instead of
# being dropped, so a gap in a stream is always explained.
#
# --ssh uses the cephadm SSH identity (ceph cephadm get-user /
# get-ssh-config / config-key get mgr/cephadm/ssh_identity_key); the
# private key is kept in an in-memory ssh-agent, or in a 0600 file on
# tmpfs that is shredded on exit. Use --plain-ssh for your own identity.
#
# Stop a detached run with `--stop`, check on it with `--status`.
#

CEPH="${CEPH:-ceph}"
CEPH_CONFIG_FILE="${CEPH_CONFIG_FILE:-/etc/ceph/ceph.conf}"
CEPH_TIMEOUT="${CEPH_TIMEOUT:-10}"
TELL_TIMEOUT="${TELL_TIMEOUT:-120}"
PERF_INTERVAL="${PERF_INTERVAL:-5}"
FS_PERF_INTERVAL="${FS_PERF_INTERVAL:-30}"
FS_STATUS_INTERVAL="${FS_STATUS_INTERVAL:-60}"
CACHE_INTERVAL="${CACHE_INTERVAL:-60}"
OBJECTER_INTERVAL="${OBJECTER_INTERVAL:-60}"
SESSION_INTERVAL="${SESSION_INTERVAL:-180}"
HISTOPS_INTERVAL="${HISTOPS_INTERVAL:-300}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-300}"
LOADS_INTERVAL="${LOADS_INTERVAL:-300}"
OSD_INTERVAL="${OSD_INTERVAL:-300}"
DISCOVERY_INTERVAL="${DISCOVERY_INTERVAL:-60}"
OSD_LIMIT="${OSD_LIMIT:-4}"
MAX_PARALLEL="${MAX_PARALLEL:-8}"
REMOTE_RETRY="${REMOTE_RETRY:-120}"
DURATION="${DURATION:-86400}"
OUT_DIR="${OUT_DIR:-/var/log/ceph}"
TAG="${TAG:-}"
FS="${FS:-}"
SKIP_SESSIONS="${SKIP_SESSIONS:-N}"
ENABLE_STATS_MODULE="${ENABLE_STATS_MODULE:-N}"
ARCHIVE="${ARCHIVE:-N}"
VERBOSE="${VERBOSE:-N}"
USE_SSH="${USE_SSH:-N}"
PLAIN_SSH="${PLAIN_SSH:-N}"
DO_DAEMONPERF="${DO_DAEMONPERF:-N}"
SSH_OPTS="${SSH_OPTS:-}"
SPACE_CHECK="${SPACE_CHECK:-Y}"
FORCE="${FORCE:-N}"
ACTION=run
RUN_DIR="${RUN_DIR:-}"
CURRENT_LINK=""

# Effective values of these are recorded per MDS daemon in
# meta/options-<mds>.json; the analyzer reads its baselines from there.
MDS_OPTS_OF_INTEREST='mds_cache_memory_limit
mds_cache_reservation
mds_health_cache_threshold
mds_cache_trim_threshold
mds_cache_trim_decay_rate
mds_cache_trim_interval
mds_max_caps_per_client
mds_min_caps_per_client
mds_min_caps_working_set
mds_recall_max_caps
mds_recall_max_decay_rate
mds_recall_max_decay_threshold
mds_recall_global_max_decay_threshold
mds_recall_warning_threshold
mds_recall_warning_decay_rate
mds_session_cache_liveness_decay_rate
mds_session_cache_liveness_magnitude
mds_session_cap_acquisition_throttle
mds_session_cap_acquisition_decay_rate
mds_session_max_caps_throttle_ratio
mds_cap_acquisition_throttle_retry_request_timeout
mds_op_history_size
mds_op_history_duration
mds_op_complaint_time
mds_bal_interval
mds_bal_fragment_size_max
mds_bal_split_size
mds_bal_merge_size
mds_log_max_segments
mds_log_max_events
mds_session_blocklist_on_timeout
mds_beacon_grace
mds_client_delegate_inos_pct
mds_client_prealloc_inos
mds_cap_revoke_eviction_timeout'

#
# Functions
#

usage()
{
    echo
    echo "usage: $0 [options]"
    echo
    echo "Options:"
    echo
    echo "  -h | --help                     print this help and exit"
    echo "  -c | --ceph-config-file <file>  ceph configuration file"
    echo "  -t | --timeout <sec>            timeout for quick ceph operations"
    echo "                                  (default ${CEPH_TIMEOUT})"
    echo "  -T | --tell-timeout <sec>       timeout for ceph tell operations"
    echo "                                  (default ${TELL_TIMEOUT})"
    echo "  -d | --duration <sec>           probe duration, 0 = until stopped"
    echo "                                  (default ${DURATION})"
    echo "  -i | --perf-interval <sec>      perf dump sampling interval"
    echo "                                  (default ${PERF_INTERVAL})"
    echo "      --fs-perf-interval <sec>    fs perf stats sampling interval"
    echo "                                  (default ${FS_PERF_INTERVAL})"
    echo "      --fs-status-interval <sec>  fs status sampling interval, 0 = disable"
    echo "                                  (default ${FS_STATUS_INTERVAL})"
    echo "      --cache-interval <sec>      cache status sampling interval"
    echo "                                  (default ${CACHE_INTERVAL})"
    echo "      --objecter-interval <sec>   objecter_requests sampling interval,"
    echo "                                  0 = disable (default ${OBJECTER_INTERVAL})"
    echo "  -s | --session-interval <sec>   session ls sampling interval, 0 = disable"
    echo "                                  (default ${SESSION_INTERVAL})"
    echo "      --skip-sessions             same as --session-interval 0"
    echo "      --histops-interval <sec>    historic ops / ops in flight sampling"
    echo "                                  interval, 0 = disable"
    echo "                                  (default ${HISTOPS_INTERVAL})"
    echo "      --skip-histops              same as --histops-interval 0"
    echo "      --loads-interval <sec>      dump loads / dump_mempools sampling"
    echo "                                  interval, 0 = disable (default ${LOADS_INTERVAL})"
    echo "      --health-interval <sec>     cluster health detail sampling"
    echo "                                  interval, 0 = disable"
    echo "                                  (default ${HEALTH_INTERVAL})"
    echo "      --osd-limit <n>             sample this many metadata pool OSDs,"
    echo "                                  0 = disable (default ${OSD_LIMIT})"
    echo "      --osd-interval <sec>        metadata pool OSD sampling interval"
    echo "                                  (default ${OSD_INTERVAL})"
    echo "      --discovery-interval <sec>  how often the active MDS set is"
    echo "                                  re-discovered (default ${DISCOVERY_INTERVAL})"
    echo "      --max-parallel <n>          max concurrent ceph calls per stream"
    echo "                                  (default ${MAX_PARALLEL})"
    echo "  -f | --fs <name>                only sample MDS ranks of this filesystem"
    echo "  -o | --out-dir <dir>            base directory for the run directory"
    echo "                                  (default ${OUT_DIR})"
    echo "      --tag <name>                tag for the run, e.g. before-max-mds-4"
    echo "      --ssh                       also sample per-thread CPU (top -b -H)"
    echo "                                  on the MDS hosts over ssh"
    echo "      --daemonperf                also run daemonperf on the MDS hosts"
    echo "                                  (implies --ssh)"
    echo "      --plain-ssh                 use the invoking user's ssh identity"
    echo "                                  instead of the cephadm one"
    echo "      --archive                   pack the run directory into a tar.gz"
    echo "                                  on exit (the directory is kept)"
    echo "      --enable-stats-module       enable the mgr stats module if it is"
    echo "                                  off (needed for fs perf stats);"
    echo "                                  restored on exit"
    echo "      --no-space-check            do not estimate the data volume and"
    echo "                                  check the free space before starting"
    echo "      --force                     start even if the estimated data"
    echo "                                  volume does not fit in --out-dir"
    echo "      --stop                      stop the running probe in --out-dir"
    echo "      --status                    show the state of the probe in --out-dir"
    echo "      --run-dir <dir>             run directory for --stop/--status/--pack"
    echo "      --pack                      (re)create the tar.gz of a run directory"
    echo "  -v | --verbose                  be verbose"
    echo "  -V | --version                  print script version and exit"
    echo
}

info() {
    echo "$*" >&2
}

log() {
    local line
    line="$(now_iso) $*"
    echo "${line}" >&2
    if [ -n "${RUN_DIR}" ] && [ -d "${RUN_DIR}/run" ]; then
        echo "${line}" >> "${RUN_DIR}/run/probe.log"
    fi
    return 0
}

version() {
    md5sum "$(command -v $0)" | cut -d' ' -f1
}

now_iso() {
    date -Is
}

day() {
    date +%Y%m%d
}

# running: the probe keeps sampling while the flag file exists. Using a
# file rather than a signal means `--stop` lets every sampler finish the
# call it is in the middle of instead of killing it.
running() {
    [ -f "${RUN_DIR}/run/running" ]
}

# nap <sec>: sleep in 1s steps so a stop is noticed quickly
nap() {
    local n="$1"

    while [ "${n}" -gt 0 ] && running; do
        sleep 1
        n=$((n - 1))
    done
}

# nap_rest <round-start> <interval>: sleep what is left of the interval
# after the round's own work, so the sampling period is the interval and
# not interval + call time. Never busy-loops: a round that overruns its
# interval still yields for a second.
nap_rest() {
    local rest

    rest=$(($1 + $2 - $(date +%s)))
    [ "${rest}" -gt 0 ] || rest=1
    nap "${rest}"
}

# run_parallel <fn> <item>...: run "fn item" for every item, at most
# MAX_PARALLEL at a time. One slow rank delays only the rest of its own
# batch, never another stream.
run_parallel() {
    local fn="$1"; shift
    local n=0
    local item

    for item in "$@"; do
        "${fn}" "${item}" &
        n=$((n + 1))
        if [ "${n}" -ge "${MAX_PARALLEL}" ]; then
            wait
            n=0
        fi
    done
    wait
}

# stream_file <base> [<name>]: data file for a stream, dated so files
# roll over at midnight
stream_file() {
    if [ -n "$2" ]; then
        echo "${RUN_DIR}/$1-$2.$(day)"
    else
        echo "${RUN_DIR}/$1.$(day)"
    fi
}

#
# record_json <outfile> <mds|-> <jq-filter> <cmd>...
#
# One JSONL record per sample: {"ts","t","mds","data"} on success,
# {"ts","t","mds","rc","error"} when the command fails or does not
# return JSON. Failures are recorded rather than dropped so that a gap
# in a stream can always be told apart from an idle MDS.
#
record_json() {
    local out="$1"; shift
    local mds="$1"; shift
    local filter="$1"; shift
    local err raw rc json ts t msg record_rc

    record_rc=1

    err=$(mktemp "${RUN_DIR}/run/tmp/err.XXXXXX" 2>/dev/null) || err=""
    if [ -n "${err}" ]; then
        raw=$(PYTHONUNBUFFERED=1 "$@" 2>"${err}")
        rc=$?
    else
        raw=$(PYTHONUNBUFFERED=1 "$@" 2>/dev/null)
        rc=$?
    fi
    ts=$(now_iso)
    t=$(date +%s)

    # normalize to a single line (some builds pretty-print or emit
    # leading whitespace)
    if [ ${rc} -eq 0 ] && json=$(printf '%s' "${raw}" | jq -c "${filter}" 2>/dev/null) &&
       [ -n "${json}" ]; then
        record_rc=0
        if [ "${mds}" = "-" ]; then
            printf '{"ts":"%s","t":%s,"data":%s}\n' "${ts}" "${t}" "${json}"
        else
            printf '{"ts":"%s","t":%s,"mds":"%s","data":%s}\n' \
                   "${ts}" "${t}" "${mds}" "${json}"
        fi >> "${out}"
    else
        msg=""
        [ -n "${err}" ] && msg=$(head -c 500 "${err}" 2>/dev/null | tr -d '\000')
        [ -n "${msg}" ] || msg=$(printf '%s' "${raw}" | head -c 500)
        [ -n "${msg}" ] || msg="no output"
        msg=$(printf '%s' "${msg}" | jq -Rs . 2>/dev/null)
        [ -n "${msg}" ] || msg='"unprintable error"'
        if [ "${mds}" = "-" ]; then
            printf '{"ts":"%s","t":%s,"rc":%s,"error":%s}\n' \
                   "${ts}" "${t}" "${rc}" "${msg}"
        else
            printf '{"ts":"%s","t":%s,"mds":"%s","rc":%s,"error":%s}\n' \
                   "${ts}" "${t}" "${mds}" "${rc}" "${msg}"
        fi >> "${out}"
    fi
    [ -n "${err}" ] && rm -f "${err}"
    return ${record_rc}
}

# record_text <outfile> <label> <cmd>...: snapshot with a header, for
# the commands that have no json formatter
record_text() {
    local out="$1"; shift
    local label="$1"; shift

    {
        echo "=== $(now_iso) ${label} ==="
        PYTHONUNBUFFERED=1 "$@"
    } >> "${out}" 2>&1
    return 0
}

# meta_json <file> <cmd>...: one-shot metadata into meta/<file>.
# stderr is only kept when the command actually failed: a ceph CLI that
# chats on stderr (a dev build prints banners) would otherwise fill
# meta/errors.log with noise and make the quality report cry wolf.
meta_json() {
    local out="$1"; shift

    meta_run "${RUN_DIR}/meta/${out}" "$@"
}

# meta_run <outfile> <cmd>...: same, for an explicit path
meta_run() {
    local out="$1"; shift
    local err rc

    err=$(mktemp "${RUN_DIR}/run/tmp/meta.XXXXXX" 2>/dev/null) || err=""
    if [ -n "${err}" ]; then
        PYTHONUNBUFFERED=1 "$@" > "${out}" 2>"${err}"
        rc=$?
        if [ ${rc} -ne 0 ]; then
            {
                printf '%s rc=%s %s\n' "$(now_iso)" "${rc}" "$*"
                head -c 1000 "${err}"
                echo
            } >> "${RUN_DIR}/meta/errors.log"
        fi
        rm -f "${err}"
    else
        PYTHONUNBUFFERED=1 "$@" > "${out}" 2>/dev/null
        rc=$?
    fi
    return ${rc}
}

#
# Remote access (--ssh / --daemonperf)
#
# By default the cephadm SSH identity is used, so no extra credentials
# are needed on the admin node and no ceph CLI is needed on the MDS
# hosts: remote ceph commands go through the host's own deployed
# cephadm binary. The private key never reaches persistent storage.
#
SSH_USER=""
SSH_CONFIG_OPT=""
SSH_IDENT_OPT=""
SSH_SECDIR=""
SSH_AGENT_PID=""
REMOTE_SUDO=""
FSID=""

setup_ssh() {
    local key cfg i

    if ! command -v ssh > /dev/null 2>&1; then
        info "WARNING: ssh not found, disabling --ssh/--daemonperf"
        USE_SSH=N
        DO_DAEMONPERF=N
        return 1
    fi

    if [ "${PLAIN_SSH}" = Y ]; then
        SSH_USER=$(id -un)
        [ "${SSH_USER}" = root ] || REMOTE_SUDO="sudo "
        log "remote access: plain ssh as ${SSH_USER}"
        return 0
    fi

    SSH_USER=$(${CEPH} cephadm get-user 2>/dev/null | tr -d '[:space:]')
    case "${SSH_USER}" in
        ''|*rror*) SSH_USER=root ;;
    esac

    key=$(${CEPH} config-key get mgr/cephadm/ssh_identity_key 2>/dev/null)
    case "${key}" in
        *"PRIVATE KEY"*) ;;
        *)
            info "WARNING: no cephadm ssh identity in config-key" \
                 "(mgr/cephadm/ssh_identity_key), falling back to plain ssh"
            PLAIN_SSH=Y
            setup_ssh
            return
            ;;
    esac

    cfg=$(${CEPH} cephadm get-ssh-config 2>/dev/null)
    case "${cfg}" in
        *Host*) ;;
        *) cfg='Host *
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  ConnectTimeout 30
  LogLevel ERROR' ;;
    esac

    # private scratch directory on tmpfs (RAM), never on the data disk
    SSH_SECDIR=$(mktemp -d -p /dev/shm mds-probe.XXXXXX 2>/dev/null) ||
        SSH_SECDIR=$(mktemp -d)
    chmod 700 "${SSH_SECDIR}"
    (umask 077; printf '%s\n' "${cfg}" > "${SSH_SECDIR}/ssh_config")
    SSH_CONFIG_OPT="-F ${SSH_SECDIR}/ssh_config"

    if command -v ssh-agent > /dev/null 2>&1 &&
       command -v ssh-add > /dev/null 2>&1; then
        ssh-agent -D -a "${SSH_SECDIR}/agent.sock" > /dev/null 2>&1 &
        SSH_AGENT_PID=$!
        i=0
        while [ ! -S "${SSH_SECDIR}/agent.sock" ] && [ ${i} -lt 20 ]; do
            sleep 1
            i=$((i + 1))
        done
        if printf '%s\n' "${key}" |
           SSH_AUTH_SOCK="${SSH_SECDIR}/agent.sock" ssh-add - > /dev/null 2>&1; then
            SSH_AUTH_SOCK="${SSH_SECDIR}/agent.sock"
            export SSH_AUTH_SOCK
            log "remote access: cephadm identity (user ${SSH_USER}) in an in-memory ssh-agent"
        else
            kill "${SSH_AGENT_PID}" 2>/dev/null
            SSH_AGENT_PID=""
        fi
    fi

    if [ -z "${SSH_AGENT_PID}" ]; then
        (umask 077; printf '%s\n' "${key}" > "${SSH_SECDIR}/id_cephadm")
        chmod 600 "${SSH_SECDIR}/id_cephadm"
        SSH_IDENT_OPT="-i ${SSH_SECDIR}/id_cephadm -o IdentitiesOnly=yes"
        log "remote access: cephadm identity (user ${SSH_USER}) in ${SSH_SECDIR}/id_cephadm (removed on exit)"
    fi

    key=
    [ "${SSH_USER}" = root ] || REMOTE_SUDO="sudo "
    return 0
}

cleanup_ssh() {
    [ -n "${SSH_AGENT_PID}" ] && kill "${SSH_AGENT_PID}" 2>/dev/null
    if [ -n "${SSH_SECDIR}" ] && [ -d "${SSH_SECDIR}" ]; then
        if [ -f "${SSH_SECDIR}/id_cephadm" ]; then
            shred -u "${SSH_SECDIR}/id_cephadm" 2>/dev/null ||
                rm -f "${SSH_SECDIR}/id_cephadm"
        fi
        rm -rf "${SSH_SECDIR}"
    fi
    SSH_AGENT_PID=""
    SSH_SECDIR=""
    return 0
}

# remote_sh <host> <command>...
remote_sh() {
    local host="$1"; shift

    ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR \
        ${SSH_CONFIG_OPT} ${SSH_IDENT_OPT} ${SSH_OPTS} \
        -l "${SSH_USER}" "${host}" "$@"
}

# remote_sh_tty <host> <command>...: daemonperf sizes its table from the
# tty on stdin, so it needs a pty
remote_sh_tty() {
    local host="$1"; shift

    ssh -tt -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR \
        ${SSH_CONFIG_OPT} ${SSH_IDENT_OPT} ${SSH_OPTS} \
        -l "${SSH_USER}" "${host}" "$@" < /dev/null
}

# remote_ceph_prefix <daemon>: shell snippet that locates the deployed
# cephadm binary on the remote host and enters the daemon's container,
# so the MDS hosts need no ceph CLI of their own
remote_ceph_prefix() {
    printf 'CB=$(ls -t /var/lib/ceph/%s/cephadm.* 2>/dev/null | head -1); [ -n "$CB" ] || { echo "no /var/lib/ceph/%s/cephadm.* on $(hostname)" >&2; exit 2; }; %spython3 "$CB" shell --fsid %s --name %s --' \
        "${FSID}" "${FSID}" "${REMOTE_SUDO}" "${FSID}" "$1"
}

mds_host() {
    ${CEPH} mds metadata "${1#mds.}" -f json 2>/dev/null |
        jq -r '.hostname // empty' 2>/dev/null
}

#
# Discovery
#
# The active MDS set is re-read every DISCOVERY_INTERVAL seconds. Every
# sampler reads run/current-mdss at the start of each round, so a rank
# that fails over to another daemon during a long run keeps being
# sampled without restarting anything. meta/active-mdss keeps the union
# of every daemon ever seen, which is what the analyzer enumerates.
#
get_active_mdss() {
    local filter

    if [ -n "${FS}" ]; then
        filter=".filesystems[] | select(.mdsmap.fs_name == \"${FS}\")"
    else
        filter=".filesystems[]"
    fi

    ${CEPH} fs dump -f json 2>/dev/null |
        jq -r "[${filter}.mdsmap.info[] |
                select(.state | contains(\"active\")) |
                (.name | if startswith(\"mds.\") then . else \"mds.\" + . end)] |
                unique | .[]"
}

get_fs_list() {
    if [ -n "${FS}" ]; then
        echo "${FS}"
    else
        ${CEPH} fs ls -f json 2>/dev/null | jq -r '.[].name' 2>/dev/null
    fi
}

current_mdss() {
    cat "${RUN_DIR}/run/current-mdss" 2>/dev/null
}

current_fses() {
    cat "${RUN_DIR}/run/fs-list" 2>/dev/null
}

current_osds() {
    cat "${RUN_DIR}/run/osd-list" 2>/dev/null
}

# note_mdss <mds>...: update the current set and the union, collect the
# per-daemon metadata of daemons seen for the first time
note_mdss() {
    local new="$1"
    local d

    printf '%s\n' "${new}" > "${RUN_DIR}/run/current-mdss"

    for d in ${new}; do
        if ! grep -qx "${d}" "${RUN_DIR}/meta/active-mdss" 2>/dev/null; then
            echo "${d}" >> "${RUN_DIR}/meta/active-mdss"
            echo "$(now_iso) new active mds: ${d}" >> "${RUN_DIR}/meta/mds-changes.log"
            [ "${META_READY}" = Y ] && collect_mds_meta "${d}"
        fi
    done
}

#
# Metadata pool OSDs: the MDS is only as fast as the pool its journal
# and dentries live in, so the OSDs carrying the most metadata PGs are
# sampled too. Without this a slow metadata pool looks exactly like a
# slow MDS.
#
get_metadata_osds() {
    local fs pool pid

    for fs in $(current_fses); do
        pid=$(${CEPH} fs get "${fs}" -f json 2>/dev/null |
              jq -r '.mdsmap.metadata_pool // empty' 2>/dev/null)
        [ -n "${pid}" ] || continue
        pool=$(${CEPH} osd pool ls detail -f json 2>/dev/null |
               jq -r --argjson id "${pid}" \
                  '.[] | select(.pool_id == $id) | .pool_name' 2>/dev/null)
        [ -n "${pool}" ] || continue
        echo "${pool}" >> "${RUN_DIR}/meta/metadata-pools"
        ${CEPH} pg ls-by-pool "${pool}" -f json 2>/dev/null |
            jq -r '[(.pg_stats // .)[]? | .acting_primary] |
                   group_by(.) | map({osd: .[0], n: length}) |
                   sort_by(-.n) | .[].osd' 2>/dev/null
    done | grep -E '^[0-9]+$' | awk '!seen[$0]++' | head -n "${OSD_LIMIT}"
}

#
# One-shot metadata
#
collect_mds_meta() {
    local d="$1"
    local want

    meta_run "${RUN_DIR}/meta/perf-schema-${d}.json" \
        ${CEPH_TELL} tell "${d}" perf schema -f json

    meta_run "${RUN_DIR}/meta/config-diff-${d}.json" \
        ${CEPH_TELL} tell "${d}" config diff -f json

    # Effective per-daemon values, not the mds section value: a rank
    # level override or a runtime `config set` on one daemon is exactly
    # what `ceph config get mds <opt>` cannot show, and the analyzer
    # takes its baselines from here.
    want=$(printf '%s\n' "${MDS_OPTS_OF_INTEREST}" | jq -R . | jq -sc .)
    meta_run "${RUN_DIR}/run/tmp/cfg-${d}.json" \
        ${CEPH} config show-with-defaults "${d}" -f json
    if ! jq --argjson want "${want}" \
            'map(select(.name as $n | $want | index($n))) |
             map({(.name): .value}) | add // {}' \
            "${RUN_DIR}/run/tmp/cfg-${d}.json" \
            > "${RUN_DIR}/meta/options-${d}.json" 2>/dev/null; then
        echo '{}' > "${RUN_DIR}/meta/options-${d}.json"
    fi
    rm -f "${RUN_DIR}/run/tmp/cfg-${d}.json"
    if [ ! -s "${RUN_DIR}/meta/options-${d}.json" ]; then
        echo '{}' > "${RUN_DIR}/meta/options-${d}.json"
    fi

    if [ "${USE_SSH}" = Y ]; then
        collect_host_meta "${d}"
    fi
    return 0
}

collect_host_meta() {
    local d="$1"
    local host

    host=$(mds_host "${d}")
    if [ -z "${host}" ]; then
        echo "$(now_iso) cannot resolve host of ${d}" >> "${RUN_DIR}/meta/errors.log"
        return 1
    fi
    echo "${host}" > "${RUN_DIR}/run/host-${d}"

    remote_sh "${host}" 'hostname -f; uname -r; nproc;
        lscpu 2>/dev/null | grep -E "Model name|Socket|NUMA node\(s\)|Thread|MHz";
        cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null;
        free -g; uptime' \
        > "${RUN_DIR}/meta/host-info-${d}.txt" 2>&1 ||
        info "WARNING: ${d} host ${host} not reachable over ssh," \
             "host samplers will retry every ${REMOTE_RETRY}s"
    return 0
}

collect_meta() {
    local d

    {
        echo "start: $(now_iso)"
        echo "probe-version: $(version)"
        echo "tag: ${TAG}"
        echo "duration: ${DURATION}"
        echo "fs: ${FS:-all}"
        echo "perf-interval: ${PERF_INTERVAL}"
        echo "fs-perf-interval: ${FS_PERF_INTERVAL}"
        echo "fs-status-interval: ${FS_STATUS_INTERVAL}"
        echo "cache-interval: ${CACHE_INTERVAL}"
        echo "objecter-interval: ${OBJECTER_INTERVAL}"
        echo "session-interval: ${SESSION_INTERVAL}"
        echo "histops-interval: ${HISTOPS_INTERVAL}"
        echo "loads-interval: ${LOADS_INTERVAL}"
        echo "health-interval: ${HEALTH_INTERVAL}"
        echo "osd-interval: ${OSD_INTERVAL}"
        echo "osd-limit: ${OSD_LIMIT}"
        echo "discovery-interval: ${DISCOVERY_INTERVAL}"
        echo "ssh: ${USE_SSH}"
        echo "daemonperf: ${DO_DAEMONPERF}"
        echo "host: $(hostname -f 2>/dev/null || hostname)"
        echo "ceph: $(${CEPH} version 2>/dev/null)"
        echo "fsid: ${FSID}"
    } > "${RUN_DIR}/meta/probe-info"

    meta_json fs-dump.json      ${CEPH} fs dump -f json
    meta_json mds-metadata.json ${CEPH} mds metadata -f json
    meta_json versions.json     ${CEPH} versions -f json
    meta_json config-dump.json  ${CEPH} config dump -f json
    meta_json osd-pool-ls-detail.json ${CEPH} osd pool ls detail -f json

    # kept for compatibility with earlier runs; the analyzer prefers
    # the per-daemon effective values in meta/options-<mds>.json
    meta_run "${RUN_DIR}/meta/mds_max_caps_per_client" \
        ${CEPH} config get mds mds_max_caps_per_client
    meta_run "${RUN_DIR}/meta/mds_cache_memory_limit" \
        ${CEPH} config get mds mds_cache_memory_limit
    meta_run "${RUN_DIR}/meta/mds_recall_max_caps" \
        ${CEPH} config get mds mds_recall_max_caps

    for d in $(current_mdss); do
        collect_mds_meta "${d}"
    done
}

collect_meta_final() {
    meta_json fs-dump-end.json ${CEPH} fs dump -f json
    meta_json status-end.json  ${CEPH} status -f json
    meta_run "${RUN_DIR}/meta/cluster-log.txt" \
        ${CEPH} log last 10000 cluster
    echo "end: $(now_iso)" >> "${RUN_DIR}/meta/probe-info"
    return 0
}

#
# Samplers (one call, one record)
#
sample_perf_one() {
    record_json "$(stream_file perf "$1").jsonl" "$1" . \
        ${CEPH_TELL} tell "$1" perf dump -f json
}

sample_objecter_one() {
    # what the MDS is waiting for in the metadata pool: the difference
    # between "the MDS is slow" and "the OSDs under it are slow"
    record_json "$(stream_file objecter "$1").jsonl" "$1" . \
        ${CEPH_TELL} tell "$1" objecter_requests -f json
}

sample_loads_one() {
    record_json "$(stream_file loads "$1").jsonl" "$1" . \
        ${CEPH_TELL} tell "$1" dump loads -f json
    record_json "$(stream_file mempools "$1").jsonl" "$1" . \
        ${CEPH_TELL} tell "$1" dump_mempools -f json
}

sample_cache_one() {
    record_text "$(stream_file cache "$1").log" "$1" \
        ${CEPH_TELL} tell "$1" cache status
}

sample_histops_one() {
    local out
    out="$(stream_file histops "$1").log"

    record_text "${out}" "$1" \
        ${CEPH_TELL} tell "$1" dump_historic_ops_by_duration
    record_text "${out}" "$1 ops in flight" \
        ${CEPH_TELL} tell "$1" dump_ops_in_flight
}

sample_session_one() {
    local d="$1"

    # a release without a json formatter for `session ls` falls back to
    # the plain output; the second call only happens when the first one
    # produced nothing usable
    record_json "$(stream_file session "${d}").jsonl" "${d}" . \
        ${CEPH_TELL} tell "${d}" session ls -f json ||
        record_text "$(stream_file session "${d}").log" "${d}" \
            ${CEPH_TELL} tell "${d}" session ls
    return 0
}

sample_fs_status_one() {
    record_json "$(stream_file fs-status).jsonl" "$1" . \
        ${CEPH} fs status "$1" -f json
}

sample_osd_one() {
    local osd="$1"

    # only the subtrees that say anything about metadata latency; a full
    # osd perf dump every 5 min would dwarf the MDS data
    record_json "$(stream_file osd-perf "${osd}").jsonl" "osd.${osd}" \
        '{osd: ((.osd // {}) | with_entries(select(.key | test("op_|_lat|slow")))), bluestore, bluefs, rocksdb}' \
        ${CEPH_TELL} tell "osd.${osd}" perf dump -f json
    record_text "$(stream_file osd-histops "${osd}").log" "osd.${osd}" \
        ${CEPH_TELL} tell "osd.${osd}" dump_historic_slow_ops
}

#
# Workers: one background loop per stream. A stream that blocks (a hung
# `ceph tell` runs into --tell-timeout) delays only itself.
#
worker_perf() {
    local t0

    while running; do
        t0=$(date +%s)
        run_parallel sample_perf_one $(current_mdss)
        nap_rest "${t0}" "${PERF_INTERVAL}"
    done
}

worker_objecter() {
    local t0

    while running; do
        t0=$(date +%s)
        run_parallel sample_objecter_one $(current_mdss)
        nap_rest "${t0}" "${OBJECTER_INTERVAL}"
    done
}

worker_cache() {
    local t0

    while running; do
        t0=$(date +%s)
        run_parallel sample_cache_one $(current_mdss)
        nap_rest "${t0}" "${CACHE_INTERVAL}"
    done
}

worker_session() {
    local t0

    while running; do
        t0=$(date +%s)
        run_parallel sample_session_one $(current_mdss)
        nap_rest "${t0}" "${SESSION_INTERVAL}"
    done
}

worker_histops() {
    local t0

    while running; do
        t0=$(date +%s)
        run_parallel sample_histops_one $(current_mdss)
        nap_rest "${t0}" "${HISTOPS_INTERVAL}"
    done
}

worker_loads() {
    local t0

    while running; do
        t0=$(date +%s)
        run_parallel sample_loads_one $(current_mdss)
        nap_rest "${t0}" "${LOADS_INTERVAL}"
    done
}

worker_fs_perf() {
    local t0

    while running; do
        t0=$(date +%s)
        record_json "$(stream_file fs-perf-stats).jsonl" - . \
            ${CEPH_TELL} fs perf stats -f json
        nap_rest "${t0}" "${FS_PERF_INTERVAL}"
    done
}

worker_fs_status() {
    local t0

    while running; do
        t0=$(date +%s)
        run_parallel sample_fs_status_one $(current_fses)
        nap_rest "${t0}" "${FS_STATUS_INTERVAL}"
    done
}

worker_health() {
    local t0

    while running; do
        t0=$(date +%s)
        record_json "$(stream_file health).jsonl" - . \
            ${CEPH} health detail -f json
        nap_rest "${t0}" "${HEALTH_INTERVAL}"
    done
}

worker_osd() {
    local t0

    while running; do
        t0=$(date +%s)
        run_parallel sample_osd_one $(current_osds)
        nap_rest "${t0}" "${OSD_INTERVAL}"
    done
}

worker_discovery() {
    local mdss

    while running; do
        nap "${DISCOVERY_INTERVAL}"
        running || break
        mdss=$(get_active_mdss)
        if [ -z "${mdss}" ]; then
            echo "$(now_iso) no active mds found, keeping the previous set" \
                >> "${RUN_DIR}/meta/mds-changes.log"
            continue
        fi
        if [ "${mdss}" != "$(current_mdss)" ]; then
            echo "$(now_iso) active mds set changed: $(echo ${mdss} | tr '\n' ' ')" \
                >> "${RUN_DIR}/meta/mds-changes.log"
        fi
        note_mdss "${mdss}"

        # the metadata pool OSDs can come back empty at startup (the mgr
        # serves `pg ls-by-pool` and may not have pg stats yet), so keep
        # trying instead of staying blind to the backend for the run
        if [ "${OSD_LIMIT}" -gt 0 ] && [ ! -s "${RUN_DIR}/run/osd-list" ]; then
            get_metadata_osds > "${RUN_DIR}/run/osd-list.new" 2>/dev/null
            if [ -s "${RUN_DIR}/run/osd-list.new" ]; then
                mv -f "${RUN_DIR}/run/osd-list.new" "${RUN_DIR}/run/osd-list"
                echo "$(now_iso) metadata pool osds: $(tr '\n' ' ' < "${RUN_DIR}/run/osd-list")" \
                    >> "${RUN_DIR}/meta/mds-changes.log"
            else
                rm -f "${RUN_DIR}/run/osd-list.new"
            fi
        fi
    done
}

#
# Remote workers
#
# ensure_bg <key> <fn> <arg>: (re)start a long lived background sampler
# if it is not running; the supervisor loop below also picks up ranks
# that only appeared after a failover.
#
ensure_bg() {
    local key="$1"; shift
    local pidf

    pidf="${RUN_DIR}/run/${key}.bgpid"
    if [ -f "${pidf}" ] && kill -0 "$(cat "${pidf}" 2>/dev/null)" 2>/dev/null; then
        return 0
    fi
    "$@" &
    echo $! > "${pidf}"
    return 0
}

ts_prefix() {
    if [ "${AWK_HAS_STRFTIME}" = Y ]; then
        awk '{ print strftime("%Y-%m-%dT%H:%M:%S"), $0; fflush() }'
    else
        cat
    fi
}

# Per-thread CPU on the MDS host. ceph-mds concentrates its work in a
# few threads, so whether ms_dispatch/MDSRank is pinned at 100% is the
# evidence that decides whether more ranks would help at all.
host_sampler() {
    local d="$1"
    local host t0

    while running; do
        host=$(cat "${RUN_DIR}/run/host-${d}" 2>/dev/null)
        if [ -z "${host}" ]; then
            collect_host_meta "${d}"
            host=$(cat "${RUN_DIR}/run/host-${d}" 2>/dev/null)
        fi
        if [ -z "${host}" ]; then
            nap "${REMOTE_RETRY}"
            continue
        fi
        t0=$(date +%s)
        timeout 3700 ssh -n -o BatchMode=yes -o ConnectTimeout=10 \
            -o LogLevel=ERROR ${SSH_CONFIG_OPT} ${SSH_IDENT_OPT} ${SSH_OPTS} \
            -l "${SSH_USER}" "${host}" \
            "top -b -H -d 5 -n 720 | grep --line-buffered -E '^top|Cpu|MiB Mem|Swap|ceph-mds|ms_dispatch|MDSRank|safe_timer|fn_anonymous|md_log_replay|OpHistorySvc|mds-log-flush|journal_write'" \
            2>&1 | ts_prefix >> "$(stream_file host "${d}").log"
        # a run that ends within 30s is a connection failure, not data
        if [ $(($(date +%s) - t0)) -lt 30 ]; then
            nap "${REMOTE_RETRY}"
        else
            nap 2
        fi
    done
}

# daemonperf reads the daemon's local admin socket, so it has to run on
# the MDS host, inside the container of that daemon. 'debugonly' is
# required to get all counters.
daemonperf_sampler() {
    local d="$1"
    local host t0

    while running; do
        host=$(cat "${RUN_DIR}/run/host-${d}" 2>/dev/null)
        if [ -z "${host}" ]; then
            nap "${REMOTE_RETRY}"
            continue
        fi
        t0=$(date +%s)
        timeout 3700 ssh -tt -o BatchMode=yes -o ConnectTimeout=10 \
            -o LogLevel=ERROR ${SSH_CONFIG_OPT} ${SSH_IDENT_OPT} ${SSH_OPTS} \
            -l "${SSH_USER}" "${host}" \
            "stty cols 2000 rows 50 2>/dev/null; $(remote_ceph_prefix "${d}") ceph daemonperf ${d} debugonly 5 720" \
            < /dev/null 2>&1 |
            sed -u 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r$//' 2>/dev/null |
            ts_prefix >> "$(stream_file daemonperf "${d}").log"
        if [ $(($(date +%s) - t0)) -lt 30 ]; then
            nap "${REMOTE_RETRY}"
        else
            nap 2
        fi
    done
}

worker_remote() {
    local d t0

    while running; do
        t0=$(date +%s)
        for d in $(current_mdss); do
            [ "${USE_SSH}" = Y ] && ensure_bg "host-${d}" host_sampler "${d}"
            [ "${DO_DAEMONPERF}" = Y ] &&
                ensure_bg "daemonperf-${d}" daemonperf_sampler "${d}"
        done
        nap_rest "${t0}" "${DISCOVERY_INTERVAL}"
    done
}

WORKER_PIDS=""

start_worker() {
    # workers ignore SIGINT so that Ctrl-C reaches only the main shell:
    # the stop flag then lets every sampler finish the call it is in
    ( trap '' INT; "$@" ) &
    WORKER_PIDS="${WORKER_PIDS} $!"
}

#
# Data volume estimate and free space check
#
# The default output directory is /var/log/ceph; filling it up on a
# customer cluster is a production incident, so the projected volume is
# measured from real samples before anything is started.
#
human() {
    awk -v b="$1" 'BEGIN {
        split("B KiB MiB GiB TiB", u, " ");
        i = 1;
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        printf "%.1f %s", b, u[i]
    }'
}

sample_size() {
    PYTHONUNBUFFERED=1 "$@" 2>/dev/null | jq -c . 2>/dev/null | wc -c | tr -d ' '
}

# per_day <interval> <size> [<count>] -> bytes per day
per_day() {
    local interval="$1" size="$2" count="${3:-1}"

    if ! [ "${interval}" -gt 0 ] 2>/dev/null; then
        echo 0
        return 0
    fi
    echo $((86400 / interval * size * count))
}

estimate_volume() {
    local d nmds nosd total days avail need
    local s_perf=40000 s_sess=20000 s_fsperf=10000

    nmds=$(current_mdss | grep -c .)
    nosd=$(current_osds | grep -c .)
    [ "${nmds}" -gt 0 ] || nmds=1

    d=$(current_mdss | head -1)
    if [ -n "${d}" ]; then
        s_perf=$(sample_size ${CEPH_TELL} tell "${d}" perf dump -f json)
        [ "${s_perf}" -gt 100 ] 2>/dev/null || s_perf=40000
        if [ "${SESSION_INTERVAL}" -gt 0 ]; then
            s_sess=$(sample_size ${CEPH_TELL} tell "${d}" session ls -f json)
            [ "${s_sess}" -gt 100 ] 2>/dev/null || s_sess=20000
        fi
    fi
    s_fsperf=$(sample_size ${CEPH_TELL} fs perf stats -f json)
    [ "${s_fsperf}" -gt 100 ] 2>/dev/null || s_fsperf=10000

    total=0
    total=$((total + $(per_day "${PERF_INTERVAL}"      "${s_perf}"  "${nmds}")))
    total=$((total + $(per_day "${SESSION_INTERVAL}"   "${s_sess}"  "${nmds}")))
    total=$((total + $(per_day "${OBJECTER_INTERVAL}"  2048         "${nmds}")))
    total=$((total + $(per_day "${CACHE_INTERVAL}"     2048         "${nmds}")))
    total=$((total + $(per_day "${HISTOPS_INTERVAL}"   8192         "${nmds}")))
    total=$((total + $(per_day "${LOADS_INTERVAL}"     8192         "${nmds}")))
    total=$((total + $(per_day "${FS_PERF_INTERVAL}"   "${s_fsperf}" 1)))
    total=$((total + $(per_day "${FS_STATUS_INTERVAL}" 4096         1)))
    total=$((total + $(per_day "${HEALTH_INTERVAL}"    4096         1)))
    [ "${nosd}" -gt 0 ] &&
        total=$((total + $(per_day "${OSD_INTERVAL}" 8192 "${nosd}")))
    [ "${USE_SSH}" = Y ] &&
        total=$((total + 20000000 * nmds))

    if [ "${DURATION}" -gt 0 ]; then
        days=$(((DURATION + 86399) / 86400))
    else
        days=1
    fi
    need=$((total * days))

    info "estimated data volume: $(human ${total})/day" \
         "($(human ${need}) for this run, ${nmds} mds, ${nosd} metadata osd)"
    echo "estimated-bytes-per-day: ${total}" >> "${RUN_DIR}/meta/probe-info"

    [ "${SPACE_CHECK}" = Y ] || return 0

    avail=$(df -Pk "${OUT_DIR}" 2>/dev/null | awk 'NR == 2 {print $4 * 1024}')
    [ -n "${avail}" ] || return 0
    info "free space in ${OUT_DIR}: $(human ${avail})"
    if [ $((need * 5)) -gt $((avail * 4)) ]; then
        info "WARNING: the estimate uses more than 80% of the free space in ${OUT_DIR}"
        if [ "${FORCE}" != Y ]; then
            info "refusing to start; use a different --out-dir, a longer"
            info "--perf-interval, a shorter --duration, or --force"
            return 1
        fi
        info "--force given, starting anyway"
    fi
    return 0
}

#
# Data quality
#
# A 24h collection happens once; the run has to say by itself whether
# the data is usable, not leave it to be discovered at analysis time.
#
pi_get() {
    sed -n "s/^$1: //p" "${RUN_DIR}/meta/probe-info" 2>/dev/null | head -1
}

expected_interval() {
    case "$1" in
        perf-*)          pi_get perf-interval ;;
        objecter-*)      pi_get objecter-interval ;;
        session-*)       pi_get session-interval ;;
        cache-*)         pi_get cache-interval ;;
        histops-*)       pi_get histops-interval ;;
        loads-*|mempools-*) pi_get loads-interval ;;
        fs-perf-stats*)  pi_get fs-perf-interval ;;
        fs-status*)      pi_get fs-status-interval ;;
        health*)         pi_get health-interval ;;
        osd-*)           pi_get osd-interval ;;
        *)               echo 0 ;;
    esac
}

quality_report() {
    local f base tot err snap interval elapsed want covered bad=0
    local start end

    start=$(pi_get start)
    end=$(pi_get end)
    [ -n "${end}" ] || end=$(now_iso)
    elapsed=$(( $(date -d "${end}" +%s 2>/dev/null || echo 0) -
                $(date -d "${start}" +%s 2>/dev/null || echo 0) ))
    [ "${elapsed}" -gt 0 ] 2>/dev/null || elapsed=0

    echo "data quality of $(basename "${RUN_DIR}")"
    echo "window: ${start} .. ${end} (${elapsed}s)"
    echo
    printf '%-44s %9s %9s %9s\n' stream records errors expected

    for f in "${RUN_DIR}"/*.jsonl; do
        [ -e "${f}" ] || continue
        base=$(basename "${f}")
        tot=$(wc -l < "${f}")
        err=$(grep -c '"rc":' "${f}")
        interval=$(expected_interval "${base}")
        want=""
        if [ -n "${interval}" ] && [ "${interval}" -gt 0 ] 2>/dev/null &&
           [ "${tot}" -gt 1 ]; then
            # measure against the window the stream itself covers, not
            # against the whole run: a rank that only became active
            # halfway through is not missing the first half
            covered=$(( $(tail -1 "${f}" | jq -r '.t // 0') -
                        $(head -1 "${f}" | jq -r '.t // 0') ))
            [ "${covered}" -gt 0 ] 2>/dev/null || covered=0
            want=$((covered / interval + 1))
        fi
        printf '%-44s %9s %9s %9s%s\n' "${base}" "${tot}" "${err}" "${want:--}" \
               "$([ "${err}" -gt 0 ] && echo '  <-- CHECK')"
        [ "${err}" -gt 0 ] && bad=1
        # less than half the expected samples means a stream was
        # starved, e.g. by a hung tell running into --tell-timeout
        if [ -n "${want}" ] && [ "${want}" -gt 4 ] &&
           [ $((tot * 2)) -lt "${want}" ]; then
            echo "    WARNING: ${base} has less than half the expected samples"
            bad=1
        fi
    done

    for f in "${RUN_DIR}"/*.log; do
        [ -e "${f}" ] || continue
        base=$(basename "${f}")
        snap=$(grep -c '^===' "${f}" 2>/dev/null)
        if [ "${snap}" -gt 0 ]; then
            printf '%-44s %9s %9s %9s\n' "${base}" "${snap}" "-" "-"
        else
            printf '%-44s %9s %9s %9s\n' "${base}" "$(wc -l < "${f}")" "-" "-"
        fi
    done

    if [ -s "${RUN_DIR}/meta/errors.log" ]; then
        echo
        echo "metadata collection errors (meta/errors.log):"
        head -5 "${RUN_DIR}/meta/errors.log" | sed 's/^/    /'
        bad=1
    fi
    if [ -s "${RUN_DIR}/meta/mds-changes.log" ]; then
        echo
        echo "mds set changes during the run (meta/mds-changes.log):"
        cat "${RUN_DIR}/meta/mds-changes.log" | sed 's/^/    /'
    fi

    echo
    if [ ${bad} -eq 0 ]; then
        echo "all streams clean"
    else
        echo "WARNING: some streams have error records or are short of samples."
        echo "inspect them with:"
        echo "  jq -r 'select(.rc) | .error' <file>.jsonl | sort | uniq -c | sort -rn | head"
    fi
    return ${bad}
}

#
# Packaging
#
archive_result() {
    local result_archive gz base parent

    if ! command -v tar > /dev/null 2>&1; then
        info "no tar found, keeping results in the directory only"
        return 1
    fi

    base=$(basename "${RUN_DIR}")
    parent=$(dirname "${RUN_DIR}")
    result_archive="${RUN_DIR}.tar.gz"

    info "archiving ${RUN_DIR} ..."

    # manifest so the analyst can verify the transfer is complete
    {
        echo "# ceph_mds_probe manifest"
        echo "# run: ${base}"
        echo "# packed: $(now_iso) on $(hostname -f 2>/dev/null || hostname)"
        echo "# columns: sha256  bytes  path"
        (
            cd "${RUN_DIR}" &&
            find . -type f ! -name MANIFEST.txt ! -path './run/running' |
            sort |
            while read -r f; do
                printf '%s  %s  %s\n' \
                       "$(sha256sum "${f}" | cut -d' ' -f1)" \
                       "$(stat -c %s "${f}")" "${f#./}"
            done
        )
    } > "${RUN_DIR}/MANIFEST.txt"

    gz=gzip
    command -v pigz > /dev/null 2>&1 && gz="pigz -p 4"

    if tar -C "${parent}" --exclude="${base}/run/running" \
           --exclude="${base}/run/tmp" -cf - "${base}" |
       ${gz} -6 > "${result_archive}.tmp"; then
        mv -f "${result_archive}.tmp" "${result_archive}"
        (cd "${parent}" && sha256sum "$(basename "${result_archive}")" \
            > "$(basename "${result_archive}").sha256")
        info "archive: ${result_archive} ($(human $(stat -c %s "${result_archive}")))"
        info "checksum: ${result_archive}.sha256"
    else
        rm -f "${result_archive}.tmp"
        info "ERROR: packing failed; the run directory is still complete: ${RUN_DIR}"
        return 1
    fi
    return 0
}

#
# --stop / --status / --pack
#
resolve_run_dir() {
    if [ -n "${RUN_DIR}" ]; then
        :
    elif [ -e "${OUT_DIR}/mds-probe-current" ]; then
        RUN_DIR=$(readlink -f "${OUT_DIR}/mds-probe-current")
    else
        info "no probe run found under ${OUT_DIR}; pass --run-dir"
        return 1
    fi
    if [ ! -d "${RUN_DIR}/meta" ]; then
        info "not a probe run directory: ${RUN_DIR}"
        return 1
    fi
    return 0
}

cmd_stop() {
    resolve_run_dir || return 1
    if [ ! -f "${RUN_DIR}/run/running" ]; then
        info "probe in ${RUN_DIR} is not running"
        return 0
    fi
    rm -f "${RUN_DIR}/run/running"
    info "stop requested; pid $(cat "${RUN_DIR}/run/probe.pid" 2>/dev/null)" \
         "will finish the calls in flight and pack up"
    return 0
}

cmd_status() {
    resolve_run_dir || return 1
    echo "run directory: ${RUN_DIR}"
    cat "${RUN_DIR}/meta/probe-info"
    if [ -f "${RUN_DIR}/run/running" ]; then
        echo "state: RUNNING (pid $(cat "${RUN_DIR}/run/probe.pid" 2>/dev/null))"
    else
        echo "state: STOPPED"
    fi
    echo "size: $(du -sh "${RUN_DIR}" 2>/dev/null | cut -f1)"
    echo "sampled mds: $(tr '\n' ' ' < "${RUN_DIR}/meta/active-mdss" 2>/dev/null)"
    echo
    quality_report
    return 0
}

cmd_pack() {
    resolve_run_dir || return 1
    if [ -f "${RUN_DIR}/run/running" ]; then
        info "WARNING: the probe is still running, the archive is a snapshot"
    fi
    archive_result
    return 0
}

#
# Run
#
workers_alive() {
    local p

    for p in ${WORKER_PIDS}; do
        kill -0 "${p}" 2>/dev/null && return 0
    done
    return 1
}

kill_workers() {
    local p f

    for f in "${RUN_DIR}"/run/*.bgpid; do
        [ -e "${f}" ] || continue
        kill -TERM "$(cat "${f}" 2>/dev/null)" 2>/dev/null
    done
    for p in ${WORKER_PIDS}; do
        kill -TERM "${p}" 2>/dev/null
    done
    command -v pkill > /dev/null 2>&1 && pkill -TERM -P $$ 2>/dev/null
    sleep 2
    for p in ${WORKER_PIDS}; do
        kill -KILL "${p}" 2>/dev/null
    done
    return 0
}

run_probe() {
    local start i

    info "sampling $(current_mdss | tr '\n' ' ')for ${DURATION} sec (0 = until stopped)"
    info "run directory: ${RUN_DIR}"
    info "stop it with: $0 --stop -o ${OUT_DIR}"

    start=$(date +%s)

    start_worker worker_perf
    start_worker worker_fs_perf
    start_worker worker_discovery
    [ "${CACHE_INTERVAL}"     -gt 0 ] && start_worker worker_cache
    [ "${OBJECTER_INTERVAL}"  -gt 0 ] && start_worker worker_objecter
    [ "${SESSION_INTERVAL}"   -gt 0 ] && start_worker worker_session
    [ "${HISTOPS_INTERVAL}"   -gt 0 ] && start_worker worker_histops
    [ "${LOADS_INTERVAL}"     -gt 0 ] && start_worker worker_loads
    [ "${HEALTH_INTERVAL}"    -gt 0 ] && start_worker worker_health
    [ "${FS_STATUS_INTERVAL}" -gt 0 ] && start_worker worker_fs_status
    [ "${OSD_LIMIT}" -gt 0 ]          && start_worker worker_osd
    [ "${USE_SSH}" = Y ]              && start_worker worker_remote

    while running; do
        sleep 1
        if [ "${DURATION}" -gt 0 ] &&
           [ $(($(date +%s) - start)) -ge "${DURATION}" ]; then
            rm -f "${RUN_DIR}/run/running"
        fi
    done

    info "stopping; waiting for the samplers to finish the calls in flight ..."
    i=0
    while [ ${i} -lt $((TELL_TIMEOUT + 10)) ] && workers_alive; do
        sleep 1
        i=$((i + 1))
    done
    kill_workers
    return 0
}

restore_stats() {
    if [ "${STATS_WAS_DISABLED}" = Y ]; then
        info "restoring mgr stats module state ..."
        if ! meta_run /dev/null ${CEPH} mgr module disable stats; then
            info "WARNING: failed to restore mgr stats module state"
        fi
        STATS_WAS_DISABLED=N
    fi
    return 0
}

#
# Main
#

OPTIONS=$(getopt -o c:d:f:hi:o:s:t:T:vV --long archive,cache-interval:,ceph-config-file:,daemonperf,discovery-interval:,duration:,enable-stats-module,force,fs:,fs-perf-interval:,fs-status-interval:,health-interval:,help,histops-interval:,loads-interval:,max-parallel:,no-space-check,objecter-interval:,osd-interval:,osd-limit:,out-dir:,pack,perf-interval:,plain-ssh,run-dir:,session-interval:,skip-histops,skip-sessions,ssh,status,stop,tag:,tell-timeout:,timeout:,verbose,version -- "$@")
if [ $? -ne 0 ]; then
    usage >&2
    exit 1
fi

eval set -- "$OPTIONS"
while true; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -c|--ceph-config-file)
            CEPH_CONFIG_FILE="$2"
            shift 2
            ;;
        -t|--timeout)
            CEPH_TIMEOUT="$2"
            shift 2
            ;;
        -T|--tell-timeout)
            TELL_TIMEOUT="$2"
            shift 2
            ;;
        -d|--duration)
            DURATION="$2"
            shift 2
            ;;
        -i|--perf-interval)
            PERF_INTERVAL="$2"
            shift 2
            ;;
        --fs-perf-interval)
            FS_PERF_INTERVAL="$2"
            shift 2
            ;;
        --fs-status-interval)
            FS_STATUS_INTERVAL="$2"
            shift 2
            ;;
        --cache-interval)
            CACHE_INTERVAL="$2"
            shift 2
            ;;
        --objecter-interval)
            OBJECTER_INTERVAL="$2"
            shift 2
            ;;
        -s|--session-interval)
            SESSION_INTERVAL="$2"
            shift 2
            ;;
        --skip-sessions)
            SESSION_INTERVAL=0
            shift
            ;;
        --histops-interval)
            HISTOPS_INTERVAL="$2"
            shift 2
            ;;
        --skip-histops)
            HISTOPS_INTERVAL=0
            shift
            ;;
        --loads-interval)
            LOADS_INTERVAL="$2"
            shift 2
            ;;
        --health-interval)
            HEALTH_INTERVAL="$2"
            shift 2
            ;;
        --osd-limit)
            OSD_LIMIT="$2"
            shift 2
            ;;
        --osd-interval)
            OSD_INTERVAL="$2"
            shift 2
            ;;
        --discovery-interval)
            DISCOVERY_INTERVAL="$2"
            shift 2
            ;;
        --max-parallel)
            MAX_PARALLEL="$2"
            shift 2
            ;;
        -f|--fs)
            FS="$2"
            shift 2
            ;;
        -o|--out-dir)
            OUT_DIR="$2"
            shift 2
            ;;
        --tag)
            TAG="$2"
            shift 2
            ;;
        --ssh)
            USE_SSH=Y
            shift
            ;;
        --daemonperf)
            DO_DAEMONPERF=Y
            USE_SSH=Y
            shift
            ;;
        --plain-ssh)
            PLAIN_SSH=Y
            shift
            ;;
        --archive)
            ARCHIVE=Y
            shift
            ;;
        --enable-stats-module)
            ENABLE_STATS_MODULE=Y
            shift
            ;;
        --no-space-check)
            SPACE_CHECK=N
            shift
            ;;
        --force)
            FORCE=Y
            shift
            ;;
        --stop)
            ACTION=stop
            shift
            ;;
        --status)
            ACTION=status
            shift
            ;;
        --pack)
            ACTION=pack
            shift
            ;;
        --run-dir)
            RUN_DIR="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=Y
            shift
            ;;
        -V|--version)
            version
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Invalid option: $1" >&1
            usage >&2
            exit 1
            ;;
    esac
done

if ! [ "${CEPH_TIMEOUT}" -gt 0 ]; then
    echo "Invalid ceph timeout: ${CEPH_TIMEOUT}" >&1
    usage >&2
    exit 1
fi

if [ "${VERBOSE}" = Y ]; then
    set -x
fi

# check `jq` is available
if ! command -v jq > /dev/null 2>&1; then
    echo "jq command not found, please install jq package" >&2
    exit 1
fi

case "${ACTION}" in
    stop)   cmd_stop;   exit $? ;;
    status) cmd_status; exit $? ;;
    pack)   cmd_pack;   exit $? ;;
esac

CEPH="${CEPH} --conf=${CEPH_CONFIG_FILE} --connect-timeout=${CEPH_TIMEOUT}"

# use timeout(1) when running cli commands if it is available. The tell
# wrapper has to be built from the bare command: wrapping the already
# wrapped ${CEPH} would leave the shorter inner timeout in charge and
# --tell-timeout would have no effect at all.
CEPH_TELL="${CEPH}"
if command -v timeout > /dev/null 2>&1; then
    # use verbose option if it is available
    verbose_opt=
    if timeout -v 10 true /dev/null 2>&1; then
        verbose_opt=-v
    fi
    CEPH_TELL="timeout ${verbose_opt} ${TELL_TIMEOUT} ${CEPH}"
    CEPH="timeout ${verbose_opt} $((CEPH_TIMEOUT * 2)) ${CEPH}"
fi

AWK_HAS_STRFTIME=N
awk 'BEGIN { exit (strftime("%Y") == "") }' > /dev/null 2>&1 &&
    AWK_HAS_STRFTIME=Y

FSID=$(${CEPH} fsid 2>/dev/null | tr -d '[:space:]')

MDSS=$(get_active_mdss)
if [ -z "${MDSS}" ]; then
    if [ -n "${FS}" ]; then
        info "no active MDS found for filesystem ${FS}"
    else
        info "no active MDS found"
    fi
    exit 1
fi
info "active MDS: $(echo ${MDSS} | tr '\n' ' ')"

TAG=$(printf '%s' "${TAG}" | sed 's/[^a-zA-Z0-9_.-]/_/g')
RUN_DIR=$(mktemp -d "${OUT_DIR}/mds-probe_${TAG}_$(date +%Y%m%d_%H%M%S)_XXXXXX")
if [ $? -ne 0 ] || [ -z "${RUN_DIR}" ]; then
    info "cannot create run directory under ${OUT_DIR}"
    exit 1
fi
mkdir -p "${RUN_DIR}/meta" "${RUN_DIR}/run/tmp"
touch "${RUN_DIR}/meta/errors.log"
echo $$ > "${RUN_DIR}/run/probe.pid"
touch "${RUN_DIR}/run/running"
CURRENT_LINK="${OUT_DIR}/mds-probe-current"
ln -sfn "${RUN_DIR}" "${CURRENT_LINK}" 2>/dev/null

# --stop and Ctrl-C both go through the flag file, so a sampler is never
# killed in the middle of a `ceph tell`
trap 'info "stop requested"; rm -f "${RUN_DIR}/run/running"' INT TERM

META_READY=N
note_mdss "${MDSS}"

STATS_WAS_DISABLED=N
if ${CEPH} mgr module ls -f json 2>/dev/null |
   jq -e '.enabled_modules | index("stats")' > /dev/null 2>&1; then
    :
elif [ "${ENABLE_STATS_MODULE}" = Y ]; then
    info "mgr stats module is not enabled, enabling it ..."
    if meta_run /dev/null ${CEPH} mgr module enable stats; then
        info "mgr stats module enabled (will be restored on exit)"
        STATS_WAS_DISABLED=Y
        # the mgr reloads its modules; commands it serves (fs perf
        # stats, pg ls-by-pool) are unreliable until it has settled
        sleep 5
    else
        info "WARNING: failed to enable mgr stats module, fs perf stats will fail"
    fi
else
    info "WARNING: mgr stats module is not enabled, fs perf stats will fail"
    info "enable it with: ceph mgr module enable stats"
fi

if [ "${USE_SSH}" = Y ]; then
    setup_ssh
fi

if [ "${OSD_LIMIT}" -gt 0 ]; then
    get_fs_list > "${RUN_DIR}/run/fs-list"
    get_metadata_osds > "${RUN_DIR}/run/osd-list" 2>/dev/null
    if [ -s "${RUN_DIR}/run/osd-list" ]; then
        info "metadata pool osds: $(tr '\n' ' ' < "${RUN_DIR}/run/osd-list")"
    fi
else
    get_fs_list > "${RUN_DIR}/run/fs-list"
fi

collect_meta
META_READY=Y

if ! estimate_volume; then
    rm -f "${CURRENT_LINK}"
    rm -rf "${RUN_DIR}"
    exit 1
fi

run_probe

collect_meta_final
cleanup_ssh
restore_stats
rm -rf "${RUN_DIR}/run/tmp"

quality_report | tee "${RUN_DIR}/meta/quality-report.txt"
QUALITY_RC=$?

info "done"
info "result: ${RUN_DIR}"
if [ "${ARCHIVE}" = Y ]; then
    archive_result
fi

exit 0
