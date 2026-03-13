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

is_pid_alive() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

latest_file() {
  local pattern="$1"
  ls -1t $pattern 2>/dev/null | head -n1 || true
}

latest_vm_log() {
  local vm="$1"
  local pattern="$2"
  local f=""
  f="$(latest_file "${V2V_LOG_BASE_DIR%/}/${vm}/${pattern}")"
  if [[ -z "$f" ]]; then
    f="$(latest_file "${V2V_LOG_BASE_DIR%/}/${vm}/runs/"*/"${pattern}")"
  fi
  echo "$f"
}

latest_log_in_dir() {
  local dir="$1"
  local pattern="$2"
  [[ -d "$dir" ]] || { echo ""; return; }
  ls -1t "${dir%/}"/$pattern 2>/dev/null | head -n1 || true
}

pipeline_run_dir_from_log() {
  local p_log="$1"
  [[ -f "$p_log" ]] || { echo ""; return; }
  dirname "$p_log"
}

extract_ts() {
  local file="$1"
  [[ -f "$file" ]] || { echo "-"; return; }
  awk '
    match($0, /^\[([0-9-]+ [0-9:]+)\]/, m) { ts=m[1] }
    END { print (ts=="" ? "-" : ts) }
  ' "$file"
}

extract_first_ts() {
  local file="$1"
  [[ -f "$file" ]] || { echo "-"; return; }
  awk '
    match($0, /^\[([0-9-]+ [0-9:]+)\]/, m) { print m[1]; found=1; exit }
    END { if (!found) print "-" }
  ' "$file"
}

pipeline_stage() {
  local file="$1"
  local stage="-"
  [[ -f "$file" ]] || { echo "$stage"; return; }

  stage="$(
    awk '
      {
        if ($0 ~ /FAIL run_qemu_ova_pipeline/)      s="failed";
        if ($0 ~ /DONE run_qemu_ova_pipeline/)      s="done";
        if ($0 ~ /\] activate lv$/)                 s="lv-up";
        if ($0 ~ /\] convert disks \(parallel\)$/)  s="convert";
        if ($0 ~ /\] build ova$/)                   s="build-ova";
        if ($0 ~ /\] import to rhv on target host$/) s="import";
        if ($0 ~ /\] deactivate lv$/)               s="lv-down";
      }
      END { print (s=="" ? "-" : s) }
    ' "$file"
  )"
  echo "$stage"
}

import_stage() {
  local file="$1"
  local stage="-"
  [[ -f "$file" ]] || { echo "$stage"; return; }

  stage="$(
    awk '
      {
        if ($0 ~ /FAIL import_v2v/)            s="failed";
        if ($0 ~ /DONE import_v2v/)            s="done";
        if ($0 ~ /\] run virt-v2v import$/)    s="running";
        if ($0 ~ /\] build import xml/)        s="xml";
        if ($0 ~ /\] resolve csv\/xml\/disk/)  s="resolve";
        if ($0 ~ /\] validate required environment/) s="validate";
      }
      END { print (s=="" ? "-" : s) }
    ' "$file"
  )"
  echo "$stage"
}

latest_percent_from_log() {
  local file="$1"
  local tail_text=""
  local pct=""

  [[ -f "$file" ]] || { echo ""; return; }
  tail_text="$(tail -c 262144 "$file" 2>/dev/null | tr '\r' '\n' || true)"

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

  echo "$pct"
}

import_summary() {
  local file="$1"
  local stage="$2"
  local pct=""

  [[ -f "$file" ]] || { echo "$stage"; return; }
  pct="$(latest_percent_from_log "$file")"

  case "$stage" in
    done)
      echo "done(100.00%)"
      ;;
    failed)
      if [[ -n "$pct" ]]; then
        echo "failed(${pct}%)"
      else
        echo "failed"
      fi
      ;;
    -)
      if [[ -n "$pct" ]]; then
        echo "running(${pct}%)"
      else
        echo "-"
      fi
      ;;
    *)
      if [[ -n "$pct" ]]; then
        echo "${stage}(${pct}%)"
      else
        echo "$stage"
      fi
      ;;
  esac
}

disk_progress_one() {
  local file="$1"
  local desc=""
  local pct=""
  local done_flag="0"
  local tail_text=""

  [[ -f "$file" ]] || { echo "||0"; return; }

  desc="$(
    awk '
      /start disk[0-9]+/ {
        d=""; t="";
        for (i=1; i<=NF; i++) {
          if ($i ~ /^disk[0-9]+$/) d=$i;
          if ($i ~ /^target=/) { t=$i; sub(/^target=/, "", t); }
        }
      }
      END {
        if (d != "") {
          if (t != "") printf "%s(%s)", d, t;
          else printf "%s", d;
        }
      }
    ' "$file"
  )"

  tail_text="$(tail -c 131072 "$file" 2>/dev/null | tr '\r' '\n' || true)"
  pct="$(latest_percent_from_log "$file")"

  if grep -q 'done disk[0-9]\+' "$file"; then
    done_flag="1"
  fi

  echo "${desc}|${pct}|${done_flag}"
}

qemu_summary() {
  local vm="$1"
  local run_dir="${2:-}"
  local qlogs_txt=""
  local latest_run_qemu_dir=""
  local line=""
  local desc=""
  local pct=""
  local done_flag=""
  local total=0
  local done=0
  local fail=0
  local summary=""

  if [[ -n "$run_dir" ]]; then
    qlogs_txt="$(ls -1 "${run_dir%/}/qemu/${vm}-disk"*.log 2>/dev/null | sort -V || true)"
  else
    qlogs_txt="$(ls -1 "${V2V_LOG_BASE_DIR%/}/${vm}/qemu/${vm}-disk"*.log 2>/dev/null | sort -V || true)"
    if [[ -z "$qlogs_txt" ]]; then
      latest_run_qemu_dir="$(ls -1dt "${V2V_LOG_BASE_DIR%/}/${vm}/runs/"*/qemu 2>/dev/null | head -n1 || true)"
      if [[ -n "$latest_run_qemu_dir" ]]; then
        qlogs_txt="$(ls -1 "${latest_run_qemu_dir%/}/${vm}-disk"*.log 2>/dev/null | sort -V || true)"
      fi
    fi
  fi
  if [[ -z "$qlogs_txt" ]]; then
    echo "-"
    return
  fi

  while IFS= read -r qf; do
    [[ -z "$qf" ]] && continue
    total=$((total + 1))
    line="$(disk_progress_one "$qf")"
    IFS='|' read -r desc pct done_flag <<<"$line"
    if [[ -z "$desc" ]]; then
      desc="$(basename "$qf" .log)"
      desc="${desc#${vm}-}"
    fi

    if [[ "$done_flag" == "1" ]]; then
      done=$((done + 1))
      pct="100.00"
    elif grep -q "fail : " "$qf" 2>/dev/null; then
      fail=$((fail + 1))
      pct="fail"
    elif [[ -z "$pct" ]]; then
      pct="-"
    fi

    if [[ -n "$summary" ]]; then
      summary="${summary} "
    fi
    summary="${summary}${desc}=${pct}"
  done <<< "$qlogs_txt"

  if (( total == 0 )); then
    echo "-"
    return
  fi

  echo "${summary} (done=${done}/${total}, fail=${fail})"
}

ova_summary() {
  local vm="$1"
  local p_log="$2"
  local p_stage="$3"
  local run_dir="${4:-}"
  local olog=""
  local pct=""

  if [[ -f "$p_log" ]]; then
    if grep -q "skip ova build (BUILD_OVA=false)" "$p_log" 2>/dev/null \
      || grep -q "ova    : skipped (IMPORT_TO_RHV=true)" "$p_log" 2>/dev/null \
      || grep -q "IMPORT_TO_RHV=true -> force BUILD_OVA=false" "$p_log" 2>/dev/null
    then
      echo "skip"
      return
    fi
  fi

  if [[ -n "$run_dir" ]]; then
    olog="$(latest_log_in_dir "$run_dir" 'make_ovirt_ova*.log')"
  else
    olog="$(latest_vm_log "$vm" 'make_ovirt_ova*.log')"
  fi
  if [[ -z "$olog" || ! -f "$olog" ]]; then
    if [[ "$p_stage" == "build-ova" ]]; then
      echo "start"
    else
      echo "-"
    fi
    return
  fi

  if grep -q "DONE make_ovirt_ova" "$olog" 2>/dev/null; then
    echo "100%"
    return
  fi

  if grep -q "error: failed while creating tar archive for ova" "$olog" 2>/dev/null; then
    echo "fail"
    return
  fi

  pct="$(
    awk '
      match($0, /packing\([^)]*\)[[:space:]]*:[[:space:]]*([0-9]+(\.[0-9]+)?)%/, m) { p=m[1] }
      END { if (p != "") print p }
    ' "$olog"
  )"
  if [[ -n "$pct" ]]; then
    echo "${pct}%"
    return
  fi

  if grep -q "packing(.*) : start" "$olog" 2>/dev/null; then
    echo "start"
    return
  fi

  echo "-"
}

lock_pid() {
  local lock_dir="$1"
  local pid_file="${lock_dir}/pid"
  if [[ -f "$pid_file" ]]; then
    cat "$pid_file" 2>/dev/null || true
  fi
}

lock_state() {
  local lock_dir="$1"
  local pid=""
  if [[ ! -d "$lock_dir" ]]; then
    echo "-"
    return
  fi
  pid="$(lock_pid "$lock_dir")"
  if is_pid_alive "$pid"; then
    echo "run:${pid}"
  else
    echo "stale"
  fi
}

collect_vms() {
  local d=""
  local base=""

  if (( ${#REQ_VMS[@]} > 0 )); then
    printf '%s\n' "${REQ_VMS[@]}" | awk 'NF>0' | sort -u
  else
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
  fi
}

print_board() {
  local vm_list=""
  local vm=""
  local p_lock=""
  local i_lock=""
  local p_log=""
  local i_log=""
  local p_stage=""
  local i_stage=""
  local i_pct_hint=""
  local i_sum=""
  local q_sum=""
  local o_sum=""
  local merged_state=""
  local start_ts=""
  local ts=""
  local ts_file=""
  local run_dir=""
  local import_newer="false"

  vm_list="$(collect_vms || true)"

  if [[ "$WATCH" == "true" ]]; then
    printf '\033[H\033[2J'
  fi

  echo "v2v status board  $(date '+%F %T')"
  echo "log_base=${V2V_LOG_BASE_DIR}  lock_base=${VM_LOCK_BASE_DIR}  import_lock_base=${IMPORT_LOCK_BASE_DIR}"
  echo
  echo "VM|PIPE_LOCK|PIPE|START_TIME|LAST_UPDATE|STATE"
  echo "--|---------|----|----------|-----------|-----"

  if [[ -z "$vm_list" ]]; then
    echo "(no vm logs/locks found)"
    return
  fi

  while IFS= read -r vm; do
    [[ -z "$vm" ]] && continue
    p_lock="$(lock_state "${VM_LOCK_BASE_DIR%/}/${vm}.lock")"
    i_lock="$(lock_state "${IMPORT_LOCK_BASE_DIR%/}/${vm}.lock")"
    p_log="$(latest_vm_log "$vm" 'pipeline_*.log')"
    if [[ -z "$p_log" ]]; then
      p_log="$(latest_vm_log "$vm" 'pipeline*.log')"
    fi
    run_dir="$(pipeline_run_dir_from_log "$p_log")"
    if [[ -n "$run_dir" ]]; then
      i_log="$(latest_log_in_dir "$run_dir" 'import_v2v*.log')"
    else
      i_log="$(latest_vm_log "$vm" 'import_v2v*.log')"
    fi
    # If pipeline log exists but no import log in that run dir,
    # fallback to the latest VM-level import log (import-only run).
    if [[ -z "$i_log" ]]; then
      i_log="$(latest_vm_log "$vm" 'import_v2v*.log')"
    fi
    p_stage="$(pipeline_stage "$p_log")"
    i_stage="$(import_stage "$i_log")"
    q_sum="$(qemu_summary "$vm" "$run_dir")"
    o_sum="$(ova_summary "$vm" "$p_log" "$p_stage" "$run_dir")"
    if [[ -n "$i_log" && ( -z "$p_log" || "$i_log" -nt "$p_log" ) ]]; then
      import_newer="true"
    else
      import_newer="false"
    fi

    start_ts="$(extract_first_ts "$p_log")"
    if [[ "$start_ts" == "-" || "$import_newer" == "true" ]]; then
      start_ts="$(extract_first_ts "$i_log")"
    fi
    ts_file="$p_log"
    if [[ "$import_newer" == "true" ]]; then
      ts_file="$i_log"
    fi
    ts="$(extract_ts "$ts_file")"

    if [[ "$i_lock" == run:* && "$i_stage" == "-" ]]; then
      i_stage="running"
    fi
    if [[ "$p_lock" == run:* && "$p_stage" == "-" ]]; then
      p_stage="running"
    fi

    # If no live lock but stage is still non-terminal, treat it as stopped.
    if [[ "$p_lock" == "stale" ]]; then
      case "$p_stage" in
        lv-up|convert|build-ova|import|lv-down|running)
          p_stage="stale-lock"
          ;;
      esac
    elif [[ "$p_lock" == "-" ]]; then
      case "$p_stage" in
        lv-up|convert|build-ova|import|lv-down|running)
          p_stage="stopped"
          ;;
      esac
    fi
    i_pct_hint="$(latest_percent_from_log "$i_log")"
    if [[ "$i_lock" == "stale" ]]; then
      case "$i_stage" in
        validate|resolve|xml|running)
          i_stage="stale-lock"
          ;;
      esac
    elif [[ "$i_lock" == "-" ]]; then
      case "$i_stage" in
        validate|resolve|xml|running)
          if [[ -n "$i_pct_hint" ]]; then
            i_stage="running-no-lock"
          else
            i_stage="stopped"
          fi
          ;;
      esac
    fi

    if [[ "$p_lock" == "-" && "$i_lock" != "-" ]]; then
      p_lock="imp:${i_lock}"
    fi

    # If the latest activity is standalone import and pipeline is not running,
    # don't keep showing an old pipeline failure as current pipe state.
    if [[ "$p_lock" == "-" && "$import_newer" == "true" ]]; then
      case "$p_stage" in
        failed|done|stopped|stale-lock|-)
          p_stage="import-only"
          ;;
      esac
    fi

    i_sum="$(import_summary "$i_log" "$i_stage")"
    merged_state="convert=${q_sum} | ova=${o_sum} | import=${i_sum}"
    printf "%s|%s|%s|%s|%s|%s\n" "$vm" "$p_lock" "$p_stage" "$start_ts" "$ts" "$merged_state"
  done <<< "$vm_list"
}

usage() {
  cat >&2 <<'EOF'
usage:
  show_v2v_status.sh [--watch[=sec]] [vm-name ...]

Summary-only board for multiple VMs.
- Shows current pipeline stage, converting disk progress, import stage, and lock state.
- Reads existing logs under /data/v2v_log by default.

options:
  --watch           refresh every 5 seconds
  --watch=<sec>     refresh every <sec> seconds
  -w <sec>          same as --watch=<sec>
  -h, --help        show this help
EOF
  exit 1
}

if [[ -z "${CONFIG_FILE:-}" ]]; then
  CONFIG_FILE="${SCRIPT_DIR}/v2v.conf"
fi

declare -a PRESERVE_ENV_KEYS=(
  V2V_BASE_DIR V2V_LOG_BASE_DIR VM_LOCK_BASE_DIR IMPORT_LOCK_BASE_DIR
)
v2v_load_config_with_env "$CONFIG_FILE" "${PRESERVE_ENV_KEYS[@]}" >/dev/null

V2V_BASE_DIR="${V2V_BASE_DIR:-/data/v2v}"
V2V_LOG_BASE_DIR="${V2V_LOG_BASE_DIR:-/data/v2v_log}"
VM_LOCK_BASE_DIR="${VM_LOCK_BASE_DIR:-${V2V_BASE_DIR%/}/locks}"
IMPORT_LOCK_BASE_DIR="${IMPORT_LOCK_BASE_DIR:-${V2V_BASE_DIR%/}/locks/import_v2v}"

WATCH="false"
WATCH_SEC="5"
REQ_VMS=()

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
    -h|--help)
      usage
      ;;
    *)
      REQ_VMS+=("$1")
      shift
      ;;
  esac
done

if [[ "$WATCH" == "true" ]]; then
  if [[ ! "$WATCH_SEC" =~ ^[0-9]+$ ]] || (( WATCH_SEC < 1 )); then
    echo "error: watch interval must be integer >= 1 (current: $WATCH_SEC)" >&2
    exit 1
  fi
fi

if [[ "$WATCH" == "true" ]]; then
  while :; do
    print_board
    sleep "$WATCH_SEC"
  done
else
  print_board
fi
