#!/usr/bin/env bash
set -euo pipefail

cmd_q() {
  local rendered
  printf -v rendered '%q ' "$@"
  echo "${rendered% }"
}

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
  V2V_LOG_BASE_DIR SCRIPT_LOG_ENABLE TOGGLE_LV_LOG_ENABLE RUN_LOG_DIR
  UP_MODE SET_PERM_ON_ACTIVE_LV DEACTIVATE_RETRY_COUNT DEACTIVATE_RETRY_SLEEP
)
CONF_SOURCE="$(v2v_load_config_with_env "$CONFIG_FILE" "${PRESERVE_ENV_KEYS[@]}")"

usage() {
  cat >&2 <<'EOF'
usage: toggle_lv_from_xml.sh <vm-xml> [up|down|status]

  up      : activate LVs (default)
  down    : deactivate LVs
  status  : print LV active state and permission

Supported source dev path styles:
  - /dev/<SD_UUID>/<VOL_UUID>
  - /rhev/data-center/mnt/blockSD/<SD_UUID>/images/<IMG_UUID>/<VOL_UUID>

Note:
  - Parses both <source dev="..."> and <source file="..."> from XML.
EOF
  exit 1
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
fi

XML_PATH="$1"
ACTION="${2:-up}"

case "$ACTION" in
  up|down|status) ;;
  *) usage ;;
esac

if [[ ! -f "$XML_PATH" ]]; then
  echo "error: xml not found: $XML_PATH" >&2
  exit 1
fi

V2V_LOG_BASE_DIR="${V2V_LOG_BASE_DIR:-/data/v2v_log}"
SCRIPT_LOG_ENABLE="${SCRIPT_LOG_ENABLE:-1}"
TOGGLE_LV_LOG_ENABLE="${TOGGLE_LV_LOG_ENABLE:-$SCRIPT_LOG_ENABLE}"
VM_NAME="$(
  awk '
  function text_between(s, open_tag, close_tag,    t) {
    t = s
    sub("^.*<" open_tag "[^>]*>", "", t)
    sub("</" close_tag ">.*$", "", t)
    return t
  }
  /^[[:space:]]*<name>/ { print text_between($0, "name", "name"); exit }
  ' "$XML_PATH"
)"
if [[ -z "$VM_NAME" ]]; then
  VM_NAME="$(basename "$XML_PATH" .xml)"
fi
SCRIPT_LOG_DIR="${V2V_LOG_BASE_DIR%/}/${VM_NAME}"
if [[ -n "${RUN_LOG_DIR:-}" ]]; then
  SCRIPT_LOG_DIR="$RUN_LOG_DIR"
fi
SCRIPT_LOG_FILE="${SCRIPT_LOG_DIR%/}/toggle_lv_from_xml-${ACTION}-$(date +%F_%H%M%S).log"

mkdir -p "$SCRIPT_LOG_DIR"
if is_enabled "$TOGGLE_LV_LOG_ENABLE"; then
  exec > >(tee -a "$SCRIPT_LOG_FILE") 2>&1
fi

if ! command -v lvchange >/dev/null 2>&1; then
  echo "error: lvchange not found" >&2
  exit 1
fi

UP_MODE="${UP_MODE:-ro}"
SET_PERM_ON_ACTIVE_LV="${SET_PERM_ON_ACTIVE_LV:-0}"
DEACTIVATE_RETRY_COUNT="${DEACTIVATE_RETRY_COUNT:-5}"
DEACTIVATE_RETRY_SLEEP="${DEACTIVATE_RETRY_SLEEP:-1}"

case "$UP_MODE" in
  ro|rw) ;;
  *)
    echo "error: UP_MODE must be ro or rw (current: $UP_MODE)" >&2
    exit 1
    ;;
esac

if [[ ! "$SET_PERM_ON_ACTIVE_LV" =~ ^[01]$ ]]; then
  echo "error: SET_PERM_ON_ACTIVE_LV must be 0 or 1 (current: $SET_PERM_ON_ACTIVE_LV)" >&2
  exit 1
fi

if [[ ! "$DEACTIVATE_RETRY_COUNT" =~ ^[0-9]+$ ]] || (( DEACTIVATE_RETRY_COUNT < 1 )); then
  echo "error: DEACTIVATE_RETRY_COUNT must be integer >= 1 (current: $DEACTIVATE_RETRY_COUNT)" >&2
  exit 1
fi

if [[ ! "$DEACTIVATE_RETRY_SLEEP" =~ ^[0-9]+$ ]]; then
  echo "error: DEACTIVATE_RETRY_SLEEP must be integer >= 0 (current: $DEACTIVATE_RETRY_SLEEP)" >&2
  exit 1
fi

log "START toggle_lv_from_xml xml=${XML_PATH} action=${ACTION} config=${CONF_SOURCE}"
if is_enabled "$TOGGLE_LV_LOG_ENABLE"; then
  log "script log : $SCRIPT_LOG_FILE"
fi

declare -a LV_LIST=()
lv_already_added() {
  local needle="$1"
  local item
  for item in "${LV_LIST[@]-}"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

get_lv_state() {
  local item="$1"
  local state
  local attr
  local state_ch

  state="$(lvs --noheadings -o lv_active "$item" 2>/dev/null | tr -d '[:space:]')"
  if [[ -n "$state" ]]; then
    echo "$state"
    return
  fi

  # Fallback for older lvm versions (ex: CentOS 7) where lv_active may be absent.
  attr="$(lvs --noheadings -o lv_attr "$item" 2>/dev/null | tr -d '[:space:]')"
  if [[ ${#attr} -ge 5 ]]; then
    state_ch="${attr:4:1}"
    case "$state_ch" in
      a) echo "active" ;;
      *) echo "inactive" ;;
    esac
    return
  fi

  echo ""
}

get_lv_attr() {
  local item="$1"
  lvs --noheadings -o lv_attr "$item" 2>/dev/null | tr -d '[:space:]'
}

get_lv_perm() {
  local item="$1"
  local perm
  local attr
  local perm_ch
  local lvdisp
  local access

  perm="$(lvs --noheadings -o lv_permissions "$item" 2>/dev/null | tr -d '[:space:]')"
  if [[ -n "$perm" ]]; then
    case "$perm" in
      writeable|writable|rw) echo "writeable"; return ;;
      read-only|readonly|read_only|r) echo "read-only"; return ;;
      *) ;;
    esac
    echo "$perm"
    return
  fi

  # Fallback for older lvm output style.
  lvdisp="$(lvdisplay -c "$item" 2>/dev/null | head -n1 || true)"
  if [[ -n "$lvdisp" ]]; then
    access="$(echo "$lvdisp" | awk -F: '{print $4}')"
    case "$access" in
      read/write) echo "writeable"; return ;;
      read\ only) echo "read-only"; return ;;
      *) ;;
    esac
  fi

  # Fallback for older lvm versions.
  attr="$(lvs --noheadings -o lv_attr "$item" 2>/dev/null | tr -d '[:space:]')"
  if [[ ${#attr} -ge 2 ]]; then
    perm_ch="${attr:1:1}"
    case "$perm_ch" in
      r|R) echo "read-only" ;;
      w|W) echo "writeable" ;;
      *) echo "" ;;
    esac
    return
  fi

  echo ""
}

is_active_state() {
  local state="$1"
  [[ "$state" == "active" || "$state" == "a" ]]
}

set_lv_permission() {
  local item="$1"
  local mode="$2"
  local cmd=()
  local out=""
  local rc=0
  local want_perm=""
  local already_msg1=""
  local already_msg2=""
  local perm_after=""

  if [[ "$mode" == "ro" ]]; then
    want_perm="read-only"
    already_msg1="already read only"
    already_msg2="already readonly"
    cmd=(lvchange -p r "$item")
  else
    want_perm="writable"
    already_msg1="already writable"
    already_msg2="already writeable"
    cmd=(lvchange -p rw "$item")
  fi

  log "  cmd: $(cmd_q "${cmd[@]}")"
  set +e
  out="$("${cmd[@]}" 2>&1)"
  rc=$?
  set -e

  if (( rc == 0 )); then
    log "  rc : 0 (${item})"
    return 0
  fi

  # CentOS 7 lvm can return non-zero even when permission is already desired.
  if [[ "$out" == *"$already_msg1"* || "$out" == *"$already_msg2"* ]]; then
    echo "  warn: lv permission already ${want_perm}, continue: ${cmd[*]}" >&2
    [[ -n "$out" ]] && echo "  detail: $out" >&2
    return 0
  fi

  perm_after="$(get_lv_perm "$item")"
  if [[ "$mode" == "ro" && "$perm_after" == "read-only" ]]; then
    return 0
  fi
  if [[ "$mode" == "rw" && ( "$perm_after" == "writeable" || "$perm_after" == "writable" ) ]]; then
    return 0
  fi

  echo "  error: failed to set lv permission to ${want_perm}: $item" >&2
  [[ -n "$out" ]] && echo "  detail: $out" >&2
  return 1
}

activate_lv() {
  local item="$1"
  local mode="$2"
  local cmd=()
  local out=""
  local rc=0
  local state_after=""

  cmd=(lvchange -ay "$item")

  if ! set_lv_permission "$item" "$mode"; then
    return 1
  fi

  log "  cmd: $(cmd_q "${cmd[@]}")"
  set +e
  out="$("${cmd[@]}" 2>&1)"
  rc=$?
  set -e

  if (( rc == 0 )); then
    log "  rc : 0 (${item})"
    return 0
  fi

  state_after="$(get_lv_state "$item")"
  if is_active_state "$state_after"; then
    return 0
  fi

  echo "  error: lvchange -ay failed: $item" >&2
  [[ -n "$out" ]] && echo "  detail: $out" >&2
  return 1
}

deactivate_lv() {
  local item="$1"
  local cmd=()
  local cmd_text=""
  local out=""
  local rc=0
  local state_after=""
  local attempt=0
  local attr_after=""

  for (( attempt = 1; attempt <= DEACTIVATE_RETRY_COUNT; attempt++ )); do
    cmd=(lvchange -an "$item")
    cmd_text="$(cmd_q "${cmd[@]}")"
    log "  cmd: ${cmd_text} (attempt ${attempt}/${DEACTIVATE_RETRY_COUNT})"
    set +e
    out="$("${cmd[@]}" 2>&1)"
    rc=$?
    set -e

    state_after="$(get_lv_state "$item")"
    if (( rc == 0 )) || ! is_active_state "$state_after"; then
      if ! set_lv_permission "$item" rw; then
        echo "  error: lv deactivated but failed to set rw permission: $item" >&2
        return 1
      fi
      log "  rc : ${rc} (${item})"
      return 0
    fi

    if (( attempt < DEACTIVATE_RETRY_COUNT )); then
      echo "  warn: deactivate retry ${attempt}/${DEACTIVATE_RETRY_COUNT} failed: $item" >&2
      [[ -n "$out" ]] && echo "  detail: $out" >&2
      if (( DEACTIVATE_RETRY_SLEEP > 0 )); then
        sleep "$DEACTIVATE_RETRY_SLEEP"
      fi
    fi
  done

  echo "  error: failed to deactivate lv after ${DEACTIVATE_RETRY_COUNT} attempts: $item" >&2
  [[ -n "$out" ]] && echo "  detail: $out" >&2
  attr_after="$(get_lv_attr "$item")"
  if [[ -n "$attr_after" ]]; then
    echo "  detail: current lv_attr=${attr_after}" >&2
  fi
  return 1
}

while IFS= read -r src; do
  [[ -z "$src" ]] && continue

  vg=""
  lv=""

  if [[ "$src" =~ ^/dev/([^/]+)/([^/]+)$ ]]; then
    vg="${BASH_REMATCH[1]}"
    lv="${BASH_REMATCH[2]}"
  elif [[ "$src" =~ ^/rhev/data-center/mnt/blockSD/([^/]+)/images/[^/]+/([^/]+)$ ]]; then
    vg="${BASH_REMATCH[1]}"
    lv="${BASH_REMATCH[2]}"
  else
    echo "warn: unsupported source path, skipping: $src" >&2
    continue
  fi

  key="${vg}/${lv}"
  if ! lv_already_added "$key"; then
    LV_LIST+=("$key")
  fi
done < <(
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

  /^[[:space:]]*<disk[[:space:]>]/ {
    in_disk = (attr($0, "device") == "disk")
  }

  in_disk && /^[[:space:]]*<source[[:space:]>]/ {
    x = attr($0, "dev")
    if (x != "") print x

    x = attr($0, "file")
    if (x != "") print x
  }

  in_disk && /^[[:space:]]*<\/disk>/ {
    in_disk = 0
  }
  ' "$XML_PATH"
)

lv_count=${#LV_LIST[@]}

if [[ $lv_count -eq 0 ]]; then
  echo "error: no disk source dev entries found in: $XML_PATH" >&2
  exit 1
fi

log "xml: $XML_PATH"
log "action: $ACTION"
if [[ "$ACTION" == "up" ]]; then
  log "up mode: $UP_MODE"
  log "set perm on active lv: $SET_PERM_ON_ACTIVE_LV"
else
  log "deactivate retry count: $DEACTIVATE_RETRY_COUNT"
  log "deactivate retry sleep: ${DEACTIVATE_RETRY_SLEEP}s"
fi
log "lv count: $lv_count"
for item in "${LV_LIST[@]-}"; do
  log "lv target   : $item"
done

for item in "${LV_LIST[@]-}"; do
  vg="${item%/*}"
  lv="${item#*/}"
  dev_path="/dev/${vg}/${lv}"

  case "$ACTION" in
    up)
      log "activate: $item"
      state_before="$(get_lv_state "$item")"

      if ! is_active_state "$state_before"; then
        if ! activate_lv "$item" "$UP_MODE"; then
          echo "error: failed to activate lv: $item" >&2
          exit 1
        fi
      else
        if [[ "$SET_PERM_ON_ACTIVE_LV" == "1" ]]; then
          if ! set_lv_permission "$item" "$UP_MODE"; then
            echo "error: failed to set permission on active lv: $item" >&2
            exit 1
          fi
        fi
        log "  skip: already active"
      fi

      if [[ -b "$dev_path" ]]; then
        log "  ok: $dev_path"
      else
        echo "[$(now_ts)]   warn: device node not visible: $dev_path" >&2
      fi
      ;;
    down)
      log "deactivate: $item"
      state_before="$(get_lv_state "$item")"

      if is_active_state "$state_before"; then
        # Set rw and deactivate in one step to land on inactive+writable (-wi...).
        if ! deactivate_lv "$item"; then
          exit 1
        fi
      else
        if ! set_lv_permission "$item" rw; then
          echo "error: failed to set rw on inactive lv: $item" >&2
          exit 1
        fi
      fi

      state_after="$(get_lv_state "$item")"
      if is_active_state "$state_after"; then
        echo "error: lv is still active after down: $item" >&2
        exit 1
      fi

      perm_after="$(get_lv_perm "$item")"
      if [[ "$perm_after" == "read-only" ]]; then
        if ! set_lv_permission "$item" rw; then
          echo "error: failed to set writable after down: $item" >&2
          exit 1
        fi
        perm_after="$(get_lv_perm "$item")"
      fi

      if [[ "$perm_after" == "read-only" ]]; then
        echo "error: lv permission is still read-only after down: $item" >&2
        exit 1
      fi

      if [[ -z "$perm_after" ]]; then
        log "  warn: permission check unavailable on this host (perm=unknown), continue"
      fi

      attr_after="$(get_lv_attr "$item")"
      if [[ -n "$attr_after" && ${#attr_after} -ge 5 ]]; then
        perm_ch="${attr_after:1:1}"
        active_ch="${attr_after:4:1}"
        log "  attr after down: ${attr_after}"
        if [[ "$perm_ch" != "w" && "$perm_ch" != "W" ]]; then
          echo "error: lv attr permission is not writeable after down: $item (attr=${attr_after})" >&2
          exit 1
        fi
        if [[ "$active_ch" == "a" ]]; then
          echo "error: lv attr still active after down: $item (attr=${attr_after})" >&2
          exit 1
        fi
      else
        log "  warn: lv_attr unavailable, cannot verify -wi state"
      fi
      ;;
    status)
      state="$(get_lv_state "$item")"
      perm="$(get_lv_perm "$item")"
      [[ -z "$state" ]] && state="unknown"
      [[ -z "$perm" ]] && perm="unknown"
      log "status: $item active=$state perm=$perm"
      ;;
  esac
done

log "DONE toggle_lv_from_xml"
