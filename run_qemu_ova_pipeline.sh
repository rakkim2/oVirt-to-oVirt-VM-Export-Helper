#!/usr/bin/env bash
set -euo pipefail

now_ts() {
  date '+%F %T'
}

log() {
  echo "[$(now_ts)] $*"
}

usage() {
  cat >&2 <<'EOF'
usage: run_qemu_ova_pipeline.sh <vm-xml>

Pipeline:
  1) toggle_lv_from_xml.sh up
  2) convert_disks_from_xml.sh (parallel qemu-img to qcow2)
  3) make_ovirt_ova.sh (OVA package from qcow2 files)
  4) toggle_lv_from_xml.sh down (always on exit)

Inputs:
  - XML path: <vm-xml>
  - RAW_BASE_DIR (default: /data/v2v)
  - OVA_BASE_DIR (default: /data/ova)
  - Pipeline log file: /data/v2v/<vm>/logs/pipeline-YYYY-mm-dd_HHMMSS.log
EOF
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
fi

XML_PATH="$1"
RAW_BASE_DIR="${RAW_BASE_DIR:-/data/v2v}"
OVA_BASE_DIR="${OVA_BASE_DIR:-/data/ova}"
PIPELINE_LOG_ENABLE="${PIPELINE_LOG_ENABLE:-1}"

if [[ ! -f "$XML_PATH" ]]; then
  echo "error: vm xml not found: $XML_PATH" >&2
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

RAW_VM_DIR="${RAW_BASE_DIR%/}/${VM_NAME}"
PIPELINE_LOG_DIR="${RAW_VM_DIR%/}/logs"
PIPELINE_LOG_FILE="${PIPELINE_LOG_DIR%/}/pipeline-$(date +%F_%H%M%S).log"

mkdir -p "$PIPELINE_LOG_DIR"

if [[ "$PIPELINE_LOG_ENABLE" == "1" ]]; then
  exec > >(tee -a "$PIPELINE_LOG_FILE") 2>&1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG_DIR="${RAW_VM_DIR%/}/images"
OVA_PATH="${OVA_BASE_DIR%/}/${VM_NAME}/${VM_NAME}.ova"

mkdir -p "$IMG_DIR"

log "START run_qemu_ova_pipeline xml=${XML_PATH}"
if [[ "$PIPELINE_LOG_ENABLE" == "1" ]]; then
  log "pipeline log : $PIPELINE_LOG_FILE"
fi

finish_pipeline() {
  local rc=$?
  trap - EXIT
  set +e

  log "[4/4] deactivate lv"
  bash "${SCRIPT_DIR}/toggle_lv_from_xml.sh" "$XML_PATH" down
  down_rc=$?
  if (( down_rc != 0 )); then
    echo "error: failed to deactivate lv (rc=${down_rc})" >&2
    if (( rc == 0 )); then
      rc=$down_rc
    fi
  fi

  if (( rc == 0 )); then
    log "DONE run_qemu_ova_pipeline"
    log "xml : $XML_PATH"
    log "ova : $OVA_PATH"
  else
    log "FAIL run_qemu_ova_pipeline rc=${rc}"
  fi

  exit "$rc"
}

trap finish_pipeline EXIT

log "[1/3] activate lv"
bash "${SCRIPT_DIR}/toggle_lv_from_xml.sh" "$XML_PATH" up

log "[2/3] convert disks (parallel)"
RAW_BASE_DIR="$RAW_BASE_DIR" \
bash "${SCRIPT_DIR}/convert_disks_from_xml.sh" "$XML_PATH"

log "[3/3] build ova"
shopt -s nullglob
qcow2_files=( "${IMG_DIR}/${VM_NAME}-disk"*.qcow2 )
shopt -u nullglob

if [[ ${#qcow2_files[@]} -eq 0 ]]; then
  echo "error: no qcow2 files found under: $IMG_DIR" >&2
  exit 1
fi

RAW_BASE_DIR="$RAW_BASE_DIR" \
OVA_BASE_DIR="$OVA_BASE_DIR" \
bash "${SCRIPT_DIR}/make_ovirt_ova.sh" "$XML_PATH" "${qcow2_files[@]}"
