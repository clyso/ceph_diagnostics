#!/usr/bin/env python

"""
The purpose of this script is to collect the diagnostic
information from the ceph cluster and store it in files
under /tmp folder.

Script assumes the ceph.conf file is present in
/etc/ceph/ceph.conf, if not then its path  should be
provided in arguments to the script.

Script would collect the following diagnostic information
system - uname, lsb_release
ceph cluster info : status, version, fsid, ceph conf
cluster health : health, health detail, df
monitor : stat, dump, getmap and metadata
osd : df, tree, dump, stat, getmap, getcrushmap, perf, metadata
pg : stat, dump, dump_stuck
mds: dump, stat, getmap

"""

__author__ = "Pooja Kulkarni"
__copyright__ = "Copyright (C) 2019 Clyso GmbH"
__credits__ = []
__license__ = ""
__version__ = "0.1"
__maintainer__ = "Joachim Kraftmayer"
__email__ = "kontakt@clyso.com "
__status__ = "Development"


import argparse
import datetime
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
LOGGER.setLevel(logging.DEBUG) #parameterize


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
    p = subprocess.Popen(command,
                         stdout=subprocess.PIPE,

                         shell=shell)
    result = p.communicate()[0]
    return str(result.strip())


def ceph_mon_command(handle, command, timeout):
    """
    Executes Ceph commands
    :param handle: cluster handle
    :param command: command to be executed
    :param timeout: timeout for the command execution
    :return: command result
    """
    cmd = {'prefix': command}
    ret, buf, err = handle.mon_command(json.dumps(cmd), b'',
                                       timeout=timeout)

    return str(buf)


def get_system_info():
    """
    Gather system information
    :return: dict
    """
    system = dict()

    system['uname'] = shell_command('uname -a') + b'\n'
    system['lsb_release'] = shell_command('lsb_release -a') + b'\n'

    # More information can be added here later on
    return system


def get_ceph_info(handle, ceph_config, timeout):
    """
    Gather overall cluster information
    :param handle: cluster handle
    :param command: command to be executed
    :param timeout: timeout for the command execution
    :return:
    """
    cluster = dict()

    cluster['status'] = ceph_mon_command(handle,
                                         'status', timeout)
    cluster['version'] = shell_command('ceph -v') + b'\n'

    cluster['versions'] = shell_command('ceph versions') + b'\n'

    cluster['fsid'] = str(handle.get_fsid()) + b'\n'

    with open(ceph_config, 'r') as f:
        ceph_conf = f.read()

    cluster['ceph_conf'] = str(ceph_conf)

    return cluster


def get_health_info(handle, timeout):
    """
    Gather cluster health information
    :param handle: cluster handle
    :param timeout: timeout for the command execution
    :return:
    """
    health = dict()

    health['stat'] = ceph_mon_command(handle, 'health', timeout)
    health['detail'] = ceph_mon_command(handle,
                                        'health detail', timeout)
    health['df'] = ceph_mon_command(handle, 'df', timeout)
    health['report'] = ceph_mon_command(handle, 'report', timeout)

    return health


def get_monitor_info(handle, timeout):
    """
    Gather ceph monitor information
    :param handle: cluster handle
    :param timeout: timeout for the command execution
    :return:
    """
    mon_info = dict()
    mon_info['stat'] = ceph_mon_command(handle, 'mon stat', timeout)
    mon_info['dump'] = ceph_mon_command(handle, 'mon dump', timeout)
    mon_info['map'] = ceph_mon_command(handle, 'mon getmap', timeout)
    mon_info['metadata'] = ceph_mon_command(handle,
                                            'mon metadata', timeout)
    return mon_info


def get_osd_info(handle, timeout):
    """
    Gather osd information
    :param handle: cluster handle
    :param timeout: timeout for the command execution
    :return:
    """
    osd_info = dict()
    osd_info['tree'] = ceph_mon_command(handle, 'osd tree', timeout)
    osd_info['df'] = ceph_mon_command(handle, 'osd df', timeout)
    osd_info['dump'] = ceph_mon_command(handle, 'osd dump', timeout)
    osd_info['stat'] = ceph_mon_command(handle,
                                        'osd stat', timeout)
    osd_info['crushmap'] = ceph_mon_command(handle,
                                            'osd getcrushmap', timeout)
    osd_info['map'] = ceph_mon_command(handle,
                                       'osd getmap', timeout)
    osd_info['metadata'] = ceph_mon_command(handle,
                                            'osd metadata', timeout)
    osd_info['perf'] = ceph_mon_command(handle, 'osd perf', timeout)
    return osd_info


def get_pg_info(handle, timeout):
    """
    Gathers pg information
    :param handle: cluster handle
    :param timeout: timeout for the command execution
    :return:
    """
    pg_info = dict()
    pg_info['stat'] = ceph_mon_command(handle, 'pg stat', timeout)
    pg_info['dump'] = ceph_mon_command(handle, 'pg dump', timeout)
    pg_info['dump_stuck'] = ceph_mon_command(handle,
                                             'pg dump_stuck', timeout)
    return pg_info


def get_mds_info(handle, timeout):
    """
    gathers mds information
    :param handle: cluster handle
    :param timeout: timeout for the command execution
    :return:
    """
    mds_info = dict()
    mds_info['dump'] = ceph_mon_command(handle, 'mds dump', timeout)
    mds_info['stat'] = ceph_mon_command(handle, 'mds stat', timeout)
    mds_info['map'] = ceph_mon_command(handle, 'mds getmap', timeout)
    return mds_info


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


def diagnostic_data_collect(handle,
                            ceph_config,
                            result_dir,
                            timeout):
    """
    collect the daignostics
    :param ceph_config: config file location
    :param result_dir: directory to store the data in
    :param timeout: timeout for command execution
    :return: -
    """
    result_dict = dict()

    LOGGER.info("Collecting system information")
    result_dict['system_info'] = get_system_info()

    LOGGER.info("Collecting Ceph cluster information")
    result_dict['ceph_cluster_info'] = get_ceph_info(handle,
                                                     ceph_config,
                                                     timeout)

    LOGGER.info("Collecting Ceph cluster : health information")
    result_dict['cluster_health'] = get_health_info(handle, timeout)

    LOGGER.info("Collecting Ceph cluster : monitor information")
    result_dict['monitor_info'] = get_monitor_info(handle, timeout)

    LOGGER.info("Collecting Ceph cluster : OSD information")
    result_dict['osd_info'] = get_osd_info(handle, timeout)

    LOGGER.info("Collecting Ceph cluster : PG information")
    result_dict['pg_info'] = get_pg_info(handle, timeout)

    LOGGER.info("Collecting Ceph cluster : MDS information")
    result_dict['mds_info'] = get_mds_info(handle, timeout)

    dict_to_files(result_dict, result_dir)


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

    args = parser.parse_args()

    if not args.ceph_config_file or not args.results_dir or not args.timeout:
        parser.print_usage()

    handle = connect(args.ceph_config_file)

    diagnostic_data_collect(handle,
                            args.ceph_config_file,
                            args.results_dir,
                            args.timeout)
