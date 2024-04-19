# Ceph Diagnostics

This repository contains a script that collects the ceph diagnostic
informations and stores it in a tarfile.

## What is being collected ?

Script collects information, some at OS level, some at the cluster
level and some at the daemon level. By default the script assumes that
ceph config file is in /etc/ceph/ceph.config.

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