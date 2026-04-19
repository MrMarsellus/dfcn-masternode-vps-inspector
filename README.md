# DFCN Masternode VPS Inspector

Diagnostic and monitoring script for DeFCoN masternodes running on VPS hosts. It collects lightweight system, network, service, journal, and RPC data to help analyze the root causes of PoSe bans, DKG/quorum issues, peer problems, clock drift, service instability, and VPS resource bottlenecks.

## One-liner: download & start

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MrMarsellus/dfcn-masternode-vps-inspector/main/dfcn-masternode-vps-inspector.sh)
```

This uses the common “curl + bash” pattern often used for GitHub-hosted shell scripts. Review remote scripts before execution if you have security concerns, or download the file first and inspect it locally.

## Recommended workflow

1. Run **Self test** first to verify required commands, service name, datadir, and CLI path.
2. Run **Instant live analysis now** to get a point-in-time diagnostic snapshot without any prior logging.
3. Start long-term logging with **Start inspection and logging**.
4. Let the script run through at least one problematic cycle, ideally until a PoSe event, quorum issue, or service instability occurs.
5. Use **Stop everything and generate report** to create the final Markdown and text summary.

## Features

- Interactive menu with:
  - Start inspection and logging
  - Stop everything and generate report
  - Instant live analysis now (no prior logging required)
  - Cleanup
  - Config
  - Status
  - Self test
  - Show recommended workflow
- Runs in the background using `nohup`, `nice`, and `ionice`; continues running after SSH/PuTTY is closed.
- Periodic time series logging to `timeseries.csv`:
  - Host metrics: load, CPU usage, RAM, swap, disk usage (root + datadir), lightweight datadir write latency (ms), TCP connections, RX/TX bytes.
  - Process metrics: `defcond` CPU%, memory%, RSS KB, thread count, open file descriptor count.
  - Chain/MN metrics: blocks, headers, verification progress, connections, masternode sync/state.
  - PoSe metrics (optional): PoSe penalty and PoSe ban height via `protx info` when a ProTx hash is configured.
  - Peer quality metrics: total peers, inbound peers, outbound peers, average ping, max ping, high-ping peer count.
  - Time and pressure metrics: NTP offset via `chronyc tracking`, service restart count, PSI CPU/memory/IO pressure values. The `tracking` command is specifically intended to show system clock performance.
- Event sampler for:
  - `getmasternodestatus` / `masternode status`
  - `quorum dkgstatus`
  - `getpeerinfo`
  - `getchaintips`
- LLMQ/DKG statistics:
  - Counts of failed DKGs per quorum type (`LLMQ_50_60`, `LLMQ_60_75`, `LLMQ_100_67`, `LLMQ_400_60`) appended as info alerts.
- Journal follow:
  - `journalctl -f` on the masternode systemd unit with pattern matching for PoSe / DKG / quorum / timeout / fork / disconnect / sync / error / failed messages.
- Alerts and focused PoSe logs:
  - `alerts.csv` containing timestamped entries from systemd, RPC patterns, DKG stats, NTP offset warnings, and OOM/kernel hints.
  - `pose-events.log` with condensed PoSe-related snapshots.
- Instant analysis mode:
  - Works even if no previous logging exists.
  - Creates a point-in-time Markdown report from current service, chain, quorum, peer, time-sync, PSI, and journal state.
- Report generation:
  - Markdown report with a rough risk score based on load, RAM pressure, CPU, header lag, connection count, IO latency, peer quality, NTP drift, service restarts, PSI pressure, and PoSe penalty behavior.
  - Short text summary including tails of `timeseries.csv`, `alerts.csv`, and PoSe-related event snippets.

## Default settings

These defaults can be changed via the interactive config menu or by editing `config.env`:

- Service: `defcond.service`
- CLI: `/usr/local/bin/defcon-cli`
- Daemon: `/usr/local/bin/defcond`
- Datadir: `/home/defcon/.defcon`
- Config: `/home/defcon/.defcon/defcon.conf`
- Interval (metrics): `120` seconds
- Interval (events): `60` seconds
- Log retention: `21` days
- Log level: `basic` (`debug` stores additional peer/quorum samples)
- IO test: enabled by default as a very lightweight datadir write-latency probe

## Generated files

The inspector stores its data under:

```bash
~/.dfcn-masternode-vps-inspector/
```

Main outputs include:

- `logs/timeseries.csv`
- `logs/alerts.csv`
- `logs/events.log`
- `logs/pose-events.log`
- `logs/journal-follow.log`
- `reports/instant-analysis-*.md`
- `reports/report-*.md`
- `reports/summary-*.txt`

## Notes

- The script does **not** modify any DeFCoN configuration and does **not** run aggressive load or stress tests. Its purpose is to observe, not to stress the node or VPS.
- The default intervals were intentionally chosen to be conservative for smaller VPS instances such as 2 vCPU / 4 GB systems.
- For PoSe analysis, it is recommended to:
  - configure your ProTx hash so PoSe penalty and ban height can be tracked over time;
  - let the inspector run across at least one full problematic cycle;
  - correlate PoSe events with peer count/quality, header lag, clock drift, restarts, PSI pressure, and service logs.
- If `chronyc` or `jq` is not installed, the script still works with reduced detail or fallback parsing. The `chronyc` command is the standard CLI for monitoring `chronyd` and inspecting clock tracking state.

## Security note

If you do not want to execute a remote script directly, use this safer review flow instead:

```bash
curl -fsSLO https://raw.githubusercontent.com/MrMarsellus/dfcn-masternode-vps-inspector/main/dfcn-masternode-vps-inspector.sh
less dfcn-masternode-vps-inspector.sh
bash dfcn-masternode-vps-inspector.sh
```

This lets you inspect the script before running it.
