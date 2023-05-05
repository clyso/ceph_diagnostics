#!/bin/sh

#
# Collect info for ceph daemons running on the current node
#

RESULTS_DIR=$(mktemp -d /tmp/ceph-collect-$(hostname)_$(date +%Y%m%d_%H%I%S)-XXX)
RESULT_ARCHIVE=${RESULTS_DIR}.tar.gz
CEPHADM_CMD=cephadm

trap cleanup INT TERM EXIT

cleanup() {
    rm -Rf ${RESULTS_DIR}
}

info() {
    echo "$*" >&2
}

set_cephadm_cmd() {
    local fsid='*'
    local cephadm

    if [ -r /etc/ceph/ceph.conf ]; then
	fsid=$(awk '$1 == "fsid" {print $3}' /etc/ceph/ceph.conf)
    fi

    cephadm=$(ls -t /var/lib/ceph/${fsid}/cephadm.* | head -1)

    if [ -n "${cephadm}" ]; then
	CEPHADM_CMD="python3 ${cephadm}"
    else
	info "WANRING: failed to find deployed cephadm binary. Expecting to find ${cephadm} in PATH"
    fi
}

list_running_daemons() {
    ${CEPHADM_CMD} ls | jq -r '.[] | select(.state == "running") | .name'
}

cmd_to_name() {
    echo "$@" | sed -e 's/ /-/g'
}

cephadm_collect() {
    local cmd="$@"
    local name=cephadm-$(cmd_to_name $@)

    ${CEPHADM_CMD} ${cmd} > ${RESULTS_DIR}/${name} 2> ${RESULTS_DIR}/${name}.log
}

cephadm_collect_json() {
    local cmd="$@"
    local name=cephadm-$(cmd_to_name $@).json

    ${CEPHADM_CMD} ${cmd} --format json-pretty \
        > ${RESULTS_DIR}/${name} 2> ${RESULTS_DIR}/${name}.log
}

daemon_collect() {
    local daemon=$1; shift
    local cmd="$@"
    local resdir=${RESULTS_DIR}/daemons/"${daemon}"
    local name=$(cmd_to_name $@)

    mkdir -p ${resdir}

    ${CEPHADM_CMD} enter --name ${daemon} -- ceph daemon ${daemon} ${cmd} \
        > ${resdir}/${name} 2> ${resdir}/${name}.log
}

collect_info_from_daemon() {
    local daemon=$1

    mkdir -p ${RESULTS_DIR}/daemons

    case "${daemon}" in
    mds.*|mgr.*|mon.*|osd.*)
	daemon_collect ${daemon} config diff
	daemon_collect ${daemon} config show
	daemon_collect ${daemon} perf dump
	daemon_collect ${daemon} dump_mempools
        ;;
    esac

    case "${daemon}" in
    mds.*)
        daemon_collect ${daemon} cache status
        daemon_collect ${daemon} dump loads
        daemon_collect ${daemon} dump_historic_ops
        daemon_collect ${daemon} dump_ops_in_flight
        daemon_collect ${daemon} get subtrees
        daemon_collect ${daemon} scrub status
        daemon_collect ${daemon} session ls
        daemon_collect ${daemon} status
        ;;
    mgr.*)
        daemon_collect ${daemon} status
        ;;
    mon.*)
        daemon_collect ${daemon} dump_historic_ops
        daemon_collect ${daemon} mon_status
        daemon_collect ${daemon} sessions
        ;;
    osd.*)
        daemon_collect ${daemon} bluefs stats
        daemon_collect ${daemon} bluestore allocator fragmentation block
        daemon_collect ${daemon} bluestore allocator score block
        daemon_collect ${daemon} bluestore bluefs device info
        daemon_collect ${daemon} cache status
        daemon_collect ${daemon} dump_historic_ops
        daemon_collect ${daemon} dump_ops_in_flight
        daemon_collect ${daemon} dump_watchers
        daemon_collect ${daemon} status
        ;;
    esac
}

set_cephadm_cmd

info "collecting cephadm status ..."
echo ${CEPHADM_CMD} > ${RESULTS_DIR}/cephadm_cmd
cephadm_collect ls
cephadm_collect check-host
cephadm_collect inspect-image

info "collecting crash info ..."
mkdir ${RESULTS_DIR}/crash
for crash in /var/lib/ceph/*/crash ; do
    test -d "${crash}" && cp -a "${crash}" ${RESULTS_DIR}/crash
done

for daemon in $(list_running_daemons); do
    info "collecting daemon ${daemon} info ..."
    collect_info_from_daemon "${daemon}"
done

info "collecting ceph-volume info ..."
cephadm_collect ceph-volume lvm list
cephadm_collect ceph-volume inventory
cephadm_collect_json ceph-volume inventory

mkdir -p ${RESULTS_DIR}/log

info "copying file logs ..."
if [ -d /var/log/ceph ]; then
    find /var/log/ceph -type f -exec cp '{}' ${RESULTS_DIR}/log ';'
fi

${CEPHADM_CMD} ls | jq -r '.[] | "\(.fsid) \(.name)"' |
while read fsid name ; do
    info "collecting daemon ${name} journal log ..."
    ${CEPHADM_CMD} logs --fsid ${fsid} --name ${name} > ${RESULTS_DIR}/log/${name}.log 2>&1
done

tar -czf ${RESULT_ARCHIVE} -C $(dirname ${RESULTS_DIR}) $(basename ${RESULTS_DIR})

info "done"
info "result: ${RESULT_ARCHIVE}"
