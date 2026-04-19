#!/usr/bin/env bash
set -Eeuo pipefail  # strict error handling

APP_NAME="dfcn-masternode-vps-inspector"
VERSION="0.4.0"
BASE_DIR="${HOME}/.${APP_NAME}"
LOG_DIR="${BASE_DIR}/logs"
RUN_DIR="${BASE_DIR}/run"
REPORT_DIR="${BASE_DIR}/reports"
CFG_FILE="${BASE_DIR}/config.env"
MONITOR_SCRIPT="${BASE_DIR}/monitor.sh"
ANALYZE_SCRIPT="${BASE_DIR}/analyze.sh"
LOCK_FILE="${RUN_DIR}/monitor.lock"
PID_FILE="${RUN_DIR}/monitor.pid"
TAIL_PID_FILE="${RUN_DIR}/journal_tail.pid"
EVENT_PID_FILE="${RUN_DIR}/event_sampler.pid"

# default paths and intervals
SERVICE_NAME_DEFAULT="defcond.service"
CLI_BIN_DEFAULT="/usr/local/bin/defcon-cli"
DAEMON_BIN_DEFAULT="/usr/local/bin/defcond"
DATA_DIR_DEFAULT="/home/defcon/.defcon"
CONF_FILE_DEFAULT="/home/defcon/.defcon/defcon.conf"
NODE_USER_DEFAULT="defcon"
INTERVAL_DEFAULT="60"
EVENT_INTERVAL_DEFAULT="20"
JOURNAL_LINES_DEFAULT="400"
RETENTION_DAYS_DEFAULT="21"
IONICE_CLASS_DEFAULT="3"
NICE_LEVEL_DEFAULT="10"
PEER_SAMPLE_MAXKB_DEFAULT="32"
LOG_LEVEL_DEFAULT="basic"      # basic or debug
PROTX_HASH_DEFAULT=""          # optional protx hash for pose tracking
IO_TEST_ENABLED_DEFAULT="1"    # 1 = enable lightweight IO test, 0 = disable

umask 077  # secure file permissions
mkdir -p "$BASE_DIR" "$LOG_DIR" "$RUN_DIR" "$REPORT_DIR"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }               # generic log message
warn(){ printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*" >&2; }    # warning log
err(){ printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; }    # error log
require_cmd(){ command -v "$1" >/dev/null 2>&1 || { err "Required command missing: $1"; exit 1; }; }  # ensure required binary exists
have_cmd(){ command -v "$1" >/dev/null 2>&1; }                     # check if binary exists

write_default_config(){
  # write initial default config file
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
  # load existing config or create default
  [ -f "$CFG_FILE" ] || write_default_config
  # shellcheck disable=SC1090
  source "$CFG_FILE"
}

prompt_default(){
  # read value with default fallback
  local label="$1" default="$2" value
  read -r -p "$label [$default]: " value || true
  if [ -z "${value:-}" ]; then printf '%s' "$default"; else printf '%s' "$value"; fi
}

setup_config_interactive(){
  # interactive configuration wizard
  load_config
  echo
  echo "Review / adjust configuration"
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

redact_conf(){
  # hide sensitive values from defcon.conf
  sed -E 's/(rpcpassword=).+/\1***REDACTED***/; s/(masternodeblsprivkey=).+/\1***REDACTED***/; s/(rpcuser=).+/\1***REDACTED***/; s/(externalip=).+/\1***REDACTED***/'
}

system_snapshot(){
  # capture static system snapshot at start
  local out="$1"
  {
    echo "===== BASIC ====="
    date -Is
    hostnamectl 2>/dev/null || true
    uname -a
    uptime
    echo
    echo "===== CPU ====="
    lscpu 2>/dev/null || cat /proc/cpuinfo
    echo
    echo "===== MEMORY ====="
    free -h
    grep -E 'MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree|Dirty|Writeback' /proc/meminfo || true
    echo
    echo "===== STORAGE ====="
    df -hT
    lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,ROTA,MODEL 2>/dev/null || true
    echo
    echo "===== DISKSTATS ====="
    tail -n 20 /proc/diskstats
    echo
    echo "===== NETWORK ====="
    ip -brief addr 2>/dev/null || ip addr || true
    ip route || true
    ss -tulpn || true
    echo
    echo "===== SYSCTL FOCUS ====="
    sysctl vm.swappiness vm.dirty_ratio vm.dirty_background_ratio net.core.somaxconn net.ipv4.tcp_syn_retries 2>/dev/null || true
    echo
    echo "===== LIMITS ====="
    ulimit -a
    echo
    echo "===== SERVICE ====="
    systemctl status "$SERVICE_NAME" --no-pager || true
    systemctl cat "$SERVICE_NAME" || true
    echo
    echo "===== PROCESS ====="
    ps -eo user,pid,ppid,%cpu,%mem,rss,vsz,etimes,stat,comm,args | grep -E 'defcond|defcon-cli|defcond|^USER' || true
    echo
    echo "===== CONFIG FILES ====="
    [ -f "$CONF_FILE" ] && redact_conf < "$CONF_FILE" || true
    echo
    [ -d "$DATA_DIR" ] && find "$DATA_DIR" -maxdepth 2 -type f | sort || true
    echo
    echo "===== JOURNAL TAIL ====="
    journalctl -u "$SERVICE_NAME" -n "$JOURNAL_LINES" --no-pager || true
  } > "$out" 2>&1
}

collect_cli_snapshot(){
  # capture static CLI snapshot at start
  local out="$1"
  {
    echo "===== CLI SNAPSHOT ====="
    if [ -x "$CLI_BIN" ]; then
      timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getblockchaininfo 2>&1 || true
      echo
      timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getnetworkinfo 2>&1 || true
      echo
      timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getpeerinfo 2>&1 || true
      echo
      timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getmasternodestatus 2>&1 || true
      echo
      timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" masternode status 2>&1 || true
      echo
      timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" protx list valid 1 2>&1 || true
      echo
      timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum list 2>&1 || true
      echo
      timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum dkgstatus 2>&1 || true
      echo
      timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum memberof 2>&1 || true
    else
      echo "CLI not found: $CLI_BIN"
    fi
  } > "$out" 2>&1
}

write_monitor_script(){
  # write the main background monitor script
cat > "$MONITOR_SCRIPT" <<'EOF2'
#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR="${HOME}/.dfcn-masternode-vps-inspector"
LOG_DIR="${BASE_DIR}/logs"
RUN_DIR="${BASE_DIR}/run"
CFG_FILE="${BASE_DIR}/config.env"
mkdir -p "$LOG_DIR" "$RUN_DIR"
# shellcheck disable=SC1090
source "$CFG_FILE"
exec 9>"${RUN_DIR}/monitor.lock"
flock -n 9 || { echo "monitor already running"; exit 1; }  # prevent double monitor
echo $$ > "${RUN_DIR}/monitor.pid"
TS_CSV="${LOG_DIR}/timeseries.csv"
PEER_LOG="${LOG_DIR}/peer-samples.log"
QUORUM_LOG="${LOG_DIR}/quorum-samples.log"

# create timeseries file with header
if [ ! -f "$TS_CSV" ]; then
  echo "timestamp,load1,load5,load15,cpu_user,cpu_system,cpu_idle,mem_total_kb,mem_avail_kb,swap_total_kb,swap_free_kb,root_use_pct,datadir_use_pct,rx_bytes,tx_bytes,established_conns,defcond_cpu_pct,defcond_mem_pct,defcond_rss_kb,defcond_threads,defcond_fd_count,io_ms,chain_blocks,headers,verificationprogress,connections,mn_synced,mn_state,pose_penalty,pose_banheight" > "$TS_CSV"
fi

cleanup(){ rm -f "${RUN_DIR}/monitor.pid"; }  # remove pid file on exit
trap cleanup EXIT

get_cpu(){ awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9,$10}' /proc/stat; }  # read cpu counters
read -r u1 n1 s1 i1 w1 irq1 sirq1 st1 g1 < <(get_cpu)
sleep 1
read -r u2 n2 s2 i2 w2 irq2 sirq2 st2 g2 < <(get_cpu)

while true; do
  ts="$(date '+%F %T')"  # timestamp
  read -r load1 load5 load15 _ < /proc/loadavg

  # compute cpu usage delta
  total1=$((u1+n1+s1+i1+w1+irq1+sirq1+st1+g1)); total2=$((u2+n2+s2+i2+w2+irq2+sirq2+st2+g2))
  idle1=$((i1+w1)); idle2=$((i2+w2)); dt=$((total2-total1)); di=$((idle2-idle1)); den=$((dt==0?1:dt))
  cpu_idle=$((100*di/den)); cpu_user=$((100*((u2-u1)+(n2-n1))/den)); cpu_system=$((100*((s2-s1)+(irq2-irq1)+(sirq2-sirq1))/den))
  read -r u1 n1 s1 i1 w1 irq1 sirq1 st1 g1 <<< "$u2 $n2 $s2 $i2 $w2 $irq2 $sirq2 $st2 $g2"
  sleep 1
  read -r u2 n2 s2 i2 w2 irq2 sirq2 st2 g2 < <(get_cpu)

  # read memory and swap
  mem_total=$(awk '/MemTotal:/{print $2}' /proc/meminfo); mem_avail=$(awk '/MemAvailable:/{print $2}' /proc/meminfo)
  swap_total=$(awk '/SwapTotal:/{print $2}' /proc/meminfo); swap_free=$(awk '/SwapFree:/{print $2}' /proc/meminfo)

  # read disk usage
  root_use=$(df -P / | awk 'NR==2{gsub(/%/,"",$5);print $5}')
  datadir_use=$(df -P "$DATA_DIR" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5);print $5}'); [ -z "$datadir_use" ] && datadir_use="$root_use"

  # read network bytes for default route iface
  iface=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
  rx_bytes=0; tx_bytes=0
  if [ -n "${iface:-}" ] && [ -r "/sys/class/net/$iface/statistics/rx_bytes" ]; then
    rx_bytes=$(cat "/sys/class/net/$iface/statistics/rx_bytes")
    tx_bytes=$(cat "/sys/class/net/$iface/statistics/tx_bytes")
  fi

  # count tcp established connections
  established=$(ss -tan 2>/dev/null | awk 'NR>1 && $1=="ESTAB"{c++} END{print c+0}')

  # read defcond process stats
  proc_line=$(ps -C "$(basename "$DAEMON_BIN")" -o pid=,%cpu=,%mem=,rss=,nlwp= 2>/dev/null | head -n1 | xargs)
  defcond_pid=""; defcond_cpu=0; defcond_mem=0; defcond_rss=0; defcond_threads=0; defcond_fd_count=0
  if [ -n "$proc_line" ]; then
    read -r defcond_pid defcond_cpu defcond_mem defcond_rss defcond_threads <<< "$proc_line"
    if [ -d "/proc/$defcond_pid/fd" ]; then
      defcond_fd_count=$(find "/proc/$defcond_pid/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    fi
  fi

  # simple optional datadir write latency test (very small file, no global sync)
  io_ms=""
  if [ "${IO_TEST_ENABLED:-1}" = "1" ] && [ -w "$DATA_DIR" ]; then
    io_test_file="$DATA_DIR/.dfcn_io_test"
    start_ns=$(date +%s%N)
    printf 'x' > "$io_test_file" 2>/dev/null || true
    end_ns=$(date +%s%N)
    delta_ns=$((end_ns-start_ns))
    io_ms=$((delta_ns/1000000))  # convert ns to ms
    rm -f "$io_test_file" 2>/dev/null || true
  fi

  chain_blocks=""; headers=""; verificationprogress=""; connections=""; mn_synced=""; mn_state=""
  pose_penalty=""; pose_banheight=""

  if [ -x "$CLI_BIN" ]; then
    # read blockchain and network info
    info=$(timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getblockchaininfo 2>/dev/null || true)  # blockchain info snapshot
    net=$(timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getnetworkinfo 2>/dev/null || true)      # network info snapshot
    mn=$(timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getmasternodestatus 2>/dev/null || timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" masternode status 2>/dev/null || true)  # masternode status snapshot

    chain_blocks=$(printf '%s' "$info" | sed -n 's/.*"blocks"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n1)
    headers=$(printf '%s' "$info" | sed -n 's/.*"headers"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n1)
    verificationprogress=$(printf '%s' "$info" | sed -n 's/.*"verificationprogress"[[:space:]]*:[[:space:]]*\([0-9.]*\).*/\1/p' | head -n1)
    connections=$(printf '%s' "$net" | sed -n 's/.*"connections"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -n1)
    mn_synced=$(printf '%s' "$mn" | sed -n 's/.*"IsSynced"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/p' | tr -d ' ' | head -n1)
    mn_state=$(printf '%s' "$mn" | sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)  # parse masternode state
    [ -z "$mn_state" ] && mn_state=$(printf '%s' "$mn" | tr '\n' ' ' | sed 's/,/;/g; s/"//g' | cut -c1-220)

    # fetch protx info for pose tracking
    if [ -n "${PROTX_HASH:-}" ]; then
      protx_info=$(timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" protx info "$PROTX_HASH" 2>/dev/null || true)
      pose_penalty=$(printf '%s' "$protx_info" | sed -n 's/.*"PoSePenalty"[[:space:]]*:[[:space:]]*\([0-9-]*\).*/\1/p' | head -n1)  # parse pose penalty
      pose_banheight=$(printf '%s' "$protx_info" | sed -n 's/.*"PoSeBanHeight"[[:space:]]*:[[:space:]]*\([0-9-]*\).*/\1/p' | head -n1)  # parse pose ban height
    fi

    # optional verbose peer/quorum snapshots
    if [ "${LOG_LEVEL:-basic}" = "debug" ]; then
      printf '%s | getpeerinfo\n' "$ts" >> "$PEER_LOG"
      timeout 30 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getpeerinfo 2>/dev/null | head -c "$((PEER_SAMPLE_MAXKB*1024))" >> "$PEER_LOG" || true
      printf '\n\n' >> "$PEER_LOG"
      printf '%s | quorum dkgstatus\n' "$ts" >> "$QUORUM_LOG"
      timeout 30 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum dkgstatus 2>/dev/null >> "$QUORUM_LOG" || true
      printf '\n\n' >> "$QUORUM_LOG"
    fi  # debug logging only
  fi

  # append all collected values to timeseries
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$ts" "$load1" "$load5" "$load15" "$cpu_user" "$cpu_system" "$cpu_idle" "$mem_total" "$mem_avail" "$swap_total" "$swap_free" "$root_use" "$datadir_use" "$rx_bytes" "$tx_bytes" "$established" "$defcond_cpu" "$defcond_mem" "$defcond_rss" "$defcond_threads" "$defcond_fd_count" "${io_ms:-}" "${chain_blocks:-}" "${headers:-}" "${verificationprogress:-}" "${connections:-}" "${mn_synced:-}" "${mn_state:-}" "${pose_penalty:-}" "${pose_banheight:-}" >> "$TS_CSV"

  # remove old log files based on retention
  find "$LOG_DIR" -type f -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true
  sleep "$INTERVAL"
done
EOF2
chmod +x "$MONITOR_SCRIPT"
}

write_event_sampler(){
  # write the RPC/journal event sampler script
cat > "${BASE_DIR}/event-sampler.sh" <<'EOF2'
#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR="${HOME}/.dfcn-masternode-vps-inspector"
LOG_DIR="${BASE_DIR}/logs"
RUN_DIR="${BASE_DIR}/run"
CFG_FILE="${BASE_DIR}/config.env"
# shellcheck disable=SC1090
source "$CFG_FILE"
echo $$ > "${RUN_DIR}/event_sampler.pid"
EVENT_LOG="${LOG_DIR}/events.log"
POSE_LOG="${LOG_DIR}/pose-events.log"
ALERTS_CSV="${LOG_DIR}/alerts.csv"
[ -f "$ALERTS_CSV" ] || echo 'timestamp,severity,source,pattern,details' > "$ALERTS_CSV"
trap 'rm -f "${RUN_DIR}/event_sampler.pid"' EXIT

while true; do
  ts="$(date '+%F %T')"  # timestamp
  svc=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)
  [ "$svc" != "active" ] && printf '%s,HIGH,systemd,service_inactive,%s\n' "$ts" "$svc" >> "$ALERTS_CSV"  # log inactive service

  if [ -x "$CLI_BIN" ]; then
    mn=$(timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getmasternodestatus 2>/dev/null || timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" masternode status 2>/dev/null || true)  # masternode status
    quorum=$(timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum dkgstatus 2>/dev/null || true)  # quorum dkgstatus
    peers=$(timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getpeerinfo 2>/dev/null || true)  # peer info

    printf '===== %s =====\n[Masternode]\n%s\n\n[Quorum]\n%s\n\n' "$ts" "$mn" "$quorum" >> "$EVENT_LOG"

    blob="$(printf '%s\n%s\n%s' "$mn" "$quorum" "$peers")"

    # simple dkg failure counts per llmq type
    dkg_50_fail=$(printf '%s' "$quorum" | grep -c 'LLMQ_50_60.*"failed": true')
    dkg_60_fail=$(printf '%s' "$quorum" | grep -c 'LLMQ_60_75.*"failed": true')
    dkg_100_fail=$(printf '%s' "$quorum" | grep -c 'LLMQ_100_67.*"failed": true')
    dkg_400_fail=$(printf '%s' "$quorum" | grep -c 'LLMQ_400_60.*"failed": true')

    [ "$dkg_50_fail" -gt 0 ] && printf '%s,INFO,dkgstats,LLMQ_50_60_fail,%s\n' "$ts" "$dkg_50_fail" >> "$ALERTS_CSV"
    [ "$dkg_60_fail" -gt 0 ] && printf '%s,INFO,dkgstats,LLMQ_60_75_fail,%s\n' "$ts" "$dkg_60_fail" >> "$ALERTS_CSV"
    [ "$dkg_100_fail" -gt 0 ] && printf '%s,INFO,dkgstats,LLMQ_100_67_fail,%s\n' "$ts" "$dkg_100_fail" >> "$ALERTS_CSV"
    [ "$dkg_400_fail" -gt 0 ] && printf '%s,INFO,dkgstats,LLMQ_400_60_fail,%s\n' "$ts" "$dkg_400_fail" >> "$ALERTS_CSV"

    # scan for important error/pose patterns
    for pat in 'pose' 'banned' 'dkg ' ' dkg' 'timeout' 'quorum ' ' quorum' 'not capable' 'watchdog' 'misbehav' 'fork' 'error' 'failed'; do
      if printf '%s' "$blob" | grep -qi "$pat"; then
        printf '%s,MEDIUM,rpc,%s,%s\n' "$ts" "$pat" "match found" >> "$ALERTS_CSV"  # log pattern match
      fi
    done

    # keep focused PoSe-related snippets
    if printf '%s' "$blob" | grep -qiE 'pose|banned'; then
      printf '===== %s =====\n%s\n\n%s\n\n' "$ts" "$mn" "$quorum" >> "$POSE_LOG"  # log pose-related detail
    fi
  fi

  sleep "$EVENT_INTERVAL"
done
EOF2
chmod +x "${BASE_DIR}/event-sampler.sh"
}

start_journal_follow(){
  # start journalctl -f for the service
  load_config
  if [ -f "$TAIL_PID_FILE" ] && kill -0 "$(cat "$TAIL_PID_FILE")" 2>/dev/null; then return 0; fi
  nohup bash -c "journalctl -u '$SERVICE_NAME' -f -o short-iso >> '$LOG_DIR/journal-follow.log' 2>&1" >/dev/null 2>&1 &
  echo $! > "$TAIL_PID_FILE"
}

start_event_sampler(){
  # start the event sampler in background
  write_event_sampler
  if [ -f "$EVENT_PID_FILE" ] && kill -0 "$(cat "$EVENT_PID_FILE")" 2>/dev/null; then return 0; fi
  nohup ionice -c "$IONICE_CLASS" nice -n "$NICE_LEVEL" "${BASE_DIR}/event-sampler.sh" >> "$LOG_DIR/event-sampler-stdout.log" 2>&1 &
  sleep 1
}

start_monitor(){
  # start full monitoring stack: monitor + journal + events
  load_config
  for c in systemctl journalctl ps ss awk sed grep timeout date df free ip nohup find flock; do require_cmd "$c"; done
  [ -x "$CLI_BIN" ] || warn "CLI not found or not executable: $CLI_BIN"
  write_monitor_script
  system_snapshot "$LOG_DIR/system-snapshot-$(date '+%F-%H%M%S').txt"
  collect_cli_snapshot "$LOG_DIR/cli-snapshot-$(date '+%F-%H%M%S').txt"
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    warn "Monitor already running with PID $(cat "$PID_FILE")"
  else
    nohup ionice -c "$IONICE_CLASS" nice -n "$NICE_LEVEL" "$MONITOR_SCRIPT" >> "$LOG_DIR/monitor-stdout.log" 2>&1 &
    sleep 1
  fi
  start_journal_follow
  start_event_sampler
  log "Inspector started. Logs: $LOG_DIR"
}

stop_monitor(){
  # stop all background processes
  for f in "$PID_FILE" "$TAIL_PID_FILE" "$EVENT_PID_FILE"; do
    if [ -f "$f" ] && kill -0 "$(cat "$f")" 2>/dev/null; then
      kill "$(cat "$f")" || true; sleep 1; kill -9 "$(cat "$f")" 2>/dev/null || true
      rm -f "$f"
    fi
  done
  log "All background processes stopped"
}

write_analyze_script(){
  # write analyzer script to generate reports
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
score_line(){ score=$((score+$1)); }  # accumulate score

{
  echo "# DFCN Masternode VPS Inspector Report"
  echo
  echo "Generated: $(date -Is)"
  echo
  echo "## Summary"
  if [ -f "$TS_CSV" ]; then
    total_samples=$(($(wc -l < "$TS_CSV")-1))
    echo "- Samples: $total_samples"
    max_load=$(awk -F',' 'NR>1{if($2>m)m=$2} END{print m+0}' "$TS_CSV")
    min_mem=$(awk -F',' 'NR>1{if(min==""||$9<min)min=$9} END{print min+0}' "$TS_CSV")
    max_cpu=$(awk -F',' 'NR>1{if($17>m)m=$17} END{print m+0}' "$TS_CSV")
    max_mem=$(awk -F',' 'NR>1{if($18>m)m=$18} END{print m+0}' "$TS_CSV")
    max_fd=$(awk -F',' 'NR>1{if($21>m)m=$21} END{print m+0}' "$TS_CSV")
    max_io=$(awk -F',' 'NR>1{if($22>m)m=$22} END{print m+0}' "$TS_CSV")
    low_conn=$(awk -F',' 'NR>1 && ($26=="" || $26+0<3){c++} END{print c+0}' "$TS_CSV")
    lagging=$(awk -F',' 'NR>1 && $23!="" && $24!="" && ($24-$23)>3 {c++} END{print c+0}' "$TS_CSV")
    echo "- Max load1: $max_load"
    echo "- Max defcond CPU %: $max_cpu"
    echo "- Max defcond MEM %: $max_mem"
    echo "- Max open file descriptors: $max_fd"
    echo "- Max IO latency ms (datadir): $max_io"
    echo "- Min MemAvailable KB: $min_mem"
    echo "- Samples with few connections (<3): $low_conn"
    echo "- Samples with header/block lag > 3: $lagging"

    [ "${max_load%.*}" -ge 3 ] && score_line 2
    [ "$min_mem" -lt 262144 ] && score_line 3
    [ "${max_cpu%.*}" -ge 90 ] && score_line 2
    [ "$low_conn" -ge 10 ] && score_line 2
    [ "$lagging" -ge 10 ] && score_line 2

    # events: high load + pose penalty
    pose_load=$(awk -F',' 'NR>1 && $(NF-1)!="" {if($2>2.0 && $(NF-1)+0>0) c++} END{print c+0}' "$TS_CSV")
    # count pose jumps > 5
    pose_jumps=$(awk -F',' 'NR>1 {if(prev!="" && $(NF-1)>prev+5) c++; prev=$(NF-1)} END{print c+0}' "$TS_CSV")
    echo "- Samples with high load and non-zero PoSe penalty: $pose_load"
    echo "- Significant PoSe penalty jumps (>5): $pose_jumps"
  else
    echo "- No timeseries data found"
    score_line 5
  fi

  echo
  echo "## Risk assessment"
  if [ "$score" -le 2 ]; then
    echo "- Low: no clear VPS-level resource issues visible."
  elif [ "$score" -le 5 ]; then
    echo "- Medium: some resource or connectivity anomalies present."
  else
    echo "- High: VPS or node behavior shows strong instability indicators."
  fi

  echo
  echo "## Relevant alerts"
  if [ -f "$ALERTS_CSV" ]; then
    tail -n 200 "$ALERTS_CSV" | sed 's/^/- /'
  else
    echo "- No alerts file found"
  fi

  echo
  echo "## Journal patterns"
  if [ -f "${LOG_DIR}/journal-follow.log" ]; then
    grep -iE 'pose|ban|dkg|quorum|timeout|sync|fork|disconnect|misbehav|error|failed' "${LOG_DIR}/journal-follow.log" | tail -n 300 | sed 's/^/- /' || true
  else
    echo "- No journal follow log found"
  fi

  echo
  echo "## Recommendations"
  echo "- Check if PoSe/DKG events correlate with low peers, header lag, high load or low RAM."
  echo "- If repeated reindex/clean states are needed, review peer quality and possible forked peers first."
  echo "- Only adjust quorum/PoSe parameters after sufficient measurement and with a clear before/after baseline."
  echo "- If the host often runs low on RAM or hits high IO latency, test a stronger VPS class."
} > "$REPORT_MD"

{
  echo "DFCN short summary"
  echo "Generated: $(date -Is)"
  echo
  [ -f "$TS_CSV" ] && echo "Last 15 rows of timeseries.csv" && tail -n 15 "$TS_CSV"
  echo
  [ -f "$ALERTS_CSV" ] && echo "Last 50 alerts" && tail -n 50 "$ALERTS_CSV"
  echo
  [ -f "${LOG_DIR}/pose-events.log" ] && echo "Last 80 PoSe-related entries" && tail -n 80 "${LOG_DIR}/pose-events.log"
} > "$REPORT_TXT"

printf '%s\n%s\n' "$REPORT_MD" "$REPORT_TXT"
EOF2
chmod +x "$ANALYZE_SCRIPT"
}

generate_report(){ write_analyze_script; mapfile -t generated < <("$ANALYZE_SCRIPT"); log "Reports created:"; printf ' - %s\n' "${generated[@]}"; }  # run analyzer and print report paths
cleanup_all(){ read -r -p "Really delete all inspector data? [yes/NO]: " ans || true; [ "$ans" = "yes" ] || { log "Aborted"; return 0; }; stop_monitor || true; rm -rf "$BASE_DIR"; log "All inspector data removed: $BASE_DIR"; }  # wipe all data
show_status(){ load_config; echo; echo "=== STATUS ==="; echo "Base dir: $BASE_DIR"; echo "Service : $SERVICE_NAME"; echo "CLI     : $CLI_BIN"; echo "Datadir : $DATA_DIR"; echo "LogLevel: ${LOG_LEVEL:-basic}"; echo "ProTx   : ${PROTX_HASH:-}"; echo "IO test : ${IO_TEST_ENABLED:-$IO_TEST_ENABLED_DEFAULT}"; for f in "$PID_FILE" "$TAIL_PID_FILE" "$EVENT_PID_FILE"; do [ -f "$f" ] && echo "$(basename "$f"): $(cat "$f")" || true; done; echo; }  # show current status
selftest(){ load_config; echo "Core commands:"; for c in awk sed grep ps ss systemctl journalctl nohup timeout date df free ip find flock ionice nice; do if have_cmd "$c"; then echo "OK  $c"; else echo "MISS $c"; fi; done; echo; echo "Service:"; systemctl is-active "$SERVICE_NAME" || true; echo; echo "Datadir:"; ls -ld "$DATA_DIR" 2>/dev/null || true; echo; echo "CLI probe:"; timeout 15 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getblockchaininfo 2>/dev/null | head -n 20 || true; }  # quick environment check

usage(){ cat <<EOF2
$APP_NAME v$VERSION

Menu:
  1) Start inspection and logging
  2) Stop everything and generate report
  3) Cleanup: delete inspector data
  4) Show / adjust configuration
  5) Show status
  6) Self test

Direct usage:
  $0 start
  $0 stop-report
  $0 cleanup
  $0 config
  $0 status
  $0 selftest
EOF2
}

menu(){
  # interactive main menu
  while true; do
    usage
    echo
    read -r -p "Choice: " choice || true
    case "$choice" in
      1) setup_config_interactive; start_monitor; break ;;
      2) stop_monitor; generate_report; break ;;
      3) cleanup_all; break ;;
      4) setup_config_interactive ;;
      5) show_status ;;
      6) selftest ;;
      *) echo "Invalid choice" ;;
    esac
    echo
  done
}

case "${1:-}" in
  start)        setup_config_interactive; start_monitor ;;  # start monitoring
  stop-report)  stop_monitor; generate_report ;;            # stop and analyze
  cleanup)      cleanup_all ;;                              # full cleanup
  config)       setup_config_interactive ;;                 # config wizard
  status)       show_status ;;                              # show status
  selftest)     selftest ;;                                 # run selftest
  "")           menu ;;                                     # show menu
  *)            usage; exit 1 ;;
esac
