# Ceph Diagnostics

This repository contains a script that collects the ceph diagnostic informations and store it in a tarfile.

## What is being collected ?

Script collects information, some at OS level, some at the cluster level and some at the daemon level. Script assumes that ceph config file is in /etc/ceph/ceph.config

1. Operating system level 
    1. uname
    2. lsb_release
    3. system statistics - RAM, CPU   
2. Cluster level
    1. ceph status
    1. ceph version and ceph versions(if applicable)
    1. fsid
    1. ceph config file (reads config file)
    1. ceph health
    2. ceph health detail
    3. ceph df
3. Daemons 
    1. Monitors 
        1. ceph mon stat
        1. ceph mon dump
        1. ceph mon getmap
        1. ceph mon metadata
    2. OSD
        1. ceph osd df
        1. ceph osd tree
        1. ceph osd dump
        1. ceph osd stat
        1. ceph osd getmap
        1. ceph osd getcrushmap
        1. ceph osd perf
        1. ceph osd metadata
    3. Placement groups
        1. ceph pg stat
        1. ceph pg dump
        1. ceph pg dump_stuck
    4. Meta Data Server
        1. ceph mds stat
        1. ceph mds dump
        1. ceph mds getmap
        

Ceph diagnostic collect script collects all the above information and puts the result of every command in a file and forms a tarball of all the files in /tmp folder.


## How to execute ?
Script makes use of librados python library to execute monitor commands. 

`python ceph_diagnostics_collect.py [--ceph-config-file] [--results-dir] [--timeout]`
- defaults :
    - ceph-config-file = /etc/ceph/ceph.config
    - results-dir = /tmp
    - timeout = 10 seconds
     

