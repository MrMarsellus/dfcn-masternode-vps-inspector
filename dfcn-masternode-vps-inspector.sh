#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="dfcn-masternode-vps-inspector"
VERSION="0.4.6"
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

browse_logs(){
  local files=() sel i f
  while true; do
    files=()
    for f in \
      "$LOG_DIR/timeseries.csv" \
      "$LOG_DIR/alerts.csv" \
      "$LOG_DIR/pose-timeline.csv" \
      "$LOG_DIR/pose-events.log" \
      "$LOG_DIR/events.log" \
      "$LOG_DIR/quorum-samples.log" \
      "$LOG_DIR/memberof.log" \
      "$LOG_DIR/protx-info.log" \
      "$LOG_DIR/mnsync.log" \
      "$LOG_DIR/chaintips.log" \
      "$LOG_DIR/peer-samples.log" \
      "$LOG_DIR/journal-follow.log" \
      "$LOG_DIR/monitor-stdout.log" \
      "$LOG_DIR/event-sampler-stdout.log"
    do
      [ -f "$f" ] && files+=("$f")
    done

    echo
    print_line
    print_line
    echo "Available raw log files"
    print_line
    print_line
    echo

    if [ "${#files[@]}" -eq 0 ]; then
      warn "No log files found in $LOG_DIR"
      return 1
    fi

    i=1
    for f in "${files[@]}"; do
      echo "  $i) $(basename "$f")"
      i=$((i+1))
    done
    echo "  q) Back"
    echo

    read -r -p "Choose log file: " sel || true
    case "$sel" in
      q|Q|"") return 0 ;;
    esac

    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#files[@]}" ]; then
      show_file "${files[$((sel-1))]}"
      ask_yes_no "Show another log file?" y || return 0
    else
      echo "Invalid choice"
    fi
  done
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

use_default_config(){
  write_default_config
  load_config
  echo
  echo "Using default configuration:"
  echo "  Service : $SERVICE_NAME"
  echo "  CLI     : $CLI_BIN"
  echo "  Daemon  : $DAEMON_BIN"
  echo "  Datadir : $DATA_DIR"
  echo "  Config  : $CONF_FILE"
  echo
}

prompt_default(){
  local label="$1" default="$2" value
  read -r -p "$label [$default]: " value || true
  if [ -z "${value:-}" ]; then printf '%s' "$default"; else printf '%s' "$value"; fi
}

configure_interactive(){
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

  echo
  echo "Configuration saved to $CFG_FILE"
}

setup_config_interactive(){
  echo
  echo "Configuration mode:"
  echo "  1) Use default configuration"
  echo "  2) Review / adjust configuration interactively"
  echo
  read -r -p "Choice [1/2]: " cfg_choice || true
  cfg_choice="${cfg_choice:-1}"

  case "$cfg_choice" in
    1)
      use_default_config
      ;;
    2)
      configure_interactive
      ;;
    *)
      echo "Invalid choice, using default configuration."
      use_default_config
      ;;
  esac
}

redact_conf(){ sed -E 's/(rpcpassword=).+/\1***REDACTED***/; s/(masternodeblsprivkey=).+/\1***REDACTED***/; s/(rpcuser=).+/\1***REDACTED***/; s/(externalip=).+/\1***REDACTED***/'; }

system_snapshot(){
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
    echo "===== TIME SYNC ====="
    timedatectl 2>/dev/null || true
    chronyc tracking 2>/dev/null || true
    chronyc sources -v 2>/dev/null || true
    echo
    echo "===== PRESSURE STALL INFO ====="
    for f in /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io; do [ -r "$f" ] && echo "--- $f ---" && cat "$f"; done
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
    systemctl show "$SERVICE_NAME" -p NRestarts -p ExecMainPID -p ExecMainStatus -p ExecMainStartTimestampMonotonic -p ActiveEnterTimestamp --no-pager 2>/dev/null || true
    echo
    echo "===== PROCESS ====="
    ps -eo user,pid,ppid,%cpu,%mem,rss,vsz,etimes,stat,comm,args | grep -E 'defcond|defcon-cli|^USER' || true
    echo
    echo "===== KERNEL / OOM HINTS ====="
    dmesg -T 2>/dev/null | grep -iE 'out of memory|oom|killed process' | tail -n 50 || true
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
      timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getchaintips 2>&1 || true
      echo
      timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getbestblockhash 2>&1 || true
      echo
      timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getmasternodestatus 2>&1 || true
      echo
      timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" masternode status 2>&1 || true
      echo
      timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" mnsync status 2>&1 || true
      echo
      timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" protx list valid 1 2>&1 || true
      echo
      if [ -n "${PROTX_HASH:-}" ]; then
        timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" protx info "$PROTX_HASH" 2>&1 || true
        echo
      fi
      timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum list 2>&1 || true
      echo
      timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum dkgstatus 2>&1 || true
      echo
      if [ -n "${PROTX_HASH:-}" ]; then
        timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum memberof "$PROTX_HASH" 2>&1 || true
      else
        timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum memberof 2>&1 || true
      fi
    else
      echo "CLI not found: $CLI_BIN"
    fi
  } > "$out" 2>&1
}

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
MEMBEROF_LOG="${LOG_DIR}/memberof.log"
PROTX_LOG="${LOG_DIR}/protx-info.log"
MNSYNC_LOG="${LOG_DIR}/mnsync.log"
CHAINTIPS_LOG="${LOG_DIR}/chaintips.log"

HEADER="timestamp,load1,load5,load15,cpu_user,cpu_system,cpu_idle,mem_total_kb,mem_avail_kb,swap_total_kb,swap_free_kb,root_use_pct,datadir_use_pct,rx_bytes,tx_bytes,established_conns,defcond_cpu_pct,defcond_mem_pct,defcond_rss_kb,defcond_threads,defcond_fd_count,io_ms,chain_blocks,headers,verificationprogress,initialblockdownload,connections,mnsync_blockchain,mnsync_mnlist,mnsync_winners,mnsync_synced,mn_state,pose_penalty,pose_banheight,pose_is_banned,chaintips_total,chaintips_forks,chaintips_headers_only,memberof_count,peer_total,peer_inbound,peer_outbound,peer_ping_avg_ms,peer_ping_max_ms,peer_high_ping_count,ntp_offset_ms,service_restarts,psi_cpu_some_avg10,psi_mem_some_avg10,psi_io_some_avg10"
[ -f "$TS_CSV" ] || echo "$HEADER" > "$TS_CSV"

trap 'rm -f "${RUN_DIR}/monitor.pid"' EXIT

get_cpu(){ awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9,$10}' /proc/stat; }

peer_summary_with_jq(){
  jq -r '[
    length,
    (map(select(.inbound==true))|length),
    (map(select(.inbound==false))|length),
    (map(select(.pingtime!=null)|.pingtime) | if length>0 then ((add/length)*1000) else null end),
    (map(select(.pingtime!=null)|.pingtime) | if length>0 then (max*1000) else null end),
    (map(select(.pingtime!=null and .pingtime>0.8))|length)
  ] | @tsv' 2>/dev/null
}

peer_summary_plain(){
  local blob="$1" total inbound outbound avg max high
  total=$(printf '%s' "$blob" | awk 'BEGIN{RS="{";c=0} /"addr"[[:space:]]*:/{c++} END{print c+0}')
  inbound=$(printf '%s' "$blob" | awk 'BEGIN{RS="{";c=0} /"addr"[[:space:]]*:/ && /"inbound"[[:space:]]*:[[:space:]]*true/{c++} END{print c+0}')
  outbound=$(printf '%s' "$blob" | awk 'BEGIN{RS="{";c=0} /"addr"[[:space:]]*:/ && /"inbound"[[:space:]]*:[[:space:]]*false/{c++} END{print c+0}')
  avg=$(printf '%s' "$blob" | awk 'BEGIN{RS="{"} /"pingtime"[[:space:]]*:/{for(i=1;i<=NF;i++) if($i ~ /"pingtime"/) {v=$(i+1); gsub(/[,:}]/,"",v); if(v!=""){sum+=v;n++}}} END{if(n>0) printf "%.2f", (sum*1000/n); else printf ""}')
  max=$(printf '%s' "$blob" | awk 'BEGIN{RS="{"} /"pingtime"[[:space:]]*:/{for(i=1;i<=NF;i++) if($i ~ /"pingtime"/) {v=$(i+1); gsub(/[,:}]/,"",v); if(v!="" && v>m)m=v}} END{if(m>0) printf "%.2f", (m*1000); else printf ""}')
  high=$(printf '%s' "$blob" | awk 'BEGIN{RS="{";c=0} /"pingtime"[[:space:]]*:/{for(i=1;i<=NF;i++) if($i ~ /"pingtime"/) {v=$(i+1); gsub(/[,:}]/,"",v); if(v!="" && v+0>0.8)c++}} END{print c+0}')
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$total" "$inbound" "$outbound" "$avg" "$max" "$high"
}

psi_avg10(){
  awk -F'[ =]' '/some/ {for(i=1;i<=NF;i++) if($i=="avg10") print $(i+1)}' "$1" 2>/dev/null | head -n1
}

json_bool_field(){
  local name="$1" blob="$2"
  printf '%s' "$blob" | sed -n "s/.*\"${name}\"[[:space:]]*:[[:space:]]*\\([^,}]*\\).*/\\1/p" | tr -d ' ' | head -n1
}

json_num_field(){
  local name="$1" blob="$2"
  printf '%s' "$blob" | sed -n "s/.*\"${name}\"[[:space:]]*:[[:space:]]*\\([0-9.-]*\\).*/\\1/p" | head -n1
}

sample_n=0

read -r u1 n1 s1 i1 w1 irq1 sirq1 st1 g1 < <(get_cpu)
sleep 1
read -r u2 n2 s2 i2 w2 irq2 sirq2 st2 g2 < <(get_cpu)

while true; do
  sample_n=$((sample_n+1))
  ts="$(date '+%F %T')"

  read -r load1 load5 load15 _ < /proc/loadavg

  total1=$((u1+n1+s1+i1+w1+irq1+sirq1+st1+g1))
  total2=$((u2+n2+s2+i2+w2+irq2+sirq2+st2+g2))
  idle1=$((i1+w1))
  idle2=$((i2+w2))
  dt=$((total2-total1))
  di=$((idle2-idle1))
  den=$((dt==0?1:dt))

  cpu_idle=$((100*di/den))
  cpu_user=$((100*((u2-u1)+(n2-n1))/den))
  cpu_system=$((100*((s2-s1)+(irq2-irq1)+(sirq2-sirq1))/den))

  read -r u1 n1 s1 i1 w1 irq1 sirq1 st1 g1 <<< "$u2 $n2 $s2 $i2 $w2 $irq2 $sirq2 $st2 $g2"
  sleep 1
  read -r u2 n2 s2 i2 w2 irq2 sirq2 st2 g2 < <(get_cpu)

  mem_total=$(awk '/MemTotal:/{print $2}' /proc/meminfo)
  mem_avail=$(awk '/MemAvailable:/{print $2}' /proc/meminfo)
  swap_total=$(awk '/SwapTotal:/{print $2}' /proc/meminfo)
  swap_free=$(awk '/SwapFree:/{print $2}' /proc/meminfo)

  root_use=$(df -P / | awk 'NR==2{gsub(/%/,"",$5);print $5}')
  datadir_use=$(df -P "$DATA_DIR" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5);print $5}')
  [ -z "${datadir_use:-}" ] && datadir_use="$root_use"

  iface=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  rx_bytes=0
  tx_bytes=0
  if [ -n "${iface:-}" ] && [ -r "/sys/class/net/$iface/statistics/rx_bytes" ]; then
    rx_bytes=$(cat "/sys/class/net/$iface/statistics/rx_bytes")
    tx_bytes=$(cat "/sys/class/net/$iface/statistics/tx_bytes")
  fi

  established=$(ss -tan 2>/dev/null | awk 'NR>1 && $1=="ESTAB"{c++} END{print c+0}')

  proc_line=$(ps -C "$(basename "$DAEMON_BIN")" -o pid=,%cpu=,%mem=,rss=,nlwp= 2>/dev/null | head -n1 | xargs)
  defcond_pid=""
  defcond_cpu=0
  defcond_mem=0
  defcond_rss=0
  defcond_threads=0
  defcond_fd_count=0
  if [ -n "${proc_line:-}" ]; then
    read -r defcond_pid defcond_cpu defcond_mem defcond_rss defcond_threads <<< "$proc_line"
    [ -d "/proc/$defcond_pid/fd" ] && defcond_fd_count=$(find "/proc/$defcond_pid/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
  fi

  io_ms=""
  if [ "${IO_TEST_ENABLED:-1}" = "1" ] && [ -w "$DATA_DIR" ]; then
    io_test_file="$DATA_DIR/.dfcn_io_test"
    start_ns=$(date +%s%N)
    printf 'x' > "$io_test_file" 2>/dev/null || true
    end_ns=$(date +%s%N)
    delta_ns=$((end_ns-start_ns))
    io_ms=$((delta_ns/1000000))
    rm -f "$io_test_file" 2>/dev/null || true
  fi

  chain_blocks=""
  headers=""
  verificationprogress=""
  initialblockdownload=""
  connections=""
  mnsync_blockchain=""
  mnsync_mnlist=""
  mnsync_winners=""
  mnsync_synced=""
  mn_state=""
  pose_penalty=""
  pose_banheight=""
  pose_is_banned="0"
  chaintips_total=""
  chaintips_forks=""
  chaintips_headers_only=""
  memberof_count=""
  peer_total=""
  peer_inbound=""
  peer_outbound=""
  peer_ping_avg_ms=""
  peer_ping_max_ms=""
  peer_high_ping_count=""
  ntp_offset_ms=""
  service_restarts=""
  psi_cpu_some_avg10=""
  psi_mem_some_avg10=""
  psi_io_some_avg10=""

  psi_cpu_some_avg10=$(psi_avg10 /proc/pressure/cpu)
  psi_mem_some_avg10=$(psi_avg10 /proc/pressure/memory)
  psi_io_some_avg10=$(psi_avg10 /proc/pressure/io)

  service_restarts=$(systemctl show "$SERVICE_NAME" -p NRestarts --value 2>/dev/null || true)

  if have_cmd chronyc; then
    ntp_offset_ms=$(chronyc tracking 2>/dev/null | awk -F':' '/System time/{gsub(/^[[:space:]]+| seconds.*/,"",$2); print ($2*1000)}' | head -n1)
  fi

  if [ -x "$CLI_BIN" ]; then
    info=$(timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getblockchaininfo 2>/dev/null || true)
    net=$(timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getnetworkinfo 2>/dev/null || true)
    mn=$(timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getmasternodestatus 2>/dev/null || timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" masternode status 2>/dev/null || true)
    mns=$(timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" mnsync status 2>/dev/null || true)
    tips=$(timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getchaintips 2>/dev/null || true)
    peers_json=$(timeout 30 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getpeerinfo 2>/dev/null || true)

    chain_blocks=$(json_num_field blocks "$info")
    headers=$(json_num_field headers "$info")
    verificationprogress=$(printf '%s' "$info" | sed -n 's/.*"verificationprogress"[[:space:]]*:[[:space:]]*\([0-9.]*\).*/\1/p' | head -n1)
    initialblockdownload=$(json_bool_field initialblockdownload "$info")
    connections=$(json_num_field connections "$net")

    mnsync_blockchain=$(json_bool_field IsBlockchainSynced "$mns")
    mnsync_mnlist=$(json_bool_field IsMasternodeListSynced "$mns")
    mnsync_winners=$(json_bool_field IsWinnersListSynced "$mns")
    mnsync_synced=$(json_bool_field IsSynced "$mns")

    mn_state=$(printf '%s' "$mn" | sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
    [ -z "${mn_state:-}" ] && mn_state=$(printf '%s' "$mn" | tr '\n' ' ' | tr ',' ';' | tr -d '"' | cut -c1-220)

    protx_info=""
    if [ -n "${PROTX_HASH:-}" ]; then
      protx_info=$(timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" protx info "$PROTX_HASH" 2>/dev/null || true)
      pose_penalty=$(json_num_field PoSePenalty "$protx_info")
      pose_banheight=$(json_num_field PoSeBanHeight "$protx_info")
      if [ -n "${pose_banheight:-}" ] && [ "${pose_banheight:-0}" -gt 0 ] 2>/dev/null; then
        pose_is_banned="1"
      fi
    fi

    memberof_raw=""
    if [ -n "${PROTX_HASH:-}" ]; then
      memberof_raw=$(timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum memberof "$PROTX_HASH" 2>/dev/null || true)
    else
      memberof_raw=$(timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum memberof 2>/dev/null || true)
    fi

    if have_cmd jq; then
      chaintips_total=$(printf '%s' "$tips" | jq 'length' 2>/dev/null || true)
      chaintips_forks=$(printf '%s' "$tips" | jq '[.[] | select(.status!="active")] | length' 2>/dev/null || true)
      chaintips_headers_only=$(printf '%s' "$tips" | jq '[.[] | select(.status=="headers-only")] | length' 2>/dev/null || true)
      memberof_count=$(printf '%s' "$memberof_raw" | jq '[.. | objects | select(has("quorumHash"))] | length' 2>/dev/null || true)
      read -r peer_total peer_inbound peer_outbound peer_ping_avg_ms peer_ping_max_ms peer_high_ping_count <<< "$(printf '%s' "$peers_json" | peer_summary_with_jq | tr '\t' ' ')"
    else
      chaintips_total=$(printf '%s' "$tips" | grep -c '"height"' || true)
      chaintips_forks=$(printf '%s' "$tips" | grep -c '"status"[[:space:]]*:[[:space:]]*"\(valid-fork\|valid-headers\|headers-only\|invalid\)"' || true)
      chaintips_headers_only=$(printf '%s' "$tips" | grep -c '"status"[[:space:]]*:[[:space:]]*"headers-only"' || true)
      memberof_count=$(printf '%s' "$memberof_raw" | grep -c '"quorumHash"' || true)
      read -r peer_total peer_inbound peer_outbound peer_ping_avg_ms peer_ping_max_ms peer_high_ping_count <<< "$(peer_summary_plain "$peers_json" | tr '\t' ' ')"
    fi

    if [ "${LOG_LEVEL:-basic}" = "debug" ] || [ $((sample_n % 5)) -eq 0 ]; then
      printf '%s | mnsync status\n%s\n\n' "$ts" "$mns" >> "$MNSYNC_LOG"
      printf '%s | getchaintips\n%s\n\n' "$ts" "$tips" >> "$CHAINTIPS_LOG"
      printf '%s | quorum memberof\n%s\n\n' "$ts" "$memberof_raw" >> "$MEMBEROF_LOG"
      [ -n "${protx_info:-}" ] && printf '%s | protx info %s\n%s\n\n' "$ts" "$PROTX_HASH" "$protx_info" >> "$PROTX_LOG"
      printf '%s | quorum dkgstatus\n' "$ts" >> "$QUORUM_LOG"
      timeout 30 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum dkgstatus 2>/dev/null >> "$QUORUM_LOG" || true
      printf '\n\n' >> "$QUORUM_LOG"
    fi

    if [ "${LOG_LEVEL:-basic}" = "debug" ]; then
      printf '%s | getpeerinfo\n' "$ts" >> "$PEER_LOG"
      printf '%s' "$peers_json" | head -c "$((PEER_SAMPLE_MAXKB*1024))" >> "$PEER_LOG" || true
      printf '\n\n' >> "$PEER_LOG"
    fi
  fi

  row=(
    "$ts"
    "$load1" "$load5" "$load15"
    "$cpu_user" "$cpu_system" "$cpu_idle"
    "$mem_total" "$mem_avail" "$swap_total" "$swap_free"
    "$root_use" "$datadir_use"
    "$rx_bytes" "$tx_bytes"
    "$established"
    "$defcond_cpu" "$defcond_mem" "$defcond_rss" "$defcond_threads" "$defcond_fd_count"
    "${io_ms:-}"
    "${chain_blocks:-}" "${headers:-}" "${verificationprogress:-}" "${initialblockdownload:-}"
    "${connections:-}"
    "${mnsync_blockchain:-}" "${mnsync_mnlist:-}" "${mnsync_winners:-}" "${mnsync_synced:-}"
    "${mn_state:-}"
    "${pose_penalty:-}" "${pose_banheight:-}" "${pose_is_banned:-0}"
    "${chaintips_total:-}" "${chaintips_forks:-}" "${chaintips_headers_only:-}" "${memberof_count:-}"
    "${peer_total:-}" "${peer_inbound:-}" "${peer_outbound:-}" "${peer_ping_avg_ms:-}" "${peer_ping_max_ms:-}" "${peer_high_ping_count:-}"
    "${ntp_offset_ms:-}" "${service_restarts:-}"
    "${psi_cpu_some_avg10:-}" "${psi_mem_some_avg10:-}" "${psi_io_some_avg10:-}"
  )
  (
    IFS=,
    printf '%s\n' "${row[*]}"
  ) >> "$TS_CSV"

  find "$LOG_DIR" -type f -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true
  sleep "$INTERVAL"
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
POSE_TIMELINE="${LOG_DIR}/pose-timeline.csv"
ALERTS_CSV="${LOG_DIR}/alerts.csv"
LAST_POSE_FILE="${RUN_DIR}/last_pose_penalty"

[ -f "$ALERTS_CSV" ] || echo 'timestamp,severity,source,pattern,details' > "$ALERTS_CSV"
[ -f "$POSE_TIMELINE" ] || echo 'timestamp,pose_penalty,pose_banheight,pose_is_banned,mn_state,mnsync_synced,memberof_count' > "$POSE_TIMELINE"

trap 'rm -f "${RUN_DIR}/event_sampler.pid"' EXIT

json_bool_field(){
  local name="$1" blob="$2"
  printf '%s' "$blob" | sed -n "s/.*\"${name}\"[[:space:]]*:[[:space:]]*\\([^,}]*\\).*/\\1/p" | tr -d ' ' | head -n1
}

json_num_field(){
  local name="$1" blob="$2"
  printf '%s' "$blob" | sed -n "s/.*\"${name}\"[[:space:]]*:[[:space:]]*\\([0-9.-]*\\).*/\\1/p" | head -n1
}

while true; do
  ts="$(date '+%F %T')"

  svc=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)
  [ "$svc" != "active" ] && printf '%s,HIGH,systemd,service_inactive,%s\n' "$ts" "$svc" >> "$ALERTS_CSV"

  restarts=$(systemctl show "$SERVICE_NAME" -p NRestarts --value 2>/dev/null || true)
  [ -n "${restarts:-}" ] && [ "$restarts" -gt 0 ] 2>/dev/null && printf '%s,INFO,systemd,restarts,%s\n' "$ts" "$restarts" >> "$ALERTS_CSV"

  if [ -x "$CLI_BIN" ]; then
    mn=$(timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getmasternodestatus 2>/dev/null || timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" masternode status 2>/dev/null || true)
    mns=$(timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" mnsync status 2>/dev/null || true)
    quorum=$(timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum dkgstatus 2>/dev/null || true)
    peers=$(timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getpeerinfo 2>/dev/null || true)
    tips=$(timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getchaintips 2>/dev/null || true)
    qlist=$(timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum list 2>/dev/null || true)

    memberof_raw=""
    if [ -n "${PROTX_HASH:-}" ]; then
      memberof_raw=$(timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum memberof "$PROTX_HASH" 2>/dev/null || true)
    else
      memberof_raw=$(timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum memberof 2>/dev/null || true)
    fi

    protx_info=""
    pose_penalty=""
    pose_banheight=""
    pose_is_banned="0"

    if [ -n "${PROTX_HASH:-}" ]; then
      protx_info=$(timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" protx info "$PROTX_HASH" 2>/dev/null || true)
      pose_penalty=$(json_num_field PoSePenalty "$protx_info")
      pose_banheight=$(json_num_field PoSeBanHeight "$protx_info")
      if [ -n "${pose_banheight:-}" ] && [ "${pose_banheight:-0}" -gt 0 ] 2>/dev/null; then
        pose_is_banned="1"
      fi
    fi

    mn_state=$(printf '%s' "$mn" | sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
    [ -z "${mn_state:-}" ] && mn_state=$(printf '%s' "$mn" | tr '\n' ' ' | tr ',' ';' | tr -d '"' | cut -c1-180)

    mnsync_synced=$(json_bool_field IsSynced "$mns")
    memberof_count=$(printf '%s' "$memberof_raw" | grep -c '"quorumHash"' || true)

    printf '%s,%s,%s,%s,%s,%s,%s\n' \
      "$ts" "${pose_penalty:-}" "${pose_banheight:-}" "${pose_is_banned:-0}" "${mn_state:-}" "${mnsync_synced:-}" "${memberof_count:-0}" \
      >> "$POSE_TIMELINE"

    printf '===== %s =====\n[Masternode]\n%s\n\n[MNSync]\n%s\n\n[ProTx]\n%s\n\n[MemberOf]\n%s\n\n[QuorumList]\n%s\n\n[QuorumDKG]\n%s\n\n[ChainTips]\n%s\n\n' \
      "$ts" "$mn" "$mns" "$protx_info" "$memberof_raw" "$qlist" "$quorum" "$tips" >> "$EVENT_LOG"

    if [ -n "${pose_penalty:-}" ]; then
      prev_pose="$(cat "$LAST_POSE_FILE" 2>/dev/null || true)"
      if [ -n "${prev_pose:-}" ] && [ "$pose_penalty" -gt "$prev_pose" ] 2>/dev/null; then
        delta=$((pose_penalty - prev_pose))
        sev="MEDIUM"
        [ "$delta" -gt 5 ] && sev="HIGH"
        printf '%s,%s,protx,pose_penalty_jump,prev=%s new=%s delta=%s\n' "$ts" "$sev" "$prev_pose" "$pose_penalty" "$delta" >> "$ALERTS_CSV"
        printf '===== %s =====\n[POSE CHANGE]\nprev=%s new=%s delta=%s\n\n[Masternode]\n%s\n\n[MNSync]\n%s\n\n[ProTx]\n%s\n\n[MemberOf]\n%s\n\n[QuorumDKG]\n%s\n\n[ChainTips]\n%s\n\n' \
          "$ts" "$prev_pose" "$pose_penalty" "$delta" "$mn" "$mns" "$protx_info" "$memberof_raw" "$quorum" "$tips" >> "$POSE_LOG"
      fi
      echo "$pose_penalty" > "$LAST_POSE_FILE"
    fi

    if [ "${pose_is_banned:-0}" = "1" ]; then
      printf '%s,HIGH,protx,pose_banned,banheight=%s penalty=%s\n' "$ts" "${pose_banheight:-}" "${pose_penalty:-}" >> "$ALERTS_CSV"
    fi

    if [ "${mnsync_synced:-}" != "true" ] && [ -n "${mnsync_synced:-}" ]; then
      printf '%s,MEDIUM,mnsync,not_synced,%s\n' "$ts" "$mnsync_synced" >> "$ALERTS_CSV"
    fi

    tip_forks=$(printf '%s' "$tips" | grep -c '"status"[[:space:]]*:[[:space:]]*"\(valid-fork\|valid-headers\|headers-only\|invalid\)"' || true)
    tip_headers_only=$(printf '%s' "$tips" | grep -c '"status"[[:space:]]*:[[:space:]]*"headers-only"' || true)
    [ "${tip_forks:-0}" -gt 0 ] 2>/dev/null && printf '%s,MEDIUM,chain,chaintip_forks,%s\n' "$ts" "$tip_forks" >> "$ALERTS_CSV"
    [ "${tip_headers_only:-0}" -gt 0 ] 2>/dev/null && printf '%s,MEDIUM,chain,headers_only_tips,%s\n' "$ts" "$tip_headers_only" >> "$ALERTS_CSV"

    peer_total=$(printf '%s' "$peers" | grep -c '"addr"' || true)
    [ "${peer_total:-0}" -lt 3 ] 2>/dev/null && printf '%s,MEDIUM,network,few_peers,%s\n' "$ts" "$peer_total" >> "$ALERTS_CSV"

    blob="$(printf '%s\n%s\n%s\n%s\n%s\n%s' "$mn" "$mns" "$protx_info" "$memberof_raw" "$quorum" "$tips")"
    for pat in 'pose' 'banned' 'timeout' 'quorum' 'not capable' 'watchdog' 'misbehav' 'fork' 'headers' 'invalid' 'error' 'failed'; do
      if printf '%s' "$blob" | grep -qi "$pat"; then
        printf '%s,MEDIUM,rpc,%s,match found\n' "$ts" "$pat" >> "$ALERTS_CSV"
      fi
    done
  fi

  if have_cmd chronyc; then
    chronyc tracking 2>/dev/null | awk -v ts="$ts" -F':' '/System time/ {gsub(/^[[:space:]]+| seconds.*/,"",$2); v=$2*1000; if (v>200 || v<-200) printf "%s,MEDIUM,ntp,offset_ms,%s\n", ts, v }' >> "$ALERTS_CSV" || true
  fi

  dmesg -T 2>/dev/null | grep -iE 'out of memory|oom|killed process' | tail -n 1 | awk -v ts="$ts" 'NF{printf "%s,HIGH,kernel,oom,%s\n", ts, $0}' >> "$ALERTS_CSV" || true

  sleep "$EVENT_INTERVAL"
done
EOF2
chmod +x "$EVENT_SCRIPT"
}

start_journal_follow(){
  load_config
  if [ -f "$TAIL_PID_FILE" ] && kill -0 "$(cat "$TAIL_PID_FILE")" 2>/dev/null; then
    return 0
  fi
  nohup bash -c "journalctl -u '$SERVICE_NAME' -f -o short-iso >> '$LOG_DIR/journal-follow.log' 2>&1" >/dev/null 2>&1 &
  echo $! > "$TAIL_PID_FILE"
}

start_event_sampler(){
  write_event_sampler
  if [ -f "$EVENT_PID_FILE" ] && kill -0 "$(cat "$EVENT_PID_FILE")" 2>/dev/null; then
    return 0
  fi
  nohup ionice -c "$IONICE_CLASS" nice -n "$NICE_LEVEL" "$EVENT_SCRIPT" >> "$LOG_DIR/event-sampler-stdout.log" 2>&1 &
  sleep 1
}

start_monitor(){
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
  echo "Recommended next steps: menu 9 (exit script; background logging continues), later menu 2 (stop + report)."
}

stop_monitor(){
  local any=0 pid f
  for f in "$PID_FILE" "$TAIL_PID_FILE" "$EVENT_PID_FILE"; do
    if [ -f "$f" ]; then
      pid="$(cat "$f" 2>/dev/null || true)"
      if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
        any=1
        kill "$pid" 2>/dev/null || true
        sleep 1
        kill -9 "$pid" 2>/dev/null || true
      fi
      rm -f "$f"
    fi
  done
  if [ "$any" -eq 1 ]; then
    log "All background processes stopped"
  else
    log "No running background processes found"
  fi
}

write_instant_analysis(){
  load_config
  local out="$1"
  {
    echo "# Instant analysis"
    echo
    echo "Generated: $(date -Is)"
    echo
    echo "## Quick verdict"
    echo "This instant analysis works even if long-term logging has never been started. It is a point-in-time diagnostic snapshot only."
    echo
    echo "## Service"
    systemctl is-active "$SERVICE_NAME" 2>/dev/null || true
    systemctl show "$SERVICE_NAME" -p NRestarts -p ExecMainPID -p ExecMainStatus --no-pager 2>/dev/null || true
    echo
    echo "## Time sync"
    timedatectl 2>/dev/null || true
    chronyc tracking 2>/dev/null || true
    chronyc sources -v 2>/dev/null || true
    echo
    echo "## Pressure stall"
    for f in /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io; do [ -r "$f" ] && echo "--- $f ---" && cat "$f"; done
    echo
    echo "## OOM / kernel hints"
    dmesg -T 2>/dev/null | grep -iE 'out of memory|oom|killed process' | tail -n 30 || true
    echo
    echo "## Chain / masternode / quorum"
    if [ -x "$CLI_BIN" ]; then
      timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getblockchaininfo 2>&1 || true
      echo
      timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getnetworkinfo 2>&1 || true
      echo
      timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getchaintips 2>&1 || true
      echo
      timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getmasternodestatus 2>&1 || timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" masternode status 2>&1 || true
      echo
      timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" mnsync status 2>&1 || true
      echo
      timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum dkgstatus 2>&1 || true
      echo
      if [ -n "${PROTX_HASH:-}" ]; then
        timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" protx info "$PROTX_HASH" 2>&1 || true
        echo
        timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum memberof "$PROTX_HASH" 2>&1 || true
      else
        timeout 20 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" quorum memberof 2>&1 || true
      fi
      echo
      echo "## Peer summary"
      peers=$(timeout 25 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getpeerinfo 2>/dev/null || true)
      if have_cmd jq; then
        printf '%s' "$peers" | jq -r '{total:length,inbound:(map(select(.inbound==true))|length),outbound:(map(select(.inbound==false))|length),avg_ping_ms:(map(select(.pingtime!=null)|.pingtime)|if length>0 then ((add/length)*1000) else null end),max_ping_ms:(map(select(.pingtime!=null)|.pingtime)|if length>0 then (max*1000) else null end),high_ping_count_gt_800ms:(map(select(.pingtime!=null and .pingtime>0.8))|length)}'
      else
        printf 'total=%s\n' "$(printf '%s' "$peers" | awk 'BEGIN{RS="{";c=0} /"addr"[[:space:]]*:/{c++} END{print c+0}')"
        printf 'inbound=%s\n' "$(printf '%s' "$peers" | awk 'BEGIN{RS="{";c=0} /"addr"[[:space:]]*:/ && /"inbound"[[:space:]]*:[[:space:]]*true/{c++} END{print c+0}')"
        printf 'outbound=%s\n' "$(printf '%s' "$peers" | awk 'BEGIN{RS="{";c=0} /"addr"[[:space:]]*:/ && /"inbound"[[:space:]]*:[[:space:]]*false/{c++} END{print c+0}')"
      fi
    else
      echo "CLI not found: $CLI_BIN"
    fi
    echo
    echo "## Journal tail"
    journalctl -u "$SERVICE_NAME" -n "$JOURNAL_LINES" --no-pager 2>/dev/null || true
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

get_idx(){
  awk -F',' -v name="$1" 'NR==1{for(i=1;i<=NF;i++) if($i==name){print i; exit}}' "$TS_CSV"
}

{
  echo "# DFCN Masternode VPS Inspector Report"
  echo
  echo "Generated: $(date -Is)"
  echo
  echo "## Summary"

  if [ -f "$TS_CSV" ]; then
    total_samples=$(($(wc -l < "$TS_CSV")-1))
    echo "- Samples: $total_samples"

    idx_load1=$(get_idx load1)
    idx_mem_avail=$(get_idx mem_avail_kb)
    idx_defcpu=$(get_idx defcond_cpu_pct)
    idx_defmem=$(get_idx defcond_mem_pct)
    idx_fd=$(get_idx defcond_fd_count)
    idx_io=$(get_idx io_ms)
    idx_conn=$(get_idx connections)
    idx_blocks=$(get_idx chain_blocks)
    idx_headers=$(get_idx headers)
    idx_ibd=$(get_idx initialblockdownload)
    idx_mnsync=$(get_idx mnsync_synced)
    idx_pose=$(get_idx pose_penalty)
    idx_pose_banned=$(get_idx pose_is_banned)
    idx_tip_forks=$(get_idx chaintips_forks)
    idx_tip_headers=$(get_idx chaintips_headers_only)
    idx_memberof=$(get_idx memberof_count)
    idx_highping=$(get_idx peer_high_ping_count)
    idx_ntp=$(get_idx ntp_offset_ms)
    idx_restarts=$(get_idx service_restarts)
    idx_psi_mem=$(get_idx psi_mem_some_avg10)

    max_load=$(awk -F',' -v c="$idx_load1" 'NR>1 && c>0{if($c>m)m=$c} END{print m+0}' "$TS_CSV")
    min_mem=$(awk -F',' -v c="$idx_mem_avail" 'NR>1 && c>0{if(min==""||$c<min)min=$c} END{print min+0}' "$TS_CSV")
    max_cpu=$(awk -F',' -v c="$idx_defcpu" 'NR>1 && c>0{if($c>m)m=$c} END{print m+0}' "$TS_CSV")
    max_mem=$(awk -F',' -v c="$idx_defmem" 'NR>1 && c>0{if($c>m)m=$c} END{print m+0}' "$TS_CSV")
    max_fd=$(awk -F',' -v c="$idx_fd" 'NR>1 && c>0{if($c>m)m=$c} END{print m+0}' "$TS_CSV")
    max_io=$(awk -F',' -v c="$idx_io" 'NR>1 && c>0{if($c>m)m=$c} END{print m+0}' "$TS_CSV")
    max_memberof=$(awk -F',' -v c="$idx_memberof" 'NR>1 && c>0 && $c!=""{if($c>m)m=$c} END{print m+0}' "$TS_CSV")

    low_conn=$(awk -F',' -v c="$idx_conn" 'NR>1 && c>0 && ($c=="" || $c+0<3){d++} END{print d+0}' "$TS_CSV")
    lagging=$(awk -F',' -v b="$idx_blocks" -v h="$idx_headers" 'NR>1 && b>0 && h>0 && $b!="" && $h!="" && ($h-$b)>3 {d++} END{print d+0}' "$TS_CSV")
    ibd_samples=$(awk -F',' -v c="$idx_ibd" 'NR>1 && c>0 && $c=="true"{d++} END{print d+0}' "$TS_CSV")
    mnsync_bad=$(awk -F',' -v c="$idx_mnsync" 'NR>1 && c>0 && $c!="" && $c!="true"{d++} END{print d+0}' "$TS_CSV")
    high_ping=$(awk -F',' -v c="$idx_highping" 'NR>1 && c>0 && $c!="" && $c+0>0{d++} END{print d+0}' "$TS_CSV")
    ntp_bad=$(awk -F',' -v c="$idx_ntp" 'NR>1 && c>0 && $c!="" && ($c+0>200 || $c+0<-200){d++} END{print d+0}' "$TS_CSV")
    psi_mem_bad=$(awk -F',' -v c="$idx_psi_mem" 'NR>1 && c>0 && $c!="" && $c+0>1{d++} END{print d+0}' "$TS_CSV")
    restart_samples=$(awk -F',' -v c="$idx_restarts" 'NR>1 && c>0 && $c!="" && $c+0>0{d++} END{print d+0}' "$TS_CSV")
    pose_load=$(awk -F',' -v c1="$idx_load1" -v cp="$idx_pose" 'NR>1 && c1>0 && cp>0 && $cp!=""{if($c1>2.0 && $cp+0>0) d++} END{print d+0}' "$TS_CSV")
    pose_jumps=$(awk -F',' -v cp="$idx_pose" 'NR>1 && cp>0 && $cp!=""{if(prev!="" && ($cp+0)>(prev+5)) d++; prev=$cp+0} END{print d+0}' "$TS_CSV")
    pose_banned_samples=$(awk -F',' -v c="$idx_pose_banned" 'NR>1 && c>0 && $c=="1"{d++} END{print d+0}' "$TS_CSV")
    tip_forks=$(awk -F',' -v c="$idx_tip_forks" 'NR>1 && c>0 && $c!="" && $c+0>0{d++} END{print d+0}' "$TS_CSV")
    tip_headers=$(awk -F',' -v c="$idx_tip_headers" 'NR>1 && c>0 && $c!="" && $c+0>0{d++} END{print d+0}' "$TS_CSV")

    echo "- Max load1: $max_load"
    echo "- Max defcond CPU %: $max_cpu"
    echo "- Max defcond MEM %: $max_mem"
    echo "- Max open file descriptors: $max_fd"
    echo "- Max IO latency ms (datadir): $max_io"
    echo "- Min MemAvailable KB: $min_mem"
    echo "- Samples with few connections (<3): $low_conn"
    echo "- Samples with header/block lag > 3: $lagging"
    echo "- Samples with initialblockdownload=true: $ibd_samples"
    echo "- Samples with mnsync not fully synced: $mnsync_bad"
    echo "- Samples with high-ping peers (>800 ms): $high_ping"
    echo "- Samples with significant NTP offset (>200 ms): $ntp_bad"
    echo "- Samples with memory PSI avg10 > 1: $psi_mem_bad"
    echo "- Samples with service restarts > 0: $restart_samples"
    echo "- Samples with high load and non-zero PoSe penalty: $pose_load"
    echo "- Significant PoSe penalty jumps (>5): $pose_jumps"
    echo "- Samples with PoSe banned state: $pose_banned_samples"
    echo "- Samples with non-active chain tips: $tip_forks"
    echo "- Samples with headers-only chain tips: $tip_headers"
    echo "- Max observed quorum memberships for this ProTx: $max_memberof"

    [ "${max_load%.*}" -ge 3 ] && score_line 2
    [ "$min_mem" -lt 262144 ] && score_line 3
    [ "${max_cpu%.*}" -ge 90 ] && score_line 2
    [ "$low_conn" -ge 10 ] && score_line 2
    [ "$lagging" -ge 10 ] && score_line 2
    [ "$ibd_samples" -ge 1 ] && score_line 2
    [ "$mnsync_bad" -ge 3 ] && score_line 2
    [ "$high_ping" -ge 10 ] && score_line 2
    [ "$ntp_bad" -ge 3 ] && score_line 2
    [ "$psi_mem_bad" -ge 3 ] && score_line 3
    [ "$tip_forks" -ge 1 ] && score_line 2
    [ "$pose_banned_samples" -ge 1 ] && score_line 2
  else
    echo "- No timeseries data found"
    score_line 1
  fi

  echo
  echo "## Risk assessment"
  if [ "$score" -le 2 ]; then
    echo "- Low: no clear VPS-level resource issues visible."
  elif [ "$score" -le 6 ]; then
    echo "- Medium: some resource, sync, chain-tip, peer-quality, or connectivity anomalies present."
  else
    echo "- High: VPS, sync state, or chain behavior shows strong instability indicators."
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
    grep -iE 'pose|ban|dkg|quorum|timeout|sync|fork|disconnect|misbehav|error|failed|oom' "${LOG_DIR}/journal-follow.log" | tail -n 300 | sed 's/^/- /' || true
  else
    echo "- No journal follow log found"
  fi

  echo
  echo "## Recommendations"
  echo "- Correlate PoSe jumps with mnsync state, chaintip anomalies, quorum membership, peer quality, and DKG status."
  echo "- If PoSe increases while VPS metrics stay clean, focus on ProTx state, quorum membership timing, and chain consistency."
  echo "- Treat initialblockdownload=true, non-active chain tips, repeated not-synced states, and PoSe banheight > 0 as first-class signals."
  echo "- Keep before/after baselines across cleanup, reindex, and reactivation attempts."
} > "$REPORT_MD"

{
  echo "DFCN short summary"
  echo "Generated: $(date -Is)"
  echo
  [ -f "$TS_CSV" ] && echo "Last 15 rows of timeseries.csv" && tail -n 15 "$TS_CSV"
  echo
  [ -f "$ALERTS_CSV" ] && echo "Last 50 alerts" && tail -n 50 "$ALERTS_CSV"
  echo
  [ -f "${LOG_DIR}/pose-timeline.csv" ] && echo "Last 80 rows of pose-timeline.csv" && tail -n 80 "${LOG_DIR}/pose-timeline.csv"
  echo
  [ -f "${LOG_DIR}/pose-events.log" ] && echo "Last 80 PoSe-related entries" && tail -n 80 "${LOG_DIR}/pose-events.log"
} > "$REPORT_TXT"

printf '%s\n%s\n' "$REPORT_MD" "$REPORT_TXT"
EOF2
chmod +x "$ANALYZE_SCRIPT"
}

generate_report(){
  write_analyze_script
  mapfile -t generated < <("$ANALYZE_SCRIPT")
  log "Reports created:"
  printf ' - %s\n' "${generated[@]}"
  printf '%s\n' "${generated[@]}"
}

instant_analysis(){
  load_config
  out="$REPORT_DIR/instant-analysis-$(date '+%F-%H%M%S').md"
  write_instant_analysis "$out"
  log "Instant analysis created: $out"
  printf '%s\n' "$out"
}

cleanup_all(){
  if ask_yes_no "Really delete ALL inspector data, logs and reports?" n; then
    stop_monitor || true
    rm -rf "$BASE_DIR"
    log "All inspector data removed: $BASE_DIR"
  else
    log "Aborted"
  fi
}

show_status(){
  load_config
  echo
  echo "=== STATUS ==="
  echo "Base dir: $BASE_DIR"
  echo "Install : $INSTALL_PATH_DEFAULT"
  echo "Service : $SERVICE_NAME"
  echo "CLI     : $CLI_BIN"
  echo "Datadir : $DATA_DIR"
  echo "LogLevel: ${LOG_LEVEL:-basic}"
  echo "ProTx   : ${PROTX_HASH:-}"
  echo "IO test : ${IO_TEST_ENABLED:-unset}"
  for f in "$PID_FILE" "$TAIL_PID_FILE" "$EVENT_PID_FILE"; do
    [ -f "$f" ] && echo "$(basename "$f"): $(cat "$f")" || true
  done
  echo
}

selftest() {
  load_config
  {
    echo "Self test viewer hint: Use the arrow keys to scroll, press q to close."
    echo
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
    if have_cmd jq; then
      timeout 15 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getblockchaininfo 2>/dev/null | jq . || true
    else
      timeout 15 "$CLI_BIN" -datadir="$DATA_DIR" -conf="$CONF_FILE" getblockchaininfo 2>/dev/null || true
    fi
  } | less
}

show_workflow(){
cat <<EOF2
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
      if [ -n "$file" ] && [ -f "$file" ] && ask_yes_no "Show the created report now?" y; then
        show_file "$file"
      fi
      if ask_yes_no "Show raw log data now?" n; then
        browse_logs || true
      fi
      ;;
    multi-report)
      if [ -n "$file" ] && [ -f "$file" ] && ask_yes_no "Show the main Markdown report now?" y; then
        show_file "$file"
      fi
      if ask_yes_no "Show raw log data now?" n; then
        browse_logs || true
      fi
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
  9) Exit script

Note: Exiting this menu does not stop background logging once it has been started.

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
      9)
        echo "Exiting menu. Background logging, if started, continues running."
        break
        ;;
      *)
        echo "Invalid choice"
        press_enter
        ;;
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
