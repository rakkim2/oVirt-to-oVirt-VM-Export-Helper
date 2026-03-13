#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_ENV_FILE="${COMMON_ENV_FILE:-${SCRIPT_DIR}/common.env}"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/v2v.conf}"
if [[ -f "$COMMON_ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$COMMON_ENV_FILE"
fi

# Multi-host v2v status watcher.
# Edit HOSTS to the servers you want to monitor.
HOSTS=(
  "root@10.4.157.236"
  # "root@10.4.157.237"
  # "root@10.4.157.238"
)

# Remote paths (usually same layout across v2v nodes).
REMOTE_STATUS_SCRIPT="/data/script/show_v2v_status.sh"
REMOTE_CONFIG_FILE="/data/script/v2v.conf"

# SSH defaults: no host-key prompt for operational convenience.
SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=5
  -o LogLevel=ERROR
)

# Optional (when SSH key is not configured):
# if empty, automatically uses REMOTE_SSH_PASS_FILE from v2v.conf.
SSH_PASS_FILE=""

# auto = detect route interface on remote host.
NET_IFACE="auto"

WATCH="false"
WATCH_SEC="5"
RESET_STATUS_MODE="false"
RESET_STATUS_ONLY="false"
declare -a VM_FILTERS=()

usage() {
  local rc="${1:-1}"
  cat >&2 <<'EOF'
usage:
  all_show_status.sh [--watch[=sec]] [--iface <name>] [vm-name ...]

description:
  Collects each remote host's show_v2v_status output over SSH and prints only
  VM rows as:
    HOSTNAME|VM|PIPE_LOCK|PIPE|START_TIME|LAST_UPDATE|STATE

options:
  --watch           refresh every 5 sec
  --watch=<sec>     refresh every <sec> sec
  -w <sec>          same as --watch=<sec>
  --reset-status    clear stale VM logs/locks on each host once, then show
  --reset-only      clear stale VM logs/locks on each host once, then exit
  --iface <name>    network interface on remote (default: auto)
  -h, --help        show this help
EOF
  exit "$rc"
}

load_local_config() {
  local conf_source=""
  local conf_pass_file=""
  local conf_script_base=""
  local conf_data_base=""
  local conf_remote_pass=""
  local cfg_dir=""

  if [[ -f "$CONFIG_FILE" ]]; then
    if declare -F v2v_load_config_with_env >/dev/null 2>&1; then
      declare -a preserve_keys=(
        SCRIPT_BASE_DIR DATA_BASE_DIR
        REMOTE_SSH_PASS_FILE SSH_PASS_FILE
      )
      conf_source="$(v2v_load_config_with_env "$CONFIG_FILE" "${preserve_keys[@]}" || true)"
      [[ -n "$conf_source" ]] || conf_source="$CONFIG_FILE"
    else
      # shellcheck source=/dev/null
      source "$CONFIG_FILE"
      conf_source="$CONFIG_FILE"
    fi
  fi

  if [[ -z "${SCRIPT_BASE_DIR:-}" ]] && declare -F v2v_read_conf_value >/dev/null 2>&1; then
    conf_script_base="$(v2v_read_conf_value "$CONFIG_FILE" "SCRIPT_BASE_DIR" || true)"
    [[ -n "$conf_script_base" ]] && SCRIPT_BASE_DIR="$conf_script_base"
  fi
  if [[ -z "${DATA_BASE_DIR:-}" ]] && declare -F v2v_read_conf_value >/dev/null 2>&1; then
    conf_data_base="$(v2v_read_conf_value "$CONFIG_FILE" "DATA_BASE_DIR" || true)"
    [[ -n "$conf_data_base" ]] && DATA_BASE_DIR="$conf_data_base"
  fi

  if [[ -z "${REMOTE_SSH_PASS_FILE:-}" ]] && declare -F v2v_read_conf_value >/dev/null 2>&1; then
    conf_remote_pass="$(v2v_read_conf_value "$CONFIG_FILE" "REMOTE_SSH_PASS_FILE" || true)"
    [[ -n "$conf_remote_pass" ]] && REMOTE_SSH_PASS_FILE="$conf_remote_pass"
  fi

  if [[ -z "$SSH_PASS_FILE" && -n "${REMOTE_SSH_PASS_FILE:-}" ]]; then
    SSH_PASS_FILE="$REMOTE_SSH_PASS_FILE"
  fi
  if [[ -n "$SSH_PASS_FILE" ]]; then
    if declare -F v2v_expand_conf_placeholders >/dev/null 2>&1; then
      SSH_PASS_FILE="$(v2v_expand_conf_placeholders "$SSH_PASS_FILE")"
    else
      conf_pass_file="$SSH_PASS_FILE"
      if [[ -n "${SCRIPT_BASE_DIR:-}" ]]; then
        conf_pass_file="${conf_pass_file//'${SCRIPT_BASE_DIR}'/$SCRIPT_BASE_DIR}"
        conf_pass_file="${conf_pass_file//'$SCRIPT_BASE_DIR'/$SCRIPT_BASE_DIR}"
      fi
      if [[ -n "${DATA_BASE_DIR:-}" ]]; then
        conf_pass_file="${conf_pass_file//'${DATA_BASE_DIR}'/$DATA_BASE_DIR}"
        conf_pass_file="${conf_pass_file//'$DATA_BASE_DIR'/$DATA_BASE_DIR}"
      fi
      SSH_PASS_FILE="$conf_pass_file"
    fi

    # Final placeholder fallback when unresolved token remains.
    if [[ "$SSH_PASS_FILE" == *'$'* ]]; then
      cfg_dir="${CONFIG_FILE%/*}"
      [[ -n "$cfg_dir" && "$cfg_dir" != "$CONFIG_FILE" ]] || cfg_dir="$SCRIPT_DIR"
      SSH_PASS_FILE="${cfg_dir%/}/remote-target-passwd"
    fi
  else
    # Common fallback path next to v2v.conf.
    cfg_dir="${CONFIG_FILE%/*}"
    [[ -n "$cfg_dir" && "$cfg_dir" != "$CONFIG_FILE" ]] || cfg_dir="$SCRIPT_DIR"
    if [[ -f "${cfg_dir%/}/remote-target-passwd" ]]; then
      SSH_PASS_FILE="${cfg_dir%/}/remote-target-passwd"
    fi
  fi
}

extract_field() {
  local line="$1"
  local key="$2"
  printf '%s\n' "$line" \
    | awk -v k="$key" '
        {
          for (i=1; i<=NF; i++) {
            if ($i ~ ("^" k "=")) {
              sub("^" k "=", "", $i)
              print $i
              exit
            }
          }
        }
      '
}

fetch_remote() {
  local host="$1"
  shift || true
  local out=""
  local rc=0
  local -a ssh_cmd=()

  if [[ -n "$SSH_PASS_FILE" ]]; then
    if ! command -v sshpass >/dev/null 2>&1; then
      echo "error: SSH_PASS_FILE is set but sshpass is not installed" >&2
      return 2
    fi
    if [[ ! -f "$SSH_PASS_FILE" ]]; then
      echo "error: SSH_PASS_FILE not found: $SSH_PASS_FILE" >&2
      return 2
    fi
    ssh_cmd=(sshpass -f "$SSH_PASS_FILE" ssh "${SSH_OPTS[@]}")
  else
    # Never prompt interactively; fail fast if key auth is unavailable.
    ssh_cmd=(ssh "${SSH_OPTS[@]}" -o BatchMode=yes)
  fi

  out="$(
    "${ssh_cmd[@]}" "$host" \
      NET_IFACE="$NET_IFACE" \
      REMOTE_STATUS_SCRIPT="$REMOTE_STATUS_SCRIPT" \
      REMOTE_CONFIG_FILE="$REMOTE_CONFIG_FILE" \
      RESET_STATUS_MODE="$RESET_STATUS_MODE" \
      RESET_STATUS_ONLY="$RESET_STATUS_ONLY" \
      bash -s -- "$@" 2>&1 <<'EOS'
set -euo pipefail
net_iface="${NET_IFACE:-auto}"
status_script="${REMOTE_STATUS_SCRIPT:-/data/script/show_v2v_status.sh}"
config_file="${REMOTE_CONFIG_FILE:-/data/script/v2v.conf}"
reset_mode="${RESET_STATUS_MODE:-false}"
reset_only="${RESET_STATUS_ONLY:-false}"

is_enabled() {
  local v
  v="$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    1|true|yes|y) return 0 ;;
    *) return 1 ;;
  esac
}

is_pid_alive() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

read_pid_from_lock() {
  local d="$1"
  if [[ -f "${d%/}/pid" ]]; then
    cat "${d%/}/pid" 2>/dev/null || true
  fi
}

reset_vm_state() {
  local vm="$1"
  local vm_lock="${VM_LOCK_BASE_DIR%/}/${vm}.lock"
  local imp_lock="${IMPORT_LOCK_BASE_DIR%/}/${vm}.lock"
  local pid=""
  local active=0

  pid="$(read_pid_from_lock "$vm_lock")"
  if is_pid_alive "$pid"; then
    active=1
  fi
  pid="$(read_pid_from_lock "$imp_lock")"
  if is_pid_alive "$pid"; then
    active=1
  fi

  if (( active == 1 )); then
    echo "warn: skip active vm=${vm}" >&2
    return
  fi

  rm -rf "${V2V_LOG_BASE_DIR%/}/${vm}" "$vm_lock" "$imp_lock"
}

collect_reset_targets() {
  local d=""
  local base=""

  if (( $# > 0 )); then
    printf '%s\n' "$@" | awk 'NF>0' | sort -u
    return
  fi

  {
    for d in "${V2V_LOG_BASE_DIR%/}"/*; do
      [[ -d "$d" ]] || continue
      base="$(basename "$d")"
      printf '%s\n' "$base"
    done
    for d in "${VM_LOCK_BASE_DIR%/}"/*.lock; do
      [[ -d "$d" ]] || continue
      base="$(basename "$d")"
      printf '%s\n' "${base%.lock}"
    done
    for d in "${IMPORT_LOCK_BASE_DIR%/}"/*.lock; do
      [[ -d "$d" ]] || continue
      base="$(basename "$d")"
      printf '%s\n' "${base%.lock}"
    done
  } | awk 'NF>0' | sort -u
}

if [[ "$net_iface" == "auto" || -z "$net_iface" ]]; then
  net_iface="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')"
fi
if [[ -z "$net_iface" || ! -r "/sys/class/net/${net_iface}/statistics/rx_bytes" ]]; then
  net_iface="$(ls -1 /sys/class/net 2>/dev/null | awk '$1!="lo"{print; exit}')"
fi

host_name="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
host_name="$(printf '%s' "$host_name" | tr -cd '[:alnum:]._-')"
[[ -n "$host_name" ]] || host_name="unknown"

rx="0"
tx="0"
if [[ -n "$net_iface" && -r "/sys/class/net/${net_iface}/statistics/rx_bytes" ]]; then
  rx="$(cat "/sys/class/net/${net_iface}/statistics/rx_bytes" 2>/dev/null || echo 0)"
fi
if [[ -n "$net_iface" && -r "/sys/class/net/${net_iface}/statistics/tx_bytes" ]]; then
  tx="$(cat "/sys/class/net/${net_iface}/statistics/tx_bytes" 2>/dev/null || echo 0)"
fi
printf '__NET__ host=%s iface=%s rx=%s tx=%s ts=%s\n' "${host_name}" "${net_iface:-unknown}" "${rx:-0}" "${tx:-0}" "$(date +%s)"

DATA_BASE_DIR="${DATA_BASE_DIR:-/data}"
V2V_BASE_DIR="${V2V_BASE_DIR:-${DATA_BASE_DIR%/}/v2v}"
V2V_LOG_BASE_DIR="${V2V_LOG_BASE_DIR:-${DATA_BASE_DIR%/}/v2v_log}"
VM_LOCK_BASE_DIR="${VM_LOCK_BASE_DIR:-${V2V_BASE_DIR%/}/locks}"
IMPORT_LOCK_BASE_DIR="${IMPORT_LOCK_BASE_DIR:-${V2V_BASE_DIR%/}/locks/import_v2v}"
if [[ -f "$config_file" ]]; then
  # shellcheck source=/dev/null
  source "$config_file" >/dev/null 2>&1 || true
  DATA_BASE_DIR="${DATA_BASE_DIR:-/data}"
  V2V_BASE_DIR="${V2V_BASE_DIR:-${DATA_BASE_DIR%/}/v2v}"
  V2V_LOG_BASE_DIR="${V2V_LOG_BASE_DIR:-${DATA_BASE_DIR%/}/v2v_log}"
  VM_LOCK_BASE_DIR="${VM_LOCK_BASE_DIR:-${V2V_BASE_DIR%/}/locks}"
  IMPORT_LOCK_BASE_DIR="${IMPORT_LOCK_BASE_DIR:-${V2V_BASE_DIR%/}/locks/import_v2v}"
fi

if is_enabled "$reset_mode"; then
  while IFS= read -r vm; do
    [[ -z "$vm" ]] && continue
    reset_vm_state "$vm"
  done < <(collect_reset_targets "$@")
  if is_enabled "$reset_only"; then
    exit 0
  fi
fi

if [[ ! -x "$status_script" && -f "$status_script" ]]; then
  chmod +x "$status_script" 2>/dev/null || true
fi
if [[ -x "$status_script" ]]; then
  CONFIG_FILE="$config_file" bash "$status_script" "$@"
else
  echo "error: remote status script not found/executable: $status_script"
  exit 127
fi
EOS
  )" || rc=$?

  printf '%s' "$out"
  return "$rc"
}

print_once() {
  local host=""
  local output=""
  local rc=0
  local net_line=""
  local status_text=""
  local host_name=""
  local vm_rows=""
  local line=""
  local any_vm="0"
  local host_w=4
  local len=0
  local i=0
  local -a row_hosts=()
  local -a row_lines=()

  for host in "${HOSTS[@]}"; do
    output="$(fetch_remote "$host" "${VM_FILTERS[@]}" || true)"
    rc=$?
    net_line="$(printf '%s\n' "$output" | awk '/^__NET__/ {print; exit}')"
    status_text="$(printf '%s\n' "$output" | awk 'BEGIN{skip=0} /^__NET__/ {skip=1; next} {print}')"

    host_name="$(extract_field "$net_line" "host")"
    [[ "$host_name" =~ ^[[:alnum:]_.-]+$ ]] || host_name="$host"

    vm_rows="$(
      printf '%s\n' "$status_text" \
        | awk -F'|' -v h="$host_name" '
            function is_vm_name(v) {
              return (v ~ /^[[:alnum:]_.:-]+$/ && v != "VM" && v !~ /^--/ && v !~ /^\(/)
            }
            function is_pipe_lock(v) {
              return (v == "-" || v == "stale" || v ~ /^run:[0-9]+$/ || v ~ /^imp:.+/)
            }
            {
              # Legacy prefixed format:
              # HOST|VM|PIPE_LOCK|PIPE|START_TIME|LAST_UPDATE|STATE...
              if ($1 == h && NF >= 7) {
                vm = $2
                pl = $3
                if (is_vm_name(vm) && is_pipe_lock(pl)) {
                  row = $2
                  for (i = 3; i <= NF; i++) row = row "|" $i
                  rows[vm] = row
                }
                next
              }

              # Normal format:
              # VM|PIPE_LOCK|PIPE|START_TIME|LAST_UPDATE|STATE...
              if (NF >= 6) {
                vm = $1
                pl = $2
                if (is_vm_name(vm) && is_pipe_lock(pl)) {
                  rows[vm] = $0
                }
              }
            }
            END {
              for (k in rows) print rows[k]
            }
          ' | sort
    )"

    if [[ -n "$vm_rows" ]]; then
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        row_hosts+=("$host_name")
        row_lines+=("$line")
        len="${#host_name}"
        if (( len > host_w )); then
          host_w="$len"
        fi
        any_vm="1"
      done <<< "$vm_rows"
    fi

    : "${rc}"
  done

  if [[ "$any_vm" != "1" ]]; then
    return
  fi

  printf "%-${host_w}s|VM|PIPE_LOCK|PIPE|START_TIME|LAST_UPDATE|STATE\n" "HOST"
  for (( i=0; i<${#row_hosts[@]}; i++ )); do
    printf "%-${host_w}s|%s\n" "${row_hosts[$i]}" "${row_lines[$i]}"
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch)
      WATCH="true"
      shift
      ;;
    --watch=*)
      WATCH="true"
      WATCH_SEC="${1#*=}"
      shift
      ;;
    -w)
      WATCH="true"
      shift
      [[ $# -gt 0 ]] || usage
      WATCH_SEC="$1"
      shift
      ;;
    --reset-status)
      RESET_STATUS_MODE="true"
      shift
      ;;
    --reset-only)
      RESET_STATUS_MODE="true"
      RESET_STATUS_ONLY="true"
      shift
      ;;
    --iface)
      shift
      [[ $# -gt 0 ]] || usage
      NET_IFACE="$1"
      shift
      ;;
    -h|--help)
      usage 0
      ;;
    *)
      VM_FILTERS+=("$1")
      shift
      ;;
  esac
done

load_local_config

if (( ${#HOSTS[@]} == 0 )); then
  echo "error: HOSTS is empty. edit this script and add remote hosts." >&2
  exit 1
fi

if [[ "$WATCH" == "true" ]]; then
  if [[ ! "$WATCH_SEC" =~ ^[0-9]+$ ]] || (( WATCH_SEC < 1 )); then
    echo "error: watch interval must be integer >= 1 (current: $WATCH_SEC)" >&2
    exit 1
  fi
  if [[ "$RESET_STATUS_ONLY" == "true" ]]; then
    echo "error: --reset-only cannot be combined with --watch" >&2
    exit 1
  fi
  while :; do
    printf '\033[H\033[2J'
    print_once
    RESET_STATUS_MODE="false"
    RESET_STATUS_ONLY="false"
    sleep "$WATCH_SEC"
  done
else
  print_once
  if [[ "$RESET_STATUS_ONLY" == "true" ]]; then
    exit 0
  fi
fi
