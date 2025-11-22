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

  cct                     run cct command
  ceph                    print ceph command output
  check-pg-on-same-host   check 2 or more pg replica/shards on the same host
  copilot                 run copilot command
  crush                   show ceph crush info
  find-by-addr            find daemon by <ip:port> address
  fsa                     run fsa command
  historic_ops            print ceph daemon historic ops
  mds                     print mds admin socket command output or processed result
  osd                     show ceph osd info
  perf                    print ceph daemon perf
  pg                      process pg dump
  pool                    show pool info
  radosgw-admin           print radosgw-admin command output
  report                  generate diagnostic report

$ cds ceph help
print ceph command output

supported commands:

  auth list
  balancer status
  config dump
  config log
  crash info <id>
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
  mds metadata
  mds stat
  mgr dump
  mgr metadata
  mon dump
  mon getmap
  mon metadata
  mon stat
  orch ls [--format yaml]
  orch ps
  orch status
  osd df tree
  osd df
  osd dump
  osd getcrushmap
  osd getmap
  osd metadata [<id>]
  osd perf
  osd pool ls detail
  osd tree
  pg dump [--format json]
  pg dump_stuck
  report
  status
  tell
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

## Integrating ceph-copilot, clyso-fsa and cct

`ceph-copilot`, `clyso-fsa` and `cct` are @clyso internal Ceph analyzing tools.
If you have access to them you may easily integrate them with `cds`.

For `ceph-copilot` integration, just make sure the `copilot` command is in the
`PATH` and running. Alternatively you may use `CEPH_COPILOT` environment
variable, like below:

```
export CEPH_COPILOT='source $HOME/clyso/ceph-copilot/.venv/bin/activate && ceph-copilot'
```

For `clyso-fsa` and/or `cct` integration, when you have them already configured
as described in the documentation, specify `clyso-fsa` and/or `cct` source
directories in `CLYSO_FSA_DIR` and/or `CLYSO_CCT_DIR` environment variables,
e.g:

```
export CLYSO_FSA_DIR="${HOME}/clyso/clyso-fsa"
export CLYSO_CCT_DIR="${HOME}/clyso/cct"
```

After setup the commands below should work:

```
$ cds copilot checkup
$ cds copilot checkup --verbose
$ cds fsa "Wonka Industries"
$ cds cct crush browse
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