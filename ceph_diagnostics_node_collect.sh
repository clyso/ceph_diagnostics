#!/bin/sh

#
# Collect info for ceph daemons running on the current node
#

RESULTS_DIR=$(mktemp -d /tmp/ceph-collect-$(hostname)_$(date +%Y%m%d_%H%I%S)-XXX)
RESULT_ARCHIVE=${RESULTS_DIR}.tar.gz

trap cleanup INT TERM EXIT

cleanup() {
    rm -Rf ${RESULTS_DIR}
}

info() {
    echo "$*" >&2
}

collect_info_from_daemon() {
    local daemon=$1

    mkdir -p ${RESULTS_DIR}/daemons

    local resdir=${RESULTS_DIR}/daemons/"${daemon}"
    mkdir ${resdir}

    local ceph_daemon_cmd="cephadm enter --name ${daemon} -- ceph daemon ${daemon}"

    case "${daemon}" in
    mds.*)
	${ceph_daemon_cmd} config show > ${resdir}/ceph-daemon-config 2>&1
	${ceph_daemon_cmd} perf dump > ${resdir}/ceph-daemon-perf 2>&1
        ${ceph_daemon_cmd} dump_historic_ops > ${resdir}/ceph-daemon-historic_ops 2>&1
        ${ceph_daemon_cmd} dump_ops_in_flight > ${resdir}/ceph-daemon-ops_in_flight 2>&1
        ${ceph_daemon_cmd} status > ${resdir}/ceph-daemon-status 2>&1
        ${ceph_daemon_cmd} get subtrees > ${resdir}/ceph-daemon-subtrees 2>&1
        ;;
    mgr.*)
	${ceph_daemon_cmd} config show > ${resdir}/ceph-daemon-config 2>&1
	${ceph_daemon_cmd} perf dump > ${resdir}/ceph-daemon-perf 2>&1
        ${ceph_daemon_cmd} status > ${resdir}/ceph-daemon-status 2>&1
        ;;
    mon.*)
	${ceph_daemon_cmd} config show > ${resdir}/ceph-daemon-config 2>&1
	${ceph_daemon_cmd} perf dump > ${resdir}/ceph-daemon-perf 2>&1
        ${ceph_daemon_cmd} dump_historic_ops > ${resdir}/ceph-daemon-historic_ops 2>&1
        ;;
    osd.*)
	${ceph_daemon_cmd} config show > ${resdir}/ceph-daemon-config 2>&1
	${ceph_daemon_cmd} perf dump > ${resdir}/ceph-daemon-perf 2>&1
        ${ceph_daemon_cmd} dump_historic_ops > ${resdir}/ceph-daemon-historic_ops 2>&1
        ${ceph_daemon_cmd} dump_ops_in_flight > ${resdir}/ceph-daemon-ops_in_flight 2>&1
        ${ceph_daemon_cmd} status > ${resdir}/ceph-daemon-status 2>&1
        ${ceph_daemon_cmd} dump_watchers > ${resdir}/ceph-daemon-watchers 2>&1
        ;;
    esac
}

info "collecting cephadm status ..."
{
    cephadm ls 2>&1
    cephadm check-host 2>&1
    cephadm inspect-image 2>&1
} > ${RESULTS_DIR}/cephadm-status

info "collecting crash info ..."
mkdir ${RESULTS_DIR}/crash
for crash in /var/lib/ceph/*/crash ; do
    test -d "${crash}" && cp -a "${crash}" ${RESULTS_DIR}/crash
done

running_daemons=$(cephadm ls | jq -r '.[] | select(.state == "running") | .name')
for daemon in ${running_daemons}; do
    info "collecting daemon ${daemon} info ..."
    collect_info_from_daemon "${daemon}"
done

info "collecting ceph-volume info ..."
cephadm ceph-volume lvm list 2>&1 > ${RESULTS_DIR}/ceph-volume-list
cephadm ceph-volume inventory --format json-pretty 2>&1 > ${RESULTS_DIR}/ceph-volume-inventory.json
cephadm ceph-volume inventory 2>&1 > ${RESULTS_DIR}/ceph-volume-inventory

mkdir -p ${RESULTS_DIR}/log

info "copying file logs ..."
if [ -d /var/log/ceph ]; then
    find /var/log/ceph -type f -exec cp '{}' ${RESULTS_DIR}/log ';'
fi

cephadm ls | jq -r '.[] | "\(.fsid) \(.name)"' |
while read fsid name ; do
    info "collecting daemon ${name} journal log ..."
    cephadm logs --fsid ${fsid} --name ${name} > ${RESULTS_DIR}/log/${name}.log 2>&1
done

tar -czf ${RESULT_ARCHIVE} -C $(dirname ${RESULTS_DIR}) $(basename ${RESULTS_DIR})

info "done"
info "result: ${RESULT_ARCHIVE}"
