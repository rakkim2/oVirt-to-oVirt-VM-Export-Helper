#!/usr/bin/env bash
set -euo pipefail

now_ts() {
  date '+%F %T'
}

log() {
  echo "[$(now_ts)] $*"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/import.conf}"
CONF_SOURCE="default-env"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  CONF_SOURCE="$CONFIG_FILE"
fi

usage() {
  cat >&2 <<'EOF'
usage: convert_disks_from_xml.sh <vm-xml>

Convert disk source paths from XML with qemu-img in parallel.
Each disk conversion runs in background and writes a separate log file.
Output format is qcow2.

Fixed paths:
  XML            : <vm-xml input>
  images output  : ${RAW_BASE_DIR:-/data/v2v}/<vm-name>/images (qcow2)
  disk logs      : ${RAW_BASE_DIR:-/data/v2v}/<vm-name>/logs/qemu

Tune values via conf/env:
  MAX_JOBS, INPUT_FORMAT, OUTPUT_FORMAT, OUTPUT_OPTIONS,
  SPARSE_SIZE, COROUTINES, CACHE_MODE, SRC_CACHE_MODE
EOF
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
fi

XML_PATH="$1"
RAW_BASE_DIR="${RAW_BASE_DIR:-/data/v2v}"

MAX_JOBS="${MAX_JOBS:-4}"
INPUT_FORMAT="${INPUT_FORMAT:-raw}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-qcow2}"
OUTPUT_OPTIONS="${OUTPUT_OPTIONS:-compat=1.1,lazy_refcounts=off,cluster_size=65536}"
SPARSE_SIZE="${SPARSE_SIZE:-}"
COROUTINES="${COROUTINES:-8}"
CACHE_MODE="${CACHE_MODE:-writeback}"
SRC_CACHE_MODE="${SRC_CACHE_MODE:-none}"

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

OUT_DIR="${RAW_BASE_DIR%/}/${vm_name}/images"
LOG_DIR="${RAW_BASE_DIR%/}/${vm_name}/logs/qemu"
mkdir -p "$OUT_DIR" "$LOG_DIR"

log "START convert_disks_from_xml xml=${XML_PATH} vm=${vm_name} config=${CONF_SOURCE}"

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

launch_convert() {
  local idx="$1"
  local src_path="$2"
  local target_dev="$3"
  local out_ext="$4"
  local out_path="${OUT_DIR%/}/${vm_name}-disk${idx}.${out_ext}"
  local log_path="${LOG_DIR%/}/${vm_name}-disk${idx}.log"
  local start_ts
  start_ts=$(date '+%F %T')

  if [[ ! -b "$src_path" && ! -f "$src_path" ]]; then
    echo "error: source is not readable block/file path: $src_path" >&2
    return 1
  fi

  (
    set -euo pipefail
    cmd=(qemu-img convert -p -f "$INPUT_FORMAT" -O "$OUTPUT_FORMAT")
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

  log "queued: disk${idx} target=${target_dev} pid=${pid}"
}

progress_from_log() {
  local log_path="$1"
  local pct

  if [[ ! -f "$log_path" ]]; then
    echo ""
    return
  fi

  pct=$(
    tail -c 65536 "$log_path" 2>/dev/null \
      | perl -0777 -ne 'while(/\(\s*([0-9]+(?:\.[0-9]+)?)\/100%\)/g){$p=$1} END{print $p if defined $p}' \
      || true
  )

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

  for i in "${!PIDS[@]}"; do
    if [[ "${PID_DONE[$i]}" == "1" ]]; then
      continue
    fi

    pid="${PIDS[$i]}"
    desc="${PID_DESCS[$i]}"
    log_path="${PID_LOGS[$i]}"

    if kill -0 "$pid" 2>/dev/null; then
      running=$((running + 1))
      pct=$(progress_from_log "$log_path")
      if [[ -n "$pct" ]]; then
        PID_LAST_PCT[$i]="$pct"
      fi
      continue
    fi

    if wait "$pid"; then
      log "ok   : ${desc}"
      PID_LAST_PCT[$i]="100.00"
    else
      echo "[$(now_ts)] fail : ${desc} (log: ${log_path})" >&2
      fail=1
    fi
    PID_DONE[$i]="1"
  done

  progress_line="progress(${vm_name}):"
  for i in "${!PIDS[@]}"; do
    desc="${PID_DESCS[$i]}"
    pct="${PID_LAST_PCT[$i]}"
    if [[ -n "$pct" ]]; then
      progress_line="${progress_line} ${desc}=${pct}%"
    else
      progress_line="${progress_line} ${desc}=-"
    fi
  done

  if (( running == 0 )); then
    break
  fi

  log "$progress_line"
  sleep "$PROGRESS_INTERVAL"
done

if (( fail != 0 )); then
  echo "error: one or more disk conversions failed" >&2
  exit 1
fi

log "DONE convert_disks_from_xml all conversions completed"
