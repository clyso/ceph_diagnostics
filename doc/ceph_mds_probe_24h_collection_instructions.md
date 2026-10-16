# Ceph MDS Probe — 24-Hour Collection Instructions

*Revised 2026-10-16, for `ceph_mds_probe.sh` as merged in #85.*

The following runs the probe for 24 hours. The amount of data collected depends on the number of
active MDS ranks and client sessions. The probe measures these before starting and prints an
estimate (see step 2).

Run everything as root, on the Cephadm admin host — the host where `cephadm shell` is normally
run.

## 0. Pre-check (~1 second)

The probe talks directly to the MDS daemons, so first make sure this works:

```
ceph tell mds.$(ceph fs dump -f json | jq -r '.filesystems[0].mdsmap.info[].name' | head -1) perf dump | head -3
```

Valid JSON output means the connection works.

## 1. (Recommended) Increase the MDS operation history

This gives us enough samples for hot-directory and subtree analysis. The default value of 20 is
too small.

First record the values currently set, if any, so that step 5 can put them back (an empty value
means the option is not set and the built-in default applies):

```
for o in mds_op_history_size mds_op_history_duration; do
    echo "$o $(ceph config dump -f json |
               jq -r --arg o "$o" '.[] | select(.section == "mds" and .name == $o) | .value')"
done > /root/mds_op_history.saved
cat /root/mds_op_history.saved
```

Then raise them for the duration of the run:

```
ceph config set mds mds_op_history_size 1000
ceph config set mds mds_op_history_duration 3600
```

## 2. Start the probe (24 hours, detached)

```
nohup ./ceph_mds_probe.sh \
    --tag baseline \
    -d 86400 \
    --ssh \
    --enable-stats-module \
    --archive \
    -o /var/log/ceph \
    > /var/log/ceph/mds-probe.out 2>&1 &
```

After about 30 seconds, verify that it actually started:

```
grep -E 'estimated data volume|free space|refusing|WARNING' /var/log/ceph/mds-probe.out
./ceph_mds_probe.sh --status
```

The probe refuses to start if the estimated data volume, archive included, would use more than
80% of the free space in `-o`, or if `-o` already has less than 10% free. In that case, it exits
and records the reason only in `mds-probe.out`.

The output file is deliberately not named `*.log`: the logrotate rule shipped with Ceph rotates
`/var/log/ceph/*.log` daily, and would rename and compress the file while the probe still writes
to it, losing the end of the run's messages.

While it runs, the probe also stops by itself if `-o` drops below 10% free: `/var/log/ceph` often
shares its filesystem with the monitor store, and a monitor stops when that fills up. A run
stopped this way is **not** packed into an archive (see [What to send back](#what-to-send-back)).

### Options and considerations

- `-d 86400` — runs for 24 hours, covering a full business cycle. Most importantly, the
  collection window must include the period when the problem is actually observed.
- `--ssh` — collects per-thread CPU usage from the MDS hosts. This tells us whether an MDS is
  CPU-bound, which is key evidence when evaluating any `max_mds` decision. The probe uses the
  Cephadm SSH identity, which requires a keyring with `mon 'allow *'` (the `client.admin` key has
  this permission). If the Cephadm SSH identity cannot be read, `mds-probe.out` will show a
  `WARNING` and the probe will fall back to your own SSH identity. In that case, your SSH identity
  must be able to reach the MDS hosts directly.
- `--enable-stats-module` — enables the stats module required for filesystem performance
  statistics, including per-client workload data. The previous configuration is restored when the
  probe exits.
- `--archive` — creates a `tar.gz` archive and its corresponding SHA-256 checksum when the run
  completes. This is the default; the option is kept so that the command reads the same with
  older versions of the probe.

Run only one probe per output directory at a time: `--status` and `--stop` act on the most recent
one.

### Session sampling (`-s`)

By default, the probe runs `session ls` on every active MDS every 180 seconds. This is where the
per-client caps data comes from, which we use to size `mds_max_caps_per_client`. The output size
and execution cost of `session ls` grow linearly with the number of sessions:

- Up to a few thousand sessions: keep the default. The cost is negligible.
- Tens of thousands of sessions: use `-s 300`. This reduces the number of calls by 40%, lowering
  both MDS load and data volume. A 24-hour run still provides 288 samples per MDS, so the caps
  analysis retains HIGH confidence, provided the run covers at least 20 hours (240 samples at
  300-second intervals). A run stopped earlier drops to MEDIUM confidence. The only other
  trade-off is that a short-lived caps spike may go undetected for up to ~5 minutes instead of
  ~3 minutes.
- `--skip-sessions` (= `-s 0`) disables session sampling completely. Use this only if
  `session ls` itself is too slow or the MDS is already under significant load. Without session
  data, the caps recommendation will be reported as "cannot assess".

## 3. While the probe is running

Check progress, current size, and per-stream data quality:

```
./ceph_mds_probe.sh --status
```

To stop the probe early:

```
./ceph_mds_probe.sh --stop
```

This performs a graceful stop and still packages the collected data into an archive. If the free
space guard stopped the run, no archive is made; `mds-probe.out` says so.

When the run finishes, check the quality report before handing the cluster back:

```
cat /var/log/ceph/mds-probe-current/meta/quality-report.txt
```

It should report `all streams clean`. If you see `<-- CHECK`, that stream has error records,
unreadable lines, or no data at all. A `WARNING: … less than half the expected samples` line
means a stream was starved. Both are worth investigating while the cluster is still in the same
state.

## 4. Collect a normal diagnostics snapshot

Also collect a standard diagnostics snapshot to provide cluster-wide context:

```
./ceph_diagnostics_collect.sh -d /var/log/ceph
```

## 5. Revert the temporary operation-history settings

After the probe has finished, put back the values recorded in step 1. An option that was not set
before is removed, so that it returns to its built-in default:

```
while read -r o v; do
    if [ -n "$v" ]; then
        ceph config set mds "$o" "$v"
    else
        ceph config rm mds "$o"
    fi
done < /root/mds_op_history.saved
ceph config dump | grep op_history
```

## What to send back

- `mds-probe_baseline_<ts>_XXXXXX.tar.gz`
- the corresponding `.sha256` file
- the diagnostics archive

The exact paths are printed at the end of `mds-probe.out`. We will run the analyzer on our side
and produce a report similar to the one we shared.

If no `.tar.gz` was made (the free space guard stopped the run, or packing failed), run
`./ceph_mds_probe.sh --pack` once there is room in `-o`, or send the run directory
`/var/log/ceph/mds-probe_baseline_<ts>_XXXXXX/` instead, for example packed with `tar` onto a
filesystem that has room.

## After a tuning change

After applying any tuning change, repeat the same 24-hour run with a different tag, for example:

```
--tag after-cap-limit
```

We can then generate a before/after comparison report to quantify the impact of the change.
