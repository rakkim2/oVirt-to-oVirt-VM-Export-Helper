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

if [[ -z "${CONFIG_FILE:-}" ]]; then
  CONFIG_FILE="${SCRIPT_DIR}/v2v.conf"
fi
declare -a PRESERVE_ENV_KEYS=(
  DATA_BASE_DIR V2V_BASE_DIR V2V_LOG_BASE_DIR QEMU_BASE_DIR RAW_BASE_DIR
  MAX_JOBS INPUT_FORMAT OUTPUT_FORMAT OUTPUT_OPTIONS SPARSE_SIZE
  COROUTINES CACHE_MODE SRC_CACHE_MODE SCRIPT_LOG_ENABLE CONVERT_LOG_ENABLE
  PROGRESS_INTERVAL RUN_LOG_DIR
)
CONF_SOURCE="$(v2v_load_config_with_env "$CONFIG_FILE" "${PRESERVE_ENV_KEYS[@]}")"

usage() {
  cat >&2 <<'EOF'
usage: convert_disks_from_xml.sh <vm-xml>

Convert disk source paths from XML with qemu-img in parallel.
Each disk conversion runs in background and writes a separate log file.
Output format is qcow2.

Fixed paths:
  XML            : <vm-xml input>
  images output  : ${QEMU_BASE_DIR:-/data/v2v/qemu}/<vm-name> (qcow2)
  disk logs      : ${V2V_LOG_BASE_DIR:-/data/v2v_log}/<vm-name>/qemu

Tune values via conf/env:
  MAX_JOBS, INPUT_FORMAT, OUTPUT_FORMAT, OUTPUT_OPTIONS,
  SPARSE_SIZE, COROUTINES, CACHE_MODE, SRC_CACHE_MODE,
  RECREATE_OUTPUT_ON_RETRY
EOF
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
fi

XML_PATH="$1"
if [[ -z "${V2V_BASE_DIR+x}" && -n "${DATA_BASE_DIR+x}" ]]; then
  V2V_BASE_DIR="${DATA_BASE_DIR%/}/v2v"
fi
if [[ -z "${QEMU_BASE_DIR+x}" && -n "${RAW_BASE_DIR+x}" ]]; then
  QEMU_BASE_DIR="$RAW_BASE_DIR"
fi
V2V_BASE_DIR="${V2V_BASE_DIR:-/data/v2v}"
V2V_LOG_BASE_DIR="${V2V_LOG_BASE_DIR:-/data/v2v_log}"
QEMU_BASE_DIR="${QEMU_BASE_DIR:-${V2V_BASE_DIR%/}/qemu}"

MAX_JOBS="${MAX_JOBS:-4}"
INPUT_FORMAT="${INPUT_FORMAT:-auto}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-qcow2}"
OUTPUT_OPTIONS="${OUTPUT_OPTIONS:-compat=1.1,lazy_refcounts=off,cluster_size=65536}"
SPARSE_SIZE="${SPARSE_SIZE:-}"
COROUTINES="${COROUTINES:-8}"
CACHE_MODE="${CACHE_MODE:-writeback}"
SRC_CACHE_MODE="${SRC_CACHE_MODE:-none}"
RECREATE_OUTPUT_ON_RETRY="${RECREATE_OUTPUT_ON_RETRY:-1}"
SCRIPT_LOG_ENABLE="${SCRIPT_LOG_ENABLE:-1}"
CONVERT_LOG_ENABLE="${CONVERT_LOG_ENABLE:-$SCRIPT_LOG_ENABLE}"

if [[ ! -f "$XML_PATH" ]]; then
  echo "error: xml not found: $XML_PATH" >&2
  exit 1
fi

if ! command -v qemu-img >/dev/null 2>&1; then
  echo "error: qemu-img not found" >&2
  exit 1
fi

if [[ ! "$MAX_JOBS" =~ ^[0-9]+$ ]] || (( MAX_JOBS < 1 )); then
  echo "error: MAX_JOBS must be integer >= 1 (current: $MAX_JOBS)" >&2
  exit 1
fi

vm_name=$(
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

if [[ -z "$vm_name" ]]; then
  echo "error: failed to parse vm name from: $XML_PATH" >&2
  exit 1
fi

OUT_DIR="${QEMU_BASE_DIR%/}/${vm_name}"
if [[ -n "${RUN_LOG_DIR:-}" ]]; then
  SCRIPT_LOG_DIR="$RUN_LOG_DIR"
  LOG_DIR="${RUN_LOG_DIR%/}/qemu"
else
  LOG_DIR="${V2V_LOG_BASE_DIR%/}/${vm_name}/qemu"
  SCRIPT_LOG_DIR="${V2V_LOG_BASE_DIR%/}/${vm_name}"
fi
SCRIPT_LOG_FILE="${SCRIPT_LOG_DIR%/}/convert_disks_from_xml-$(date +%F_%H%M%S).log"

mkdir -p "$OUT_DIR" "$LOG_DIR" "$SCRIPT_LOG_DIR"
if is_enabled "$CONVERT_LOG_ENABLE"; then
  exec > >(tee -a "$SCRIPT_LOG_FILE") 2>&1
fi

log "START convert_disks_from_xml xml=${XML_PATH} vm=${vm_name} config=${CONF_SOURCE}"
if is_enabled "$CONVERT_LOG_ENABLE"; then
  log "script log : $SCRIPT_LOG_FILE"
fi

disk_lines=$(
  awk '
  function attr(s, key,    i, rest, j, dq, sq) {
    dq = "\""
    sq = sprintf("%c", 39)

    i = index(s, key "=" dq)
    if (i) {
      rest = substr(s, i + length(key) + 2)
      j = index(rest, dq)
      if (j) return substr(rest, 1, j - 1)
    }

    i = index(s, key "=" sq)
    if (i) {
      rest = substr(s, i + length(key) + 2)
      j = index(rest, sq)
      if (j) return substr(rest, 1, j - 1)
    }

    return ""
  }

  BEGIN {
    in_disk = 0
    idx = 0
  }

  /^[[:space:]]*<disk[[:space:]>]/ {
    in_disk = (attr($0, "device") == "disk")
    src = ""
    tdev = ""
  }

  in_disk && /^[[:space:]]*<source[[:space:]>]/ {
    x = attr($0, "dev")
    if (x == "") x = attr($0, "file")
    if (x != "") src = x
  }

  in_disk && /^[[:space:]]*<target[[:space:]>]/ {
    x = attr($0, "dev")
    if (x != "") tdev = x
  }

  in_disk && /^[[:space:]]*<\/disk>/ {
    if (src != "") {
      idx++
      if (tdev == "") tdev = "disk" idx
      printf "%d\t%s\t%s\n", idx, src, tdev
    }
    in_disk = 0
  }
  ' "$XML_PATH"
)

if [[ -z "$disk_lines" ]]; then
  echo "error: no disk entries found in: $XML_PATH" >&2
  exit 1
fi

declare -a PIDS=()
declare -a PID_DESCS=()
declare -a PID_LOGS=()
declare -a PID_LAST_PCT=()
declare -a PID_STATE=()

PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-30}"

stop_conversion_jobs() {
  local sig="${1:-INT}"
  local pid

  trap - INT TERM HUP
  echo
  echo "[$(now_ts)] interrupt: ${sig} received, stopping qemu-img jobs..." >&2

  for pid in "${PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      if command -v pkill >/dev/null 2>&1; then
        pkill -TERM -P "$pid" 2>/dev/null || true
      fi
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done

  sleep 1

  for pid in "${PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      if command -v pkill >/dev/null 2>&1; then
        pkill -KILL -P "$pid" 2>/dev/null || true
      fi
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done

  wait 2>/dev/null || true
  exit 130
}

trap 'stop_conversion_jobs INT' INT
trap 'stop_conversion_jobs TERM' TERM
trap 'stop_conversion_jobs HUP' HUP

wait_for_slot() {
  while :; do
    running=$(jobs -pr | wc -l | tr -d '[:space:]')
    if (( running < MAX_JOBS )); then
      break
    fi
    sleep 1
  done
}

file_holders() {
  local path="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof "$path" 2>/dev/null || true
    return
  fi
  if command -v fuser >/dev/null 2>&1; then
    fuser -v "$path" 2>/dev/null || true
    return
  fi
  echo "(holder check unavailable: lsof/fuser not found)"
}

is_file_in_use() {
  local path="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof "$path" >/dev/null 2>&1
    return $?
  fi
  if command -v fuser >/dev/null 2>&1; then
    fuser "$path" >/dev/null 2>&1
    return $?
  fi
  return 1
}

launch_convert() {
  local idx="$1"
  local src_path="$2"
  local target_dev="$3"
  local out_ext="$4"
  local input_fmt="$INPUT_FORMAT"
  local out_path="${OUT_DIR%/}/${vm_name}-disk${idx}.${out_ext}"
  local log_path="${LOG_DIR%/}/${vm_name}-disk${idx}.log"
  local start_ts
  start_ts=$(date '+%F %T')

  if [[ ! -b "$src_path" && ! -f "$src_path" ]]; then
    echo "error: source is not readable block/file path: $src_path" >&2
    return 1
  fi
  if [[ -e "$out_path" ]]; then
    if is_file_in_use "$out_path"; then
      echo "error: output image is in use by another process: $out_path" >&2
      file_holders "$out_path" >&2
      return 1
    fi
    if is_enabled "$RECREATE_OUTPUT_ON_RETRY"; then
      log "cleanup     : remove old output ${out_path}"
      rm -f "$out_path"
    fi
  fi

  if [[ "$INPUT_FORMAT" == "auto" ]]; then
    input_fmt="$(
      qemu-img info --output=json "$src_path" 2>/dev/null \
        | tr -d '\n' \
        | sed -n 's/.*"format"[[:space:]]*:[[:space:]]*"\([^"]\+\)".*/\1/p'
    )"
    if [[ -z "$input_fmt" ]]; then
      echo "error: failed to auto-detect input format: $src_path" >&2
      echo "hint : set INPUT_FORMAT manually (e.g. raw or qcow2)" >&2
      return 1
    fi
  fi

  (
    set -euo pipefail
    cmd=(qemu-img convert -p -f "$input_fmt" -O "$OUTPUT_FORMAT")
    if [[ -n "$OUTPUT_OPTIONS" ]]; then
      cmd+=(-o "$OUTPUT_OPTIONS")
    fi
    if [[ -n "$SPARSE_SIZE" ]]; then
      cmd+=(-S "$SPARSE_SIZE")
    fi
    if [[ -n "$COROUTINES" ]]; then
      cmd+=(-m "$COROUTINES")
    fi
    if [[ -n "$CACHE_MODE" ]]; then
      cmd+=(-t "$CACHE_MODE")
    fi
    if [[ -n "$SRC_CACHE_MODE" ]]; then
      cmd+=(-T "$SRC_CACHE_MODE")
    fi
    cmd+=("$src_path" "$out_path")

    {
      echo "[$start_ts] start disk${idx} target=${target_dev}"
      echo "input format: ${input_fmt}"
      printf 'cmd:'
      for token in "${cmd[@]}"; do
        printf ' %q' "$token"
      done
      echo
      "${cmd[@]}"
      rc=$?
      end_ts=$(date '+%F %T')
      echo "[$end_ts] done disk${idx} rc=${rc}"
      exit "$rc"
    } >"$log_path" 2>&1
  ) &

  pid=$!
  PIDS+=("$pid")
  PID_DESCS+=("disk${idx}(${target_dev})")
  PID_LOGS+=("$log_path")
  PID_LAST_PCT+=("")
  PID_STATE+=("running")

  log "queued: disk${idx} target=${target_dev} src=${src_path} out=${out_path} log=${log_path} pid=${pid}"
}

progress_from_log() {
  local log_path="$1"
  local pct
  local tail_text=""

  if [[ ! -f "$log_path" ]]; then
    echo ""
    return
  fi

  tail_text="$(tail -c 131072 "$log_path" 2>/dev/null | tr '\r' '\n' || true)"
  pct="$(
    printf '%s' "$tail_text" \
      | grep -Eo '[0-9]+([.][0-9]+)?/100%' \
      | tail -n1 \
      | cut -d/ -f1 \
      || true
  )"
  if [[ -z "$pct" ]]; then
    pct="$(
      printf '%s' "$tail_text" \
        | grep -Eo '[0-9]+([.][0-9]+)?%' \
        | tail -n1 \
        | tr -d '%' \
        || true
    )"
  fi

  if [[ -n "$pct" ]]; then
    echo "$pct"
  else
    echo ""
  fi
}

log "xml         : $XML_PATH"
log "vm          : $vm_name"
log "output dir  : $OUT_DIR"
log "log dir     : $LOG_DIR"
log "max jobs    : $MAX_JOBS"
log "input fmt   : $INPUT_FORMAT"
log "output fmt  : $OUTPUT_FORMAT"
log "overwrite   : $RECREATE_OUTPUT_ON_RETRY"

out_ext="$OUTPUT_FORMAT"
while IFS=$'\t' read -r idx src_path target_dev; do
  [[ -z "$idx" ]] && continue
  wait_for_slot
  launch_convert "$idx" "$src_path" "$target_dev" "$out_ext"
done <<< "$disk_lines"

log "waiting for ${#PIDS[@]} conversion jobs for ${vm_name}... (updates every ${PROGRESS_INTERVAL}s)"
fail=0
declare -a PID_DONE=()
for _ in "${PIDS[@]}"; do
  PID_DONE+=("0")
done

while :; do
  running=0
  done_count=0
  fail_count=0

  for i in "${!PIDS[@]}"; do
    if [[ "${PID_DONE[$i]}" == "1" ]]; then
      if [[ "${PID_STATE[$i]}" == "done" ]]; then
        done_count=$((done_count + 1))
      elif [[ "${PID_STATE[$i]}" == "fail" ]]; then
        fail_count=$((fail_count + 1))
      fi
      continue
    fi

    pid="${PIDS[$i]}"
    desc="${PID_DESCS[$i]}"
    log_path="${PID_LOGS[$i]}"

    if kill -0 "$pid" 2>/dev/null; then
      running=$((running + 1))
      PID_STATE[$i]="running"
      pct=$(progress_from_log "$log_path")
      if [[ -n "$pct" ]]; then
        PID_LAST_PCT[$i]="$pct"
      fi
      continue
    fi

    if wait "$pid"; then
      log "ok   : ${desc}"
      PID_LAST_PCT[$i]="100.00"
      PID_STATE[$i]="done"
      done_count=$((done_count + 1))
    else
      echo "[$(now_ts)] fail : ${desc} (log: ${log_path})" >&2
      fail=1
      PID_STATE[$i]="fail"
      fail_count=$((fail_count + 1))
    fi
    PID_DONE[$i]="1"
  done

  progress_line="progress(${vm_name}): running=${running} done=${done_count}/${#PIDS[@]} fail=${fail_count}"
  log "$progress_line"
  for i in "${!PIDS[@]}"; do
    desc="${PID_DESCS[$i]}"
    pct="${PID_LAST_PCT[$i]}"
    state="${PID_STATE[$i]}"
    if [[ "$state" == "done" ]]; then
      log "  ${desc}: done (100.00%)"
    elif [[ "$state" == "fail" ]]; then
      log "  ${desc}: fail"
    elif [[ -n "$pct" ]]; then
      log "  ${desc}: ${pct}%"
    else
      log "  ${desc}: -"
    fi
  done

  if (( running == 0 )); then
    break
  fi

  sleep "$PROGRESS_INTERVAL"
done

if (( fail != 0 )); then
  echo "error: one or more disk conversions failed" >&2
  exit 1
fi

log "DONE convert_disks_from_xml all conversions completed"
