#!/bin/sh

#
# Collect Ceph cluster info
#

CENSORED="${CENSORED:-<CENSORED>}"
CEPH="${CEPH:-ceph}"
CEPH_CONFIG_FILE="${CEPH_CONFIG_FILE:-/etc/ceph/ceph.conf}"
CEPH_TIMEOUT="${CEPH_TIMEOUT:-10}"
QUERY_INACTIVE_PG="${QUERY_INACTIVE_PG:-N}"
RADOSGW_ADMIN="${RADOSGW_ADMIN:-radosgw-admin}"
VERBOSE="${VERBOSE:-N}"
COLLECT_OSD_ASOK_STATS="${COLLECT_OSD_ASOK_STATS:-N}"

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
    echo "  -q | --query-inactive-pg        query inactive pg"
    echo "  -r | --results-dir <dir>        directory to store result"
    echo "  -t | --timeout <seconds>        timeout for ceph operations"
    echo "  -u | --uncensored               don't hide sensitive data"
    echo "  -v | --verbose                  be verbose"
    echo "  -o | --osd-asok-stats           collect osd stats via admin socket (tell)"
    echo
}

cleanup() {
    rm -Rf ${RESULTS_DIR}
}

info() {
    echo "$*" >&2
}

censor_config() {
    if [ -z "${CENSORED}" ]; then
	"$@"
	return
    fi

    "$@" | sed "s/\(ACCESS_KEY\|SECRET_KEY\|PASSWORD\)\(\s*\).*/\1\2${CENSORED}/gi"
}

censor_auth() {
    if [ -z "${CENSORED}" ]; then
	"$@"
	return
    fi

    "$@" | sed "s/\(key:\)\(\s*\).*/\1\2${CENSORED}/g"
}

store() {
    local name="$1"; shift

    "$@" > "${RESULTS_DIR}/${name}" 2> "${RESULTS_DIR}/${name}".log
}

show_stored() {
    local name="$1"

    cat "${RESULTS_DIR}/${name}"
}

get_system_info() {
    local t=system_info

    info "collecting system info ..."

    store ${t}-uname       uname -a
    store ${t}-lsb_release lsb_release -a
}

get_ceph_info() {
    local t=ceph_cluster_info

    info "collecting ceph cluster info ..."

    store ${t}-status      ${CEPH} status
    store ${t}-version     ${CEPH} version
    store ${t}-versions    ${CEPH} versions
    store ${t}-fsid        ${CEPH} fsid
    store ${t}-ceph_conf   cat ${CEPH_CONFIG_FILE}
    store ${t}-config_dump censor_config ${CEPH} config dump
    store ${t}-config_log  censor_config ${CEPH} config log
    store ${t}-auth_list   censor_auth ${CEPH} auth list
}

get_health_info() {
    local t=cluster_health
    local id

    info "collecting cluster health info ..."

    store ${t}-stat            ${CEPH} health
    store ${t}-detail          ${CEPH} health detail
    store ${t}-df              ${CEPH} df
    store ${t}-df-detail       ${CEPH} df detail
    store ${t}-report          ${CEPH} report
    store ${t}-crash_ls        ${CEPH} crash ls
    store ${t}-balancer-status ${CEPH} balancer status

    show_stored ${t}-crash_ls | grep -o '^[0-9][^ ]*' |
    while read id; do
        store ${t}-crash_info_${id} ${CEPH} crash info ${id}
    done
}

get_monitor_info() {
    local t=monitor_info

    info "collecting monitor info ..."

    store ${t}-stat     ${CEPH} mon stat
    store ${t}-dump     ${CEPH} mon dump
    store ${t}-map      ${CEPH} mon getmap
    store ${t}-metadata ${CEPH} mon metadata

    show_stored ${t}-dump |
    sed -nEe 's/^.* (mon\..*)$/\1/p' |
    while read mon; do
        store ${t}-${mon}-config_diff            ${CEPH} tell ${mon} config diff
        store ${t}-${mon}-config_show            ${CEPH} tell ${mon} config show
        store ${t}-${mon}-dump_historic_ops      ${CEPH} tell ${mon} dump_historic_ops
        store ${t}-${mon}-dump_historic_slow_ops ${CEPH} tell ${mon} dump_historic_slow_ops
        store ${t}-${mon}-dump_mempools          ${CEPH} tell ${mon} dump_mempools
        store ${t}-${mon}-mon_status             ${CEPH} tell ${mon} mon_status
        store ${t}-${mon}-ops                    ${CEPH} tell ${mon} ops
        store ${t}-${mon}-perf_dump              ${CEPH} tell ${mon} perf dump
        store ${t}-${mon}-sessions               ${CEPH} tell ${mon} sessions
    done
}

get_device_info() {
    local t=device_info

    info "collecting device info ..."

    store ${t}-ls ${CEPH} device ls
}

get_manager_info() {
    local t=manager_info

    info "collecting manager info ..."

    store ${t}-ls-modules ${CEPH} mgr module ls
    store ${t}-dump       ${CEPH} mgr dump
    store ${t}-metadata   ${CEPH} mgr metadata

    show_stored ${t}-dump |
    sed -nEe 's/^.*"active_name": "([^"]*)".*$/mgr.\1/p' |
    while read mgr; do
        store ${t}-${mgr}-mds_requests  ${CEPH} tell ${mgr} mds_requests
        store ${t}-${mgr}-config_diff   ${CEPH} tell ${mgr} config diff
        store ${t}-${mgr}-config_show   ${CEPH} tell ${mgr} config show
        store ${t}-${mgr}-dump_cache    ${CEPH} tell ${mgr} dump_cache
        store ${t}-${mgr}-dump_mempools ${CEPH} tell ${mgr} dump_mempools
        store ${t}-${mgr}-mgr_status    ${CEPH} tell ${mgr} mgr_status
        store ${t}-${mgr}-perf_dump     ${CEPH} tell ${mgr} perf dump
        store ${t}-${mgr}-status        ${CEPH} tell ${mgr} status
    done
}

get_osd_info() {
    local t=osd_info

    info "collecting osd info ..."

    store ${t}-tree      ${CEPH} osd tree
    store ${t}-tree_json ${CEPH} osd tree --format json
    store ${t}-df        ${CEPH} osd df
    store ${t}-df-tree   ${CEPH} osd df tree
    store ${t}-dump      ${CEPH} osd dump
    store ${t}-stat      ${CEPH} osd stat
    store ${t}-crushmap  ${CEPH} osd getcrushmap
    store ${t}-map       ${CEPH} osd getmap
    store ${t}-metadata  ${CEPH} osd metadata
    store ${t}-perf      ${CEPH} osd perf

    show_stored ${t}-crushmap | store ${t}-crushmap.txt crushtool -d -

    if [ "${COLLECT_OSD_ASOK_STATS}" = Y ]; then
	show_stored ${t}-dump |
        sed -nEe 's/^(osd\.[0-9*]) .*$/\1/p' |
        while read osd; do
            store ${t}-${osd}-cache_status            ${CEPH} tell ${osd} cache status
            store ${t}-${osd}-config_diff             ${CEPH} tell ${osd} config diff
            store ${t}-${osd}-config_show             ${CEPH} tell ${osd} config show
            store ${t}-${osd}-dump_historic_ops       ${CEPH} tell ${osd} dump_historic_ops
            store ${t}-${osd}-dump_historic_slow_ops  ${CEPH} tell ${osd} dump_historic_slow_ops
            store ${t}-${osd}-dump_mempools           ${CEPH} tell ${osd} dump_mempools
            store ${t}-${osd}-dump_ops_in_flight      ${CEPH} tell ${osd} dump_ops_in_flight
            store ${t}-${osd}-dump_osd_network        ${CEPH} tell ${osd} dump_osd_network
            store ${t}-${osd}-dump_scrub_reservations ${CEPH} tell ${osd} dump_scrub_reservations
            store ${t}-${osd}-dump_scrubs             ${CEPH} tell ${osd} dump_scrubs
            store ${t}-${osd}-perf_dump               ${CEPH} tell ${osd} perf dump
            store ${t}-${osd}-status                  ${CEPH} tell ${osd} status
        done
    fi
}

get_pg_info() {
    local t=pg_info
    local pgid

    info "collecting pg info ..."

    store ${t}-stat       ${CEPH} pg stat
    store ${t}-dump       ${CEPH} pg dump
    store ${t}-dump_stuck ${CEPH} pg dump_stuck
    store ${t}-dump_json  ${CEPH} pg dump --format json

    if [ "$QUERY_INACTIVE_PG" = Y ]; then
	store ${t}-dump_stuck_inactive ${CEPH} pg dump_stuck inactive
	show_stored ${t}-dump_stuck_inactive | grep -o '^[0-9][^ ]*' |
        while read pgid; do
            store ${t}-query-${pgid} ${CEPH} pg ${pgid} query
        done
    fi
}

get_mds_info() {
    local t=mds_info

    info "collecting mds info ..."

    store ${t}-stat ${CEPH} mds stat
    store ${t}-metadata ${CEPH} mds metadata
}

get_fs_info() {
    local t=fs_info
    local mds

    info "collecting fs info ..."

    store ${t}-ls     ${CEPH} fs ls
    store ${t}-status ${CEPH} fs status
    store ${t}-dump   ${CEPH} fs dump

    show_stored ${t}-dump |
    sed -nEe 's/^\[(mds\.[^{]*).*state up:active.*/\1/p' |
    while read mds; do
        store ${t}-${mds}-cache_status       ${CEPH} tell ${mds} cache status
        store ${t}-${mds}-dump_historic_ops  ${CEPH} tell ${mds} dump_historic_ops
        store ${t}-${mds}-dump_loads         ${CEPH} tell ${mds} dump loads
        store ${t}-${mds}-dump_mempools      ${CEPH} tell ${mds} dump_mempools
        store ${t}-${mds}-dump_ops_in_flight ${CEPH} tell ${mds} dump_ops_in_flight
        store ${t}-${mds}-perf_dump          ${CEPH} tell ${mds} perf dump
        store ${t}-${mds}-scrub_status       ${CEPH} tell ${mds} scrub status
        store ${t}-${mds}-session_ls         ${CEPH} tell ${mds} session ls
        store ${t}-${mds}-status             ${CEPH} tell ${mds} status
        store ${t}-${mds}-config_diff        ${CEPH} tell ${mds} config diff
        store ${t}-${mds}-config_show        ${CEPH} tell ${mds} config show
        store ${t}-${mds}-damage_ls          ${CEPH} tell ${mds} damage ls
        store ${t}-${mds}-dump_blocked_ops   ${CEPH} tell ${mds} dump_blocked_ops
    done
}

get_radosgw_admin_info() {
    local t=radosgw_admin_info

    if ! ${CEPH} osd dump | grep -q '^pool .* application rgw'; then
	return
    fi

    root_pool=$(${CEPH} config get client.admin rgw_realm_root_pool)
    if [ -z "${root_pool}" ]; then
	return
    fi
    if ! ${CEPH} osd pool ls | fgrep -q "${root_pool}"; then
	return
    fi

    info "collecting radosgw info ..."

    store ${t}-bucket_stats                  ${RADOSGW_ADMIN} bucket stats
    store ${t}-bucket_limit_check            ${RADOSGW_ADMIN} bucket limit check
    store ${t}-metadata_list_bucket.instance ${RADOSGW_ADMIN} metadata list bucket.instance
    store ${t}-period_get                    ${RADOSGW_ADMIN} period get
    store ${t}-sync_status                   ${RADOSGW_ADMIN} sync status
}

get_orch_info() {
    local t=orch_info

    info "collecting orchestrator info ..."

    store ${t}-status  ${CEPH} orch status
    store ${t}-ls      ${CEPH} orch ls
    store ${t}-ls_yaml ${CEPH} orch ls --format yaml
    store ${t}-ps      ${CEPH} orch ps
}

archive_result() {
    info "archiving ${RESULTS_DIR} ..."

    tar -czf ${RESULT_ARCHIVE} -C $(dirname ${RESULTS_DIR}) $(basename ${RESULTS_DIR})

    info "done"
    info "result: ${RESULT_ARCHIVE}"
}

#
# Main
#

OPTIONS=$(getopt -o hc:oqr:t:uv --long help,ceph-config-file:,osd-asok-stats,query-inactive-pg,results-dir:,timeout:,uncensored,verbose -- "$@")
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
	-o|--osd-asok-stats)
	    COLLECT_OSD_ASOK_STATS=Y
	    shift
	    ;;
	-q|--query-inactive-pg)
	    QUERY_INACTIVE_PG=Y
	    shift
	    ;;
	-r|--results-dir)
	    RESULTS_DIR="$2"
	    shift 2
	    ;;
	-t|--timeout)
	    CEPH_TIMEOUT="$2"
	    shift 2
	    ;;
	-u|--uncensored)
	    CENSORED=
	    shift
	    ;;
	-v|--verbose)
	    VERBOSE=Y
	    shift
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

CEPH="${CEPH} --conf=${CEPH_CONFIG_FILE} --connect-timeout=${CEPH_TIMEOUT}"
RADOSGW_ADMIN="${RADOSGW_ADMIN} --conf=${CEPH_CONFIG_FILE}"

# use timeout(1) when running cli commands if it is available
if `which timeout > /dev/null 2>&1`; then
    # use verbose option if it is available
    verbose_opt=
    if `timeout -v 10 true /dev/null 2>&1`; then
	verbose_opt=-v
    fi
    CEPH="timeout ${verbose_opt} $((CEPH_TIMEOUT * 2)) ${CEPH}"
    RADOSGW_ADMIN="timeout ${verbose_opt} $((CEPH_TIMEOUT * 2)) ${RADOSGW_ADMIN}"
fi

if [ -n "${RESULTS_DIR}" ]; then
    mkdir -p "${RESULTS_DIR}"
else
    RESULTS_DIR=$(mktemp -d /tmp/ceph-collect_$(date +%Y%m%d_%H%I%S)-XXX)
fi
RESULT_ARCHIVE=${RESULTS_DIR}.tar.gz

trap cleanup INT TERM EXIT

get_system_info
get_ceph_info
get_health_info
get_monitor_info
get_device_info
get_manager_info
get_osd_info
get_pg_info
get_mds_info
get_fs_info
get_radosgw_admin_info
get_orch_info

archive_result
