# DFCN Masternode VPS Inspector

Diagnostic and monitoring script for DeFCoN masternodes running on VPS hosts. It collects lightweight system, network, service, journal, and RPC data to help analyze the root causes of PoSe bans, DKG/quorum issues, peer problems, and resource bottlenecks.

## One‑liner: download & start

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MrMarsellus/dfcn-masternode-vps-inspector/main/dfcn-masternode-vps-inspector.sh)
```

This follows the common “curl + bash” pattern used for shell scripts hosted on GitHub. Always review remote scripts before execution if you have any security concerns. [web:102][web:106]

## Features

- Interactive menu with: Start, Stop+Report, Cleanup, Config, Status, and Self‑test.
- Runs in the background using `nohup`, `nice`, and `ionice`; continues running after SSH/PuTTY is closed.
- Periodic time series logging to `timeseries.csv`:
  - Host metrics: load, CPU usage, RAM, swap, disk usage (root + datadir), simple datadir write latency (ms), TCP connections, RX/TX bytes.
  - Process metrics: `defcond` CPU%, memory%, RSS KB, thread count, open file descriptor count.
  - Chain/MN metrics: blocks, headers, verification progress, connections, masternode sync/state.
  - PoSe metrics (optional): PoSe penalty and PoSe ban height via `protx info` (if ProTx hash is configured). [web:78]
- Event sampler for:
  - `getmasternodestatus` / `masternode status`
  - `quorum dkgstatus`
  - `getpeerinfo`
- LLMQ/DKG statistics:
  - Counts of failed DKGs per quorum type (`LLMQ_50_60`, `LLMQ_60_75`, `LLMQ_100_67`, `LLMQ_400_60`) appended as info‑alerts.
- Journal follow:
  - `journalctl -f` on the masternode systemd unit with pattern matching for PoSe / DKG / quorum / timeout / fork / disconnect / sync / error / failed messages.
- Alerts and focused PoSe logs:
  - `alerts.csv` containing timestamped entries from systemd, RPC patterns, and DKG stats.
  - `pose-events.log` with condensed PoSe‑related snapshots (masternode + quorum state around PoSe/ban matches).
- Report generation:
  - Markdown report with a rough risk score based on load, RAM pressure, CPU, header lag, connection count, IO latency, and PoSe penalty behavior.
  - Short text summary including the tail of `timeseries.csv`, `alerts.csv`, and PoSe event snippets.

## Default settings

These defaults can be changed via the interactive config menu or by editing `config.env`:

- Service: `defcond.service`
- CLI: `/usr/local/bin/defcon-cli`
- Daemon: `/usr/local/bin/defcond`
- Datadir: `/home/defcon/.defcon`
- Config: `/home/defcon/.defcon/defcon.conf`
- Interval (metrics): `60` seconds
- Interval (events): `20` seconds
- Log retention: `21` days
- Log level: `basic` (use `debug` for additional peer/quorum samples)

## Notes

- The script does **not** modify any DeFCoN configuration and does **not** run aggressive load or stress tests. Its purpose is to observe, not to put additional load on the node or VPS.
- For PoSe analysis, it is recommended to:
  - Configure your ProTx hash in the inspector so PoSe penalty and ban height can be tracked over time.
  - Let the inspector run across at least one full PoSe ban cycle to see how host metrics and PoSe values correlate.
