# DFCN Masternode VPS Inspector

Diagnostic and monitoring script for DeFCoN masternodes running on VPS hosts. It collects lightweight system, network, service, journal, and RPC data to help analyze the root causes of PoSe bans, DKG/quorum issues, peer problems, and resource bottlenecks. [web:30]

## One‑liner: download & start

bash <(curl -fsSL https://raw.githubusercontent.com/MrMarsellus/dfcn-masternode-vps-inspector/main/dfcn-masternode-vps-inspector.sh)

This follows the common “curl + bash” pattern used for shell scripts hosted on GitHub. [web:30][web:31]

## Features

- Menu with Start, Stop+Report, Cleanup, Status, and Self‑test.
- Runs in the background using `nohup`, `nice`, and `ionice`; continues running after SSH/PuTTY is closed.
- Periodic time series logging of CPU, RAM, swap, load, disk usage, network bytes, connections, `defcond` resource usage, file descriptor count, and blockchain/masternode status.
- Event sampler for `getmasternodestatus`, `masternode status`, `quorum dkgstatus`, and `getpeerinfo`.
- Journal follow with pattern matching for PoSe/DKG/quorum/timeout/fork/disconnect/error events.
- Report generation with a rough risk assessment and a list of notable findings. [web:18][web:22]

## Default settings

- Service: defcond.service
- CLI: /usr/local/bin/defcon-cli
- Daemon: /usr/local/bin/defcond
- Datadir: /home/defcon/.defcon
- Config: /home/defcon/.defcon/defcon.conf

## Notes

The script does not modify any DeFCoN configuration and does not run aggressive load or stress tests. Its purpose is to observe, not to put additional load on the node or VPS. [web:18]
