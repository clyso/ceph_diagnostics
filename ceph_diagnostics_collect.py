#!/usr/bin/env python

"""
The purpose of this script is to collect the diagnostic
information from the ceph cluster and store it in files
under /tmp folder.

Script assumes the ceph.conf file is present in
/etc/ceph/ceph.conf, if not then its path  should be
provided in arguments to the script.

Script would collect system and ceph cluster diagnostic information.
"""

__author__ = ""
__copyright__ = "Copyright (C) 2019 Clyso GmbH"
__credits__ = []
__license__ = ""
__version__ = "0.1"
__maintainer__ = "Joachim Kraftmayer"
__email__ = "kontakt@clyso.com "
__status__ = "Development"


import argparse
import datetime
import re
import sys
import shutil
import logging
import tempfile
import tarfile
import json
import subprocess
import rados

CEPH_TIMEOUT = 10

# Set up logging for the script
logging.basicConfig(stream=sys.stdout, level=logging.INFO)
LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)


def connect(ceph_config_file, timeout = CEPH_TIMEOUT):
    """
    Creates a handle to the Ceph Cluster.
    :param ceph_config_file: ceph conf file
    :param keyring: client keyring ==> needed ? or not?
    :return: handle to the cluster
    """

    handle = rados.Rados(conffile = ceph_config_file)
    LOGGER.info("librados version: " + str(handle.version()))
    LOGGER.info("Attempting to connect to: " +
                str(handle.conf_get('mon initial members')))

    handle.connect() #timeout shoudl be specified
    LOGGER.info("Cluster ID" + handle.get_fsid())

    return handle


def shell_command(command, shell=True):
    """
    execute a shell command in the cluster
    :param command: command to execute
    :return: result of the command
    """
    LOGGER.debug("SHELL COMMAND: %s", command)
    p = subprocess.Popen(command, stdout=subprocess.PIPE, shell=shell)
    result = p.communicate()[0]
    if not result:
        LOGGER.info("command failed: %s", command)

    return result.strip()

def ceph_shell_command(command, timeout):
    """
    execute Ceph shell command via shell
    :param command: command to execute
    :param timeout: ceph connect timeout
    :return: result of the command
    """
    LOGGER.debug("CEPH COMMAND: %s", command)

    return shell_command('ceph --connect-timeout=%d %s' % (timeout, command)) + b'\n'


def ceph_mon_command(handle, command, timeout):
    """
    Executes Ceph commands
    :param handle: cluster handle
    :param command: command to be executed
    :param timeout: timeout for the command execution
    :return: command result
    """
    LOGGER.debug("MON COMMAND: %s", command)
    cmd = {'prefix': command}
    ret, buf, err = handle.mon_command(json.dumps(cmd), b'', timeout=timeout)
    if err == "command not known":
        LOGGER.info("command not known: %s", command)

    return buf


def get_system_info():
    """
    Gather system information
    :return: dict
    """
    system = dict()

    system['uname'] = shell_command('uname -a') + b'\n'

    # TODO verify if lsb_release packages installed -> DONE
    res = str(shell_command('dpkg -l | grep lsb').decode('utf-8'))
    if "lsb-release" in res:
        system['lsb_release'] = shell_command('lsb_release -a') + b'\n'

    # More information can be added here later on

    print(system)
    return system


def get_ceph_info(handle, ceph_config, uncensored, timeout):
    """
    Gather overall cluster information
    :param handle: cluster handle
    :param ceph_config: path to ceph config
    :param uncensored: don't hide sensitive data
    :param timeout: ceph commands execution timeout
    :return:
    """
    cluster = dict()

    cluster['status'] = ceph_mon_command(handle,
                                         'status', timeout)
    cluster['version'] = shell_command('ceph -v') + b'\n'

    # ceph versions command was introduced in mimic
    version = cluster['version']
    version = str(version.decode('utf-8')).split(' ')[2].split(".")[0]

    if int(version) >= 13:
        cluster['versions'] = ceph_shell_command('versions', timeout)


    fsid = handle.get_fsid() + '\n'
    cluster['fsid'] = str.encode(fsid)

    with open(ceph_config, 'r') as f:
        ceph_conf = f.read()

    cephconf = str(ceph_conf)
    cluster['ceph_conf'] = str.encode(cephconf)

    if int(version) >= 13:
        config_dump = ceph_shell_command('config dump', timeout)
        if uncensored:
            cluster['config_dump'] = config_dump
        else:
            cluster['config_dump'] = re.sub(r'(ACCESS_KEY|SECRET_KEY|PASSWORD).*',
                                            r'\1 <CENSORED>',
                                            config_dump.decode("utf-8"),
                                            flags=re.IGNORECASE).encode("utf-8")

    auth_list = ceph_shell_command('auth list', timeout)
    if uncensored:
        cluster['auth_list'] = auth_list
    else:
        cluster['auth_list'] = re.sub(r'(key:) .*', r'\1 <CENSORED>',
                                      auth_list.decode("utf-8")).encode("utf-8")

    return cluster


def get_health_info(handle, timeout):
    """
    Gather cluster health information
    :param handle: cluster handle
    :param timeout: timeout for the command execution
    :return:
    """
    health = dict()

    health['stat']   = ceph_mon_command(handle, 'health'       , timeout)
    # TODO command not known with ceph_mon_command
    #health['detail'] = ceph_mon_command(handle, 'health detail', timeout)
    health['detail'] = ceph_shell_command('health detail', timeout)
    health['df']     = ceph_mon_command(handle, 'df'           , timeout)
    health['df-detail'] = ceph_shell_command('df detail', timeout)
    health['report'] = ceph_mon_command(handle, 'report'       , timeout)

    health['crash_ls'] = ceph_shell_command('crash ls', timeout)
    for id in filter(lambda id: id and id != 'ID',
                     [(l + ' ID').split()[0] for l in health['crash_ls'].decode("utf-8").split("\n")]):
        health['crash_info_' + id] = ceph_shell_command('crash info ' + id, timeout)

    return health


def get_monitor_info(handle, timeout):
    """
    Gather ceph monitor information
    :param handle: cluster handle
    :param timeout: timeout for the command execution
    :return:
    """
    mon_info = dict()
    mon_info['stat']     = ceph_mon_command(handle, 'mon stat'    , timeout)
    mon_info['dump']     = ceph_mon_command(handle, 'mon dump'    , timeout)
    mon_info['map']      = ceph_mon_command(handle, 'mon getmap'  , timeout)
    mon_info['metadata'] = ceph_mon_command(handle, 'mon metadata', timeout)
    return mon_info


def get_device_info(handle, timeout):
    """
    GAther ceph device information
    :param handle: cluster handle
    :param timeout: timeout for the command execution
    :return:
    """
    device_info = dict()
    device_info['ls'] = ceph_mon_command(handle, 'device ls', timeout)

    return device_info


def get_manager_info(handle, timeout):
    """
    Gather ceph manager information
    :param handle: cluster handle
    :param timeout: timeout for the command execution
    :return:
    """
    mgr_info = dict()
    mgr_info['ls-modules'] = ceph_mon_command(handle, 'mgr module ls', timeout)
    mgr_info['dump']       = ceph_mon_command(handle, 'mgr dump'     , timeout)
    mgr_info['metadata']   = ceph_mon_command(handle, 'mgr metadata' , timeout)
    return mgr_info


def get_osd_info(handle, timeout):
    """
    Gather osd information
    :param handle: cluster handle
    :param timeout: timeout for the command execution
    :return:
    """
    osd_info = dict()
    osd_info['tree']     = ceph_mon_command(handle, 'osd tree'       , timeout)
    osd_info['df']       = ceph_mon_command(handle, 'osd df'         , timeout)
    osd_info['df-tree']  = ceph_shell_command('osd df tree'          , timeout)
    osd_info['dump']     = ceph_mon_command(handle, 'osd dump'       , timeout)
    osd_info['stat']     = ceph_mon_command(handle, 'osd stat'       , timeout)
    osd_info['crushmap'] = ceph_mon_command(handle, 'osd getcrushmap', timeout)
    osd_info['map']      = ceph_mon_command(handle, 'osd getmap'     , timeout)
    osd_info['metadata'] = ceph_mon_command(handle, 'osd metadata'   , timeout)
    osd_info['perf']     = ceph_mon_command(handle, 'osd perf'       , timeout)
    return osd_info


def get_pg_info(handle, timeout, query_inactive_pg):
    """
    Gathers pg information
    :param handle: cluster handle
    :param timeout: timeout for the command execution
    :param query_inactive_pg: if need to query inactive pg
    :return:
    """
    pg_info = dict()
    pg_info['stat']       = ceph_mon_command(handle, 'pg stat'      , timeout)
    pg_info['dump']       = ceph_mon_command(handle, 'pg dump'      , timeout)
    pg_info['dump_stuck'] = ceph_mon_command(handle, 'pg dump_stuck', timeout)
    pg_info['dump_json']  = ceph_shell_command('pg dump --format json', timeout)

    if query_inactive_pg:
        dump_inactive = ceph_shell_command('pg dump_stuck inactive',
                                           timeout).decode("utf-8").split("\n")
        for pg in filter(lambda pg: pg and pg[0].isdigit(),
                         [(l + 'X').split()[0] for l in dump_inactive]):
            pg_info['query-' + pg] = ceph_shell_command('pg ' + pg + ' query',
                                                        timeout)

    return pg_info


def get_mds_info(handle, timeout):
    """
    gathers mds information
    :param handle: cluster handle
    :param timeout: timeout for the command execution
    :return:
    """
    mds_info = dict()
    mds_info['dump'] = ceph_mon_command(handle, 'mds dump'  , timeout)
    mds_info['stat'] = ceph_mon_command(handle, 'mds stat'  , timeout)
    mds_info['map']  = ceph_mon_command(handle, 'mds getmap', timeout)
    return mds_info


def get_fs_info(handle, timeout):
    """
    gathers fs information
    :param handle: cluster handle
    :param timeout: timeout for the command execution
    :return:
    """
    fs_info = dict()
    fs_info['dump'] = ceph_shell_command('fs dump', timeout)
    return fs_info


def get_radosgw_admin_info(handle, timeout):
    """
    gathers radosgw-admin information
    :param handle: cluster handle
    :param timeout: timeout for the command execution
    :return:
    """
    radosgw_admin_info = dict()

    osd_dump = ceph_shell_command("osd dump", timeout)
    if not re.search('^pool .* application rgw', osd_dump.decode('utf-8'),
                     re.MULTILINE):
        LOGGER.debug('skipping radosgw_admin_info: no rgw pools found')
        return radosgw_admin_info

    radosgw_admin_info['bucket_stats'] = shell_command('radosgw-admin bucket stats') + b'\n'
    radosgw_admin_info['bucket_limit_check'] = shell_command('radosgw-admin bucket limit check') + b'\n'
    radosgw_admin_info['metadata_list_bucket.instance'] = shell_command('radosgw-admin metadata list bucket.instance') + b'\n'

    return radosgw_admin_info


def get_orch_info(handle, timeout):
    """
    gathers orchestrator information
    :param handle: cluster handle
    :param timeout: timeout for the command execution
    :return:
    """
    orch_info = dict()
    orch_info['status'] = ceph_shell_command('orch status', timeout)
    return orch_info


def dict_to_files(result_dict, dest_dir):
    """
    Writes the diagnostics to specific files
    and creates a tarball for the same
    :param result_dict: results of all the commands
    :param dest_dir: directory where tarball is saved
    :return:
    """
    tempdir = tempfile.mkdtemp()

    # timestamp every generated dignostic file
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%I%S")
    tarball = '{0}/ceph-collect_{1}.tar.gz'.format(dest_dir, timestamp)

    with tarfile.open(tarball, 'w:gz') as tar:
        for filename, content in result_dict.items():

            for contentname, contentdata in content.items():
                tmpfile = '{0}/{1}'.format(tempdir, filename +
                                           "-" + contentname)

                LOGGER.debug('Writing file %s', tmpfile)
                with open(tmpfile, 'wb') as f:
                    f.write(contentdata)
                f.close()

                tar.add(name=tmpfile,
                        arcname='ceph-collect_{0}/{1}'.format(timestamp,
                                                              filename + "-" +
                                                              contentname))
    tar.close()
    LOGGER.info("Diagnostics are written to : "+ tarball)

    LOGGER.info("Cleaning up temporary directory")
    shutil.rmtree(tempdir)


def diagnostic_data_collect(handle, args):
    """
    collect the daignostics
    :param ceph_config: config file location
    :param args: command line arguments
    :return: -
    """
    result_dict = dict()

    LOGGER.info("Collecting system information")
    result_dict['system_info'] = get_system_info()

    LOGGER.info("Collecting Ceph cluster information")
    result_dict['ceph_cluster_info'] = get_ceph_info(handle,
                                                     args.ceph_config_file,
                                                     args.uncensored,
                                                     args.timeout)

    LOGGER.info("Collecting Ceph cluster : health information")
    result_dict['cluster_health'] = get_health_info(handle, args.timeout)

    LOGGER.info("Collecting Ceph cluster : monitor information")
    result_dict['monitor_info'] = get_monitor_info(handle, args.timeout)

    LOGGER.info("Collecting Ceph cluster : device information")
    result_dict['device_info'] = get_device_info(handle, args.timeout)

    LOGGER.info("Collecting Ceph cluster : manager information")
    result_dict['manager_info'] = get_manager_info(handle, args.timeout)

    LOGGER.info("Collecting Ceph cluster : OSD information")
    result_dict['osd_info'] = get_osd_info(handle, args.timeout)

    LOGGER.info("Collecting Ceph cluster : PG information")
    result_dict['pg_info'] = get_pg_info(handle, args.timeout,
                                         args.query_inactive_pg)

    LOGGER.info("Collecting Ceph cluster : MDS information")
    result_dict['mds_info'] = get_mds_info(handle, args.timeout)

    LOGGER.info("Collecting Ceph cluster : FS information")
    result_dict['fs_info'] = get_fs_info(handle, args.timeout)

    LOGGER.info("Collecting Ceph cluster : radosgw-admin information")
    result_dict['radosgw_admin_info'] = get_radosgw_admin_info(handle,
                                                               args.timeout)

    LOGGER.info("Collecting Ceph cluster : orchestrator information")
    result_dict['orch_info'] = get_orch_info(handle, args.timeout)

    dict_to_files(result_dict, args.results_dir)


if __name__ == '__main__':
    RETURN_VALUE = 1
    parser = argparse.ArgumentParser(
        description='Ceph Diagnostics: Collect '
                    'diagnostic information from '
                    'a Ceph cluster')
    parser.add_argument('--ceph-config-file',
                        action='store',
                        dest='ceph_config_file',
                        default='/etc/ceph/ceph.conf',
                        help='Ceph Configuration file')
    parser.add_argument('--results-dir',
                        action='store',
                        dest='results_dir',
                        default=tempfile.gettempdir(),
                        help='Directory to store result of diagnostic'
                             'information of cluster')
    parser.add_argument('--timeout',
                        action='store',
                        dest='timeout',
                        default=CEPH_TIMEOUT,
                        help='Timeout for Ceph operations')
    parser.add_argument('--query-inactive-pg',
                        action='store_true',
                        dest='query_inactive_pg',
                        default=False,
                        help='Query inactive pg')
    parser.add_argument('--uncensored',
                        action='store_true',
                        dest='uncensored',
                        default=False,
                        help="Don't hide sensitive data")
    parser.add_argument('--verbose',
                        action='store_true',
                        dest='verbose',
                        default=False,
                        help='Be verbose')


    args = parser.parse_args()

    if not args.ceph_config_file or not args.results_dir or not args.timeout:
        parser.print_usage()

    if args.verbose:
        LOGGER.setLevel(logging.DEBUG)

    handle = connect(args.ceph_config_file)

    diagnostic_data_collect(handle, args)

