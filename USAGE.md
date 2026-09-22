cds pg scrub-stats
```
total number of pgs: 4449
total scrub duration: 259619 sec
average scrub duration: 58 sec
total number of objects: 673149263
average number of objects per pg: 151303
total size: 2220003750197429 bytes
average pg size: 498989379680 bytes
per pool scrub duration:
  24: 259474 sec (4096 pgs, 63 sec/pg, 541991969822 bytes/pg, 164215 obj/pg, 49.33 sec std_dev)
  25: 96 sec (128 pgs, 0 sec/pg, 0 bytes/pg, 2341 obj/pg, 0.72 sec std_dev)
  26: 38 sec (32 pgs, 1 sec/pg, 134571 bytes/pg, 5850 obj/pg, 0.37 sec std_dev)
  21: 0 sec (32 pgs, 0 sec/pg, 0 bytes/pg, 0 obj/pg, 0.00 sec std_dev)
  15: 3 sec (32 pgs, 0 sec/pg, 128357019 bytes/pg, 38 obj/pg, 0.26 sec std_dev)
  14: 0 sec (32 pgs, 0 sec/pg, 128 bytes/pg, 0 obj/pg, 0.00 sec std_dev)
  16: 0 sec (32 pgs, 0 sec/pg, 0 bytes/pg, 0 obj/pg, 0.01 sec std_dev)
  17: 6 sec (32 pgs, 0 sec/pg, 309681 bytes/pg, 1083 obj/pg, 0.07 sec std_dev)
  20: 0 sec (32 pgs, 0 sec/pg, 0 bytes/pg, 2 obj/pg, 0.00 sec std_dev)
  7: 0 sec (1 pgs, 0 sec/pg, 520160352 bytes/pg, 125 obj/pg, 0.00 sec std_dev)
```


cds osd sum
```
OSD DEV TYPES: {'hdd': 0, 'hybrid': 0, 'ssd': 50}
OSD HOSTS:
 ceph-0001 (10): [0, 179, 419, 424, 429, 434, 439, 444, 449, 454]
 ceph-0002 (10): [178, 418, 423, 428, 432, 437, 442, 447, 453, 458]
 ceph-0003 (10): [177, 417, 422, 427, 433, 438, 443, 448, 452, 457]
 ceph-0004 (10): [176, 416, 421, 426, 431, 436, 441, 445, 450, 455]
 ceph-0005 (10): [175, 378, 420, 425, 430, 435, 440, 446, 451, 456]
```

cds rgw top - outputs bucket metrics (can sort by metric)
```
Bucket Name                                            Num Objects     Shards      Size (TiB)      Objects/Shard
----------------------------------------------------------------------------------------------------------------
bucket-1                                                   62,214         17           49.99           3,659.65
bucket-2                                                  448,326         37           29.50          12,116.92
bucket-3                                                      422         17           23.22              24.82
bucket-4                                                  202,075         37           22.37           5,461.49
bucket-5                                                8,016,419      10009           21.96             800.92
bucket-6                                                  305,441         37           20.93           8,255.16
bucket-7                                                   91,222         17           19.20           5,366.00
bucket-8                                                  228,727         17           18.92          13,454.53
bucket-9                                                  267,896         17           16.33          15,758.59
bucket-10                                                  11,549         17           15.07             679.35
bucket-11                                                 269,496         17           14.10          15,852.71
bucket-12                                                 198,716         17           13.89          11,689.18
bucket-13                                                 197,877         17           13.42          11,639.82
bucket-14                                                 198,345         17           13.37          11,667.35
bucket-15                                                 203,168         17           13.14          11,951.06
bucket-16                                                   6,245         17           12.61             367.35
bucket-17                                                  16,442         17           12.52             967.18
bucket-18                                                  15,526         17            9.93             913.29
bucket-19                                                 478,856         37            7.98          12,942.05
bucket-20                                                  15,939         17            5.99             937.59
```

# CephFS MDS Tuning Probe

`ceph_mds_probe.sh` continuously samples active MDS ranks from any admin
node (`ceph tell`) and produces timestamped time series for sizing
`mds_max_caps_per_client`, `mds_cache_memory_limit` and `max_mds`.

Every stream runs in its own background worker, so a slow or hung
`ceph tell` on one stream never delays the others, and the active MDS
set is re-discovered every `--discovery-interval` seconds, so ranks that
fail over to another daemon during a long run keep being sampled.

## Where to run it

On any node that already has the ceph CLI and an admin keyring - the one
where `ceph -s` is normally typed. No root, and no login to the MDS hosts.
That is the same requirement as `ceph_diagnostics_collect.sh`, with four
things that only matter because this one runs for a day:

- **It must reach the MDS daemons directly.** `ceph tell mds.<rank>` is not
  forwarded by a mon: the CLI takes the address out of the mdsmap and
  connects to the MDS public address. A collection that cannot do that
  produces a full day of error records, so check it first - it takes a
  second:

  ```
  ceph tell mds.$(ceph fs dump -f json |
                  jq -r '.filesystems[0].mdsmap.info[].name' | head -1) \
      perf dump | head -3
  ```

  JSON back means the path works.

- **The node has to stay up for the whole window**, and the run has to
  survive the terminal closing - see "Running it detached" below.
- **Room for the data.** A collection is gigabytes where an ordinary
  diagnostics archive is megabytes. The probe measures real samples before
  it starts and refuses if the estimate does not fit in `-o`.
- **`--ssh` asks for a little more.** It reads the cephadm SSH identity
  (`ceph cephadm get-user`, `ceph cephadm get-ssh-config`,
  `ceph config-key get mgr/cephadm/ssh_identity_key`); the last one needs a
  keyring with mon `allow *`, which `client.admin` has and a restricted one
  may not. Without it the probe warns and falls back to the invoking user's
  own ssh identity, which then has to reach the MDS hosts by itself. Run it
  on the cephadm admin host - the one where `cephadm shell` is run.

Commands it needs: `ceph` and `jq` are required; `timeout`, `tar`, `pigz`
and `pkill` are used when present; `ssh`, `ssh-agent` and `ssh-add` only
with `--ssh`.

## Collecting a baseline

What to hand a customer who is asked for a collection:

```
nohup ./ceph_mds_probe.sh \
    --tag baseline \
    -d 86400 \
    --ssh \
    --enable-stats-module \
    --archive \
    -o /var/log/ceph \
    > /var/log/ceph/probe.log 2>&1 &
```

| option | why |
|---|---|
| `-d 86400` | 24h, to cover a whole business cycle; under 20h the caps confidence drops to MEDIUM |
| `--ssh` | the per-thread CPU of the MDS hosts. Without it the report has to say it cannot tell a CPU-bound MDS from one that is not, which is the hardest piece of evidence the max_mds decision has |
| `--enable-stats-module` | `fs perf stats` needs the mgr stats module; its previous state is restored on exit |
| `--archive` | packs the run into a tar.gz with a sha256 manifest |
| `-o` | where the data lands, `/var/log/ceph` by default |

While it runs, from any other terminal:

```
./ceph_mds_probe.sh --status     # progress, sampled ranks, per-stream quality
./ceph_mds_probe.sh --stop       # each sampler finishes the call it is in
```

**Read the quality report before the cluster is handed back:**

```
cat /var/log/ceph/mds-probe-current/meta/quality-report.txt
```

`all streams clean` is the answer to look for. A `<-- CHECK` means a stream
carries error records, and that is worth chasing while the cluster is still
in the state that produced them.

Then send back the two files the run printed:

```
/var/log/ceph/mds-probe_baseline_<timestamp>_XXXXXX.tar.gz
/var/log/ceph/mds-probe_baseline_<timestamp>_XXXXXX.tar.gz.sha256
```

### Things worth saying out loud

- **The window has to cover the problem.** A cluster that only stalls during
  the nightly backup needs the 24h aimed at that, or the collection is a
  picture of a healthy cluster.
- **For hot directory evidence, raise the op history first.** The default
  `mds_op_history_size` is 20, so the historic ops are a very thin sample -
  a 2 minute run over four snapshots yielded 58 requests, and the
  splittability criterion wants at least 50. This is the one cluster setting
  worth changing for a collection; the probe never changes it by itself.

  ```
  ceph config set mds mds_op_history_size 1000
  ceph config set mds mds_op_history_duration 3600
  # afterwards
  ceph config rm mds mds_op_history_size
  ceph config rm mds mds_op_history_duration
  ```

- **Tens of thousands of sessions**: add `-s 300`, or `--skip-sessions`. The
  cost is that the caps decision degrades to "no session data to assess".
- **Take an ordinary diagnostics snapshot too**, for the cluster context
  around the time series: `./ceph_diagnostics_collect.sh -d /var/log/ceph`.

## What it samples, and how much of it

Sample intervals: perf counters every 5s, `fs perf stats` every 30s,
`fs status`, `cache status` and `objecter_requests` every 60s,
`session ls` every 180s, historic ops / `dump loads` / `dump_mempools`
and the metadata pool OSDs every 300s, health detail every 300s. The run
directory is created under `/var/log/ceph` (see `-o`); the script prints
its path on exit, and `<out-dir>/mds-probe-current` points at it.

Before it starts, the probe measures one sample of the biggest streams,
projects the data volume of the whole run and refuses to start if that
would use more than 80% of the free space in `-o` (`--force` overrides,
`--no-space-check` skips the estimate).

`--stop` clears the run's flag file, so every sampler finishes the call
it is in the middle of instead of being killed; Ctrl-C does the same.
On exit the probe writes `meta/quality-report.txt`: records and error
records per stream, measured against the samples the intervals should
have produced.

## Host CPU (`--ssh`)

```
./ceph_mds_probe.sh --tag baseline --ssh --daemonperf
```

`--ssh` samples `top -b -H` on the MDS hosts, which is what shows
whether `ms_dispatch`/`MDSRank` is pinned at 100% - the evidence that
decides whether more ranks would help at all. It uses the cephadm SSH
identity (`ceph cephadm get-user`, `ceph cephadm get-ssh-config`,
`ceph config-key get mgr/cephadm/ssh_identity_key`); the private key is
loaded into an in-memory ssh-agent, or into a 0600 file on tmpfs that is
shredded on exit. Remote ceph commands run through the host's own
deployed cephadm binary, so the MDS hosts need no ceph CLI.
`--plain-ssh` uses the invoking user's own identity instead; see
"Where to run it" for what reading the cephadm identity requires.

## A/B comparison after a config change

```
./ceph_mds_probe.sh --tag after-cap-limit
```

Re-run with a different `--tag` after a config change so the two
collections can be compared.

## Probe options

| option | description |
|---|---|
| `-d, --duration <sec>` | probe duration, 0 = until stopped (default 86400) |
| `-i, --perf-interval <sec>` | perf dump interval (default 5) |
| `--fs-perf-interval <sec>` | fs perf stats interval (default 30) |
| `--fs-status-interval <sec>` | fs status interval, 0 = disable (default 60) |
| `--cache-interval <sec>` | cache status interval (default 60) |
| `--objecter-interval <sec>` | objecter_requests interval, 0 = disable (default 60) |
| `-s, --session-interval <sec>` | session ls interval, 0 = disable (default 180) |
| `--skip-sessions` | do not sample session ls (large clusters) |
| `--histops-interval <sec>` | historic ops / ops in flight interval, 0 = disable (default 300) |
| `--skip-histops` | do not sample historic ops (hot-subtree analysis) |
| `--loads-interval <sec>` | dump loads / dump_mempools interval, 0 = disable (default 300) |
| `--health-interval <sec>` | cluster health detail interval, 0 = disable (default 300) |
| `--osd-limit <n>` | sample this many metadata pool OSDs, 0 = disable (default 4) |
| `--osd-interval <sec>` | metadata pool OSD interval (default 300) |
| `--discovery-interval <sec>` | how often the active MDS set is re-discovered (default 60) |
| `--max-parallel <n>` | max concurrent ceph calls per stream (default 8) |
| `-f, --fs <name>` | only sample ranks of this filesystem |
| `--tag <name>` | run tag, e.g. before-max-mds-4 |
| `--ssh` | also sample per-thread CPU (`top -b -H`) on the MDS hosts |
| `--daemonperf` | also run `daemonperf` on the MDS hosts (implies `--ssh`) |
| `--plain-ssh` | use the invoking user's ssh identity instead of the cephadm one |
| `--archive` | pack the run directory into a tar.gz on exit (directory kept) |
| `--enable-stats-module` | enable the mgr stats module if it is off (needed for fs perf stats); restored on exit |
| `--no-space-check` | do not estimate the volume / check free space before starting |
| `--force` | start even if the estimate does not fit in `--out-dir` |
| `--stop` / `--status` / `--pack` | stop, inspect or (re)pack the run in `-o` |
| `--run-dir <dir>` | run directory for `--stop`/`--status`/`--pack` |
| `-o, --out-dir <dir>` | base directory for the run (default /var/log/ceph) |
| `-t, --timeout <sec>` | timeout for quick ceph operations |
| `-T, --tell-timeout <sec>` | timeout for ceph tell operations |

## Probe output layout

Data files carry the local date and roll over at midnight. A sample the
probe could not take is recorded as `{"ts","t","mds","rc","error"}`
instead of being dropped, so a gap in a stream is always explained.

```
<run-dir>/run/                        pid, running flag, internal state
<run-dir>/meta/                       run info, fs dump, mds metadata,
                                      effective per-daemon MDS options,
                                      perf schemas, mds set changes,
                                      cluster log, quality report
<run-dir>/fs-perf-stats.<day>.jsonl   per-client workload snapshots
<run-dir>/fs-status.<day>.jsonl       per-rank req/s, cache, standby list
<run-dir>/health.<day>.jsonl          cluster health detail
<run-dir>/perf-<mds>.<day>.jsonl      raw perf counters
<run-dir>/objecter-<mds>.<day>.jsonl  MDS -> OSD requests in flight
<run-dir>/session-<mds>.<day>.jsonl   per-session caps
<run-dir>/loads-<mds>.<day>.jsonl     balancer / subtree load
<run-dir>/mempools-<mds>.<day>.jsonl  cache memory accounting
<run-dir>/cache-<mds>.<day>.log       cache status snapshots
<run-dir>/histops-<mds>.<day>.log     historic ops by duration + ops in
                                      flight (hot-subtree candidates)
<run-dir>/osd-perf-<osd>.<day>.jsonl  metadata pool OSDs, filtered perf
<run-dir>/osd-histops-<osd>.<day>.log metadata pool OSDs, slow ops
<run-dir>/host-<mds>.<day>.log        per-thread CPU on the MDS host (--ssh)
<run-dir>/daemonperf-<mds>.<day>.log  daemonperf on the MDS host
```

`meta/options-<mds>.json` holds the value every option is really running
with on that daemon (`config show-with-defaults`), which a rank level
override or a runtime `config set` makes different from what
`ceph config get mds <opt>` reports.

# fs perf stats in collect

`ceph_diagnostics_collect.sh` also stores a `fs perf stats` snapshot
(`fs_info-perf_stats`, plain + json) for client-level workload analysis
in collected archives.
