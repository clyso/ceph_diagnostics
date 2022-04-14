# Ceph Diagnostics

This repository contains a script that collects the ceph diagnostic informations and store it in a tarfile.

## What is being collected ?

Script collects information, some at OS level, some at the cluster level and some at the daemon level. Script assumes that ceph config file is in /etc/ceph/ceph.config

Ceph diagnostic collect script collects all information and puts the result of every command in a file and forms a tarball of all the files in /tmp folder.


## How to execute ?
Script makes use of librados python library to execute monitor commands. 

`python ceph_diagnostics_collect.py [--ceph-config-file] [--results-dir] [--timeout] [--query-inactive-pg] [--verbose]`
- defaults :
    - ceph-config-file = /etc/ceph/ceph.config
    - results-dir = /tmp
    - timeout = 10 seconds
     

