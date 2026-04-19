# DFCN Masternode VPS Inspector

Diagnose- und Monitoring-Script für DeFCoN-Masternodes auf VPS-Systemen. Es sammelt ressourcenschonend System-, Netzwerk-, Service-, Journal- und RPC-Daten, um Ursachen für PoSe-Bans, DKG-/Quorum-Probleme, Peer-Probleme und Ressourcenengpässe zu analysieren.

## Einzeiler Download + Start

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MrMarsellus/dfcn-masternode-vps-inspector/main/dfcn-masternode-vps-inspector.sh)
```

## Funktionen

- Menü mit Start, Stop+Report, Cleanup, Status, Selftest.
- Hintergrundbetrieb mit `nohup`, `nice`, `ionice`; läuft weiter nach SSH/PuTTY-Trennung.
- Regelmäßige Zeitreihe mit CPU, RAM, Swap, Load, Disk-Auslastung, Netzwerkbytes, Verbindungen, `defcond`-Ressourcen, FD-Anzahl und Blockchain-/MN-Status.
- Event-Sampler für `getmasternodestatus`, `masternode status`, `quorum dkgstatus`, `getpeerinfo`.
- Journal-Follow mit Pattern-Auswertung für PoSe/DKG/Quorum/Timeout/Fork/Disconnect/Error.
- Report mit grober Risikoeinschätzung und Auffälligkeiten.

## Standardvorgaben

- Service: `defcond.service`
- CLI: `/usr/local/bin/defcon-cli`
- Daemon: `/usr/local/bin/defcond`
- Datadir: `/home/defcon/.defcon`
- Config: `/home/defcon/.defcon/defcon.conf`

## Hinweise

Das Script ändert keine DeFCoN-Konfiguration und führt keine aggressiven Lasttests aus. Es soll beobachten, nicht belasten.
