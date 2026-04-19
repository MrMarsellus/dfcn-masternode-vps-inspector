#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="dfcn-masternode-vps-inspector"
VERSION="0.4.3"
BASE_DIR="${HOME}/.${APP_NAME}"
INSTALL_PATH_DEFAULT="${HOME}/dfcn-masternode-vps-inspector.sh"
LOG_DIR="${BASE_DIR}/logs"
RUN_DIR="${BASE_DIR}/run"
REPORT_DIR="${BASE_DIR}/reports"
CFG_FILE="${BASE_DIR}/config.env"
MONITOR_SCRIPT="${BASE_DIR}/monitor.sh"
ANALYZE_SCRIPT="${BASE_DIR}/analyze.sh"
EVENT_SCRIPT="${BASE_DIR}/event-sampler.sh"
PID_FILE="${RUN_DIR}/monitor.pid"
TAIL_PID_FILE="${RUN_DIR}/journal_tail.pid"
EVENT_PID_FILE="${RUN_DIR}/event_sampler.pid"

SERVICE_NAME_DEFAULT="defcond.service"
CLI_BIN_DEFAULT="/usr/local/bin/defcon-cli"
DAEMON_BIN_DEFAULT="/usr/local/bin/defcond"
DATA_DIR_DEFAULT="/home/defcon/.defcon"
CONF_FILE_DEFAULT="/home/defcon/.defcon/defcon.conf"
NODE_USER_DEFAULT="defcon"
INTERVAL_DEFAULT="120"
EVENT_INTERVAL_DEFAULT="60"
JOURNAL_LINES_DEFAULT="400"
RETENTION_DAYS_DEFAULT="21"
IONICE_CLASS_DEFAULT="3"
NICE_LEVEL_DEFAULT="10"
PEER_SAMPLE_MAXKB_DEFAULT="32"
LOG_LEVEL_DEFAULT="basic"
PROTX_HASH_DEFAULT=""
IO_TEST_ENABLED_DEFAULT="1"

print_line() {
  echo "------------------------------------------------------------"
}

umask 077
mkdir -p "$BASE_DIR" "$LOG_DIR" "$RUN_DIR" "$REPORT_DIR"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn(){ printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*" >&2; }
err(){ printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; }
require_cmd(){ command -v "$1" >/dev/null 2>&1 || { err "Required command missing: $1"; exit 1; }; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }
press_enter(){ read -r -p "Press Enter to continue..." _ || true; }
ask_yes_no(){ local prompt="$1" default="${2:-y}" ans; if [ "$default" = "y" ]; then read -r -p "$prompt [Y/n]: " ans || true; ans="${ans:-y}"; else read -r -p "$prompt [y/N]: " ans || true; ans="${ans:-n}"; fi; case "$ans" in y|Y|yes|YES) return 0;; *) return 1;; esac; }
post_action_menu_prompt(){ ask_yes_no "Return to main menu?" y; }
show_file(){
  local f="$1"
  [ -f "$f" ] || { warn "File not found: $f"; return 1; }
  echo
  print_line
  print_line
  echo "Report viewer hint: Use the arrow keys to scroll. Press q to close the view."
  print_line
  print_line
  echo
  if have_cmd less; then
    less "$f"
  else
    cat "$f"
  fi
}

write_default_config(){
cat > "$CFG_FILE" <<EOF2
SERVICE_NAME="${SERVICE_NAME_DEFAULT}"
CLI_BIN="${CLI_BIN_DEFAULT}"
DAEMON_BIN="${DAEMON_BIN_DEFAULT}"
DATA_DIR="${DATA_DIR_DEFAULT}"
CONF_FILE="${CONF_FILE_DEFAULT}"
NODE_USER="${NODE_USER_DEFAULT}"
INTERVAL="${INTERVAL_DEFAULT}"
EVENT_INTERVAL="${EVENT_INTERVAL_DEFAULT}"
JOURNAL_LINES="${JOURNAL_LINES_DEFAULT}"
RETENTION_DAYS="${RETENTION_DAYS_DEFAULT}"
IONICE_CLASS="${IONICE_CLASS_DEFAULT}"
NICE_LEVEL="${NICE_LEVEL_DEFAULT}"
PEER_SAMPLE_MAXKB="${PEER_SAMPLE_MAXKB_DEFAULT}"
LOG_LEVEL="${LOG_LEVEL_DEFAULT}"
PROTX_HASH="${PROTX_HASH_DEFAULT}"
IO_TEST_ENABLED="${IO_TEST_ENABLED_DEFAULT}"
EOF2
}

load_config(){
  [ -f "$CFG_FILE" ] || write_default_config
  # shellcheck disable=SC1090
  source "$CFG_FILE"
}

prompt_default(){
  local label="$1" default="$2" value
  read -r -p "$label [$default]: " value || true
  if [ -z "${value:-}" ]; then printf '%s' "$default"; else printf '%s' "$value"; fi
}

setup_config_interactive(){
  load_config
  echo
  echo "Review / adjust configuration"
  echo "Press Enter to keep the current value shown in brackets."
  echo
  SERVICE_NAME="$(prompt_default 'Systemd service name' "$SERVICE_NAME")"
  CLI_BIN="$(prompt_default 'Path to defcon-cli' "$CLI_BIN")"
  DAEMON_BIN="$(prompt_default 'Path to defcond' "$DAEMON_BIN")"
  DATA_DIR="$(prompt_default 'Data directory' "$DATA_DIR")"
  CONF_FILE="$(prompt_default 'Path to defcon.conf' "$CONF_FILE")"
  NODE_USER="$(prompt_default 'Node Linux user' "$NODE_USER")"
  INTERVAL="$(prompt_default 'Metric interval in seconds' "$INTERVAL")"
  EVENT_INTERVAL="$(prompt_default 'Event interval in seconds' "$EVENT_INTERVAL")"
  JOURNAL_LINES="$(prompt_default 'Initial journal lines' "$JOURNAL_LINES")"
  RETENTION_DAYS="$(prompt_default 'Log retention days' "$RETENTION_DAYS")"
  PEER_SAMPLE_MAXKB="$(prompt_default 'Max KB per peer sample (debug)' "$PEER_SAMPLE_MAXKB")"
  LOG_LEVEL="$(prompt_default 'Log level (basic|debug)' "$LOG_LEVEL")"
  PROTX_HASH="$(prompt_default 'ProTx hash for PoSe (optional)' "$PROTX_HASH")"
  IO_TEST_ENABLED="$(prompt_default 'Enable lightweight IO latency test? (0/1)' "${IO_TEST_ENABLED:-$IO_TEST_ENABLED_DEFAULT}")"
  cat > "$CFG_FILE" <<EOF2
SERVICE_NAME="$SERVICE_NAME"
CLI_BIN="$CLI_BIN"
DAEMON_BIN="$DAEMON_BIN"
DATA_DIR="$DATA_DIR"
CONF_FILE="$CONF_FILE"
NODE_USER="$NODE_USER"
INTERVAL="$INTERVAL"
EVENT_INTERVAL="$EVENT_INTERVAL"
JOURNAL_LINES="$JOURNAL_LINES"
RETENTION_DAYS="$RETENTION_DAYS"
IONICE_CLASS="$IONICE_CLASS"
NICE_LEVEL="$NICE_LEVEL"
PEER_SAMPLE_MAXKB="$PEER_SAMPLE_MAXKB"
LOG_LEVEL="$LOG_LEVEL"
PROTX_HASH="$PROTX_HASH"
IO_TEST_ENABLED="$IO_TEST_ENABLED"
EOF2
  echo "Configuration saved to $CFG_FILE"
}

redact_conf(){ sed -E 's/(rpcpassword=).+/\1***REDACTED***/; s/(masternodeblsprivkey=).+/\1***REDACTED***/; s/(rpcuser=).+/\1***REDACTED***/; s/(externalip=).+/\1***REDACTED***/'; }

system_snapshot(){ local out="$1"; { echo "===== BASIC ====="; date -Is; hostnamectl 2>/dev/null || true; uname -a; uptime; echo; echo "===== CPU ====="; lscpu 2>/dev/null || cat /proc/cpuinfo; echo; echo "===== MEMORY ====="; free -h; grep -E 'MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree|Dirty|Writeback' /proc/meminfo || true; echo; echo "===== STORAGE ====="; df -hT; lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,ROTA,MODEL 2>/dev/null || true; echo; echo "===== DISKSTATS ====="; tail -n 20 /proc/diskstats; echo; echo "===== NETWORK ====="; ip -brief addr 2>/dev/null || ip addr || true; ip route || true; ss -tulpn || true; echo; echo "===== TIME SYNC ====="; timedatectl 2>/dev/null || true; chronyc tracking 2>/dev/null || true; chronyc sources -v 2>/dev/null || true; echo; echo "===== PRESSURE STALL INFO ====="; for f in /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io; do [ -r "$f" ] && echo "--- $f ---" && cat "$f"; done; echo; echo "===== SYSCTL FOCUS ====="; sysctl vm.swappiness vm.dirty_ratio vm.dirty_background_ratio net.core.somaxconn net.ipv4.tcp_syn_retries 2>/dev/null || true; echo; echo "===== LIMITS ====="; ulimit -a; echo; echo "===== SERVICE ====="; systemctl status "$SERVICE_NAME" --no-pager || true; systemctl cat "$SERVICE_NAME" || true; systemctl show "$SERVICE_NAME" -p NRestarts -p ExecMainPID -p ExecMainStatus -p ExecMainStartTimestampMonotonic -p ActiveEnterTimestamp --no-pager 2>/dev/null || true; echo; echo "===== PROCESS ====="; ps -eo user,pid,ppid,%cpu,%mem,rss,vsz,etimes,stat,comm,args | grep -E 'defcond|defcon-cli|^USER' || true; echo; echo "===== KERNEL / OOM HINTS ====="; dmesg -T 2>/dev/null | grep -iE 'out of memory|oom|killed process' | tail -n 50 || true; echo; echo "===== CONFIG FILES ====="; [ -f "$CONF_FILE" ] && redact_conf < "$CONF_FILE" || true; echo; [ -d "$DATA_DIR" ] && find "$DATA_DIR" -maxdepth 2 -type f | sort || true; echo; echo "===== JOURNAL TAIL ====="; journalctl -u "$SERVICE_NAME" -n "$JOURNAL_LINES" --no-pager || true; } > "$out" 2>&1; }

collect_cli_snapshot(){ local out="$1"; { echo "===== CLI SNAPSHOT ====="; if [ -x "$CLI_BIN" ]; then timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getblockchaininfo 2>&1 || true; echo; timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getnetworkinfo 2>&1 || true; echo; timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getpeerinfo 2>&1 || true; echo; timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getchaintips 2>&1 || true; echo; timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getbestblockhash 2>&1 || true; echo; timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getmasternodestatus 2>&1 || true; echo; timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" masternode status 2>&1 || true; echo; timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" protx list valid 1 2>&1 || true; echo; if [ -n "${PROTX_HASH:-}" ]; then timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" protx info "$PROTX_HASH" 2>&1 || true; echo; fi; timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum list 2>&1 || true; echo; timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum dkgstatus 2>&1 || true; echo; timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum memberof 2>&1 || true; else echo "CLI not found: $CLI_BIN"; fi; } > "$out" 2>&1; }

write_monitor_script(){
cat > "$MONITOR_SCRIPT" <<'EOF2'
#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR="${HOME}/.dfcn-masternode-vps-inspector"
LOG_DIR="${BASE_DIR}/logs"
RUN_DIR="${BASE_DIR}/run"
CFG_FILE="${BASE_DIR}/config.env"
mkdir -p "$LOG_DIR" "$RUN_DIR"
source "$CFG_FILE"
have_cmd(){ command -v "$1" >/dev/null 2>&1; }
exec 9>"${RUN_DIR}/monitor.lock"
flock -n 9 || { echo "monitor already running"; exit 1; }
echo $$ > "${RUN_DIR}/monitor.pid"
TS_CSV="${LOG_DIR}/timeseries.csv"
PEER_LOG="${LOG_DIR}/peer-samples.log"
QUORUM_LOG="${LOG_DIR}/quorum-samples.log"
HEADER="timestamp,load1,load5,load15,cpu_user,cpu_system,cpu_idle,mem_total_kb,mem_avail_kb,swap_total_kb,swap_free_kb,root_use_pct,datadir_use_pct,rx_bytes,tx_bytes,established_conns,defcond_cpu_pct,defcond_mem_pct,defcond_rss_kb,defcond_threads,defcond_fd_count,io_ms,chain_blocks,headers,verificationprogress,connections,mn_synced,mn_state,pose_penalty,pose_banheight,peer_total,peer_inbound,peer_outbound,peer_ping_avg_ms,peer_ping_max_ms,peer_high_ping_count,ntp_offset_ms,service_restarts,psi_cpu_some_avg10,psi_mem_some_avg10,psi_io_some_avg10"
[ -f "$TS_CSV" ] || echo "$HEADER" > "$TS_CSV"
trap 'rm -f "${RUN_DIR}/monitor.pid"' EXIT
get_cpu(){ awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9,$10}' /proc/stat; }
peer_summary_with_jq(){ jq -r '[length,map(select(.inbound==true))|length,map(select(.inbound==false))|length,(map(select(.pingtime!=null)|.pingtime) | if length>0 then ((add/length)*1000) else null end),(map(select(.pingtime!=null)|.pingtime) | if length>0 then (max*1000) else null end),(map(select(.pingtime!=null and .pingtime>0.8))|length)] | @tsv' 2>/dev/null; }
peer_summary_plain(){ local blob="$1" total inbound outbound avg max high; total=$(printf '%s' "$blob" | awk 'BEGIN{RS="{";c=0} /"addr"[[:space:]]*:/{c++} END{print c+0}'); inbound=$(printf '%s' "$blob" | awk 'BEGIN{RS="{";c=0} /"addr"[[:space:]]*:/ && /"inbound"[[:space:]]*:[[:space:]]*true/{c++} END{print c+0}'); outbound=$(printf '%s' "$blob" | awk 'BEGIN{RS="{";c=0} /"addr"[[:space:]]*:/ && /"inbound"[[:space:]]*:[[:space:]]*false/{c++} END{print c+0}'); avg=$(printf '%s' "$blob" | awk 'BEGIN{RS="{"} /"pingtime"[[:space:]]*:/{for(i=1;i<=NF;i++) if($i ~ /"pingtime"/) {v=$(i+1); gsub(/[,:}]/,"",v); if(v!=""){sum+=v;n++}}} END{if(n>0) printf "%.2f", (sum*1000/n); else printf ""}'); max=$(printf '%s' "$blob" | awk 'BEGIN{RS="{"} /"pingtime"[[:space:]]*:/{for(i=1;i<=NF;i++) if($i ~ /"pingtime"/) {v=$(i+1); gsub(/[,:}]/,"",v); if(v!="" && v>m)m=v}} END{if(m>0) printf "%.2f", (m*1000); else printf ""}'); high=$(printf '%s' "$blob" | awk 'BEGIN{RS="{";c=0} /"pingtime"[[:space:]]*:/{for(i=1;i<=NF;i++) if($i ~ /"pingtime"/) {v=$(i+1); gsub(/[,:}]/,"",v); if(v!="" && v+0>0.8)c++}} END{print c+0}'); printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$total" "$inbound" "$outbound" "$avg" "$max" "$high"; }
psi_avg10(){ awk -F'[ =]' '/some/ {for(i=1;i<=NF;i++) if($i=="avg10") print $(i+1)}' "$1" 2>/dev/null | head -n1; }
read -r u1 n1 s1 i1 w1 irq1 sirq1 st1 g1 < <(get_cpu); sleep 1; read -r u2 n2 s2 i2 w2 irq2 sirq2 st2 g2 < <(get_cpu)
while true; do
  ts="$(date '+%F %T')"; read -r load1 load5 load15 _ < /proc/loadavg
  total1=$((u1+n1+s1+i1+w1+irq1+sirq1+st1+g1)); total2=$((u2+n2+s2+i2+w2+irq2+sirq2+st2+g2)); idle1=$((i1+w1)); idle2=$((i2+w2)); dt=$((total2-total1)); di=$((idle2-idle1)); den=$((dt==0?1:dt))
  cpu_idle=$((100*di/den)); cpu_user=$((100*((u2-u1)+(n2-n1))/den)); cpu_system=$((100*((s2-s1)+(irq2-irq1)+(sirq2-sirq1))/den))
  read -r u1 n1 s1 i1 w1 irq1 sirq1 st1 g1 <<< "$u2 $n2 $s2 $i2 $w2 $irq2 $sirq2 $st2 $g2"; sleep 1; read -r u2 n2 s2 i2 w2 irq2 sirq2 st2 g2 < <(get_cpu)
  mem_total=$(awk '/MemTotal:/{print $2}' /proc/meminfo); mem_avail=$(awk '/MemAvailable:/{print $2}' /proc/meminfo); swap_total=$(awk '/SwapTotal:/{print $2}' /proc/meminfo); swap_free=$(awk '/SwapFree:/{print $2}' /proc/meminfo)
  root_use=$(df -P / | awk 'NR==2{gsub(/%/,"",$5);print $5}'); datadir_use=$(df -P "$DATA_DIR" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5);print $5}'); [ -z "$datadir_use" ] && datadir_use="$root_use"
  iface=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'); rx_bytes=0; tx_bytes=0; if [ -n "${iface:-}" ] && [ -r "/sys/class/net/$iface/statistics/rx_bytes" ]; then rx_bytes=$(cat "/sys/class/net/$iface/statistics/rx_bytes"); tx_bytes=$(cat "/sys/class/net/$iface/statistics/tx_bytes"); fi
  established=$(ss -tan 2>/dev/null | awk 'NR>1 && $1=="ESTAB"{c++} END{print c+0}')
  proc_line=$(ps -C "$(basename "$DAEMON_BIN")" -o pid=,%cpu=,%mem=,rss=,nlwp= 2>/dev/null | head -n1 | xargs); defcond_pid=""; defcond_cpu=0; defcond_mem=0; defcond_rss=0; defcond_threads=0; defcond_fd_count=0
  if [ -n "$proc_line" ]; then read -r defcond_pid defcond_cpu defcond_mem defcond_rss defcond_threads <<< "$proc_line"; [ -d "/proc/$defcond_pid/fd" ] && defcond_fd_count=$(find "/proc/$defcond_pid/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l); fi
  io_ms=""; if [ "${IO_TEST_ENABLED:-1}" = "1" ] && [ -w "$DATA_DIR" ]; then io_test_file="$DATA_DIR/.dfcn_io_test"; start_ns=$(date +%s%N); printf 'x' > "$io_test_file" 2>/dev/null || true; end_ns=$(date +%s%N); delta_ns=$((end_ns-start_ns)); io_ms=$((delta_ns/1000000)); rm -f "$io_test_file" 2>/dev/null || true; fi
  chain_blocks=""; headers=""; verificationprogress=""; connections=""; mn_synced=""; mn_state=""; pose_penalty=""; pose_banheight=""; peer_total=""; peer_inbound=""; peer_outbound=""; peer_ping_avg_ms=""; peer_ping_max_ms=""; peer_high_ping_count=""; ntp_offset_ms=""; service_restarts=""; psi_cpu_some_avg10=""; psi_mem_some_avg10=""; psi_io_some_avg10=""
  psi_cpu_some_avg10=$(psi_avg10 /proc/pressure/cpu); psi_mem_some_avg10=$(psi_avg10 /proc/pressure/memory); psi_io_some_avg10=$(psi_avg10 /proc/pressure/io); service_restarts=$(systemctl show "$SERVICE_NAME" -p NRestarts --value 2>/dev/null || true)
  if have_cmd chronyc; then ntp_offset_ms=$(chronyc tracking 2>/dev/null | awk -F':' '/System time/{gsub(/^[[:space:]]+| seconds.*/,"",$2); print ($2*1000)}' | head -n1); fi
  if [ -x "$CLI_BIN" ]; then
    info=$(timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getblockchaininfo 2>/dev/null || true); net=$(timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getnetworkinfo 2>/dev/null || true); mn=$(timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getmasternodestatus 2>/dev/null || timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" masternode status 2>/dev/null || true); peers_json=$(timeout 30 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getpeerinfo 2>/dev/null || true)
    chain_blocks=$(printf '%s' "$info" | sed -n 's/.*"blocks"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n1); headers=$(printf '%s' "$info" | sed -n 's/.*"headers"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n1); verificationprogress=$(printf '%s' "$info" | sed -n 's/.*"verificationprogress"[[:space:]]*:[[:space:]]*\([0-9.]*\).*/\1/p' | head -n1); connections=$(printf '%s' "$net" | sed -n 's/.*"connections"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n1); mn_synced=$(printf '%s' "$mn" | sed -n 's/.*"IsSynced"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/p' | tr -d ' ' | head -n1); mn_state=$(printf '%s' "$mn" | sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1); [ -z "$mn_state" ] && mn_state=$(printf '%s' "$mn" | tr '\n' ' ' | sed 's/,/;/g; s/"//g' | cut -c1-220)
    if [ -n "${PROTX_HASH:-}" ]; then protx_info=$(timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" protx info "$PROTX_HASH" 2>/dev/null || true); pose_penalty=$(printf '%s' "$protx_info" | sed -n 's/.*"PoSePenalty"[[:space:]]*:[[:space:]]*\([0-9-]*\).*/\1/p' | head -n1); pose_banheight=$(printf '%s' "$protx_info" | sed -n 's/.*"PoSeBanHeight"[[:space:]]*:[[:space:]]*\([0-9-]*\).*/\1/p' | head -n1); fi
    if have_cmd jq; then read -r peer_total peer_inbound peer_outbound peer_ping_avg_ms peer_ping_max_ms peer_high_ping_count <<< "$(printf '%s' "$peers_json" | peer_summary_with_jq | tr '\t' ' ')"; else read -r peer_total peer_inbound peer_outbound peer_ping_avg_ms peer_ping_max_ms peer_high_ping_count <<< "$(peer_summary_plain "$peers_json" | tr '\t' ' ')"; fi
    if [ "${LOG_LEVEL:-basic}" = "debug" ]; then printf '%s | getpeerinfo\n' "$ts" >> "$PEER_LOG"; printf '%s' "$peers_json" | head -c "$((PEER_SAMPLE_MAXKB*1024))" >> "$PEER_LOG" || true; printf '\n\n' >> "$PEER_LOG"; printf '%s | quorum dkgstatus\n' "$ts" >> "$QUORUM_LOG"; timeout 30 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum dkgstatus 2>/dev/null >> "$QUORUM_LOG" || true; printf '\n\n' >> "$QUORUM_LOG"; fi
  fi
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$ts" "$load1" "$load5" "$load15" "$cpu_user" "$cpu_system" "$cpu_idle" "$mem_total" "$mem_avail" "$swap_total" "$swap_free" "$root_use" "$datadir_use" "$rx_bytes" "$tx_bytes" "$established" "$defcond_cpu" "$defcond_mem" "$defcond_rss" "$defcond_threads" "$defcond_fd_count" "${io_ms:-}" "${chain_blocks:-}" "${headers:-}" "${verificationprogress:-}" "${connections:-}" "${mn_synced:-}" "${mn_state:-}" "${pose_penalty:-}" "${pose_banheight:-}" "${peer_total:-}" "${peer_inbound:-}" "${peer_outbound:-}" "${peer_ping_avg_ms:-}" "${peer_ping_max_ms:-}" "${peer_high_ping_count:-}" "${ntp_offset_ms:-}" "${service_restarts:-}" "${psi_cpu_some_avg10:-}" "${psi_mem_some_avg10:-}" "${psi_io_some_avg10:-}" >> "$TS_CSV"
  find "$LOG_DIR" -type f -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true; sleep "$INTERVAL"
done
EOF2
chmod +x "$MONITOR_SCRIPT"
}

write_event_sampler(){
cat > "$EVENT_SCRIPT" <<'EOF2'
#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR="${HOME}/.dfcn-masternode-vps-inspector"
LOG_DIR="${BASE_DIR}/logs"
RUN_DIR="${BASE_DIR}/run"
CFG_FILE="${BASE_DIR}/config.env"
source "$CFG_FILE"
have_cmd(){ command -v "$1" >/dev/null 2>&1; }
echo $$ > "${RUN_DIR}/event_sampler.pid"
EVENT_LOG="${LOG_DIR}/events.log"
POSE_LOG="${LOG_DIR}/pose-events.log"
ALERTS_CSV="${LOG_DIR}/alerts.csv"
[ -f "$ALERTS_CSV" ] || echo 'timestamp,severity,source,pattern,details' > "$ALERTS_CSV"
trap 'rm -f "${RUN_DIR}/event_sampler.pid"' EXIT
while true; do
  ts="$(date '+%F %T')"; svc=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true); [ "$svc" != "active" ] && printf '%s,HIGH,systemd,service_inactive,%s\n' "$ts" "$svc" >> "$ALERTS_CSV"
  restarts=$(systemctl show "$SERVICE_NAME" -p NRestarts --value 2>/dev/null || true); [ -n "$restarts" ] && [ "$restarts" -gt 0 ] 2>/dev/null && printf '%s,INFO,systemd,restarts,%s\n' "$ts" "$restarts" >> "$ALERTS_CSV"
  if [ -x "$CLI_BIN" ]; then
    mn=$(timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getmasternodestatus 2>/dev/null || timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" masternode status 2>/dev/null || true)
    quorum=$(timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum dkgstatus 2>/dev/null || true)
    peers=$(timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getpeerinfo 2>/dev/null || true)
    tips=$(timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getchaintips 2>/dev/null || true)
    printf '===== %s =====\n[Masternode]\n%s\n\n[Quorum]\n%s\n\n[ChainTips]\n%s\n\n' "$ts" "$mn" "$quorum" "$tips" >> "$EVENT_LOG"
    blob="$(printf '%s\n%s\n%s\n%s' "$mn" "$quorum" "$peers" "$tips")"
    for item in 'LLMQ_50_60' 'LLMQ_60_75' 'LLMQ_100_67' 'LLMQ_400_60'; do c=$(printf '%s' "$quorum" | grep -c "$item.*\"failed\": true"); [ "$c" -gt 0 ] && printf '%s,INFO,dkgstats,%s_fail,%s\n' "$ts" "$item" "$c" >> "$ALERTS_CSV"; done
    for pat in 'pose' 'banned' 'timeout' 'quorum' 'not capable' 'watchdog' 'misbehav' 'fork' 'headers' 'invalid' 'error' 'failed'; do if printf '%s' "$blob" | grep -qi "$pat"; then printf '%s,MEDIUM,rpc,%s,%s\n' "$ts" "$pat" "match found" >> "$ALERTS_CSV"; fi; done
    if printf '%s' "$blob" | grep -qiE 'pose|banned'; then printf '===== %s =====\n%s\n\n%s\n\n%s\n\n' "$ts" "$mn" "$quorum" "$tips" >> "$POSE_LOG"; fi
  fi
  if have_cmd chronyc; then chronyc tracking 2>/dev/null | awk -v ts="$ts" -F':' '/System time/ {gsub(/^[[:space:]]+| seconds.*/,"",$2); v=$2*1000; if (v>200 || v<-200) printf "%s,MEDIUM,ntp,offset_ms,%s\n", ts, v }' >> "$ALERTS_CSV" || true; fi
  dmesg -T 2>/dev/null | grep -iE 'out of memory|oom|killed process' | tail -n 1 | awk -v ts="$ts" 'NF{printf "%s,HIGH,kernel,oom,%s\n", ts, $0}' >> "$ALERTS_CSV" || true
  sleep "$EVENT_INTERVAL"
done
EOF2
chmod +x "$EVENT_SCRIPT"
}

start_journal_follow(){ load_config; if [ -f "$TAIL_PID_FILE" ] && kill -0 "$(cat "$TAIL_PID_FILE")" 2>/dev/null; then return 0; fi; nohup bash -c "journalctl -u '$SERVICE_NAME' -f -o short-iso >> '$LOG_DIR/journal-follow.log' 2>&1" >/dev/null 2>&1 & echo $! > "$TAIL_PID_FILE"; }
start_event_sampler(){ write_event_sampler; if [ -f "$EVENT_PID_FILE" ] && kill -0 "$(cat "$EVENT_PID_FILE")" 2>/dev/null; then return 0; fi; nohup ionice -c "$IONICE_CLASS" nice -n "$NICE_LEVEL" "$EVENT_SCRIPT" >> "$LOG_DIR/event-sampler-stdout.log" 2>&1 & sleep 1; }

start_monitor(){ load_config; for c in systemctl journalctl ps ss awk sed grep timeout date df free ip nohup find flock; do require_cmd "$c"; done; [ -x "$CLI_BIN" ] || warn "CLI not found or not executable: $CLI_BIN"; write_monitor_script; system_snapshot "$LOG_DIR/system-snapshot-$(date '+%F-%H%M%S').txt"; collect_cli_snapshot "$LOG_DIR/cli-snapshot-$(date '+%F-%H%M%S').txt"; if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then warn "Monitor already running with PID $(cat "$PID_FILE")"; else nohup ionice -c "$IONICE_CLASS" nice -n "$NICE_LEVEL" "$MONITOR_SCRIPT" >> "$LOG_DIR/monitor-stdout.log" 2>&1 & sleep 1; fi; start_journal_follow; start_event_sampler; log "Inspector started. Logs: $LOG_DIR"; echo "Recommended next steps: menu 6 (status), later menu 2 (stop + report)."; }
stop_monitor(){ local any=0; for f in "$PID_FILE" "$TAIL_PID_FILE" "$EVENT_PID_FILE"; do if [ -f "$f" ] && kill -0 "$(cat "$f")" 2>/dev/null; then any=1; kill "$(cat "$f")" || true; sleep 1; kill -9 "$(cat "$f")" 2>/dev/null || true; rm -f "$f"; fi; done; if [ "$any" -eq 1 ]; then log "All background processes stopped"; else log "No running background processes found"; fi; }

write_instant_analysis(){
  load_config
  local out="$1"
  {
    echo "# Instant analysis"; echo; echo "Generated: $(date -Is)"; echo; echo "## Quick verdict"; echo "This instant analysis works even if long-term logging has never been started. It is a point-in-time diagnostic snapshot only."; echo; echo "## Service"; systemctl is-active "$SERVICE_NAME" 2>/dev/null || true; systemctl show "$SERVICE_NAME" -p NRestarts -p ExecMainPID -p ExecMainStatus --no-pager 2>/dev/null || true; echo; echo "## Time sync"; timedatectl 2>/dev/null || true; chronyc tracking 2>/dev/null || true; chronyc sources -v 2>/dev/null || true; echo; echo "## Pressure stall"; for f in /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io; do [ -r "$f" ] && echo "--- $f ---" && cat "$f"; done; echo; echo "## OOM / kernel hints"; dmesg -T 2>/dev/null | grep -iE 'out of memory|oom|killed process' | tail -n 30 || true; echo; echo "## Chain / masternode / quorum"; if [ -x "$CLI_BIN" ]; then timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getblockchaininfo 2>&1 || true; echo; timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getnetworkinfo 2>&1 || true; echo; timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getchaintips 2>&1 || true; echo; timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getmasternodestatus 2>&1 || timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" masternode status 2>&1 || true; echo; timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum dkgstatus 2>&1 || true; echo; if [ -n "${PROTX_HASH:-}" ]; then timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" protx info "$PROTX_HASH" 2>&1 || true; fi; echo; echo "## Peer summary"; peers=$(timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getpeerinfo 2>/dev/null || true); if have_cmd jq; then printf '%s' "$peers" | jq -r '{total:length,inbound:(map(select(.inbound==true))|length),outbound:(map(select(.inbound==false))|length),avg_ping_ms:(map(select(.pingtime!=null)|.pingtime)|if length>0 then ((add/length)*1000) else null end),max_ping_ms:(map(select(.pingtime!=null)|.pingtime)|if length>0 then (max*1000) else null end),high_ping_count_gt_800ms:(map(select(.pingtime!=null and .pingtime>0.8))|length)}'; else printf 'total=%s\n' "$(printf '%s' "$peers" | awk 'BEGIN{RS="{";c=0} /"addr"[[:space:]]*:/{c++} END{print c+0}')"; printf 'inbound=%s\n' "$(printf '%s' "$peers" | awk 'BEGIN{RS="{";c=0} /"addr"[[:space:]]*:/ && /"inbound"[[:space:]]*:[[:space:]]*true/{c++} END{print c+0}')"; printf 'outbound=%s\n' "$(printf '%s' "$peers" | awk 'BEGIN{RS="{";c=0} /"addr"[[:space:]]*:/ && /"inbound"[[:space:]]*:[[:space:]]*false/{c++} END{print c+0}')"; fi; else echo "CLI not found: $CLI_BIN"; fi; echo; echo "## Journal tail"; journalctl -u "$SERVICE_NAME" -n "$JOURNAL_LINES" --no-pager 2>/dev/null || true;
  } > "$out" 2>&1
}

write_analyze_script(){
cat > "$ANALYZE_SCRIPT" <<'EOF2'
#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR="${HOME}/.dfcn-masternode-vps-inspector"
LOG_DIR="${BASE_DIR}/logs"
REPORT_DIR="${BASE_DIR}/reports"
mkdir -p "$REPORT_DIR"
TS_CSV="${LOG_DIR}/timeseries.csv"
ALERTS_CSV="${LOG_DIR}/alerts.csv"
REPORT_MD="${REPORT_DIR}/report-$(date '+%F-%H%M%S').md"
REPORT_TXT="${REPORT_DIR}/summary-$(date '+%F-%H%M%S').txt"
score=0
score_line(){ score=$((score+$1)); }
get_idx(){ awk -F',' -v name="$1" 'NR==1{for(i=1;i<=NF;i++) if($i==name){print i; exit}}' "$TS_CSV"; }
{
  echo "# DFCN Masternode VPS Inspector Report"; echo; echo "Generated: $(date -Is)"; echo; echo "## Summary"
  if [ -f "$TS_CSV" ]; then
    total_samples=$(($(wc -l < "$TS_CSV")-1)); echo "- Samples: $total_samples"
    idx_load1=$(get_idx load1); idx_mem_avail=$(get_idx mem_avail_kb); idx_defcpu=$(get_idx defcond_cpu_pct); idx_defmem=$(get_idx defcond_mem_pct); idx_fd=$(get_idx defcond_fd_count); idx_io=$(get_idx io_ms); idx_conn=$(get_idx connections); idx_blocks=$(get_idx chain_blocks); idx_headers=$(get_idx headers); idx_highping=$(get_idx peer_high_ping_count); idx_ntp=$(get_idx ntp_offset_ms); idx_restarts=$(get_idx service_restarts); idx_psi_mem=$(get_idx psi_mem_some_avg10); idx_pose=$(get_idx pose_penalty)
    max_load=$(awk -F',' -v c="$idx_load1" 'NR>1 && c>0{if($c>m)m=$c} END{print m+0}' "$TS_CSV"); min_mem=$(awk -F',' -v c="$idx_mem_avail" 'NR>1 && c>0{if(min==""||$c<min)min=$c} END{print min+0}' "$TS_CSV"); max_cpu=$(awk -F',' -v c="$idx_defcpu" 'NR>1 && c>0{if($c>m)m=$c} END{print m+0}' "$TS_CSV"); max_mem=$(awk -F',' -v c="$idx_defmem" 'NR>1 && c>0{if($c>m)m=$c} END{print m+0}' "$TS_CSV"); max_fd=$(awk -F',' -v c="$idx_fd" 'NR>1 && c>0{if($c>m)m=$c} END{print m+0}' "$TS_CSV"); max_io=$(awk -F',' -v c="$idx_io" 'NR>1 && c>0{if($c>m)m=$c} END{print m+0}' "$TS_CSV")
    low_conn=$(awk -F',' -v c="$idx_conn" 'NR>1 && c>0 && ($c=="" || $c+0<3){d++} END{print d+0}' "$TS_CSV"); lagging=$(awk -F',' -v b="$idx_blocks" -v h="$idx_headers" 'NR>1 && b>0 && h>0 && $b!="" && $h!="" && ($h-$b)>3 {d++} END{print d+0}' "$TS_CSV"); high_ping=$(awk -F',' -v c="$idx_highping" 'NR>1 && c>0 && $c!="" && $c+0>0 {d++} END{print d+0}' "$TS_CSV"); ntp_bad=$(awk -F',' -v c="$idx_ntp" 'NR>1 && c>0 && $c!="" && ($c+0>200 || $c+0<-200) {d++} END{print d+0}' "$TS_CSV"); psi_mem_bad=$(awk -F',' -v c="$idx_psi_mem" 'NR>1 && c>0 && $c!="" && $c+0>1 {d++} END{print d+0}' "$TS_CSV"); restart_samples=$(awk -F',' -v c="$idx_restarts" 'NR>1 && c>0 && $c!="" && $c+0>0 {d++} END{print d+0}' "$TS_CSV"); pose_load=$(awk -F',' -v c1="$idx_load1" -v cp="$idx_pose" 'NR>1 && c1>0 && cp>0 && $cp!="" {if($c1>2.0 && $cp+0>0) d++} END{print d+0}' "$TS_CSV"); pose_jumps=$(awk -F',' -v cp="$idx_pose" 'NR>1 && cp>0 {if(prev!="" && $cp>prev+5) d++; prev=$cp} END{print d+0}' "$TS_CSV")
    echo "- Max load1: $max_load"; echo "- Max defcond CPU %: $max_cpu"; echo "- Max defcond MEM %: $max_mem"; echo "- Max open file descriptors: $max_fd"; echo "- Max IO latency ms (datadir): $max_io"; echo "- Min MemAvailable KB: $min_mem"; echo "- Samples with few connections (<3): $low_conn"; echo "- Samples with header/block lag > 3: $lagging"; echo "- Samples with high-ping peers (>800 ms): $high_ping"; echo "- Samples with significant NTP offset (>200 ms): $ntp_bad"; echo "- Samples with memory PSI avg10 > 1: $psi_mem_bad"; echo "- Samples with service restarts > 0: $restart_samples"; echo "- Samples with high load and non-zero PoSe penalty: $pose_load"; echo "- Significant PoSe penalty jumps (>5): $pose_jumps"
    [ "${max_load%.*}" -ge 3 ] && score_line 2; [ "$min_mem" -lt 262144 ] && score_line 3; [ "${max_cpu%.*}" -ge 90 ] && score_line 2; [ "$low_conn" -ge 10 ] && score_line 2; [ "$lagging" -ge 10 ] && score_line 2; [ "$high_ping" -ge 10 ] && score_line 2; [ "$ntp_bad" -ge 3 ] && score_line 2; [ "$psi_mem_bad" -ge 3 ] && score_line 3
  else echo "- No timeseries data found"; score_line 1; fi
  echo; echo "## Risk assessment"; if [ "$score" -le 2 ]; then echo "- Low: no clear VPS-level resource issues visible."; elif [ "$score" -le 6 ]; then echo "- Medium: some resource, time-sync, peer-quality, or connectivity anomalies present."; else echo "- High: VPS or node behavior shows strong instability indicators."; fi
  echo; echo "## Relevant alerts"; if [ -f "$ALERTS_CSV" ]; then tail -n 200 "$ALERTS_CSV" | sed 's/^/- /'; else echo "- No alerts file found"; fi
  echo; echo "## Journal patterns"; if [ -f "${LOG_DIR}/journal-follow.log" ]; then grep -iE 'pose|ban|dkg|quorum|timeout|sync|fork|disconnect|misbehav|error|failed|oom' "${LOG_DIR}/journal-follow.log" | tail -n 300 | sed 's/^/- /' || true; else echo "- No journal follow log found"; fi
  echo; echo "## Recommendations"; echo "- Correlate PoSe/DKG events with low peers, header lag, NTP offset, service restarts, and memory/IO pressure."; echo "- If repeated reindex or cleanup is required, investigate peer quality and possible forked peers before quorum changes."; echo "- Treat significant clock drift, OOM hints, and repeated service restarts as first-class suspects."; echo "- Only adjust quorum/PoSe parameters after collecting a stable before/after baseline."
} > "$REPORT_MD"
{ echo "DFCN short summary"; echo "Generated: $(date -Is)"; echo; [ -f "$TS_CSV" ] && echo "Last 15 rows of timeseries.csv" && tail -n 15 "$TS_CSV"; echo; [ -f "$ALERTS_CSV" ] && echo "Last 50 alerts" && tail -n 50 "$ALERTS_CSV"; echo; [ -f "${LOG_DIR}/pose-events.log" ] && echo "Last 80 PoSe-related entries" && tail -n 80 "${LOG_DIR}/pose-events.log"; } > "$REPORT_TXT"
printf '%s\n%s\n' "$REPORT_MD" "$REPORT_TXT"
EOF2
chmod +x "$ANALYZE_SCRIPT"
}

generate_report(){ write_analyze_script; mapfile -t generated < <("$ANALYZE_SCRIPT"); log "Reports created:"; printf ' - %s\n' "${generated[@]}"; printf '%s\n' "${generated[@]}"; }
instant_analysis(){ load_config; out="$REPORT_DIR/instant-analysis-$(date '+%F-%H%M%S').md"; write_instant_analysis "$out"; log "Instant analysis created: $out"; printf '%s\n' "$out"; }
cleanup_all(){ if ask_yes_no "Really delete ALL inspector data, logs and reports?" n; then stop_monitor || true; rm -rf "$BASE_DIR"; log "All inspector data removed: $BASE_DIR"; else log "Aborted"; fi; }
show_status(){ load_config; echo; echo "=== STATUS ==="; echo "Base dir: $BASE_DIR"; echo "Install : $INSTALL_PATH_DEFAULT"; echo "Service : $SERVICE_NAME"; echo "CLI     : $CLI_BIN"; echo "Datadir : $DATA_DIR"; echo "LogLevel: ${LOG_LEVEL:-basic}"; echo "ProTx   : ${PROTX_HASH:-}"; echo "IO test : ${IO_TEST_ENABLED:-unset}"; for f in "$PID_FILE" "$TAIL_PID_FILE" "$EVENT_PID_FILE"; do [ -f "$f" ] && echo "$(basename "$f"): $(cat "$f")" || true; done; echo; }
selftest(){
  {
    load_config
    echo "Core commands:"
    for c in awk sed grep ps ss systemctl journalctl nohup timeout date df free ip find flock ionice nice; do
      if have_cmd "$c"; then
        echo "OK  $c"
      else
        echo "MISS $c"
      fi
    done
    echo
    echo "Service:"
    systemctl is-active "$SERVICE_NAME" || true
    echo
    echo "Datadir:"
    ls -ld "$DATA_DIR" 2>/dev/null || true
    echo
    echo "CLI probe:"
    timeout 15 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getblockchaininfo 2>/dev/null | head -n 20 || true
  } | less
}
show_workflow(){ cat <<EOF2
Recommended workflow:
  1) Run selftest to verify commands, service and datadir.
  2) Run instant live analysis for a no-history snapshot.
  3) Start inspection and logging for long-term correlation.
  4) When a PoSe issue happened, stop everything and generate the report.
  5) Review reports under: $REPORT_DIR

Recommended install + start command:
  curl -fsSL -o "$INSTALL_PATH_DEFAULT" https://raw.githubusercontent.com/MrMarsellus/dfcn-masternode-vps-inspector/main/dfcn-masternode-vps-inspector.sh && chmod +x "$INSTALL_PATH_DEFAULT" && "$INSTALL_PATH_DEFAULT"
EOF2
}

handle_post_action(){
  local kind="$1" file="${2:-}"
  case "$kind" in
    report)
      if [ -n "$file" ] && [ -f "$file" ] && ask_yes_no "Show the created report now?" y; then show_file "$file"; fi
      ;;
    multi-report)
      if [ -n "$file" ] && ask_yes_no "Show the main Markdown report now?" y; then show_file "$file"; fi
      ;;
    text)
      ;;
  esac
  post_action_menu_prompt
}

usage() {
  print_line
  print_line
  echo "$APP_NAME v$VERSION"
  print_line
  print_line
  cat <<EOF2

Report viewer hint:
  When a report is shown, use the arrow keys to scroll.
  Press q to close the report view and return.

Menu:
  1) Start inspection and logging
  2) Stop everything and generate report
  3) Instant live analysis now (no prior logging required)
  4) Cleanup: delete inspector data, logs and reports
  5) Show / adjust configuration
  6) Show status
  7) Self test
  8) Show recommended workflow

Direct usage:
  $0 start
  $0 stop-report
  $0 analyze-now
  $0 cleanup
  $0 config
  $0 status
  $0 selftest
  $0 workflow

Recommended install + start:
  curl -fsSL -o "$INSTALL_PATH_DEFAULT" https://raw.githubusercontent.com/MrMarsellus/dfcn-masternode-vps-inspector/main/dfcn-masternode-vps-inspector.sh && chmod +x "$INSTALL_PATH_DEFAULT" && "$INSTALL_PATH_DEFAULT"
EOF2
}
menu(){
  while true; do
    usage
    echo
    read -r -p "Choice: " choice || true
    case "$choice" in
      1)
        setup_config_interactive
        start_monitor
        post_action_menu_prompt || break
        ;;
      2)
        stop_monitor
        mapfile -t generated < <(generate_report | tail -n 2)
        main_report="${generated[0]:-}"
        handle_post_action multi-report "$main_report" || break
        ;;
      3)
        report_path="$(instant_analysis | tail -n 1)"
        handle_post_action report "$report_path" || break
        ;;
      4)
        cleanup_all
        post_action_menu_prompt || break
        ;;
      5)
        setup_config_interactive
        post_action_menu_prompt || break
        ;;
      6)
        show_status
        post_action_menu_prompt || break
        ;;
      7)
        selftest
        post_action_menu_prompt || break
        ;;
      8)
        show_workflow
        post_action_menu_prompt || break
        ;;
      *)
        echo "Invalid choice" ; press_enter ;;
    esac
    echo
  done
}

case "${1:-}" in
  start)        setup_config_interactive; start_monitor ;;
  stop-report)  generate_report ;;
  analyze-now)  instant_analysis ;;
  cleanup)      cleanup_all ;;
  config)       setup_config_interactive ;;
  status)       show_status ;;
  selftest)     selftest ;;
  workflow)     show_workflow ;;
  "")           menu ;;
  *)            usage; exit 1 ;;
esac
