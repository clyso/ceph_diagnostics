# Ceph Diagnostics Node Show

This is a collection of scripts for displaying and analyzing data
collected by `ceph_diagnostics_node_collect.py`.

The scripts are stored in commands subdirectory and are supposed to be
run via `ceph_diagnostics_node_show` (aka `cdns` wrapper).

## Usage example

```
$ git clone https://gitlab.clyso.com/clyso/ceph_diagnostics.git
$ cd ceph_diagnostics/ceph_diagnostics_node_show
$ PATH=$(pwd):$PATH # add `cdns` script to the path
$ cd ~/arch/ceph-collect-one1-ceph3_20230121_170532-4x6 # cd to a ceph_diagnostics_node_collect.py collected data dir
$ cdns help
Ceph Diagnostics Node Show

usage: cdns <command> [options] [args]

Commands:

  daemon      print daemon admin socket command output
  perf        print ceph daemon perf

$ cdns daemon help
usage: cdns daemon <daemon> <command>

print daemon admin socket command output

% cdns daemon
mon.one1-ceph3
crash.one1-ceph3
mgr.one1-ceph3.rneibz
osd.26
osd.31
osd.25
osd.30
osd.27
osd.28
osd.24
osd.29

$ cdns daemon osd.28 help
Commands:

  status
  ops_in_flight
  bluestore allocator score block
  historic_ops
  bluefs stats
  perf
  config diff
  cache status
  dump mempools
  watchers
  config
  bluestore bluefs device info
  bluestore allocator fragmentation block

$ cdns daemon osd.28 status
Inferring fsid f91289a2-736d-11ea-b9c7-020100010025
{
    "cluster_fsid": "f91289a2-736d-11ea-b9c7-020100010025",
    "osd_fsid": "1b393040-6783-4b29-b9d7-f24bc85c96c1",
    "whoami": 28,
    "state": "active",
    "oldest_map": 198258,
    "newest_map": 198892,
    "num_pgs": 96
}

$ cdns perf help
usage: sesa perf [-h] [-d mds.x|mon.x|osd.x] [-n] [-l] [{daemons,dump,grep}] [key] [subkey] [subsubkey]

print ceph daemon perf

positional arguments:
  {daemons,dump,grep}   command to run
  key                   perf key (if not specified, list all keys)
  subkey                perf sub-key
  subsubkey             perf sub-sub-key

options:
  -h, --help            show this help message and exit
  -d mds.x|mon.x|osd.x, --daemon mds.x|mon.x|osd.x
                        print ops for this daemon
  -n, --no-keys         print only values
  -l, --no-vals         print only keys

$ cdns perf -d osd.29 grep slow
osd.29   bluefs bytes_written_slow 0
osd.29   bluefs max_bytes_slow 0
osd.29   bluefs read_disk_bytes_slow 0
osd.29   bluefs read_random_disk_bytes_slow 0
osd.29   bluefs slow_total_bytes 8001561821184
osd.29   bluefs slow_used_bytes 0

$ cdns perf dump bluefs slow_used_bytes
osd.24   bluefs slow_used_bytes 0
osd.25   bluefs slow_used_bytes 0
osd.26   bluefs slow_used_bytes 0
osd.27   bluefs slow_used_bytes 0
osd.28   bluefs slow_used_bytes 0
osd.29   bluefs slow_used_bytes 0
osd.30   bluefs slow_used_bytes 0
osd.31   bluefs slow_used_bytes 0
```

## Adding a new command

To add a new command create a script (executable) in
`ceph_diagnostics_show/commands` subdirectory with the name of the new
command. The script may expect that at the moment of its execution the
`CEPH_DIAGNOSTICS_COLLECT_DIR` environment variable is set to the
location of a ceph_diagnostics_collect.py collected data dir, and use
this variable when looking for files. When run with `description`
argument the script should just print its one line description and
exit. When run with `help` argument the script should print its help
screen and exit. This is needed for `cdns help` to produce useful
output. When run with any other arguments (or without arguments) the
script is expected to do actual job, i.e. process the collected data
in some way and produce some useful output. See other scripts from
`commands` subdirectory for examples.