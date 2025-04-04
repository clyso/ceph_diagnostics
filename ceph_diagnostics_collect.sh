#!/bin/sh

#
# Collect Ceph cluster info
#

CENSORED="${CENSORED:-CENSORED}"
CEPH="${CEPH:-ceph}"
CEPH_CONFIG_FILE="${CEPH_CONFIG_FILE:-/etc/ceph/ceph.conf}"
CEPH_TIMEOUT="${CEPH_TIMEOUT:-10}"
QUERY_INACTIVE_PG="${QUERY_INACTIVE_PG:-N}"
RADOSGW_ADMIN="${RADOSGW_ADMIN:-radosgw-admin}"
VERBOSE="${VERBOSE:-N}"
COLLECT_ALL_OSD_ASOK_STATS="${COLLECT_ALL_OSD_ASOK_STATS:-N}"
RESET_MDS_PERF_AND_SLEEP="${RESET_MDS_PERF_AND_SLEEP:-0}"
RESET_MGR_PERF_AND_SLEEP="${RESET_MGR_PERF_AND_SLEEP:-0}"
RESET_MON_PERF_AND_SLEEP="${RESET_MON_PERF_AND_SLEEP:-0}"
RESET_OSD_PERF_AND_SLEEP="${RESET_OSD_PERF_AND_SLEEP:-0}"

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
    echo "  -h | --help                            print this help and exit"
    echo "  -c | --ceph-config-file <file>         ceph configuration file"
    echo "  -q | --query-inactive-pg               query inactive pg"
    echo "  -r | --results-dir <dir>               directory to store result"
    echo "  -t | --timeout <seconds>               timeout for ceph operations"
    echo "  -u | --uncensored                      don't hide sensitive data"
    echo "  -v | --verbose                         be verbose"
    echo "  -a | --all-osd-asok-stats              get data via admin socket (tell)"
    echo "                                         for all osds"
    echo "  -D | --mds-perf-reset-and-sleep <sec>  reset mds perf counters and sleep"
    echo "  -G | --mgr-perf-reset-and-sleep <sec>  reset mgr perf counters and sleep"
    echo "  -M | --mon-perf-reset-and-sleep <sec>  reset mon perf counters and sleep"
    echo "  -O | --osd-perf-reset-and-sleep <sec>  reset osd perf counters and sleep"
    echo
}

cleanup() {
    test -n "${RESULTS_DIR}" && rm -Rf "${RESULTS_DIR}"
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
    local log_name="${name}.log"  # Default log filename

    if echo "$name" | grep -qE "\.json$"; then
        log_name="${name%.json}-json.log"
    fi

    "$@" > "${RESULTS_DIR}/${name}" 2> "${RESULTS_DIR}/${log_name}"
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

    store ${t}-status.json          ${CEPH} status -f json
    store ${t}-versions.json        ${CEPH} versions -f json
    store ${t}-config_dump.json     censor_config ${CEPH} config dump -f json
    store ${t}-config_log.json      censor_config ${CEPH} config log -f json
    store ${t}-auth_list.json       censor_auth ${CEPH} auth list -f json
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

    store ${t}-detail.json          ${CEPH} health detail -f json
    store ${t}-df-detail.json       ${CEPH} df detail -f json
    store ${t}-report.json          ${CEPH} report -f json
    store ${t}-crash_ls.json        ${CEPH} crash ls -f json
    store ${t}-balancer-status.json ${CEPH} balancer status -f json

    show_stored ${t}-crash_ls | grep -o '^[0-9][^ ]*' |
    while read id; do
        store ${t}-crash_info_${id} ${CEPH} crash info ${id} 
        store ${t}-crash_info_${id}.json ${CEPH} crash info ${id} -f json
    done
}

get_monitor_info() {
    local t=monitor_info

    info "collecting monitor info ..."

    store ${t}-stat     ${CEPH} mon stat
    store ${t}-dump     ${CEPH} mon dump
    store ${t}-map      ${CEPH} mon getmap
    store ${t}-metadata ${CEPH} mon metadata

    store ${t}-stat.json    ${CEPH} mon stat -f json
    store ${t}-dump.json    ${CEPH} mon dump -f json
    store ${t}-metadata.json ${CEPH} mon metadata -f json

    if [ "${RESET_MON_PERF_AND_SLEEP}" -gt 0 ]; then
	store ${t}-perf_reset ${CEPH} tell mon.\* perf reset all
	info "sleeping for ${RESET_MON_PERF_AND_SLEEP} sec after reseting mon perf counters ..."
	sleep ${RESET_MON_PERF_AND_SLEEP}
    fi

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

        store ${t}-${mon}-config_diff.json            ${CEPH} tell ${mon} config diff -f json
        store ${t}-${mon}-config_show.json            ${CEPH} tell ${mon} config show -f json
        store ${t}-${mon}-dump_historic_ops.json      ${CEPH} tell ${mon} dump_historic_ops -f json
        store ${t}-${mon}-dump_historic_slow_ops.json ${CEPH} tell ${mon} dump_historic_slow_ops -f json
        store ${t}-${mon}-dump_mempools.json          ${CEPH} tell ${mon} dump_mempools -f json
        store ${t}-${mon}-mon_status.json             ${CEPH} tell ${mon} mon_status -f json
        store ${t}-${mon}-ops.json                    ${CEPH} tell ${mon} ops -f json
        store ${t}-${mon}-perf_dump.json              ${CEPH} tell ${mon} perf dump -f json
        store ${t}-${mon}-sessions.json               ${CEPH} tell ${mon} sessions -f json
    done
}

get_device_info() {
    local t=device_info

    info "collecting device info ..."

    store ${t}-ls      ${CEPH} device ls
    store ${t}-ls_json ${CEPH} device ls --format json # TODO: update the extension
}

get_manager_info() {
    local t=manager_info

    info "collecting manager info ..."

    store ${t}-ls-modules ${CEPH} mgr module ls
    store ${t}-dump       ${CEPH} mgr dump
    store ${t}-metadata   ${CEPH} mgr metadata

    store ${t}-ls-modules.json  ${CEPH} mgr module ls -f json
    store ${t}-dump.json        ${CEPH} mgr dump -f json
    store ${t}-metadata.json    ${CEPH} mgr metadata -f json

    if [ "${RESET_MGR_PERF_AND_SLEEP}" -gt 0 ]; then
	store ${t}-perf_reset ${CEPH} tell mgr.\* perf reset all
	info "sleeping for ${RESET_MGR_PERF_AND_SLEEP} sec after reseting mgr perf counters ..."
	sleep ${RESET_MGR_PERF_AND_SLEEP}
    fi

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

        store ${t}-${mgr}-mds_requests.json  ${CEPH} tell ${mgr} mds_requests -f json
        store ${t}-${mgr}-config_diff.json   ${CEPH} tell ${mgr} config diff -f json
        store ${t}-${mgr}-config_show.json   ${CEPH} tell ${mgr} config show -f json
        store ${t}-${mgr}-dump_cache.json    ${CEPH} tell ${mgr} dump_cache -f json
        store ${t}-${mgr}-dump_mempools.json ${CEPH} tell ${mgr} dump_mempools -f json
        store ${t}-${mgr}-mgr_status.json    ${CEPH} tell ${mgr} mgr_status -f json
        store ${t}-${mgr}-perf_dump.json     ${CEPH} tell ${mgr} perf dump -f json
        store ${t}-${mgr}-status.json        ${CEPH} tell ${mgr} status -f json
    done
}

get_osd_info() {
    local t=osd_info

    info "collecting osd info ..."

    store ${t}-tree      ${CEPH} osd tree
    store ${t}-tree_json ${CEPH} osd tree --format json # TODO: update the extension
    store ${t}-df        ${CEPH} osd df
    store ${t}-df-tree   ${CEPH} osd df tree
    store ${t}-dump      ${CEPH} osd dump
    store ${t}-stat      ${CEPH} osd stat
    store ${t}-crushmap  ${CEPH} osd getcrushmap
    store ${t}-map       ${CEPH} osd getmap
    store ${t}-metadata  ${CEPH} osd metadata
    store ${t}-perf      ${CEPH} osd perf

    store ${t}-tree.json ${CEPH} osd tree -f json
    store ${t}-df.json   ${CEPH} osd df -f json
    store ${t}-df-tree.json ${CEPH} osd df tree -f json
    store ${t}-dump.json ${CEPH} osd dump -f json
    store ${t}-stat.json ${CEPH} osd stat -f json
    store ${t}-metadata.json  ${CEPH} osd metadata -f json
    store ${t}-perf.json      ${CEPH} osd perf -f json

    show_stored ${t}-crushmap | store ${t}-crushmap.txt crushtool -d -

    if [ "${RESET_OSD_PERF_AND_SLEEP}" -gt 0 ]; then
	store ${t}-perf_reset ${CEPH} tell osd.\* perf reset all
	info "sleeping for ${RESET_OSD_PERF_AND_SLEEP} sec after reseting osd perf counters ..."
	sleep ${RESET_OSD_PERF_AND_SLEEP}
    fi

    # Sort osds by weight and collect stats for one of every class
    # with highest weight, unless COLLECT_ALL_OSD_ASOK_STATS is set,
    # in which case stats for all osds are collected.
    # The sort and awk commands below parse lines like this:
    #
    #   99    ssd     0.21799          osd.99               up   1.00000  1.00000
    #
    show_stored ${t}-tree | sort -n -k 3 |
    awk -v a=$(test "${COLLECT_ALL_OSD_ASOK_STATS}" = Y && echo 1) '
        $5 == "up" && $6 > 0.8 {
            if (a) {print $4} else {o[$2] = $4}
        }
        END {
            if (!a) {
                for (c in o) print o[c]
             }
        }' |
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

        store ${t}-${osd}-cache_status.json             ${CEPH} tell ${osd} cache status -f json
        store ${t}-${osd}-config_diff.json              ${CEPH} tell ${osd} config diff -f json
        store ${t}-${osd}-config_show.json              ${CEPH} tell ${osd} config show -f json
        store ${t}-${osd}-dump_historic_ops.json        ${CEPH} tell ${osd} dump_historic_ops -f json
        store ${t}-${osd}-dump_mempools.json            ${CEPH} tell ${osd} dump_mempools -f json
        store ${t}-${osd}-dump_ops_in_flight.json       ${CEPH} tell ${osd} dump_ops_in_flight -f json
        store ${t}-${osd}-dump_osd_network.json         ${CEPH} tell ${osd} dump_osd_network -f json
        store ${t}-${osd}-dump_scrub_reservations.json  ${CEPH} tell ${osd} dump_scrub_reservations -f json
        store ${t}-${osd}-dump_scrubs.json              ${CEPH} tell ${osd} dump_scrubs -f json
        store ${t}-${osd}-perf_dump.json                ${CEPH} tell ${osd} perf dump -f json
        store ${t}-${osd}-status.json                   ${CEPH} tell ${osd} status -f json
    done
}

get_pg_info() {
    local t=pg_info
    local pgid

    info "collecting pg info ..."

    store ${t}-stat       ${CEPH} pg stat
    store ${t}-dump       ${CEPH} pg dump
    store ${t}-dump_stuck ${CEPH} pg dump_stuck
    store ${t}-dump_json  ${CEPH} pg dump --format json # TODO: update the extension

    store ${t}-stat.json       ${CEPH} pg stat -f json
    store ${t}-dump.json       ${CEPH} pg dump -f json
    store ${t}-dump_stuck.json ${CEPH} pg dump_stuck -f json

    if [ "$QUERY_INACTIVE_PG" = Y ]; then
	store ${t}-dump_stuck_inactive ${CEPH} pg dump_stuck inactive
	show_stored ${t}-dump_stuck_inactive | grep -o '^[0-9][^ ]*' |
        while read pgid; do
            store ${t}-query-${pgid} ${CEPH} pg ${pgid} query
            store ${t}-query-${pgid}.json ${CEPH} pg ${pgid} query -f json
        done
    fi
}

get_mds_info() {
    local t=mds_info

    info "collecting mds info ..."

    store ${t}-stat ${CEPH} mds stat
    store ${t}-metadata ${CEPH} mds metadata

    store ${t}-stat.json ${CEPH} mds stat -f json    
    store ${t}-metadata.json ${CEPH} mds metadata -f json
}

get_fs_info() {
    local t=fs_info
    local mds

    info "collecting fs info ..."

    store ${t}-ls     ${CEPH} fs ls
    store ${t}-status ${CEPH} fs status
    store ${t}-dump   ${CEPH} fs dump

    store ${t}-ls.json     ${CEPH} fs ls -f json
    store ${t}-status.json ${CEPH} fs status -f json
    store ${t}-dump.json   ${CEPH} fs dump -f json

    if [ "${RESET_MDS_PERF_AND_SLEEP}" -gt 0 ]; then
	store ${t}-perf_reset ${CEPH} tell mds.\* perf reset all
	info "sleeping for ${RESET_MDS_PERF_AND_SLEEP} sec after reseting mds perf counters ..."
	sleep ${RESET_MDS_PERF_AND_SLEEP}
    fi

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

        store ${t}-${mds}-cache_status.json       ${CEPH} tell ${mds} cache status -f json
        store ${t}-${mds}-dump_historic_ops.json  ${CEPH} tell ${mds} dump historic_ops -f json
        store ${t}-${mds}-dump_loads.json         ${CEPH} tell ${mds} dump loads -f json
        store ${t}-${mds}-dump_mempools.json      ${CEPH} tell ${mds} dump mempools -f json
        store ${t}-${mds}-dump_ops_in_flight.json ${CEPH} tell ${mds} dump ops_in_flight -f json
        store ${t}-${mds}-perf_dump.json          ${CEPH} tell ${mds} perf dump -f json
        store ${t}-${mds}-scrub_status.json       ${CEPH} tell ${mds} scrub status -f json
        store ${t}-${mds}-session_ls.json         ${CEPH} tell ${mds} session ls -f json
        store ${t}-${mds}-status.json             ${CEPH} tell ${mds} status -f json
        store ${t}-${mds}-config_diff.json        ${CEPH} tell ${mds} config diff -f json
        store ${t}-${mds}-config_show.json        ${CEPH} tell ${mds} config show -f json
        store ${t}-${mds}-damage_ls.json          ${CEPH} tell ${mds} damage ls -f json
        store ${t}-${mds}-dump_blocked_ops.json   ${CEPH} tell ${mds} dump blocked_ops -f json
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

    store ${t}-bucket_stats.json                  ${RADOSGW_ADMIN} bucket stats --format json
    store ${t}-bucket_limit_check.json            ${RADOSGW_ADMIN} bucket limit check --format json
    store ${t}-metadata_list_bucket.instance.json ${RADOSGW_ADMIN} metadata list bucket.instance --format json
    store ${t}-period_get.json                    ${RADOSGW_ADMIN} period get --format json
    store ${t}-sync_status.json                   ${RADOSGW_ADMIN} sync status --format json
}

get_orch_info() {
    local t=orch_info

    info "collecting orchestrator info ..."

    store ${t}-status  ${CEPH} orch status
    store ${t}-ls      ${CEPH} orch ls
    store ${t}-ls_yaml ${CEPH} orch ls --format yaml
    store ${t}-ps      ${CEPH} orch ps

    store ${t}-status.json  ${CEPH} orch status -f json
    store ${t}-ps.json      ${CEPH} orch ps -f json
}

archive_result() {
    local result_archive compress

    info "archiving ${RESULTS_DIR} ..."

    if which tar > /dev/null 2>&1; then
	result_archive=${RESULTS_DIR}.tar.gz

        tar -czf ${result_archive} -C $(dirname ${RESULTS_DIR}) $(basename ${RESULTS_DIR})

    elif which cpio > /dev/null 2>&1; then
	result_archive=${RESULTS_DIR}.cpio

	if which gzip > /dev/null 2>&1; then
	    compress="gzip -c"
	    result_archive=${result_archive}.gz
	elif which bzip2 > /dev/null 2>&1; then
	    compress="bzip2 -c"
	    result_archive=${result_archive}.bz2
	else
	    compress="cat"
	fi

        (
           cd $(dirname ${RESULTS_DIR}) &&
           find $(basename ${RESULTS_DIR}) -print | cpio -o -H newc
	) | ${compress} > ${result_archive}
    else
	info "no archiving tool found, keeping results in directory"
	result_archive=${RESULTS_DIR}

	# Reset RESULTS_DIR to prevent removal on cleanup
	RESULTS_DIR=
    fi

    info "done"
    info "result: ${result_archive}"
}

#
# Main
#

OPTIONS=$(getopt -o ac:hqr:t:uvD:G:M:O: --long all-osd-asok-stats,ceph-config-file:,help,query-inactive-pg,results-dir:,timeout:,uncensored,verbose,mds-perf-reset-and-sleep:,mgr-perf-reset-and-sleep:,mon-perf-reset-and-sleep:,osd-perf-reset-and-sleep: -- "$@")
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
	-a|--all-osd-asok-stats)
	    COLLECT_ALL_OSD_ASOK_STATS=Y
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
	-D|--mds-perf-reset-and-sleep)
	    RESET_MDS_PERF_AND_SLEEP="$2"
	    shift 2
	    ;;
	-G|--mgr-perf-reset-and-sleep)
	    RESET_MGR_PERF_AND_SLEEP="$2"
	    shift 2
	    ;;
	-M|--mon-perf-reset-and-sleep)
	    RESET_MON_PERF_AND_SLEEP="$2"
	    shift 2
	    ;;
	-O|--osd-perf-reset-and-sleep)
	    RESET_OSD_PERF_AND_SLEEP="$2"
	    shift 2
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
