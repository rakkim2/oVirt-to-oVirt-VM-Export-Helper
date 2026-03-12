#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_ENV_FILE="${COMMON_ENV_FILE:-${SCRIPT_DIR}/common.env}"
if [[ ! -f "$COMMON_ENV_FILE" ]]; then
  echo "error: common library not found: $COMMON_ENV_FILE" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$COMMON_ENV_FILE"

resolve_xml_path_from_input() {
  local input="$1"
  local candidate=""
  local fallback=""

  if [[ -f "$input" ]]; then
    printf '%s' "$input"
    return 0
  fi

  if [[ "$input" == */* ]]; then
    printf '%s' "$input"
    return 0
  fi

  if [[ "$input" == *.xml ]]; then
    candidate="${XML_OUT_DIR%/}/${input}"
  else
    candidate="${XML_OUT_DIR%/}/${input}.xml"
    fallback="${XML_OUT_DIR%/}/${input}"
  fi

  if [[ -f "$candidate" ]]; then
    printf '%s' "$candidate"
    return 0
  fi
  if [[ -n "$fallback" && -f "$fallback" ]]; then
    printf '%s' "$fallback"
    return 0
  fi

  printf '%s' "$candidate"
}

is_non_negative_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

is_pid_alive() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

wait_pid_exit() {
  local pid="$1"
  local timeout="$2"
  local waited=0

  while (( waited < timeout )); do
    if ! is_pid_alive "$pid"; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  if ! is_pid_alive "$pid"; then
    return 0
  fi
  return 1
}

list_descendants() {
  local root="$1"
  local child=""

  if ! command -v pgrep >/dev/null 2>&1; then
    return 0
  fi

  while IFS= read -r child; do
    [[ -z "$child" ]] && continue
    echo "$child"
    list_descendants "$child"
  done < <(pgrep -P "$root" 2>/dev/null || true)
}

kill_pid_tree() {
  local root="$1"
  local sig="$2"
  local p=""
  local targets=()
  local desc=""

  if is_pid_alive "$root"; then
    while IFS= read -r desc; do
      [[ -z "$desc" ]] && continue
      targets+=("$desc")
    done < <(list_descendants "$root" | awk '!seen[$0]++')
    targets+=("$root")
  fi

  for (( i=${#targets[@]}-1; i>=0; i-- )); do
    p="${targets[$i]}"
    if is_pid_alive "$p"; then
      kill "-${sig}" "$p" 2>/dev/null || true
    fi
  done
}

stop_pipeline_vm() {
  local vm_name="$1"
  local lock_dir="${VM_LOCK_BASE_DIR%/}/${vm_name}.lock"
  local pid_file="${lock_dir}/pid"
  local pid=""

  if [[ ! -d "$lock_dir" ]]; then
    echo "info: no lock found for vm=${vm_name} under ${VM_LOCK_BASE_DIR}" >&2
    return 0
  fi

  if [[ ! -f "$pid_file" ]]; then
    echo "warn: lock exists but pid file missing: ${pid_file}" >&2
    rm -rf "$lock_dir" >/dev/null 2>&1 || true
    return 0
  fi

  pid="$(cat "$pid_file" 2>/dev/null || true)"
  if ! is_pid_alive "$pid"; then
    echo "warn: stale lock (pid not alive): vm=${vm_name} pid=${pid}" >&2
    rm -rf "$lock_dir" >/dev/null 2>&1 || true
    return 0
  fi

  echo "[$(now_ts)] STOP pipeline vm=${vm_name} pid=${pid} wait=${STOP_WAIT_SECONDS}s"
  echo "[$(now_ts)] cmd stop  : TERM process tree rooted at pid=${pid}"
  kill_pid_tree "$pid" TERM

  if ! wait_pid_exit "$pid" "$STOP_WAIT_SECONDS"; then
    echo "[$(now_ts)] cmd stop  : KILL process tree rooted at pid=${pid}"
    kill_pid_tree "$pid" KILL
    sleep 1
  fi

  if is_pid_alive "$pid"; then
    echo "error: failed to stop vm=${vm_name} pid=${pid}" >&2
    return 1
  fi

  rm -rf "$lock_dir" >/dev/null 2>&1 || true
  echo "[$(now_ts)] DONE stop vm=${vm_name}"
  return 0
}

dump_log_tail() {
  local label="$1"
  local path="$2"
  if [[ ! -f "$path" ]]; then
    return 0
  fi
  log "----- ${label}: ${path} (tail -n ${FAILURE_TAIL_LINES}) -----"
  tail -n "$FAILURE_TAIL_LINES" "$path" || true
}

dump_failure_context() {
  local vm_log_dir="${V2V_LOG_BASE_DIR%/}/${VM_NAME}"
  local run_log_dir="${RUN_LOG_DIR:-}"
  local latest_toggle=""
  local latest_convert=""
  local latest_ova=""
  local latest_import=""
  local qlog=""
  local qlog_pattern="${vm_log_dir}/qemu/${VM_NAME}-disk*.log"
  local qemu_count=0

  if (( FAILURE_TAIL_LINES == 0 )); then
    log "failure tail dump disabled (FAILURE_TAIL_LINES=0)"
    return
  fi

  if [[ -n "$run_log_dir" ]]; then
    latest_toggle="$(ls -1t "${run_log_dir}"/toggle_lv_from_xml-*.log 2>/dev/null | head -n1 || true)"
    latest_convert="$(ls -1t "${run_log_dir}"/convert_disks_from_xml-*.log 2>/dev/null | head -n1 || true)"
    latest_ova="$(ls -1t "${run_log_dir}"/make_ovirt_ova-*.log 2>/dev/null | head -n1 || true)"
    latest_import="$(ls -1t "${run_log_dir}"/import_v2v-*.log 2>/dev/null | head -n1 || true)"
    qlog_pattern="${run_log_dir}/qemu/${VM_NAME}-disk*.log"
  else
    latest_toggle="$(ls -1t "${vm_log_dir}"/toggle_lv_from_xml-*.log 2>/dev/null | head -n1 || true)"
    latest_convert="$(ls -1t "${vm_log_dir}"/convert_disks_from_xml-*.log 2>/dev/null | head -n1 || true)"
    latest_ova="$(ls -1t "${vm_log_dir}"/make_ovirt_ova-*.log 2>/dev/null | head -n1 || true)"
    latest_import="$(ls -1t "${vm_log_dir}"/import_v2v-*.log 2>/dev/null | head -n1 || true)"
  fi

  [[ -n "$latest_toggle" ]] && dump_log_tail "toggle_lv_from_xml" "$latest_toggle"
  [[ -n "$latest_convert" ]] && dump_log_tail "convert_disks_from_xml" "$latest_convert"
  [[ -n "$latest_ova" ]] && dump_log_tail "make_ovirt_ova" "$latest_ova"
  [[ -n "$latest_import" ]] && dump_log_tail "import_v2v" "$latest_import"

  while IFS= read -r qlog; do
    [[ -z "$qlog" ]] && continue
    qemu_count=$((qemu_count + 1))
    dump_log_tail "qemu-disk-log#${qemu_count}" "$qlog"
  done < <(ls -1t $qlog_pattern 2>/dev/null | head -n "$FAILURE_QEMU_LOG_COUNT" || true)
}

append_command_result() {
  local step="$1"
  local rc="$2"
  local cmd_text="$3"
  local line=""
  line="$(printf '[%s] vm=%s step=%s rc=%s cmd=%s' "$(now_ts)" "${VM_NAME:-unknown}" "$step" "$rc" "$cmd_text")"
  printf '%s\n' "$line" >>"$RESULT_VM_LOG_FILE"
}

append_run_result_summary() {
  local status="$1"
  local rc="$2"
  local reason="$3"
  local end_ts
  local line=""
  end_ts="$(now_ts)"
  line="$(printf '[%s] vm=%s status=%s rc=%s start=%s end=%s reason=%s pipeline_log=%s' \
    "$end_ts" "${VM_NAME:-unknown}" "$status" "$rc" "${PIPELINE_START_TS:-unknown}" "$end_ts" "$reason" "${PIPELINE_LOG_FILE:-unknown}")"
  printf '%s\n' "$line" | tee -a "$RESULT_VM_LOG_FILE" "$RESULT_GLOBAL_LOG_FILE" >/dev/null
}

append_status_board_snapshot() {
  local phase="$1"
  local status_script="${SCRIPT_DIR}/show_v2v_status.sh"
  {
    printf '===== %s phase=%s trigger_vm=%s =====\n' "$(now_ts)" "$phase" "$VM_NAME"
    if [[ -f "$status_script" ]]; then
      CONFIG_FILE="$CONFIG_FILE" \
      V2V_BASE_DIR="$V2V_BASE_DIR" \
      V2V_LOG_BASE_DIR="$V2V_LOG_BASE_DIR" \
      VM_LOCK_BASE_DIR="$VM_LOCK_BASE_DIR" \
      IMPORT_LOCK_BASE_DIR="${V2V_BASE_DIR%/}/locks/import_v2v" \
      bash "$status_script" || true
    else
      echo "show_v2v_status.sh not found: $status_script"
    fi
    echo
  } 2>&1 | tee -a "$STATUS_BOARD_GLOBAL_LOG_FILE" >/dev/null
}

SELF_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
if [[ -z "${CONFIG_FILE:-}" ]]; then
  CONFIG_FILE="${SCRIPT_DIR}/v2v.conf"
fi

declare -a PRESERVE_ENV_KEYS=(
  DATA_BASE_DIR V2V_BASE_DIR V2V_LOG_BASE_DIR XML_OUT_DIR LIBVIRT_URI
  QEMU_BASE_DIR RAW_BASE_DIR OVA_STAGING_BASE_DIR OVA_OUTPUT_DIR OVA_BASE_DIR
  PIPELINE_LOG_ENABLE BUILD_OVA IMPORT_TO_RHV IMPORT_CSV_PATH
  REMOTE_TARGET_HOST REMOTE_TARGET_USER REMOTE_SSH_PORT REMOTE_SSH_OPTS
  REMOTE_IMPORT_SCRIPT REMOTE_CSV_PATH PRECHECK REMOTE_IMPORT_PRECHECK
  RUN_WITH_NOHUP RUN_ID RUN_LOG_DIR VM_LOCK_BASE_DIR IMPORT_LOCK_BASE_DIR
  FAILURE_TAIL_LINES FAILURE_QEMU_LOG_COUNT STOP_WAIT_SECONDS
)
CONF_SOURCE="$(v2v_load_config_with_env "$CONFIG_FILE" "${PRESERVE_ENV_KEYS[@]}")"

usage() {
  local rc="${1:-1}"
  cat >&2 <<'EOF'
usage:
  run_qemu_ova_pipeline.sh <vm-name|vm-xml>
  run_qemu_ova_pipeline.sh --stop <vm-name>

Pipeline:
  1) toggle_lv_from_xml.sh up
  2) convert_disks_from_xml.sh (parallel qemu-img to qcow2)
  3) make_ovirt_ova.sh (optional, by BUILD_OVA=true)
  4) import_v2v.sh --run-location=remote (optional, by IMPORT_TO_RHV=true; runs import on target and skips OVA stage)
  5) toggle_lv_from_xml.sh down (always on exit)

Inputs:
  - VM input: <vm-name> or <vm-xml>
    - if vm-name is given, XML is auto-resolved from ${XML_OUT_DIR}/<vm-name>.xml
  - V2V_BASE_DIR (default: /data/v2v)
  - V2V_LOG_BASE_DIR (default: /data/v2v_log)
  - XML_OUT_DIR (default: /data/xml)
  - LIBVIRT_URI (default: qemu:///system)
  - QEMU_BASE_DIR (default: ${V2V_BASE_DIR}/qemu)
  - OVA_OUTPUT_DIR (default: ${V2V_BASE_DIR}/ova)
  - OVA_STAGING_BASE_DIR (default: ${OVA_OUTPUT_DIR}/ova_stag)
  - BUILD_OVA (default: true)
  - IMPORT_TO_RHV (default: true when REMOTE_TARGET_HOST is set, else false)
  - IMPORT_CSV_PATH (optional override passed to remote import script)
  - REMOTE_TARGET_HOST / REMOTE_TARGET_USER / REMOTE_IMPORT_SCRIPT (for remote import)
  - PRECHECK (default: false; true면 remote host/engine/storage 사전 점검)
  - RUN_WITH_NOHUP (default: true)
  - VM_LOCK_BASE_DIR (default: ${V2V_BASE_DIR}/locks)
  - VM log dir: /data/v2v_log/<vm>/
    - pipeline log     : pipeline_<YYYY-mm-dd_HHMMSS>.log
  - Status board log (global only):
    - /data/v2v_log/status_board.log
  - Result logs:
    - VM per-run   : /data/v2v_log/<vm>/result-YYYY-mm-dd_HHMMSS.log
    - Global all   : /data/v2v_log/result.log
  - Stop mode uses VM lock pid and terminates pipeline process tree.
  - STOP_WAIT_SECONDS (default: 10) for --stop graceful wait before force kill
EOF
  exit "$rc"
}

MODE="run"
XML_PATH=""
STOP_VM_NAME=""
if [[ $# -eq 1 && ( "${1:-}" == "-h" || "${1:-}" == "--help" ) ]]; then
  usage 0
fi
if [[ $# -eq 2 && "$1" == "--stop" ]]; then
  MODE="stop"
  STOP_VM_NAME="$2"
elif [[ $# -eq 1 ]]; then
  XML_PATH="$1"
else
  usage 1
fi
if [[ -z "${V2V_BASE_DIR+x}" && -n "${DATA_BASE_DIR+x}" ]]; then
  V2V_BASE_DIR="${DATA_BASE_DIR%/}/v2v"
fi
if [[ -z "${QEMU_BASE_DIR+x}" && -n "${RAW_BASE_DIR+x}" ]]; then
  QEMU_BASE_DIR="$RAW_BASE_DIR"
fi
if [[ -z "${OVA_OUTPUT_DIR+x}" && -n "${OVA_BASE_DIR+x}" ]]; then
  OVA_OUTPUT_DIR="$OVA_BASE_DIR"
fi
V2V_BASE_DIR="${V2V_BASE_DIR:-/data/v2v}"
V2V_LOG_BASE_DIR="${V2V_LOG_BASE_DIR:-/data/v2v_log}"
XML_OUT_DIR="${XML_OUT_DIR:-/data/xml}"
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
QEMU_BASE_DIR="${QEMU_BASE_DIR:-${V2V_BASE_DIR%/}/qemu}"
OVA_OUTPUT_DIR="${OVA_OUTPUT_DIR:-${V2V_BASE_DIR%/}/ova}"
OVA_STAGING_BASE_DIR="${OVA_STAGING_BASE_DIR:-${OVA_OUTPUT_DIR%/}/ova_stag}"
PIPELINE_LOG_ENABLE="${PIPELINE_LOG_ENABLE:-1}"
if [[ -z "${BUILD_OVA:-}" ]]; then
  BUILD_OVA="true"
fi
IMPORT_CSV_PATH="${IMPORT_CSV_PATH:-}"
REMOTE_TARGET_HOST="${REMOTE_TARGET_HOST:-}"
REMOTE_TARGET_USER="${REMOTE_TARGET_USER:-root}"
REMOTE_SSH_PORT="${REMOTE_SSH_PORT:-22}"
REMOTE_SSH_OPTS="${REMOTE_SSH_OPTS:-}"
REMOTE_IMPORT_SCRIPT="${REMOTE_IMPORT_SCRIPT:-/data/script/import_v2v.sh}"
REMOTE_CSV_PATH="${REMOTE_CSV_PATH:-}"
IMPORT_CSV_PATH="$(v2v_expand_conf_placeholders "${IMPORT_CSV_PATH:-}")"
REMOTE_IMPORT_SCRIPT="$(v2v_expand_conf_placeholders "$REMOTE_IMPORT_SCRIPT")"
REMOTE_CSV_PATH="$(v2v_expand_conf_placeholders "$REMOTE_CSV_PATH")"

# Fallback for accidental empty effective values after config load:
# re-read critical keys directly from config text.
if [[ -z "$REMOTE_TARGET_HOST" ]]; then
  conf_remote_host="$(v2v_read_conf_value "$CONFIG_FILE" "REMOTE_TARGET_HOST" || true)"
  if [[ -n "$conf_remote_host" ]]; then
    REMOTE_TARGET_HOST="$conf_remote_host"
  fi
fi
if [[ -z "${IMPORT_TO_RHV:-}" ]]; then
  conf_import_to_rhv="$(v2v_read_conf_value "$CONFIG_FILE" "IMPORT_TO_RHV" || true)"
  if [[ -n "$conf_import_to_rhv" ]]; then
    IMPORT_TO_RHV="$conf_import_to_rhv"
  fi
fi

if [[ -z "${IMPORT_TO_RHV:-}" ]]; then
  if [[ -n "$REMOTE_TARGET_HOST" ]]; then
    IMPORT_TO_RHV="true"
  else
    IMPORT_TO_RHV="false"
  fi
fi
BUILD_OVA="$(normalize_bool "$BUILD_OVA")" || exit 1
IMPORT_TO_RHV="$(normalize_bool "$IMPORT_TO_RHV")" || exit 1
if ! v2v_preserved_var_is_set "PRECHECK" && v2v_preserved_var_is_set "REMOTE_IMPORT_PRECHECK"; then
  PRECHECK="${REMOTE_IMPORT_PRECHECK:-false}"
fi
PRECHECK="$(normalize_bool "${PRECHECK:-false}")" || exit 1
RUN_WITH_NOHUP="$(normalize_bool "${RUN_WITH_NOHUP:-true}")" || exit 1
NOHUP_LAUNCHED="${NOHUP_LAUNCHED:-0}"
VM_LOCK_BASE_DIR="${VM_LOCK_BASE_DIR:-${V2V_BASE_DIR%/}/locks}"
IMPORT_LOCK_BASE_DIR="${IMPORT_LOCK_BASE_DIR:-${V2V_BASE_DIR%/}/locks/import_v2v}"
FAILURE_TAIL_LINES="${FAILURE_TAIL_LINES:-120}"
FAILURE_QEMU_LOG_COUNT="${FAILURE_QEMU_LOG_COUNT:-3}"
STOP_WAIT_SECONDS="${STOP_WAIT_SECONDS:-10}"

if ! is_non_negative_int "$FAILURE_TAIL_LINES"; then
  echo "error: FAILURE_TAIL_LINES must be integer >= 0 (current: $FAILURE_TAIL_LINES)" >&2
  exit 1
fi
if ! is_non_negative_int "$FAILURE_QEMU_LOG_COUNT"; then
  echo "error: FAILURE_QEMU_LOG_COUNT must be integer >= 0 (current: $FAILURE_QEMU_LOG_COUNT)" >&2
  exit 1
fi
if ! is_non_negative_int "$STOP_WAIT_SECONDS"; then
  echo "error: STOP_WAIT_SECONDS must be integer >= 0 (current: $STOP_WAIT_SECONDS)" >&2
  exit 1
fi

if [[ "$MODE" == "stop" ]]; then
  stop_pipeline_vm "$STOP_VM_NAME"
  exit $?
fi

XML_INPUT="$XML_PATH"
XML_PATH="$(resolve_xml_path_from_input "$XML_INPUT")"

if [[ ! -f "$XML_PATH" ]]; then
  echo "error: vm xml not found: $XML_PATH (input=${XML_INPUT})" >&2
  if [[ "$XML_INPUT" != */* ]]; then
    echo "hint : place xml at ${XML_OUT_DIR%/}/${XML_INPUT%.xml}.xml or pass full xml path" >&2
  fi
  exit 1
fi

VM_NAME=$(
  awk '
  function text_between(s, open_tag, close_tag,    t) {
    t = s
    sub("^.*<" open_tag "[^>]*>", "", t)
    sub("</" close_tag ">.*$", "", t)
    return t
  }
  /^[[:space:]]*<name>/ { print text_between($0, "name", "name"); exit }
  ' "$XML_PATH"
)

if [[ -z "$VM_NAME" ]]; then
  echo "error: failed to parse vm name from xml: $XML_PATH" >&2
  exit 1
fi

if ! command -v virsh >/dev/null 2>&1; then
  echo "error: virsh not found" >&2
  exit 1
fi

# Block the pipeline if the VM still appears in the active domain list.
log "cmd check   : virsh -r -c ${LIBVIRT_URI} list | awk vm=${VM_NAME}"
if virsh -r -c "$LIBVIRT_URI" list \
  | awk -v vm="$VM_NAME" 'NR > 2 && $2 == vm { found=1 } END { exit(found ? 0 : 1) }'
then
  echo "error: vm is still running (found in virsh -r list): $VM_NAME" >&2
  echo "hint : shut down the VM completely, then retry" >&2
  exit 1
fi

QEMU_VM_DIR="${QEMU_BASE_DIR%/}/${VM_NAME}"
VM_LOG_BASE_DIR="${V2V_LOG_BASE_DIR%/}/${VM_NAME}"
RUN_ID="${RUN_ID:-$(date +%F_%H%M%S)}"
RUN_LOG_DIR="${RUN_LOG_DIR:-${VM_LOG_BASE_DIR%/}}"
PIPELINE_LOG_DIR="$RUN_LOG_DIR"
PIPELINE_LOG_FILE="${PIPELINE_LOG_DIR%/}/pipeline_${RUN_ID}.log"
STATUS_BOARD_GLOBAL_LOG_FILE="${V2V_LOG_BASE_DIR%/}/status_board.log"
RESULT_VM_LOG_FILE="${VM_LOG_BASE_DIR%/}/result-${RUN_ID}.log"
RESULT_GLOBAL_LOG_FILE="${V2V_LOG_BASE_DIR%/}/result.log"
VM_LOCK_DIR="${VM_LOCK_BASE_DIR%/}/${VM_NAME}.lock"
VM_LOCK_PID_FILE="${VM_LOCK_DIR}/pid"
IMPORT_LOCK_DIR="${IMPORT_LOCK_BASE_DIR%/}/${VM_NAME}.lock"
IMPORT_LOCK_PID_FILE="${IMPORT_LOCK_DIR}/pid"
LOCK_ACQUIRED=0
PIPELINE_START_TS="$(now_ts)"
FAIL_REASON=""
CURRENT_STEP="init"

mkdir -p "$PIPELINE_LOG_DIR" "$VM_LOG_BASE_DIR" "${V2V_LOG_BASE_DIR%/}"
touch "$STATUS_BOARD_GLOBAL_LOG_FILE" "$RESULT_VM_LOG_FILE" "$RESULT_GLOBAL_LOG_FILE"

lock_holder_pid() {
  if [[ -f "$VM_LOCK_PID_FILE" ]]; then
    cat "$VM_LOCK_PID_FILE" 2>/dev/null || true
  fi
}

import_lock_holder_pid() {
  if [[ -f "$IMPORT_LOCK_PID_FILE" ]]; then
    cat "$IMPORT_LOCK_PID_FILE" 2>/dev/null || true
  fi
}

is_vm_locked() {
  local holder_pid=""
  [[ -d "$VM_LOCK_DIR" ]] || return 1
  holder_pid="$(lock_holder_pid)"
  if is_pid_alive "$holder_pid"; then
    return 0
  fi
  rm -rf "$VM_LOCK_DIR" >/dev/null 2>&1 || true
  return 1
}

acquire_vm_lock() {
  local holder_pid=""
  mkdir -p "$VM_LOCK_BASE_DIR"

  if mkdir "$VM_LOCK_DIR" >/dev/null 2>&1; then
    echo "$$" > "$VM_LOCK_PID_FILE"
    LOCK_ACQUIRED=1
    return 0
  fi

  holder_pid="$(lock_holder_pid)"
  if is_pid_alive "$holder_pid"; then
    echo "error: duplicate run blocked for vm=${VM_NAME} (pid=${holder_pid})" >&2
    return 1
  fi

  rm -rf "$VM_LOCK_DIR" >/dev/null 2>&1 || true
  if mkdir "$VM_LOCK_DIR" >/dev/null 2>&1; then
    echo "$$" > "$VM_LOCK_PID_FILE"
    LOCK_ACQUIRED=1
    return 0
  fi

  echo "error: failed to acquire vm lock: $VM_LOCK_DIR" >&2
  return 1
}

release_vm_lock() {
  if [[ "$LOCK_ACQUIRED" == "1" ]]; then
    rm -rf "$VM_LOCK_DIR" >/dev/null 2>&1 || true
    LOCK_ACQUIRED=0
  fi
}

check_import_lock_for_vm() {
  local holder_pid=""
  if [[ ! -d "$IMPORT_LOCK_DIR" ]]; then
    return 0
  fi

  holder_pid="$(import_lock_holder_pid)"
  if is_pid_alive "$holder_pid"; then
    echo "error: import lock is active for vm=${VM_NAME} (pid=${holder_pid})" >&2
    echo "hint : stop existing import first (example: kill -TERM ${holder_pid})" >&2
    return 1
  fi

  log "warn         : stale import lock removed: ${IMPORT_LOCK_DIR}"
  rm -rf "$IMPORT_LOCK_DIR" >/dev/null 2>&1 || true
  return 0
}

if [[ "$RUN_WITH_NOHUP" == "true" && "$NOHUP_LAUNCHED" != "1" ]]; then
  mkdir -p "$VM_LOCK_BASE_DIR"
  if is_vm_locked; then
    holder_pid="$(lock_holder_pid)"
    echo "error: duplicate run blocked for vm=${VM_NAME} (pid=${holder_pid})" >&2
    exit 1
  fi

  NOHUP_STDOUT_LOG="${PIPELINE_LOG_DIR%/}/nohup-${RUN_ID}.log"
  echo "[$(now_ts)] cmd nohup : env NOHUP_LAUNCHED=1 RUN_WITH_NOHUP=false ... bash ${SELF_PATH} ${XML_PATH}"
  nohup env \
    NOHUP_LAUNCHED=1 \
    RUN_WITH_NOHUP=false \
    CONFIG_FILE="$CONFIG_FILE" \
    V2V_BASE_DIR="$V2V_BASE_DIR" \
    V2V_LOG_BASE_DIR="$V2V_LOG_BASE_DIR" \
    LIBVIRT_URI="$LIBVIRT_URI" \
    QEMU_BASE_DIR="$QEMU_BASE_DIR" \
    OVA_STAGING_BASE_DIR="$OVA_STAGING_BASE_DIR" \
    OVA_OUTPUT_DIR="$OVA_OUTPUT_DIR" \
    PIPELINE_LOG_ENABLE="$PIPELINE_LOG_ENABLE" \
    BUILD_OVA="$BUILD_OVA" \
    IMPORT_TO_RHV="$IMPORT_TO_RHV" \
    IMPORT_CSV_PATH="$IMPORT_CSV_PATH" \
    REMOTE_TARGET_HOST="$REMOTE_TARGET_HOST" \
    REMOTE_TARGET_USER="$REMOTE_TARGET_USER" \
    REMOTE_SSH_PORT="$REMOTE_SSH_PORT" \
    REMOTE_SSH_OPTS="$REMOTE_SSH_OPTS" \
    REMOTE_IMPORT_SCRIPT="$REMOTE_IMPORT_SCRIPT" \
    REMOTE_CSV_PATH="$REMOTE_CSV_PATH" \
    PRECHECK="$PRECHECK" \
    RUN_ID="$RUN_ID" \
    RUN_LOG_DIR="$RUN_LOG_DIR" \
    VM_LOCK_BASE_DIR="$VM_LOCK_BASE_DIR" \
    IMPORT_LOCK_BASE_DIR="$IMPORT_LOCK_BASE_DIR" \
    bash "$SELF_PATH" "$XML_PATH" \
    >"$NOHUP_STDOUT_LOG" 2>&1 &
  bg_pid=$!

  echo "[$(now_ts)] launched in nohup vm=${VM_NAME} pid=${bg_pid}"
  echo "[$(now_ts)] nohup log : $NOHUP_STDOUT_LOG"
  exit 0
fi

if ! acquire_vm_lock; then
  exit 1
fi
trap release_vm_lock EXIT

if [[ "$PIPELINE_LOG_ENABLE" == "1" ]]; then
  exec > >(tee -a "$PIPELINE_LOG_FILE") 2>&1
fi

IMG_DIR="${QEMU_VM_DIR%/}"
OVA_PATH="${OVA_OUTPUT_DIR%/}/${VM_NAME}.ova"

mkdir -p "$IMG_DIR"

log "START run_qemu_ova_pipeline xml=${XML_PATH} config=${CONF_SOURCE}"
if [[ "$PIPELINE_LOG_ENABLE" == "1" ]]; then
  log "pipeline log : $PIPELINE_LOG_FILE"
fi
if v2v_preserved_var_is_set "IMPORT_TO_RHV"; then
  log "info         : IMPORT_TO_RHV overridden by env -> ${IMPORT_TO_RHV}"
fi
if v2v_preserved_var_is_set "BUILD_OVA"; then
  log "info         : BUILD_OVA overridden by env -> ${BUILD_OVA}"
fi
log "run log dir  : $RUN_LOG_DIR"
log "status board : $STATUS_BOARD_GLOBAL_LOG_FILE"
log "result log vm: $RESULT_VM_LOG_FILE"
log "result log all: $RESULT_GLOBAL_LOG_FILE"
append_status_board_snapshot "start"
if [[ "$IMPORT_TO_RHV" == "true" && "$BUILD_OVA" == "true" ]]; then
  log "info         : IMPORT_TO_RHV=true -> force BUILD_OVA=false (skip OVA packaging)"
  BUILD_OVA="false"
fi
CURRENT_STEP="validate-config"
if [[ "$IMPORT_TO_RHV" == "true" ]]; then
  if [[ -z "$REMOTE_TARGET_HOST" ]]; then
    FAIL_REASON="missing REMOTE_TARGET_HOST"
    echo "error: IMPORT_TO_RHV=true requires REMOTE_TARGET_HOST (set in v2v.conf or env)" >&2
    exit 1
  fi
  if [[ ! -f "${SCRIPT_DIR}/import_v2v.sh" ]]; then
    FAIL_REASON="missing import_v2v.sh"
    echo "error: import_v2v.sh not found: ${SCRIPT_DIR}/import_v2v.sh" >&2
    exit 1
  fi
fi
log "vm lock      : $VM_LOCK_DIR"
log "import lock  : $IMPORT_LOCK_DIR"
log "build ova    : $BUILD_OVA"
log "import rhv   : $IMPORT_TO_RHV"
if [[ "$IMPORT_TO_RHV" == "true" ]]; then
  log "import remote: ${REMOTE_TARGET_USER}@${REMOTE_TARGET_HOST} script=${REMOTE_IMPORT_SCRIPT}"
  log "precheck     : ${PRECHECK}"
fi
log "nohup mode   : $RUN_WITH_NOHUP (launched=${NOHUP_LAUNCHED})"
log "qemu dir     : $QEMU_VM_DIR"
log "ova staging  : ${OVA_STAGING_BASE_DIR%/}/${VM_NAME}"
log "ova output   : $OVA_PATH"
log "fail tail    : lines=${FAILURE_TAIL_LINES} qemu_logs=${FAILURE_QEMU_LOG_COUNT}"

CURRENT_STEP="import-lock-check"
if ! check_import_lock_for_vm; then
  FAIL_REASON="active import lock detected"
  exit 1
fi

if [[ "$IMPORT_TO_RHV" == "true" && "$PRECHECK" == "true" ]]; then
  CURRENT_STEP="precheck"
  precheck_cmd=(bash "${SCRIPT_DIR}/import_v2v.sh" --run-location=remote --check "$VM_NAME")
  if [[ -n "$IMPORT_CSV_PATH" ]]; then
    precheck_cmd+=("$IMPORT_CSV_PATH")
  fi
  printf -v precheck_cmd_q '%q ' "${precheck_cmd[@]}"
  log "[precheck] remote host/engine/storage check"
  log "cmd         : CONFIG_FILE=${CONFIG_FILE} REMOTE_TARGET_HOST=${REMOTE_TARGET_HOST} REMOTE_TARGET_USER=${REMOTE_TARGET_USER} REMOTE_SSH_PORT=${REMOTE_SSH_PORT} REMOTE_IMPORT_SCRIPT=${REMOTE_IMPORT_SCRIPT} PRECHECK=false ${precheck_cmd_q% }"
  if CONFIG_FILE="$CONFIG_FILE" \
    REMOTE_TARGET_HOST="$REMOTE_TARGET_HOST" \
    REMOTE_TARGET_USER="$REMOTE_TARGET_USER" \
    REMOTE_SSH_PORT="$REMOTE_SSH_PORT" \
    REMOTE_SSH_OPTS="$REMOTE_SSH_OPTS" \
    REMOTE_IMPORT_SCRIPT="$REMOTE_IMPORT_SCRIPT" \
    REMOTE_CSV_PATH="$REMOTE_CSV_PATH" \
    IMPORT_RUN_WITH_NOHUP="false" \
    RUN_LOG_DIR="$RUN_LOG_DIR" \
    PRECHECK="false" \
    "${precheck_cmd[@]}"
  then
    append_command_result "precheck" "0" "${precheck_cmd_q% }"
  else
    precheck_rc=$?
    FAIL_REASON="precheck failed"
    append_command_result "precheck" "$precheck_rc" "${precheck_cmd_q% }"
    exit "$precheck_rc"
  fi
  append_status_board_snapshot "after-precheck"
else
  append_command_result "precheck" "0" "skip PRECHECK=false or IMPORT_TO_RHV=false"
fi

if [[ "$IMPORT_TO_RHV" == "true" ]]; then
  STEP_UP="[1/3]"
  STEP_CONVERT="[2/3]"
  STEP_IMPORT="[3/3]"
  STEP_BUILD_OVA="[skip]"
  STEP_DOWN="[4/4]"
elif [[ "$BUILD_OVA" == "true" ]]; then
  STEP_UP="[1/3]"
  STEP_CONVERT="[2/3]"
  STEP_BUILD_OVA="[3/3]"
  STEP_IMPORT="[skip]"
  STEP_DOWN="[4/4]"
else
  STEP_UP="[1/2]"
  STEP_CONVERT="[2/2]"
  STEP_BUILD_OVA="[skip]"
  STEP_IMPORT="[skip]"
  STEP_DOWN="[3/3]"
fi

finish_pipeline() {
  local rc=$?
  local summary_reason=""
  trap - EXIT
  set +e

  CURRENT_STEP="lv-down"
  log "${STEP_DOWN} deactivate lv"
  log "cmd         : V2V_LOG_BASE_DIR=${V2V_LOG_BASE_DIR} bash ${SCRIPT_DIR}/toggle_lv_from_xml.sh ${XML_PATH} down"
  if V2V_LOG_BASE_DIR="$V2V_LOG_BASE_DIR" \
    RUN_LOG_DIR="$RUN_LOG_DIR" \
    bash "${SCRIPT_DIR}/toggle_lv_from_xml.sh" "$XML_PATH" down
  then
    down_rc=0
  else
    down_rc=$?
  fi
  append_command_result "lv-down" "$down_rc" "bash ${SCRIPT_DIR}/toggle_lv_from_xml.sh ${XML_PATH} down"
  append_status_board_snapshot "after-lv-down"
  if (( down_rc != 0 )); then
    echo "error: failed to deactivate lv (rc=${down_rc})" >&2
    if [[ -z "$FAIL_REASON" ]]; then
      FAIL_REASON="lv-down failed"
    fi
    if (( rc == 0 )); then
      rc=$down_rc
    fi
  fi

  if (( rc == 0 )); then
    summary_reason="pipeline completed"
    log "DONE run_qemu_ova_pipeline"
    log "xml : $XML_PATH"
    if [[ "$IMPORT_TO_RHV" == "true" ]]; then
      log "import : done on target (${REMOTE_TARGET_USER}@${REMOTE_TARGET_HOST})"
      if [[ -n "$RUN_LOG_DIR" ]]; then
        log "hint   : check target logs under ${RUN_LOG_DIR}/import_v2v-*.log"
      else
        log "hint   : check target logs under /data/v2v_log/${VM_NAME}/import_v2v-*.log"
      fi
      log "ova    : skipped (IMPORT_TO_RHV=true)"
    elif [[ "$BUILD_OVA" == "true" ]]; then
      log "ova : $OVA_PATH"
    else
      log "ova : skipped (BUILD_OVA=false)"
    fi
  else
    if [[ -n "$FAIL_REASON" ]]; then
      summary_reason="$FAIL_REASON"
    else
      summary_reason="${CURRENT_STEP} failed"
    fi
    log "FAIL run_qemu_ova_pipeline rc=${rc}"
    log "collecting failure context tails..."
    dump_failure_context
  fi

  if (( rc == 0 )); then
    append_run_result_summary "success" "$rc" "$summary_reason"
  else
    append_run_result_summary "fail" "$rc" "$summary_reason"
  fi

  release_vm_lock
  exit "$rc"
}

trap finish_pipeline EXIT

CURRENT_STEP="lv-up"
log "${STEP_UP} activate lv"
log "cmd         : V2V_LOG_BASE_DIR=${V2V_LOG_BASE_DIR} bash ${SCRIPT_DIR}/toggle_lv_from_xml.sh ${XML_PATH} up"
if V2V_LOG_BASE_DIR="$V2V_LOG_BASE_DIR" \
  RUN_LOG_DIR="$RUN_LOG_DIR" \
  bash "${SCRIPT_DIR}/toggle_lv_from_xml.sh" "$XML_PATH" up
then
  append_command_result "lv-up" "0" "bash ${SCRIPT_DIR}/toggle_lv_from_xml.sh ${XML_PATH} up"
else
  up_rc=$?
  FAIL_REASON="lv-up failed"
  append_command_result "lv-up" "$up_rc" "bash ${SCRIPT_DIR}/toggle_lv_from_xml.sh ${XML_PATH} up"
  exit "$up_rc"
fi
append_status_board_snapshot "after-lv-up"

CURRENT_STEP="convert"
log "${STEP_CONVERT} convert disks (parallel)"
log "cmd         : QEMU_BASE_DIR=${QEMU_BASE_DIR} V2V_LOG_BASE_DIR=${V2V_LOG_BASE_DIR} bash ${SCRIPT_DIR}/convert_disks_from_xml.sh ${XML_PATH}"
if QEMU_BASE_DIR="$QEMU_BASE_DIR" \
  V2V_LOG_BASE_DIR="$V2V_LOG_BASE_DIR" \
  RUN_LOG_DIR="$RUN_LOG_DIR" \
  bash "${SCRIPT_DIR}/convert_disks_from_xml.sh" "$XML_PATH"
then
  append_command_result "convert" "0" "bash ${SCRIPT_DIR}/convert_disks_from_xml.sh ${XML_PATH}"
else
  convert_rc=$?
  FAIL_REASON="convert failed"
  append_command_result "convert" "$convert_rc" "bash ${SCRIPT_DIR}/convert_disks_from_xml.sh ${XML_PATH}"
  exit "$convert_rc"
fi
append_status_board_snapshot "after-convert"

if [[ "$IMPORT_TO_RHV" == "true" ]]; then
  CURRENT_STEP="import"
  import_cmd=(bash "${SCRIPT_DIR}/import_v2v.sh" --run-location=remote "$VM_NAME")
  if [[ -n "$IMPORT_CSV_PATH" ]]; then
    import_cmd+=("$IMPORT_CSV_PATH")
  fi
  printf -v import_cmd_q '%q ' "${import_cmd[@]}"

  log "${STEP_IMPORT} import to rhv on target host"
  log "cmd         : CONFIG_FILE=${CONFIG_FILE} REMOTE_TARGET_HOST=${REMOTE_TARGET_HOST} REMOTE_TARGET_USER=${REMOTE_TARGET_USER} REMOTE_SSH_PORT=${REMOTE_SSH_PORT} REMOTE_IMPORT_SCRIPT=${REMOTE_IMPORT_SCRIPT} PRECHECK=false ${import_cmd_q% }"
  if CONFIG_FILE="$CONFIG_FILE" \
    REMOTE_TARGET_HOST="$REMOTE_TARGET_HOST" \
    REMOTE_TARGET_USER="$REMOTE_TARGET_USER" \
    REMOTE_SSH_PORT="$REMOTE_SSH_PORT" \
    REMOTE_SSH_OPTS="$REMOTE_SSH_OPTS" \
    REMOTE_IMPORT_SCRIPT="$REMOTE_IMPORT_SCRIPT" \
    REMOTE_CSV_PATH="$REMOTE_CSV_PATH" \
    IMPORT_RUN_WITH_NOHUP="false" \
    RUN_LOG_DIR="$RUN_LOG_DIR" \
    PRECHECK="false" \
    "${import_cmd[@]}"
  then
    append_command_result "import" "0" "${import_cmd_q% }"
  else
    import_rc=$?
    FAIL_REASON="import failed"
    append_command_result "import" "$import_rc" "${import_cmd_q% }"
    exit "$import_rc"
  fi
  append_status_board_snapshot "after-import"
else
  append_command_result "import" "0" "skip IMPORT_TO_RHV=false"
  append_status_board_snapshot "after-import-skip"
fi

if [[ "$BUILD_OVA" == "true" ]]; then
  CURRENT_STEP="build-ova"
  log "${STEP_BUILD_OVA} build ova"
  shopt -s nullglob
  qcow2_files=( "${IMG_DIR}/${VM_NAME}-disk"*.qcow2 )
  shopt -u nullglob

  if [[ ${#qcow2_files[@]} -eq 0 ]]; then
    echo "error: no qcow2 files found under: $IMG_DIR" >&2
    exit 1
  fi

  log "cmd         : QEMU_BASE_DIR=${QEMU_BASE_DIR} OVA_STAGING_BASE_DIR=${OVA_STAGING_BASE_DIR} OVA_OUTPUT_DIR=${OVA_OUTPUT_DIR} V2V_LOG_BASE_DIR=${V2V_LOG_BASE_DIR} bash ${SCRIPT_DIR}/make_ovirt_ova.sh ${XML_PATH} <qcow2_files...>"
  if QEMU_BASE_DIR="$QEMU_BASE_DIR" \
    OVA_STAGING_BASE_DIR="$OVA_STAGING_BASE_DIR" \
    OVA_OUTPUT_DIR="$OVA_OUTPUT_DIR" \
    V2V_LOG_BASE_DIR="$V2V_LOG_BASE_DIR" \
    RUN_LOG_DIR="$RUN_LOG_DIR" \
    bash "${SCRIPT_DIR}/make_ovirt_ova.sh" "$XML_PATH" "${qcow2_files[@]}"
  then
    append_command_result "build-ova" "0" "bash ${SCRIPT_DIR}/make_ovirt_ova.sh ${XML_PATH} <qcow2_files...>"
  else
    ova_rc=$?
    FAIL_REASON="build-ova failed"
    append_command_result "build-ova" "$ova_rc" "bash ${SCRIPT_DIR}/make_ovirt_ova.sh ${XML_PATH} <qcow2_files...>"
    exit "$ova_rc"
  fi
  append_status_board_snapshot "after-build-ova"
else
  log "${STEP_BUILD_OVA} skip ova build (BUILD_OVA=false)"
  append_command_result "build-ova" "0" "skip BUILD_OVA=false"
  append_status_board_snapshot "after-build-ova-skip"
fi
