# Ceph Diagnostics

This repository contains `ceph_diagnostics_collect.sh` script that
collects ceph diagnostic information and stores it in a tarfile.

## What is being collected ?

The script collects information at the cluster level and some at the
daemon level. By default the script assumes that ceph config file is
in /etc/ceph/ceph.config.

Ceph diagnostic collect script collects all information and puts the
result of every command in a file and forms a tarball of all the files
in /tmp folder.

## How to execute ?

Normally it is just enough to download and execute the script:
```
./ceph_diagnostics_collect.sh
```

There are options that one might want to set to collect more info or
specify ceph config location. To get information about all options
available run:
```
./ceph_diagnostics_collect.sh -h
```

## How to analyse ?

There is ceph_diagnostics_show tool that may be useful for analyzing
collected data. See ceph_diagnostics_show/README.md for details.

# Ceph Node Diagnostics

This repository also contains `ceph_diagnostics_node_collect.sh`
script that collects a ceph node diagnostic information and stores it
in a tarfile.

## What is being collected ?

The script collects OS and ceph specific information that can be found
on the node the script is running at. The information includes logs,
perf stats, configuration and other useful output for all ceph daemons
on this node.

The script is suppposed to be executed on cephadm deployed cluster.

## How to execute ?

Just download and execute the script:
```
./ceph_diagnostics_node_collect.sh
```

## How to analyse ?

There is ceph_diagnostics_node_show tool that may be useful for analyzing
collected data. See ceph_diagnostics_node_show/README.md for details.

# CephFS MDS Tuning Probe

`ceph_mds_probe.sh` continuously samples active MDS ranks from any admin
node (`ceph tell`) and produces timestamped time series (fs perf stats,
perf counters, cache status, per-session caps, objecter requests,
balancer load, historic ops, health details, and the OSDs carrying the
metadata pool). It is meant for sizing decisions such as
`mds_max_caps_per_client`, `mds_cache_memory_limit` and `max_mds`; run
it for at least 24h, re-run with a different `--tag` after a config
change, and compare the runs:

```
./ceph_mds_probe.sh --tag baseline
./ceph_mds_probe.sh --tag after-cap-limit
```

Each stream samples in its own worker, so one slow `ceph tell` cannot
starve the others, and the active MDS set is re-discovered while the
probe runs, so a rank that fails over to another daemon keeps being
sampled. Samples that fail are recorded with their error instead of
being dropped, and the run ends with a data quality report.

With `--ssh` the probe also samples per-thread CPU (`top -b -H`) and
`daemonperf` on the MDS hosts, using the cephadm SSH identity; the
private key stays in memory. All cluster sampling is read-only: apart
from the optional `--enable-stats-module` (which is restored on exit),
the script never modifies any configuration.

Run it detached and control it with `--status` / `--stop`; `--stop`
lets every sampler finish the call it is in the middle of.

See USAGE.md for the full option list and the output layout.
