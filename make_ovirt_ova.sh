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
  OVA_OUTPUT_DIR OVA_BASE_DIR OVA_STAGING_BASE_DIR
  ENGINE_VSYSTEM_TYPE GENERATE_MANIFEST USE_TAR_SPARSE TAR_PROGRESS_INTERVAL
  SCRIPT_LOG_ENABLE MAKE_OVA_LOG_ENABLE
  FORCE_OVF_DISK_FORMAT_URI OVF_DISK_FORMAT_URI
  FORCE_OVF_VOLUME_FORMAT OVF_VOLUME_FORMAT
  FORCE_OVF_VOLUME_TYPE OVF_VOLUME_TYPE
  FORCE_BOOT_DISK_INDEX RUN_LOG_DIR
)
CONF_SOURCE="$(v2v_load_config_with_env "$CONFIG_FILE" "${PRESERVE_ENV_KEYS[@]}")"

usage() {
  cat >&2 <<'USAGE'
usage: make_ovirt_ova.sh <vm-xml> [disk1] [disk2] ...

Build OVA package from disk image files.
This script does not run qemu-img convert.

Fixed paths:
  XML          : <vm-xml input>
  output OVA   : ${OVA_OUTPUT_DIR:-/data/v2v/ova}/<vm-name>.ova

When disk args are omitted:
  - auto load from ${QEMU_BASE_DIR:-/data/v2v/qemu}/<vm-name>/<vm-name>-disk*.qcow2

Compatibility defaults:
  - ovf:format / ovf:volume-format / ovf:volume-type are auto-selected per disk format
  - Envelope includes ovirt namespace and ENGINE VirtualSystemType
USAGE
  exit 1
}

if [[ $# -lt 1 ]]; then
  usage
fi

XML_PATH="$1"
shift
DISK_INPUTS=("$@")

# Keep RAW_BASE_DIR name for backward compatibility with existing usage.
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
QEMU_BASE_DIR="${QEMU_BASE_DIR:-${V2V_BASE_DIR%/}/qemu}"
OVA_OUTPUT_DIR="${OVA_OUTPUT_DIR:-${V2V_BASE_DIR%/}/ova}"
OVA_STAGING_BASE_DIR="${OVA_STAGING_BASE_DIR:-${OVA_OUTPUT_DIR%/}/ova_stag}"
ENGINE_VSYSTEM_TYPE="${ENGINE_VSYSTEM_TYPE:-ENGINE 4.1.0.0}"
GENERATE_MANIFEST="${GENERATE_MANIFEST:-0}"
USE_TAR_SPARSE="${USE_TAR_SPARSE:-1}"
TAR_PROGRESS_INTERVAL="${TAR_PROGRESS_INTERVAL:-5}"
SCRIPT_LOG_ENABLE="${SCRIPT_LOG_ENABLE:-1}"
MAKE_OVA_LOG_ENABLE="${MAKE_OVA_LOG_ENABLE:-$SCRIPT_LOG_ENABLE}"

RAW_OVF_FORMAT_URI="http://en.wikipedia.org/wiki/Byte"
QCOW2_OVF_FORMAT_URI="http://www.gnome.org/~markmc/qcow-image-format.html"
VMDK_OVF_FORMAT_URI="http://www.vmware.com/specifications/vmdk.html#streamOptimized"

# Optional force override (old variable names also accepted).
FORCE_OVF_DISK_FORMAT_URI="${FORCE_OVF_DISK_FORMAT_URI:-${OVF_DISK_FORMAT_URI:-}}"
FORCE_OVF_VOLUME_FORMAT="${FORCE_OVF_VOLUME_FORMAT:-${OVF_VOLUME_FORMAT:-}}"
FORCE_OVF_VOLUME_TYPE="${FORCE_OVF_VOLUME_TYPE:-${OVF_VOLUME_TYPE:-}}"
FORCE_BOOT_DISK_INDEX="${FORCE_BOOT_DISK_INDEX:-}"

if [[ ! -f "$XML_PATH" ]]; then
  echo "error: xml not found: $XML_PATH" >&2
  exit 1
fi

if ! command -v qemu-img >/dev/null 2>&1; then
  echo "error: qemu-img not found" >&2
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

SCRIPT_LOG_DIR="${V2V_LOG_BASE_DIR%/}/${vm_name}"
if [[ -n "${RUN_LOG_DIR:-}" ]]; then
  SCRIPT_LOG_DIR="$RUN_LOG_DIR"
fi
SCRIPT_LOG_FILE="${SCRIPT_LOG_DIR%/}/make_ovirt_ova-$(date +%F_%H%M%S).log"
mkdir -p "$SCRIPT_LOG_DIR"
if is_enabled "$MAKE_OVA_LOG_ENABLE"; then
  exec > >(tee -a "$SCRIPT_LOG_FILE") 2>&1
fi

if [[ ${#DISK_INPUTS[@]} -eq 0 ]]; then
  auto_dir="${QEMU_BASE_DIR%/}/${vm_name}"
  shopt -s nullglob
  DISK_INPUTS=( "${auto_dir}/${vm_name}-disk"*.qcow2 )
  shopt -u nullglob
fi

if [[ ${#DISK_INPUTS[@]} -eq 0 ]]; then
  echo "error: no disk input files" >&2
  echo "hint : pass disk files or put qcow2 files under ${QEMU_BASE_DIR%/}/${vm_name}" >&2
  exit 1
fi

OUT_OVA="${OVA_OUTPUT_DIR%/}/${vm_name}.ova"
STAGING_DIR="${OVA_STAGING_BASE_DIR%/}/${vm_name}"
mkdir -p "$STAGING_DIR"
mkdir -p "$(dirname "$OUT_OVA")"

log "START make_ovirt_ova vm=${vm_name} xml=${XML_PATH} config=${CONF_SOURCE}"
if is_enabled "$MAKE_OVA_LOG_ENABLE"; then
  log "script log : $SCRIPT_LOG_FILE"
fi

ovf_file="${STAGING_DIR%/}/${vm_name}.ovf"
mf_file="${STAGING_DIR%/}/${vm_name}.mf"

filesize_bytes() {
  local path="$1"
  if stat -c%s "$path" >/dev/null 2>&1; then
    stat -c%s "$path"
  else
    stat -f%z "$path"
  fi
}

virtual_size_bytes() {
  local path="$1"
  local v

  v=$(
    qemu-img info --output=json "$path" 2>/dev/null \
      | tr -d '\n' \
      | sed -n 's/.*"virtual-size"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p'
  )

  if [[ -n "$v" ]]; then
    echo "$v"
  else
    filesize_bytes "$path"
  fi
}

image_format() {
  local path="$1"
  local fmt

  fmt=$(
    qemu-img info --output=json "$path" 2>/dev/null \
      | tr -d '\n' \
      | sed -n 's/.*"format"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
  )

  if [[ -n "$fmt" ]]; then
    echo "$fmt"
    return
  fi

  case "$path" in
    *.qcow2) echo "qcow2" ;;
    *.raw) echo "raw" ;;
    *.vmdk) echo "vmdk" ;;
    *) echo "raw" ;;
  esac
}

ovf_format_uri_for_image() {
  local fmt="$1"
  case "$fmt" in
    qcow2) echo "$QCOW2_OVF_FORMAT_URI" ;;
    raw) echo "$RAW_OVF_FORMAT_URI" ;;
    vmdk) echo "$VMDK_OVF_FORMAT_URI" ;;
    *) echo "$RAW_OVF_FORMAT_URI" ;;
  esac
}

ovf_volume_format_for_image() {
  local fmt="$1"
  case "$fmt" in
    qcow2|vmdk) echo "COW" ;;
    raw) echo "RAW" ;;
    *) echo "RAW" ;;
  esac
}

ovf_volume_type_for_image() {
  local _fmt="$1"
  echo "Sparse"
}

ovf_disk_interface_for_bus() {
  local bus="$1"
  case "$bus" in
    virtio) echo "VirtIO" ;;
    scsi|virtio-scsi|virtio_scsi) echo "VirtIO_SCSI" ;;
    ide) echo "IDE" ;;
    sata) echo "SATA" ;;
    *) echo "VirtIO" ;;
  esac
}

sha1_of_file() {
  local path="$1"
  if command -v sha1sum >/dev/null 2>&1; then
    sha1sum "$path" | awk '{print $1}'
  else
    shasum -a 1 "$path" | awk '{print $1}'
  fi
}

tar_supports_sparse() {
  tar --help 2>/dev/null | grep -q -- '--sparse'
}

allocated_bytes() {
  local path="$1"
  local blocks
  local bsize

  if stat -c '%b %B' "$path" >/dev/null 2>&1; then
    read -r blocks bsize <<<"$(stat -c '%b %B' "$path")"
    echo $((blocks * bsize))
    return
  fi

  if stat -f '%b %k' "$path" >/dev/null 2>&1; then
    read -r blocks bsize <<<"$(stat -f '%b %k' "$path")"
    echo $((blocks * bsize))
    return
  fi

  filesize_bytes "$path"
}

gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
    return
  fi

  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
    return
  fi

  printf '%08x-%04x-%04x-%04x-%012x\n' \
    "$RANDOM$RANDOM" \
    "$RANDOM" \
    "$RANDOM" \
    "$RANDOM" \
    "$RANDOM$RANDOM$RANDOM"
}

parse_vm_int() {
  local tag="$1"
  awk -v t="$tag" '
  function text_between(s, open_tag, close_tag,    x) {
    x = s
    sub("^.*<" open_tag "[^>]*>", "", x)
    sub("</" close_tag ">.*$", "", x)
    return x
  }
  $0 ~ "^[[:space:]]*<" t "[[:space:]>]" {
    print text_between($0, t, t)
    exit
  }
  ' "$XML_PATH"
}

parse_vcpu_count() {
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
  function text_between(s, open_tag, close_tag,    x) {
    x = s
    sub("^.*<" open_tag "[^>]*>", "", x)
    sub("</" close_tag ">.*$", "", x)
    return x
  }
  /^[[:space:]]*<vcpu[[:space:]>]/ {
    c = attr($0, "current")
    if (c != "") {
      print c
      exit
    }
    print text_between($0, "vcpu", "vcpu")
    exit
  }
  ' "$XML_PATH"
}

vcpu_count="$(parse_vcpu_count)"
memory_kib="$(parse_vm_int "memory")"

if [[ -z "$vcpu_count" || ! "$vcpu_count" =~ ^[0-9]+$ ]]; then
  vcpu_count=1
fi
if [[ -z "$memory_kib" || ! "$memory_kib" =~ ^[0-9]+$ ]]; then
  memory_kib=1048576
fi
memory_mb=$(( (memory_kib + 1023) / 1024 ))

# Parse disk metadata order from XML.
declare -a XML_TARGET_DEVS=()
declare -a XML_DISK_BUSES=()
declare -a XML_BOOT_ORDERS=()
while IFS=$'\t' read -r didx tdev bus boot_order; do
  [[ -z "$didx" ]] && continue
  [[ -z "$tdev" ]] && tdev="disk${didx}"
  [[ -z "$bus" ]] && bus="virtio"
  XML_TARGET_DEVS+=("$tdev")
  XML_DISK_BUSES+=("$bus")
  XML_BOOT_ORDERS+=("$boot_order")
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

  BEGIN { in_disk = 0; idx = 0 }

  /^[[:space:]]*<disk[[:space:]>]/ {
    in_disk = (attr($0, "device") == "disk")
    tdev = ""
    bus = "virtio"
    boot = ""
  }

  in_disk && /^[[:space:]]*<target[[:space:]>]/ {
    x = attr($0, "dev")
    if (x != "") tdev = x
    x = attr($0, "bus")
    if (x != "") bus = x
  }

  in_disk && /^[[:space:]]*<boot[[:space:]>]/ {
    x = attr($0, "order")
    if (x != "") boot = x
  }

  in_disk && /^[[:space:]]*<\/disk>/ {
    idx++
    if (tdev == "") tdev = "disk" idx
    printf "%d\t%s\t%s\t%s\n", idx, tdev, bus, boot
    in_disk = 0
  }
  ' "$XML_PATH"
)

boot_disk_index=0

if [[ -n "$FORCE_BOOT_DISK_INDEX" && "$FORCE_BOOT_DISK_INDEX" =~ ^[0-9]+$ ]]; then
  boot_disk_index="$FORCE_BOOT_DISK_INDEX"
fi

if (( boot_disk_index == 0 )); then
  min_boot_order=""
  for i in "${!XML_BOOT_ORDERS[@]}"; do
    bo="${XML_BOOT_ORDERS[$i]}"
    if [[ "$bo" =~ ^[0-9]+$ ]] && (( bo > 0 )); then
      if [[ -z "$min_boot_order" || "$bo" -lt "$min_boot_order" ]]; then
        min_boot_order="$bo"
        boot_disk_index=$((i + 1))
      fi
    fi
  done
fi

if (( boot_disk_index == 0 )); then
  for pref in vda sda xvda hda; do
    for i in "${!XML_TARGET_DEVS[@]}"; do
      if [[ "${XML_TARGET_DEVS[$i]}" == "$pref" ]]; then
        boot_disk_index=$((i + 1))
        break 2
      fi
    done
  done
fi

if (( boot_disk_index == 0 )); then
  boot_disk_index=1
fi

if (( boot_disk_index < 1 || boot_disk_index > ${#DISK_INPUTS[@]} )); then
  boot_disk_index=1
fi

declare -a SRC_PATHS=()
declare -a STAGED_NAMES=()
declare -a FILE_IDS=()
declare -a DISK_IDS=()
declare -a DISK_ALIASES=()
declare -a TARGET_DEVS=()
declare -a DISK_INTERFACES=()
declare -a FILE_SIZES=()
declare -a VIRT_SIZES=()
declare -a CAP_GIBS=()
declare -a BOOT_FLAGS=()
declare -a ITEM_BOOT_ORDERS=()
declare -a SRC_FORMATS=()
declare -a OVF_FORMAT_URIS=()
declare -a OVF_VOLUME_FORMATS=()
declare -a OVF_VOLUME_TYPES=()
HAS_VIRTIO_SCSI=0
SCSI_CONTROLLER_INSTANCE_ID=""

for i in "${!DISK_INPUTS[@]}"; do
  idx=$((i + 1))
  src_path="${DISK_INPUTS[$i]}"

  if [[ ! -f "$src_path" ]]; then
    echo "error: disk input not found/readable: $src_path" >&2
    exit 1
  fi

  file_id="$(gen_uuid)"
  disk_id="$(gen_uuid)"
  disk_alias="${vm_name}-disk${idx}"
  staged_name="$file_id"
  staged_path="${STAGING_DIR%/}/${staged_name}"

  rm -f "$staged_path"
  log "stage disk${idx}: src=${src_path} staged=${staged_path}"
  if ln "$src_path" "$staged_path" 2>/dev/null; then
    log "cmd         : ln ${src_path} ${staged_path} (hardlink)"
  else
    log "cmd         : cp -f ${src_path} ${staged_path} (fallback copy)"
    cp -f "$src_path" "$staged_path"
  fi

  file_size="$(filesize_bytes "$staged_path")"
  virt_size="$(virtual_size_bytes "$staged_path")"
  src_fmt="$(image_format "$staged_path")"
  if [[ -z "$src_fmt" ]]; then
    echo "error: failed to detect image format: $staged_path" >&2
    exit 1
  fi

  if [[ -n "$FORCE_OVF_DISK_FORMAT_URI" ]]; then
    disk_ovf_uri="$FORCE_OVF_DISK_FORMAT_URI"
  else
    disk_ovf_uri="$(ovf_format_uri_for_image "$src_fmt")"
  fi

  if [[ -n "$FORCE_OVF_VOLUME_FORMAT" ]]; then
    disk_volume_format="$FORCE_OVF_VOLUME_FORMAT"
  else
    disk_volume_format="$(ovf_volume_format_for_image "$src_fmt")"
  fi

  if [[ -n "$FORCE_OVF_VOLUME_TYPE" ]]; then
    disk_volume_type="$FORCE_OVF_VOLUME_TYPE"
  else
    disk_volume_type="$(ovf_volume_type_for_image "$src_fmt")"
  fi

  cap_gib=$(( (virt_size + 1073741824 - 1) / 1073741824 ))
  if (( cap_gib < 1 )); then
    cap_gib=1
  fi

  if (( i < ${#XML_TARGET_DEVS[@]} )); then
    target_dev="${XML_TARGET_DEVS[$i]}"
  else
    target_dev="disk${idx}"
  fi

  if (( i < ${#XML_DISK_BUSES[@]} )); then
    disk_bus="${XML_DISK_BUSES[$i]}"
  else
    disk_bus="virtio"
  fi
  disk_interface="$(ovf_disk_interface_for_bus "$disk_bus")"

  boot_flag="false"
  item_boot_order="0"
  if (( idx == boot_disk_index )); then
    boot_flag="true"
    item_boot_order="1"
  fi

  SRC_PATHS+=("$src_path")
  STAGED_NAMES+=("$staged_name")
  FILE_IDS+=("$file_id")
  DISK_IDS+=("$disk_id")
  DISK_ALIASES+=("$disk_alias")
  TARGET_DEVS+=("$target_dev")
  DISK_INTERFACES+=("$disk_interface")
  FILE_SIZES+=("$file_size")
  VIRT_SIZES+=("$virt_size")
  CAP_GIBS+=("$cap_gib")
  BOOT_FLAGS+=("$boot_flag")
  ITEM_BOOT_ORDERS+=("$item_boot_order")
  SRC_FORMATS+=("$src_fmt")
  OVF_FORMAT_URIS+=("$disk_ovf_uri")
  OVF_VOLUME_FORMATS+=("$disk_volume_format")
  OVF_VOLUME_TYPES+=("$disk_volume_type")
done

if (( ${#XML_TARGET_DEVS[@]} != 0 && ${#XML_TARGET_DEVS[@]} != ${#SRC_PATHS[@]} )); then
  echo "warn: xml disk count (${#XML_TARGET_DEVS[@]}) != disk input count (${#SRC_PATHS[@]})" >&2
fi

for i in "${!DISK_INTERFACES[@]}"; do
  if [[ "${DISK_INTERFACES[$i]}" == "VirtIO_SCSI" ]]; then
    HAS_VIRTIO_SCSI=1
    SCSI_CONTROLLER_INSTANCE_ID="$(gen_uuid)"
    break
  fi
done

log "vm          : $vm_name"
log "vcpu/memory : ${vcpu_count} / ${memory_mb} MiB"
log "disk count  : ${#SRC_PATHS[@]}"
log "boot disk   : index=${boot_disk_index}"
if [[ -n "$FORCE_OVF_DISK_FORMAT_URI" || -n "$FORCE_OVF_VOLUME_FORMAT" || -n "$FORCE_OVF_VOLUME_TYPE" ]]; then
  log "ovf format  : forced by env override"
else
  log "ovf format  : auto (match each disk format)"
fi
log "output ova  : $OUT_OVA"
if (( GENERATE_MANIFEST == 1 )); then
  log "manifest    : enabled"
else
  log "manifest    : disabled (speed mode)"
fi

for i in "${!SRC_PATHS[@]}"; do
  idx=$((i + 1))
  log "${DISK_ALIASES[$i]} : target=${TARGET_DEVS[$i]} iface=${DISK_INTERFACES[$i]} boot=${BOOT_FLAGS[$i]} srcfmt=${SRC_FORMATS[$i]} ovf=${OVF_FORMAT_URIS[$i]} file=${SRC_PATHS[$i]} staged=${STAGED_NAMES[$i]}"
done
if (( HAS_VIRTIO_SCSI == 1 )); then
  log "controller   : virtio-scsi enabled (instance-id=${SCSI_CONTROLLER_INSTANCE_ID})"
fi

virtual_system_id="$(gen_uuid)"

{
  cat <<OVF
<?xml version="1.0" encoding="UTF-8"?>
<ovf:Envelope xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1"
              xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData"
              xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData"
              xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
              xmlns="http://schemas.dmtf.org/ovf/envelope/1"
              xmlns:ovirt="http://www.ovirt.org/ovf">
  <References>
OVF

  for i in "${!FILE_IDS[@]}"; do
    printf '    <File ovf:href="%s" ovf:id="%s" ovf:size="%s"></File>\n' \
      "${FILE_IDS[$i]}" "${FILE_IDS[$i]}" "${FILE_SIZES[$i]}"
  done

  cat <<OVF
  </References>
  <NetworkSection>
    <Info>List of networks</Info>
  </NetworkSection>
  <DiskSection>
    <Info>List of Virtual Disks</Info>
OVF

  for i in "${!DISK_IDS[@]}"; do
    printf '    <Disk ovf:diskId="%s" ovf:capacity="%s" ovf:capacityAllocationUnits="byte * 2^30" ovf:populatedSize="%s" ovf:parentRef="" ovf:fileRef="%s" ovf:format="%s" ovf:volume-format="%s" ovf:volume-type="%s" ovf:disk-interface="%s" ovf:boot="%s" ovf:pass-discard="false" ovf:disk-alias="%s" ovf:disk-description="Uploaded by virt-v2v" ovf:wipe-after-delete="false" ovf:description="Auto-generated for Export To OVA" ovf:disk_storage_type="IMAGE" ovf:cinder_volume_type=""></Disk>\n' \
      "${DISK_IDS[$i]}" "${CAP_GIBS[$i]}" "${FILE_SIZES[$i]}" "${FILE_IDS[$i]}" \
      "${OVF_FORMAT_URIS[$i]}" "${OVF_VOLUME_FORMATS[$i]}" "${OVF_VOLUME_TYPES[$i]}" "${DISK_INTERFACES[$i]}" "${BOOT_FLAGS[$i]}" \
      "${DISK_ALIASES[$i]}"
  done

  cat <<OVF
  </DiskSection>
  <VirtualSystem ovf:id="$virtual_system_id">
    <Name>${vm_name}</Name>
    <Description>generated by custom v2v script</Description>
    <OperatingSystemSection ovf:id="1" ovirt:id="5001" ovf:required="false">
      <Info>Guest Operating System</Info>
      <Description>Other Linux x64</Description>
    </OperatingSystemSection>
    <VirtualHardwareSection>
      <Info>${vcpu_count} CPU, ${memory_mb} Memory</Info>
      <System>
        <vssd:VirtualSystemType>${ENGINE_VSYSTEM_TYPE}</vssd:VirtualSystemType>
      </System>
      <Item>
        <rasd:Caption>${vcpu_count} virtual cpu</rasd:Caption>
        <rasd:Description>Number of virtual CPU</rasd:Description>
        <rasd:InstanceId>1</rasd:InstanceId>
        <rasd:ResourceType>3</rasd:ResourceType>
        <rasd:num_of_sockets>1</rasd:num_of_sockets>
        <rasd:cpu_per_socket>${vcpu_count}</rasd:cpu_per_socket>
        <rasd:threads_per_cpu>1</rasd:threads_per_cpu>
        <rasd:max_num_of_vcpus>$((vcpu_count * 16))</rasd:max_num_of_vcpus>
        <rasd:VirtualQuantity>${vcpu_count}</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:Caption>${memory_mb} MB of memory</rasd:Caption>
        <rasd:Description>Memory Size</rasd:Description>
        <rasd:InstanceId>2</rasd:InstanceId>
        <rasd:ResourceType>4</rasd:ResourceType>
        <rasd:AllocationUnits>MegaBytes</rasd:AllocationUnits>
        <rasd:VirtualQuantity>${memory_mb}</rasd:VirtualQuantity>
      </Item>
OVF

  if (( HAS_VIRTIO_SCSI == 1 )); then
    cat <<OVF
      <Item>
        <rasd:Caption>VirtIO SCSI Controller</rasd:Caption>
        <rasd:Description>SCSI Controller</rasd:Description>
        <rasd:InstanceId>${SCSI_CONTROLLER_INSTANCE_ID}</rasd:InstanceId>
        <rasd:ResourceType>6</rasd:ResourceType>
        <rasd:ResourceSubType>virtio-scsi</rasd:ResourceSubType>
      </Item>
OVF
  fi

  for i in "${!DISK_IDS[@]}"; do
    disk_parent="00000000-0000-0000-0000-000000000000"
    if (( HAS_VIRTIO_SCSI == 1 )) && [[ "${DISK_INTERFACES[$i]}" == "VirtIO_SCSI" ]]; then
      disk_parent="$SCSI_CONTROLLER_INSTANCE_ID"
    fi
    printf '%s\n' \
'      <Item>' \
"        <rasd:Caption>${DISK_ALIASES[$i]}</rasd:Caption>" \
"        <rasd:InstanceId>${FILE_IDS[$i]}</rasd:InstanceId>" \
'        <rasd:ResourceType>17</rasd:ResourceType>' \
"        <rasd:HostResource>ovf:/disk/${DISK_IDS[$i]}</rasd:HostResource>" \
"        <rasd:Parent>${disk_parent}</rasd:Parent>" \
'        <Type>disk</Type>' \
'        <Device>disk</Device>' \
"        <BootOrder>${ITEM_BOOT_ORDERS[$i]}</BootOrder>" \
'        <IsPlugged>true</IsPlugged>' \
'        <IsReadOnly>false</IsReadOnly>' \
"        <Alias>${DISK_ALIASES[$i]}</Alias>" \
'      </Item>'
  done

  cat <<OVF
    </VirtualHardwareSection>
  </VirtualSystem>
</ovf:Envelope>
OVF
} > "$ovf_file"

if (( GENERATE_MANIFEST == 1 )); then
  {
    ovf_base="$(basename "$ovf_file")"
    printf 'SHA1(%s)= %s\n' "$ovf_base" "$(sha1_of_file "$ovf_file")"
    for staged_name in "${STAGED_NAMES[@]}"; do
      printf 'SHA1(%s)= %s\n' "$staged_name" "$(sha1_of_file "${STAGING_DIR%/}/${staged_name}")"
    done
  } > "$mf_file"
fi

tmp_ova="${OUT_OVA}.tmp.$$"

tar_cmd=(tar -cf "$tmp_ova")
tar_sparse_enabled=0
if (( USE_TAR_SPARSE == 1 )) && tar_supports_sparse; then
  tar_cmd+=(--sparse)
  tar_sparse_enabled=1
fi

tar_cmd+=( -C "$STAGING_DIR" "$(basename "$ovf_file")" )
if (( GENERATE_MANIFEST == 1 )); then
  tar_cmd+=( -C "$STAGING_DIR" "$(basename "$mf_file")" )
fi
for staged_name in "${STAGED_NAMES[@]}"; do
  tar_cmd+=( -C "$STAGING_DIR" "$staged_name" )
done
printf -v tar_cmd_q '%q ' "${tar_cmd[@]}"
log "cmd         : ${tar_cmd_q% }"

estimated_total="$(filesize_bytes "$ovf_file")"
if (( GENERATE_MANIFEST == 1 )); then
  estimated_total=$((estimated_total + $(filesize_bytes "$mf_file")))
fi
for staged_name in "${STAGED_NAMES[@]}"; do
  staged_path="${STAGING_DIR%/}/${staged_name}"
  if (( tar_sparse_enabled == 1 )); then
    part_size="$(allocated_bytes "$staged_path")"
  else
    part_size="$(filesize_bytes "$staged_path")"
  fi
  estimated_total=$((estimated_total + part_size))
done
estimated_total=$((estimated_total + ((${#STAGED_NAMES[@]} + 4) * 1024)))

log "packing(${vm_name}) : start (updates every ${TAR_PROGRESS_INTERVAL}s)"
"${tar_cmd[@]}" &
tar_pid=$!
last_size=0
last_ts=$(date +%s)

while kill -0 "$tar_pid" 2>/dev/null; do
  sleep "$TAR_PROGRESS_INTERVAL"
  if ! kill -0 "$tar_pid" 2>/dev/null; then
    break
  fi

  if [[ -f "$tmp_ova" ]]; then
    cur_size="$(filesize_bytes "$tmp_ova")"
  else
    cur_size=0
  fi

  now_ts=$(date +%s)
  dt=$((now_ts - last_ts))
  if (( dt < 1 )); then
    dt=1
  fi

  delta=$((cur_size - last_size))
  if (( delta < 0 )); then
    delta=0
  fi

  if (( estimated_total > 0 )); then
    pct=$((cur_size * 100 / estimated_total))
    if (( pct > 99 )); then
      pct=99
    fi
  else
    pct=0
  fi

  log "packing(${vm_name}) : ${pct}% ($((cur_size / 1048576))/$((estimated_total / 1048576)) MiB, $((delta / dt / 1048576)) MiB/s)"

  last_size=$cur_size
  last_ts=$now_ts
done

if ! wait "$tar_pid"; then
  echo "error: failed while creating tar archive for ova" >&2
  rm -f "$tmp_ova"
  exit 1
fi

final_size="$(filesize_bytes "$tmp_ova")"
log "packing(${vm_name}) : 100% (${final_size} bytes)"
mv -f "$tmp_ova" "$OUT_OVA"

log "DONE make_ovirt_ova created=${OUT_OVA}"
