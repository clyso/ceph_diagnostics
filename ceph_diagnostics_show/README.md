# Ceph Diagnostics Show

This is a collection of scripts for displaying and analyzing data
collected by `ceph_diagnostics_collect.py`.

The scripts are stored in commands subdirectory and are supposed to be
run via `ceph_diagnostics_show` (aka `cds` wrapper).

## Usage example

```
$ git clone https://gitlab.clyso.com/clyso/ceph_diagnostics.git
$ cd ceph_diagnostics/ceph_diagnostics_show
$ PATH=$(pwd):$PATH # add `cds` script to the path
$ cd ~/arch/ceph-collect_20220530_140200 # cd to a ceph_diagnostics_collect.py collected data dir
$ cds help
Ceph Diagnostics Show

usage: cds <command> [options] [args]

Commands:

  ceph        print ceph command output

$ cds ceph help
print ceph command output

supported commands:

  auth list
  config dump
  crash ls
  device ls
  df detail
  df
  fs dump
  fs ls
  fs status
  fsid
  health detail
  health
  mds dump
  mds getmap
  mds stat
  mgr dump
  mgr metadata
  mon dump
  mon getmap
  mon metadata
  mon stat
  orch status
  osd df tree
  osd df
  osd dump
  osd getcrushmap
  osd getmap
  osd metadata
  osd perf
  osd tree
  pg dump [--format json]
  pg dump_stuck
  report
  status
  version
  versions

$ cds ceph version
ceph version 17.2.5 (98318ae89f1a893a6ded3a640405cdbb33e08757) quincy (stable)

$ cds ceph status 
  cluster:
    id:     3cacfa58-55cf-11ed-abaf-5cba2c03dec0
    health: HEALTH_ERR
            1 MDSs report damaged metadata
            (muted: OSDMAP_FLAGS)
 
  services:
    mon: 3 daemons, quorum ceph101,ceph102,ceph103 (age 6w)
    mgr: ceph102.wlimih(active, since 3w), standbys: ceph103.tghnab, ceph101.bziyll
    mds: 1/1 daemons up, 2 standby
    osd: 72 osds: 72 up (since 2w), 72 in (since 6w)
         flags noout
 
  data:
    volumes: 1/1 healthy
    pools:   4 pools, 1073 pgs
    objects: 116.39M objects, 345 TiB
    usage:   535 TiB used, 268 TiB / 803 TiB avail
    pgs:     1068 active+clean
             5    active+clean+scrubbing+deep
 
  io:
    client:   9.0 MiB/s wr, 0 op/s rd, 4 op/s wr
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
screen and exit. This is needed for `cds help` to produce useful
output. When run with any other arguments (or without arguments) the
script is expected to do actual job, i.e. process the collected data
in some way and produce some useful output. See other scripts from
`commands` subdirectory for examples.