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