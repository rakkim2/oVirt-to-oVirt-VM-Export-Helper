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

log_cmd() {
  local label="$1"
  shift
  local q=""
  printf -v q '%q ' "$@"
  log "cmd ${label}: ${q% }"
}

normalize_run_location() {
  local v
  v="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    targetspm) echo "targetspm" ;;
    remote) echo "remote" ;;
    *)
      echo "error: --run-location must be one of: targetspm, remote (current: $1)" >&2
      exit 1
      ;;
  esac
}

normalize_vm_name_input() {
  local raw="$1"
  local base="$raw"
  if [[ "$base" == */* ]]; then
    base="${base##*/}"
  fi
  if [[ "$base" == *.xml ]]; then
    base="${base%.xml}"
  fi
  printf '%s' "$base"
}

is_pid_alive() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

lock_holder_pid() {
  local lock_dir="$1"
  local pid_file="${lock_dir}/pid"
  if [[ -f "$pid_file" ]]; then
    cat "$pid_file" 2>/dev/null || true
  fi
}

is_vm_locked() {
  local lock_dir="$1"
  local holder_pid=""

  [[ -d "$lock_dir" ]] || return 1
  holder_pid="$(lock_holder_pid "$lock_dir")"
  if is_pid_alive "$holder_pid"; then
    return 0
  fi

  rm -rf "$lock_dir" >/dev/null 2>&1 || true
  return 1
}

acquire_vm_lock() {
  local lock_dir="$1"
  local holder_pid=""

  mkdir -p "$(dirname "$lock_dir")"
  if mkdir "$lock_dir" >/dev/null 2>&1; then
    echo "$$" > "${lock_dir}/pid"
    return 0
  fi

  holder_pid="$(lock_holder_pid "$lock_dir")"
  if is_pid_alive "$holder_pid"; then
    echo "error: duplicate import blocked for vm=${VM_NAME} (pid=${holder_pid})" >&2
    return 1
  fi

  rm -rf "$lock_dir" >/dev/null 2>&1 || true
  if mkdir "$lock_dir" >/dev/null 2>&1; then
    echo "$$" > "${lock_dir}/pid"
    return 0
  fi

  echo "error: failed to acquire lock: $lock_dir" >&2
  return 1
}

release_vm_lock() {
  local lock_dir="$1"
  rm -rf "$lock_dir" >/dev/null 2>&1 || true
}

normalize_rhv_engine_url() {
  local u="$1"
  u="${u%/}"
  [[ -n "$u" ]] || { echo ""; return; }

  if [[ ! "$u" =~ ^https?:// ]]; then
    u="https://${u}"
  fi

  case "$u" in
    */ovirt-engine/api|*/ovirt-engine/api/*|*/api) ;;
    */ovirt-engine) u="${u}/api" ;;
    *)
      # If user gave only host[:port], add the standard engine API path.
      if [[ "${u#*://}" != */* ]]; then
        u="${u}/ovirt-engine/api"
      fi
      ;;
  esac

  echo "$u"
}

run_precheck() {
  # Keep compatibility with existing PRECHECK path, but do nothing.
  # virt-v2v itself is the source of truth for connectivity/validation failures.
  return 0
}

build_runtime_import_xml() {
  local source_xml="$1"
  local vm_name="$2"
  local qemu_vm_dir="${QEMU_BASE_DIR%/}/${vm_name}"
  local runtime_xml="${LOG_DIR%/}/${vm_name}-import-runtime-$(date +%F_%H%M%S).xml"

  if [[ ! -d "$qemu_vm_dir" ]]; then
    echo "error: qemu disk directory not found: $qemu_vm_dir" >&2
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 not found (required to generate runtime import xml)" >&2
    return 1
  fi

  log "disk dir     : $qemu_vm_dir"
  log "runtime xml  : $runtime_xml"
  log "cmd xmlpatch : python3 - '${source_xml}' '${qemu_vm_dir}' '${vm_name}' '${runtime_xml}'"

  python3 - "$source_xml" "$qemu_vm_dir" "$vm_name" "$runtime_xml" <<'PY'
import glob
import json
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

source_xml = sys.argv[1]
qemu_vm_dir = sys.argv[2]
vm_name = sys.argv[3]
runtime_xml = sys.argv[4]

def local_name(tag: str) -> str:
    return tag.split("}", 1)[-1]

def find_first(node, name: str):
    for ch in node.iter():
        if local_name(ch.tag) == name:
            return ch
    return None

def find_children(node, name: str):
    out = []
    for ch in list(node):
        if local_name(ch.tag) == name:
            out.append(ch)
    return out

def pick_disk_file(idx: int) -> str:
    prefix = f"{vm_name}-disk{idx}"
    cand = glob.glob(os.path.join(qemu_vm_dir, prefix + ".*"))
    if not cand:
        cand = glob.glob(os.path.join(qemu_vm_dir, prefix))
    if not cand:
        return ""
    cand.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return cand[0]

def detect_format(path: str) -> str:
    ext = os.path.splitext(path)[1].lower().lstrip(".")
    if ext in {"qcow2", "raw", "vmdk"}:
        return ext
    try:
        out = subprocess.check_output(
            ["qemu-img", "info", "--output=json", path],
            stderr=subprocess.DEVNULL,
            text=True,
        )
        fmt = (json.loads(out) or {}).get("format")
        if fmt:
            return fmt
    except Exception:
        pass
    return "raw"

tree = ET.parse(source_xml)
root = tree.getroot()
devices = find_first(root, "devices")
if devices is None:
    print("error: invalid xml (missing <devices>)", file=sys.stderr)
    raise SystemExit(1)

disks = [d for d in find_children(devices, "disk") if d.attrib.get("device") == "disk"]
if not disks:
    print("error: invalid xml (no <disk device='disk'> entries)", file=sys.stderr)
    raise SystemExit(1)

mapped = []
for idx, disk in enumerate(disks, start=1):
    disk_file = pick_disk_file(idx)
    if not disk_file:
        print(f"error: missing converted disk file for disk{idx} under {qemu_vm_dir}", file=sys.stderr)
        print(f"hint : expected file pattern {vm_name}-disk{idx}.*", file=sys.stderr)
        raise SystemExit(1)

    fmt = detect_format(disk_file)
    disk.set("type", "file")

    source_elem = None
    for ch in list(disk):
        if local_name(ch.tag) == "source":
            source_elem = ch
            break
    if source_elem is None:
        source_elem = ET.SubElement(disk, "source")
    source_elem.attrib.clear()
    source_elem.set("file", disk_file)
    for sec in list(source_elem):
        if local_name(sec.tag) == "seclabel":
            source_elem.remove(sec)

    driver_elem = None
    for ch in list(disk):
        if local_name(ch.tag) == "driver":
            driver_elem = ch
            break
    if driver_elem is None:
        driver_elem = ET.SubElement(disk, "driver")
    driver_elem.set("name", "qemu")
    driver_elem.set("type", fmt)

    mapped.append((idx, disk_file, fmt))

tree.write(runtime_xml, encoding="utf-8", xml_declaration=True)
print(f"OK: wrote {runtime_xml} (disks={len(mapped)})")
for idx, path, fmt in mapped:
    print(f"disk{idx}: {path} fmt={fmt}")
PY

  RUNTIME_IMPORT_XML="$runtime_xml"
}

run_remote_import() {
  local csv_path="$1"
  local remote_login="${REMOTE_TARGET_USER}@${REMOTE_TARGET_HOST}"
  local remote_config_guess="${REMOTE_IMPORT_SCRIPT%/*}/v2v.conf"
  local remote_config="${CONFIG_FILE:-$remote_config_guess}"
  local remote_import_nohup="${IMPORT_RUN_WITH_NOHUP:-true}"
  local -a ssh_cmd=(ssh)
  local -a ssh_args=(-p "$REMOTE_SSH_PORT")

  if [[ -z "$REMOTE_TARGET_HOST" ]]; then
    echo "error: REMOTE_TARGET_HOST is empty (set in v2v.conf)" >&2
    return 1
  fi
  if [[ ! "$REMOTE_SSH_PORT" =~ ^[0-9]+$ ]]; then
    echo "error: REMOTE_SSH_PORT must be numeric (current: $REMOTE_SSH_PORT)" >&2
    return 1
  fi
  if ! command -v ssh >/dev/null 2>&1; then
    echo "error: ssh not found" >&2
    return 1
  fi

  if [[ -n "$REMOTE_SSH_PASS_FILE" || -n "$REMOTE_SSH_PASS" ]]; then
    if ! command -v sshpass >/dev/null 2>&1; then
      echo "error: sshpass not found (required when REMOTE_SSH_PASS_FILE or REMOTE_SSH_PASS is set)" >&2
      return 1
    fi
    if [[ -n "$REMOTE_SSH_PASS_FILE" ]]; then
      if [[ "$REMOTE_SSH_PASS_FILE" == *'$'* ]]; then
        echo "error: unresolved variable in REMOTE_SSH_PASS_FILE: $REMOTE_SSH_PASS_FILE" >&2
        echo "hint : set SCRIPT_BASE_DIR in v2v.conf or use absolute REMOTE_SSH_PASS_FILE path" >&2
        return 1
      fi
      if [[ ! -f "$REMOTE_SSH_PASS_FILE" ]]; then
        echo "error: REMOTE_SSH_PASS_FILE not found: $REMOTE_SSH_PASS_FILE" >&2
        return 1
      fi
      ssh_cmd=(sshpass -f "$REMOTE_SSH_PASS_FILE" ssh)
    else
      ssh_cmd=(sshpass -p "$REMOTE_SSH_PASS" ssh)
    fi
  fi

  if [[ -n "$REMOTE_SSH_OPTS" ]]; then
    # shellcheck disable=SC2206
    local extra_ssh_args=($REMOTE_SSH_OPTS)
    ssh_args+=("${extra_ssh_args[@]}")
  fi

  log "START import_v2v(remote) vm=${VM_NAME} remote=${remote_login} config=${CONF_SOURCE}"
  log "run location : remote"
  log "remote script : ${REMOTE_IMPORT_SCRIPT}"
  log "remote csv    : ${csv_path}"
  log "mode          : ${MODE}"
  log "precheck      : ${PRECHECK}"
  log "remote nohup  : ${remote_import_nohup}"
  if [[ -n "$REMOTE_SSH_PASS_FILE" || -n "$REMOTE_SSH_PASS" ]]; then
    log "ssh auth      : sshpass"
  else
    log "ssh auth      : interactive/key"
  fi

  "${ssh_cmd[@]}" "${ssh_args[@]}" "$remote_login" bash -s -- "$REMOTE_IMPORT_SCRIPT" "$VM_NAME" "$csv_path" "$MODE" "$PRECHECK" "${RUN_LOG_DIR:-}" "$remote_config" "$remote_import_nohup" <<'EOS'
set -euo pipefail
script_path="$1"
vm_name="$2"
csv_path="$3"
mode="$4"
precheck="$5"
run_log_dir="${6:-}"
remote_config_in="${7:-}"
import_nohup="${8:-true}"
remote_config="$remote_config_in"
# Backward-compatible guard:
# if args are shifted and run_log_dir receives *.conf, treat it as config path.
if [[ -z "$remote_config" && -n "$run_log_dir" && "$run_log_dir" == *.conf ]]; then
  remote_config="$run_log_dir"
  run_log_dir=""
fi
if [[ -z "$remote_config" || ! -f "$remote_config" ]]; then
  remote_config="${script_path%/*}/v2v.conf"
fi
remote_host="$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)"
echo "[$(date '+%F %T')] remote host   : ${remote_host:-unknown}"
echo "[$(date '+%F %T')] remote config : ${remote_config}"

if [[ ! -f "$script_path" ]]; then
  echo "error: remote script not found: $script_path" >&2
  exit 2
fi

if [[ "$mode" == "check" ]]; then
  CONFIG_FILE="$remote_config" RUN_LOG_DIR="$run_log_dir" PRECHECK=true IMPORT_RUN_WITH_NOHUP=false bash "$script_path" --run-location=targetspm --check "$vm_name" "$csv_path"
  exit 0
fi

if [[ "$precheck" == "true" ]]; then
  CONFIG_FILE="$remote_config" RUN_LOG_DIR="$run_log_dir" PRECHECK=true IMPORT_RUN_WITH_NOHUP=false bash "$script_path" --run-location=targetspm --check "$vm_name" "$csv_path"
fi

# Keep import run in foreground and skip internal precheck in run mode
# so the source-side wrapper decides precheck timing.
CONFIG_FILE="$remote_config" RUN_LOG_DIR="$run_log_dir" PRECHECK=false IMPORT_RUN_WITH_NOHUP="$import_nohup" bash "$script_path" --run-location=targetspm "$vm_name" "$csv_path"
EOS

  log "DONE import_v2v(remote) vm=${VM_NAME}"
}

usage() {
  cat >&2 <<'EOF'
usage:
  import_v2v.sh --run-location=targetspm <vm-name> [csv-path]
  import_v2v.sh --run-location=targetspm --check <vm-name> [csv-path]
  import_v2v.sh --run-location=remote <vm-name> [csv-path]
  import_v2v.sh --run-location=remote --check <vm-name> [csv-path]

Import VM disks to oVirt/RHV using virt-v2v.
This script reads the existing VM XML profile, then generates a runtime XML
that points disk sources to converted files under ${QEMU_BASE_DIR}/<vm>.

Config/env options:
  - CONFIG_FILE               (default: ./v2v.conf)
  - IMPORT_CSV_PATH           (default: <script-dir>/vmlist.csv)
  - IMPORT_SOURCE_XML         (optional source VM XML path; defaults to ${XML_OUT_DIR}/<vm>.xml if exists)
  - IMPORT_V2V_LOG_ENABLE     (default: 1)
  - IMPORT_RUN_WITH_NOHUP     (default: true)
  - PRECHECK                  (default: false)
  - IMPORT_LOCK_BASE_DIR      (default: ${V2V_BASE_DIR}/locks/import_v2v)
  - ENGINE_CONNECT_TIMEOUT    (default: 10, seconds)
  - REMOTE_TARGET_HOST        (required when --run-location=remote)
  - REMOTE_TARGET_USER        (default: root)
  - REMOTE_SSH_PORT           (default: 22)
  - REMOTE_SSH_OPTS           (optional)
  - REMOTE_SSH_PASS_FILE      (optional; sshpass password file)
  - REMOTE_SSH_PASS           (optional; plain password string)
  - REMOTE_IMPORT_SCRIPT      (default: /data/script/import_v2v.sh on target)
  - REMOTE_CSV_PATH           (default: <REMOTE_IMPORT_SCRIPT dir>/vmlist.csv)

Required RHV options (set in v2v.conf):
  - RHV_ENGINE_URL
  - RHV_USERNAME (default: admin@internal)
  - RHV_PASS_FILE
  - RHV_CAFILE (optional but recommended)
  - RHV_CLUSTER_DEFAULT / RHV_STORAGE_DEFAULT (or provide vm mapping in CSV)

Modes:
  - run          : precheck + actual import (default)
  - check        : precheck only (dry-run style), no import execution
  - run-location : required. must be targetspm or remote
EOF
  exit 1
}

MODE="run"
RUN_LOCATION=""
while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    -h|--help)
      usage
      ;;
    --check)
      MODE="check"
      shift
      ;;
    --run-location=*)
      RUN_LOCATION="$(normalize_run_location "${1#*=}")"
      shift
      ;;
    --run-location)
      if [[ $# -lt 2 ]]; then
        echo "error: --run-location requires a value: targetspm or remote" >&2
        usage
      fi
      RUN_LOCATION="$(normalize_run_location "$2")"
      shift 2
      ;;
    --*)
      echo "error: unknown option: $1" >&2
      usage
      ;;
    -*)
      echo "error: unknown short option: $1" >&2
      usage
      ;;
    *)
      break
      ;;
  esac
done

if [[ -z "$RUN_LOCATION" ]]; then
  echo "error: --run-location is required (targetspm or remote)" >&2
  usage
fi

if [[ "$RUN_LOCATION" == "remote" ]]; then
  REMOTE_MODE="true"
else
  REMOTE_MODE="false"
fi

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
fi

SELF_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
if [[ -z "${CONFIG_FILE:-}" ]]; then
  CONFIG_FILE="${SCRIPT_DIR}/v2v.conf"
fi

declare -a PRESERVE_ENV_KEYS=(
  DATA_BASE_DIR V2V_BASE_DIR V2V_LOG_BASE_DIR RUN_LOG_DIR XML_OUT_DIR
  QEMU_BASE_DIR RAW_BASE_DIR IMPORT_CSV_PATH IMPORT_SOURCE_XML
  IMPORT_V2V_LOG_ENABLE IMPORT_RUN_WITH_NOHUP PRECHECK
  NOHUP_LAUNCHED IMPORT_LOCK_BASE_DIR ENGINE_CONNECT_TIMEOUT
  RHV_ENGINE_URL RHV_USERNAME RHV_PASS_FILE RHV_CAFILE
  RHV_CLUSTER_DEFAULT RHV_STORAGE_DEFAULT RHV_DIRECT
  REMOTE_TARGET_HOST REMOTE_TARGET_USER REMOTE_SSH_PORT REMOTE_SSH_OPTS
  REMOTE_SSH_PASS_FILE REMOTE_SSH_PASS REMOTE_IMPORT_SCRIPT REMOTE_CSV_PATH
  V2V_OUTPUT_FORMAT V2V_OUTPUT_ALLOCATION V2V_VERBOSE LIBGUESTFS_BACKEND
)
CONF_SOURCE="$(v2v_load_config_with_env "$CONFIG_FILE" "${PRESERVE_ENV_KEYS[@]}")"

VM_INPUT_RAW="$1"
VM_NAME="$(normalize_vm_name_input "$VM_INPUT_RAW")"
if [[ -z "$VM_NAME" ]]; then
  echo "error: failed to normalize vm name from input: $VM_INPUT_RAW" >&2
  exit 1
fi
if [[ "$VM_INPUT_RAW" != "$VM_NAME" && -z "${IMPORT_SOURCE_XML:-}" && "$VM_INPUT_RAW" == *.xml && -f "$VM_INPUT_RAW" ]]; then
  IMPORT_SOURCE_XML="$VM_INPUT_RAW"
fi

if [[ -z "${V2V_BASE_DIR+x}" && -n "${DATA_BASE_DIR+x}" ]]; then
  V2V_BASE_DIR="${DATA_BASE_DIR%/}/v2v"
fi
if [[ -z "${QEMU_BASE_DIR+x}" && -n "${RAW_BASE_DIR+x}" ]]; then
  QEMU_BASE_DIR="$RAW_BASE_DIR"
fi

V2V_BASE_DIR="${V2V_BASE_DIR:-/data/v2v}"
V2V_LOG_BASE_DIR="${V2V_LOG_BASE_DIR:-/data/v2v_log}"
RUN_LOG_DIR="${RUN_LOG_DIR:-}"
XML_OUT_DIR="${XML_OUT_DIR:-/data/xml}"
QEMU_BASE_DIR="${QEMU_BASE_DIR:-${V2V_BASE_DIR%/}/qemu}"
IMPORT_SOURCE_XML="${IMPORT_SOURCE_XML:-}"
IMPORT_V2V_LOG_ENABLE="$(normalize_bool "${IMPORT_V2V_LOG_ENABLE:-${SCRIPT_LOG_ENABLE:-1}}")" || exit 1
IMPORT_RUN_WITH_NOHUP="$(normalize_bool "${IMPORT_RUN_WITH_NOHUP:-true}")" || exit 1
PRECHECK="$(normalize_bool "${PRECHECK:-false}")" || exit 1
NOHUP_LAUNCHED="${NOHUP_LAUNCHED:-0}"
IMPORT_LOCK_BASE_DIR="${IMPORT_LOCK_BASE_DIR:-${V2V_BASE_DIR%/}/locks/import_v2v}"
ENGINE_CONNECT_TIMEOUT="${ENGINE_CONNECT_TIMEOUT:-10}"

RHV_ENGINE_URL="${RHV_ENGINE_URL:-}"
RHV_USERNAME="${RHV_USERNAME:-admin@internal}"
RHV_PASS_FILE="${RHV_PASS_FILE:-}"
RHV_CAFILE="${RHV_CAFILE:-}"
RHV_CLUSTER_DEFAULT="${RHV_CLUSTER_DEFAULT:-}"
RHV_STORAGE_DEFAULT="${RHV_STORAGE_DEFAULT:-}"
RHV_DIRECT="$(normalize_bool "${RHV_DIRECT:-false}")" || exit 1
REMOTE_TARGET_HOST="${REMOTE_TARGET_HOST:-}"
REMOTE_TARGET_USER="${REMOTE_TARGET_USER:-root}"
REMOTE_SSH_PORT="${REMOTE_SSH_PORT:-22}"
REMOTE_SSH_OPTS="${REMOTE_SSH_OPTS:-}"
REMOTE_SSH_PASS_FILE="${REMOTE_SSH_PASS_FILE:-}"
REMOTE_SSH_PASS="${REMOTE_SSH_PASS:-}"
REMOTE_IMPORT_SCRIPT="${REMOTE_IMPORT_SCRIPT:-/data/script/import_v2v.sh}"
REMOTE_CSV_PATH="${REMOTE_CSV_PATH:-}"

# Recover base dirs so ${SCRIPT_BASE_DIR}/${DATA_BASE_DIR} placeholders expand reliably.
if [[ -z "${SCRIPT_BASE_DIR:-}" ]]; then
  conf_script_base_dir="$(v2v_read_conf_value "$CONFIG_FILE" "SCRIPT_BASE_DIR" || true)"
  if [[ -n "$conf_script_base_dir" ]]; then
    SCRIPT_BASE_DIR="$conf_script_base_dir"
  fi
fi
if [[ -z "${SCRIPT_BASE_DIR:-}" ]]; then
  SCRIPT_BASE_DIR="${CONFIG_FILE%/*}"
fi
if [[ -z "${DATA_BASE_DIR:-}" ]]; then
  conf_data_base_dir="$(v2v_read_conf_value "$CONFIG_FILE" "DATA_BASE_DIR" || true)"
  if [[ -n "$conf_data_base_dir" ]]; then
    DATA_BASE_DIR="$conf_data_base_dir"
  fi
fi
SCRIPT_BASE_DIR="$(v2v_expand_conf_placeholders "$SCRIPT_BASE_DIR")"
if [[ -z "${DATA_BASE_DIR:-}" && "$SCRIPT_BASE_DIR" == */script ]]; then
  DATA_BASE_DIR="${SCRIPT_BASE_DIR%/script}"
fi

# Fallback: if critical remote target host is empty after config load,
# parse it directly from config text to avoid accidental empty effective value.
if [[ -z "$REMOTE_TARGET_HOST" ]]; then
  conf_remote_host="$(v2v_read_conf_value "$CONFIG_FILE" "REMOTE_TARGET_HOST" || true)"
  if [[ -n "$conf_remote_host" ]]; then
    REMOTE_TARGET_HOST="$conf_remote_host"
  fi
fi
if [[ -z "$RHV_ENGINE_URL" ]]; then
  conf_rhv_engine_url="$(v2v_read_conf_value "$CONFIG_FILE" "RHV_ENGINE_URL" || true)"
  if [[ -n "$conf_rhv_engine_url" ]]; then
    RHV_ENGINE_URL="$conf_rhv_engine_url"
  fi
fi
if [[ -z "$RHV_PASS_FILE" ]]; then
  conf_rhv_pass_file="$(v2v_read_conf_value "$CONFIG_FILE" "RHV_PASS_FILE" || true)"
  if [[ -n "$conf_rhv_pass_file" ]]; then
    RHV_PASS_FILE="$conf_rhv_pass_file"
    if [[ "$RHV_PASS_FILE" == *'${SCRIPT_BASE_DIR}'* && -n "${SCRIPT_BASE_DIR:-}" ]]; then
      RHV_PASS_FILE="${RHV_PASS_FILE//'${SCRIPT_BASE_DIR}'/${SCRIPT_BASE_DIR}}"
    fi
    if [[ "$RHV_PASS_FILE" == *'${DATA_BASE_DIR}'* && -n "${DATA_BASE_DIR:-}" ]]; then
      RHV_PASS_FILE="${RHV_PASS_FILE//'${DATA_BASE_DIR}'/${DATA_BASE_DIR}}"
    fi
  fi
fi
if [[ -z "$REMOTE_SSH_PASS_FILE" ]]; then
  conf_remote_ssh_pass_file="$(v2v_read_conf_value "$CONFIG_FILE" "REMOTE_SSH_PASS_FILE" || true)"
  if [[ -n "$conf_remote_ssh_pass_file" ]]; then
    REMOTE_SSH_PASS_FILE="$conf_remote_ssh_pass_file"
  fi
fi

# Always expand config placeholders regardless of source (config/env/fallback parser).
RHV_PASS_FILE="$(v2v_expand_conf_placeholders "$RHV_PASS_FILE")"
REMOTE_SSH_PASS_FILE="$(v2v_expand_conf_placeholders "$REMOTE_SSH_PASS_FILE")"
REMOTE_IMPORT_SCRIPT="$(v2v_expand_conf_placeholders "$REMOTE_IMPORT_SCRIPT")"
REMOTE_CSV_PATH="$(v2v_expand_conf_placeholders "$REMOTE_CSV_PATH")"
# Final safety fallback: if placeholders remain, use config-dir conventional files.
if [[ "$RHV_PASS_FILE" == *'$'* ]]; then
  cfg_dir="${CONFIG_FILE%/*}"
  if [[ -f "${cfg_dir%/}/engine-passwd" ]]; then
    RHV_PASS_FILE="${cfg_dir%/}/engine-passwd"
  fi
fi
if [[ "$REMOTE_SSH_PASS_FILE" == *'$'* ]]; then
  cfg_dir="${CONFIG_FILE%/*}"
  if [[ -f "${cfg_dir%/}/remote-target-passwd" ]]; then
    REMOTE_SSH_PASS_FILE="${cfg_dir%/}/remote-target-passwd"
  fi
fi
V2V_OUTPUT_FORMAT="${V2V_OUTPUT_FORMAT:-raw}"
V2V_OUTPUT_ALLOCATION="${V2V_OUTPUT_ALLOCATION:-preallocated}"
V2V_VERBOSE="$(normalize_bool "${V2V_VERBOSE:-true}")" || exit 1
LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND:-direct}"
RAW_RHV_ENGINE_URL="$RHV_ENGINE_URL"
RHV_ENGINE_URL="$(normalize_rhv_engine_url "$RHV_ENGINE_URL")"

if [[ $# -eq 2 ]]; then
  CSV_PATH="$2"
elif [[ "$REMOTE_MODE" == "true" && -n "$REMOTE_CSV_PATH" ]]; then
  CSV_PATH="$REMOTE_CSV_PATH"
elif [[ "$REMOTE_MODE" == "true" ]]; then
  CSV_PATH="${REMOTE_IMPORT_SCRIPT%/*}/vmlist.csv"
else
  CSV_PATH="${IMPORT_CSV_PATH:-${SCRIPT_DIR}/vmlist.csv}"
fi
LOG_DIR="${V2V_LOG_BASE_DIR%/}/${VM_NAME}"
if [[ -n "$RUN_LOG_DIR" ]]; then
  if [[ -f "$RUN_LOG_DIR" ]]; then
    echo "warn: RUN_LOG_DIR points to a file, not directory; ignore: $RUN_LOG_DIR" >&2
    RUN_LOG_DIR=""
  fi
fi
if [[ -n "$RUN_LOG_DIR" ]]; then
  LOG_DIR="$RUN_LOG_DIR"
fi
LOG_FILE="${LOG_DIR%/}/import_v2v-$(date +%F_%H%M%S).log"
LOCK_DIR="${IMPORT_LOCK_BASE_DIR%/}/${VM_NAME}.lock"

if [[ ! "$ENGINE_CONNECT_TIMEOUT" =~ ^[0-9]+$ ]] || (( ENGINE_CONNECT_TIMEOUT < 1 )); then
  echo "error: ENGINE_CONNECT_TIMEOUT must be integer >= 1 (current: $ENGINE_CONNECT_TIMEOUT)" >&2
  exit 1
fi

if [[ "$REMOTE_MODE" == "true" ]]; then
  run_remote_import "$CSV_PATH"
  exit $?
fi

if [[ "$MODE" == "run" && "$IMPORT_RUN_WITH_NOHUP" == "true" && "$NOHUP_LAUNCHED" != "1" ]]; then
  mkdir -p "$LOG_DIR" "$IMPORT_LOCK_BASE_DIR"
  if is_vm_locked "$LOCK_DIR"; then
    holder_pid="$(lock_holder_pid "$LOCK_DIR")"
    echo "error: duplicate import blocked for vm=${VM_NAME} (pid=${holder_pid})" >&2
    exit 1
  fi

  NOHUP_LOG="${LOG_DIR%/}/nohup-import_v2v-${VM_NAME}-$(date +%F_%H%M%S).log"
  log "cmd nohup   : env NOHUP_LAUNCHED=1 IMPORT_RUN_WITH_NOHUP=false ... bash ${SELF_PATH} --run-location=${RUN_LOCATION} ${VM_INPUT_RAW} ${CSV_PATH}"
  nohup env \
    NOHUP_LAUNCHED=1 \
    IMPORT_RUN_WITH_NOHUP=false \
    CONFIG_FILE="$CONFIG_FILE" \
    bash "$SELF_PATH" "--run-location=${RUN_LOCATION}" "$VM_INPUT_RAW" "$CSV_PATH" \
    >"$NOHUP_LOG" 2>&1 &
  bg_pid=$!
  echo "$bg_pid" > "${LOCK_DIR%/*}/${VM_NAME}.pid" 2>/dev/null || true
  log "launched in nohup vm=${VM_NAME} pid=${bg_pid}"
  log "nohup log   : $NOHUP_LOG"
  exit 0
fi

STEP_VALIDATE="[1/3]"
STEP_RESOLVE="[2/3]"
STEP_IMPORT="[3/3]"
LOCK_ACQUIRED=0

finish_import() {
  local rc=$?
  trap - EXIT

  if [[ "$LOCK_ACQUIRED" == "1" ]]; then
    release_vm_lock "$LOCK_DIR"
    LOCK_ACQUIRED=0
  fi

  if (( rc == 0 )); then
    log "DONE import_v2v vm=${VM_NAME}"
  else
    log "FAIL import_v2v vm=${VM_NAME} rc=${rc}"
  fi
  exit "$rc"
}

mkdir -p "$LOG_DIR"
if [[ "$IMPORT_V2V_LOG_ENABLE" == "true" ]]; then
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

log "START import_v2v vm=${VM_NAME} config=${CONF_SOURCE}"
if [[ "$IMPORT_V2V_LOG_ENABLE" == "true" ]]; then
  log "script log   : $LOG_FILE"
fi
log "mode         : ${MODE}"
log "run location : ${RUN_LOCATION}"
log "nohup mode   : ${IMPORT_RUN_WITH_NOHUP} (launched=${NOHUP_LAUNCHED})"
log "precheck run : ${PRECHECK}"
host_name="$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)"
virt_v2v_bin="$(command -v virt-v2v 2>/dev/null || true)"
virt_v2v_ver="$(virt-v2v --version 2>/dev/null | head -n1 || true)"
log "host         : ${host_name:-unknown}"
log "virt-v2v bin : ${virt_v2v_bin:-not-found}"
log "virt-v2v ver : ${virt_v2v_ver:-unknown}"
log "csv          : $CSV_PATH"
log "source xml   : ${IMPORT_SOURCE_XML:-auto(${XML_OUT_DIR%/}/${VM_NAME}.xml)}"
log "qemu base    : ${QEMU_BASE_DIR%/}"
if [[ -n "$RUN_LOG_DIR" ]]; then
  log "run log dir  : $RUN_LOG_DIR"
fi
log "lock         : $LOCK_DIR"
if [[ -n "$RAW_RHV_ENGINE_URL" && "$RAW_RHV_ENGINE_URL" != "$RHV_ENGINE_URL" ]]; then
  log "rhv engine   : normalized '$RAW_RHV_ENGINE_URL' -> '$RHV_ENGINE_URL'"
fi
log "rhv engine   : $RHV_ENGINE_URL"
log "rhv user     : $RHV_USERNAME"
log "rhv direct   : $RHV_DIRECT"
log "output       : format=${V2V_OUTPUT_FORMAT} allocation=${V2V_OUTPUT_ALLOCATION}"

trap finish_import EXIT

log "${STEP_VALIDATE} validate required environment"

if ! acquire_vm_lock "$LOCK_DIR"; then
  exit 1
fi
LOCK_ACQUIRED=1

CLUSTER="$RHV_CLUSTER_DEFAULT"
STORAGE="$RHV_STORAGE_DEFAULT"

log "${STEP_RESOLVE} resolve csv/xml/disk inputs"
log "cmd csv      : optional resolve cluster/storage from '${CSV_PATH}'"

csv_line=""
if [[ -f "$CSV_PATH" ]]; then
  csv_line="$(
    sed '1s/^\xEF\xBB\xBF//' "$CSV_PATH" | sed 's/\r$//' \
      | awk -F',' -v vm="$VM_NAME" '
        function trim(s,    t) {
          t = s
          gsub(/^[[:space:]]+/, "", t)
          gsub(/[[:space:]]+$/, "", t)
          return t
        }
        NR == 1 {
          h = tolower(trim($1))
          if (h == "vm" || h == "vm_name" || h == "name") next
        }
        {
          v = trim($1)
          c = trim($2)
          s = trim($3)
          if (v == vm) {
            printf "%s\t%s\t%s\n", v, c, s
            exit
          }
        }
      ' || true
  )"
fi

if [[ -n "$csv_line" ]]; then
  IFS=$'\t' read -r _csv_vm csv_cluster csv_storage <<<"$csv_line"
  [[ -n "$csv_cluster" ]] && CLUSTER="$csv_cluster"
  [[ -n "$csv_storage" ]] && STORAGE="$csv_storage"
fi
log "resolved     : cluster=${CLUSTER} storage=${STORAGE}"

if [[ "$MODE" == "check" ]]; then
  run_precheck "$STORAGE"
  log "CHECK-ONLY mode: skip import execution"
  exit 0
fi

PROFILE_XML_PATH="${IMPORT_SOURCE_XML:-}"
if [[ -z "$PROFILE_XML_PATH" ]]; then
  xml_candidate="${XML_OUT_DIR%/}/${VM_NAME}.xml"
  PROFILE_XML_PATH="$xml_candidate"
fi

RUNTIME_IMPORT_XML=""
if [[ -f "$PROFILE_XML_PATH" ]]; then
  if build_runtime_import_xml "$PROFILE_XML_PATH" "$VM_NAME" && [[ -n "${RUNTIME_IMPORT_XML:-}" && -f "$RUNTIME_IMPORT_XML" ]]; then
    PROFILE_XML_PATH="$RUNTIME_IMPORT_XML"
  else
    log "warn         : runtime xml generation failed, use original source xml"
  fi
else
  log "warn         : source xml not found: ${PROFILE_XML_PATH}"
fi

echo "----"
echo "VM      : $VM_NAME"
echo "Cluster : $CLUSTER"
echo "Storage : $STORAGE"
echo "XML     : $PROFILE_XML_PATH"
echo "----"

log "${STEP_IMPORT} run virt-v2v import"
cmd=(virt-v2v
  -i libvirtxml "$PROFILE_XML_PATH"
  -o rhv-upload
  -oc "$RHV_ENGINE_URL"
  -os "$STORAGE"
  -op "$RHV_PASS_FILE"
  -oo "rhv-cluster=$CLUSTER"
  -of "$V2V_OUTPUT_FORMAT"
  -oa "$V2V_OUTPUT_ALLOCATION"
)
if [[ "$RHV_DIRECT" == "true" ]]; then
  cmd+=(-oo rhv-direct)
fi
if [[ -n "$RHV_CAFILE" ]]; then
  cmd+=(-oo "rhv-cafile=$RHV_CAFILE")
fi
if [[ "$V2V_VERBOSE" == "true" ]]; then
  cmd+=(-v)
fi

if [[ -n "$LIBGUESTFS_BACKEND" ]]; then
  export LIBGUESTFS_BACKEND
fi

printf -v cmd_q '%q ' "${cmd[@]}"
log "cmd         : ${cmd_q% }"
log "env         : LIBGUESTFS_BACKEND=${LIBGUESTFS_BACKEND}"

if [[ "$PRECHECK" == "true" ]]; then
  run_precheck "$STORAGE"
fi

"${cmd[@]}"
