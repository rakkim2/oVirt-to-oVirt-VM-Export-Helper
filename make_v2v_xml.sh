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
  DATA_BASE_DIR V2V_BASE_DIR V2V_LOG_BASE_DIR XML_OUT_DIR LIBVIRT_URI
  SCRIPT_LOG_ENABLE MAKE_V2V_XML_LOG_ENABLE RUN_LOG_DIR
  USE_DEV_PATH VIRTIOSCSITOVIRTIO_CHANGE PRESERVE_DISK_BUS INCLUDE_NETWORK
)
CONF_SOURCE="$(v2v_load_config_with_env "$CONFIG_FILE" "${PRESERVE_ENV_KEYS[@]}")"

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <vm-name>" >&2
  exit 1
fi

VM_NAME="$1"
if [[ -z "${V2V_BASE_DIR+x}" && -n "${DATA_BASE_DIR+x}" ]]; then
  V2V_BASE_DIR="${DATA_BASE_DIR%/}/v2v"
fi
V2V_BASE_DIR="${V2V_BASE_DIR:-/data/v2v}"
V2V_LOG_BASE_DIR="${V2V_LOG_BASE_DIR:-/data/v2v_log}"
OUT_DIR="${XML_OUT_DIR:-/data/xml}"
CONN_URI="${LIBVIRT_URI:-qemu:///system}"
SCRIPT_LOG_ENABLE="$(normalize_bool "${SCRIPT_LOG_ENABLE:-1}")" || exit 1
MAKE_V2V_XML_LOG_ENABLE="$(normalize_bool "${MAKE_V2V_XML_LOG_ENABLE:-$SCRIPT_LOG_ENABLE}")" || exit 1
VM_LOG_DIR="${V2V_LOG_BASE_DIR%/}/${VM_NAME}"
if [[ -n "${RUN_LOG_DIR:-}" ]]; then
  VM_LOG_DIR="$RUN_LOG_DIR"
fi
SCRIPT_LOG_FILE="${VM_LOG_DIR%/}/make_v2v_xml-$(date +%F_%H%M%S).log"
# 1: convert blockSD source path to /dev/<SD_UUID>/<VOL_UUID> in output XML
# 0: keep original /rhev/data-center/mnt/blockSD/.../images/... path
USE_DEV_PATH="${USE_DEV_PATH:-1}"
# Option name made explicit:
#   true  -> change virtio-scsi(scsi bus) disks to virtio bus
#   false -> keep original bus
if [[ -z "${VIRTIOSCSITOVIRTIO_CHANGE+x}" && -n "${PRESERVE_DISK_BUS+x}" ]]; then
  preserve_disk_bus="$(normalize_bool "$PRESERVE_DISK_BUS")" || exit 1
  if [[ "$preserve_disk_bus" == "true" ]]; then
    VIRTIOSCSITOVIRTIO_CHANGE="false"
  else
    VIRTIOSCSITOVIRTIO_CHANGE="true"
  fi
fi
VIRTIOSCSITOVIRTIO_CHANGE="$(normalize_bool "${VIRTIOSCSITOVIRTIO_CHANGE:-false}")" || exit 1
INCLUDE_NETWORK="$(normalize_bool "${INCLUDE_NETWORK:-true}")" || exit 1

if ! command -v virsh >/dev/null 2>&1; then
  echo "error: virsh not found" >&2
  exit 1
fi

mkdir -p "$OUT_DIR" "$VM_LOG_DIR"
if [[ "$MAKE_V2V_XML_LOG_ENABLE" == "true" ]]; then
  exec > >(tee -a "$SCRIPT_LOG_FILE") 2>&1
fi

OUT_XML="${OUT_DIR%/}/${VM_NAME}.xml"
TMP_XML=$(mktemp)
trap 'rm -f "$TMP_XML"' EXIT

log "START make_v2v_xml vm=${VM_NAME} uri=${CONN_URI} output=${OUT_XML} config=${CONF_SOURCE} virtioscsitovirtio_change=${VIRTIOSCSITOVIRTIO_CHANGE} include_network=${INCLUDE_NETWORK}"
if [[ "$MAKE_V2V_XML_LOG_ENABLE" == "true" ]]; then
  log "script log : $SCRIPT_LOG_FILE"
fi

dumpxml_cmd=(virsh -r -c "$CONN_URI" dumpxml "$VM_NAME")
printf -v dumpxml_cmd_q '%q ' "${dumpxml_cmd[@]}"
log "cmd         : ${dumpxml_cmd_q% } > ${TMP_XML}"
"${dumpxml_cmd[@]}" > "$TMP_XML"

awk -v virtioscsitovirtio_change="$VIRTIOSCSITOVIRTIO_CHANGE" -v include_network="$INCLUDE_NETWORK" '
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

function text_between(s, open_tag, close_tag,    t) {
  t = s
  sub("^.*<" open_tag "[^>]*>", "", t)
  sub("</" close_tag ">.*$", "", t)
  return t
}

function trim(s,    t) {
  t = s
  sub(/^[[:space:]]+/, "", t)
  sub(/[[:space:]]+$/, "", t)
  return t
}

BEGIN {
  name = ""
  mem = ""
  curmem = ""
  vcpu_total = ""
  vcpu_current = ""
  arch = ""
  machine = ""
  hvmtype = ""
  boot_dev = ""
  os_type_seen = 0

  in_os = 0
  in_os_type = 0
  os_type_text = ""
  in_devices = 0
  virtio_scsi_ctrl = 0
  virtio_scsi_ctrl_index = "0"

  in_disk = 0
  disk_count = 0

  in_iface = 0
  iface_count = 0
}

!name && /^[[:space:]]*<name>/ {
  name = text_between($0, "name", "name")
}

!mem && /^[[:space:]]*<memory[[:space:]>]/ {
  mem = text_between($0, "memory", "memory")
}

!curmem && /^[[:space:]]*<currentMemory[[:space:]>]/ {
  curmem = text_between($0, "currentMemory", "currentMemory")
}

!vcpu_total && /^[[:space:]]*<vcpu[[:space:]>]/ {
  vcpu_total = text_between($0, "vcpu", "vcpu")
  vcpu_current = attr($0, "current")
  if (vcpu_current == "") vcpu_current = vcpu_total
}

/^[[:space:]]*<os>/ { in_os = 1 }

in_os && !in_os_type && /^[[:space:]]*<type[[:space:]>]/ {
  x = attr($0, "arch")
  if (x != "") arch = x
  x = attr($0, "machine")
  if (x != "") machine = x

  os_type_text = $0
  sub(/^.*<type[^>]*>/, "", os_type_text)

  if ($0 ~ /<\/type>/) {
    sub(/<\/type>.*$/, "", os_type_text)
    os_type_text = trim(os_type_text)
    if (os_type_text != "") hvmtype = os_type_text
    os_type_seen = 1
  } else {
    in_os_type = 1
  }
}

in_os && in_os_type {
  t = $0
  if (t ~ /<\/type>/) {
    sub(/<\/type>.*$/, "", t)
    os_type_text = os_type_text t
    os_type_text = trim(os_type_text)
    if (os_type_text != "") hvmtype = os_type_text
    os_type_seen = 1
    in_os_type = 0
  } else {
    os_type_text = os_type_text t
  }
  next
}

in_os && /^[[:space:]]*<boot[[:space:]>]/ {
  x = attr($0, "dev")
  if (x != "") boot_dev = x
}

in_os && /^[[:space:]]*<\/os>/ { in_os = 0 }

/^[[:space:]]*<devices>/ { in_devices = 1 }
/^[[:space:]]*<\/devices>/ { in_devices = 0 }

in_devices && /^[[:space:]]*<controller[[:space:]>]/ {
  if (attr($0, "type") == "scsi" && attr($0, "model") == "virtio-scsi") {
    virtio_scsi_ctrl = 1
    x = attr($0, "index")
    if (x != "") virtio_scsi_ctrl_index = x
  }
}

  /^[[:space:]]*<disk[[:space:]>]/ {
    in_disk = (attr($0, "device") == "disk")
    if (in_disk) {
      dtype = attr($0, "type")
      if (dtype == "") dtype = "file"

      fmt = "raw"
      src_attr = ""
      src_path = ""
      tdev = ""
      bus = ""
      dserial = ""
      disk_boot_order = ""
    }
  }

in_disk && /^[[:space:]]*<driver[[:space:]>]/ {
  x = attr($0, "type")
  if (x != "") fmt = x
}

in_disk && /^[[:space:]]*<serial>/ {
  x = text_between($0, "serial", "serial")
  if (x != "") dserial = x
}

in_disk && /^[[:space:]]*<source[[:space:]>]/ {
  x = attr($0, "dev")
  if (x != "") {
    src_attr = "dev"
    src_path = x
  }

  x = attr($0, "file")
  if (x != "") {
    src_attr = "file"
    src_path = x
  }
}

  in_disk && /^[[:space:]]*<target[[:space:]>]/ {
    x = attr($0, "dev")
    if (x != "") tdev = x

    x = attr($0, "bus")
    if (x != "") bus = x
  }

  in_disk && /^[[:space:]]*<boot[[:space:]>]/ {
    x = attr($0, "order")
    if (x != "") disk_boot_order = x
  }

  in_disk && /^[[:space:]]*<\/disk>/ {
    if (src_path != "" && tdev != "") {
      if (bus == "") {
        if (virtio_scsi_ctrl == 1) {
          bus = "scsi"
        } else {
          bus = "virtio"
        }
      }
      if (virtioscsitovirtio_change == "true" && virtio_scsi_ctrl == 1 && bus == "scsi") {
        bus = "virtio"
      }
      disk_count++
      disk_dtype[disk_count] = dtype
      disk_fmt[disk_count] = fmt
      disk_src_attr[disk_count] = src_attr
      disk_src_path[disk_count] = src_path
      disk_tdev[disk_count] = tdev
      disk_bus[disk_count] = bus
      disk_serial[disk_count] = dserial
      disk_boot[disk_count] = disk_boot_order
    }
    in_disk = 0
  }

  /^[[:space:]]*<interface[[:space:]>]/ {
    in_iface = 1
    iface_type = attr($0, "type")
    if (iface_type == "") iface_type = "bridge"
    iface_mac = ""
    iface_src_bridge = ""
    iface_src_network = ""
    iface_src_dev = ""
    iface_model = ""
    iface_target_dev = ""
    iface_boot_order = ""
  }

  in_iface && /^[[:space:]]*<mac[[:space:]>]/ {
    x = attr($0, "address")
    if (x != "") iface_mac = x
  }

  in_iface && /^[[:space:]]*<source[[:space:]>]/ {
    x = attr($0, "bridge")
    if (x != "") iface_src_bridge = x
    x = attr($0, "network")
    if (x != "") iface_src_network = x
    x = attr($0, "dev")
    if (x != "") iface_src_dev = x
  }

  in_iface && /^[[:space:]]*<model[[:space:]>]/ {
    x = attr($0, "type")
    if (x != "") iface_model = x
  }

  in_iface && /^[[:space:]]*<target[[:space:]>]/ {
    x = attr($0, "dev")
    if (x != "") iface_target_dev = x
  }

  in_iface && /^[[:space:]]*<boot[[:space:]>]/ {
    x = attr($0, "order")
    if (x != "") iface_boot_order = x
  }

  in_iface && /^[[:space:]]*<\/interface>/ {
    iface_count++
    iface_types[iface_count] = iface_type
    iface_macs[iface_count] = iface_mac
    iface_src_bridges[iface_count] = iface_src_bridge
    iface_src_networks[iface_count] = iface_src_network
    iface_src_devs[iface_count] = iface_src_dev
    iface_models[iface_count] = iface_model
    iface_target_devs[iface_count] = iface_target_dev
    iface_boot_orders[iface_count] = iface_boot_order
    in_iface = 0
  }

END {
  if (name == "") {
    print "error: failed to parse VM name from dumpxml" > "/dev/stderr"
    exit 2
  }
  if (mem == "") {
    print "error: failed to parse memory from dumpxml" > "/dev/stderr"
    exit 2
  }
  if (curmem == "") curmem = mem
  if (vcpu_total == "") {
    print "error: failed to parse vcpu from dumpxml" > "/dev/stderr"
    exit 2
  }
  if (!os_type_seen || hvmtype == "") {
    print "error: failed to parse os type from dumpxml" > "/dev/stderr"
    exit 2
  }
  if (arch == "") {
    print "error: failed to parse os arch from dumpxml" > "/dev/stderr"
    exit 2
  }
  if (disk_count == 0) {
    print "error: no disk(device=disk) found in dumpxml" > "/dev/stderr"
    exit 2
  }

  print "<domain type=\"kvm\">"
  print "  <name>" name "</name>"
  print "  <memory unit=\"KiB\">" mem "</memory>"
  print "  <currentMemory unit=\"KiB\">" curmem "</currentMemory>"

  if (vcpu_current != "" && vcpu_current != vcpu_total) {
    print "  <vcpu placement=\"static\" current=\"" vcpu_current "\">" vcpu_total "</vcpu>"
  } else {
    print "  <vcpu>" vcpu_total "</vcpu>"
  }

  print "  <os>"
  if (machine != "") {
    print "    <type arch=\"" arch "\" machine=\"" machine "\">" hvmtype "</type>"
  } else {
    print "    <type arch=\"" arch "\">" hvmtype "</type>"
  }
  if (boot_dev != "") {
    print "    <boot dev=\"" boot_dev "\"/>"
  }
  print "  </os>"

  print "  <devices>"
  need_scsi_controller = 0
  for (i = 1; i <= disk_count; i++) {
    if (disk_bus[i] == "scsi") {
      need_scsi_controller = 1
      break
    }
  }
  if (need_scsi_controller == 1) {
    print "    <controller type=\"scsi\" index=\"" virtio_scsi_ctrl_index "\" model=\"virtio-scsi\"/>"
  }
  for (i = 1; i <= disk_count; i++) {
    print "    <disk type=\"" disk_dtype[i] "\" device=\"disk\">"
    print "      <driver name=\"qemu\" type=\"" disk_fmt[i] "\"/>"
    print "      <source " disk_src_attr[i] "=\"" disk_src_path[i] "\"/>"
    if (disk_serial[i] != "") {
      print "      <serial>" disk_serial[i] "</serial>"
    }
    if (disk_boot[i] != "") {
      print "      <boot order=\"" disk_boot[i] "\"/>"
    }
    print "      <target dev=\"" disk_tdev[i] "\" bus=\"" disk_bus[i] "\"/>"
    print "    </disk>"
  }
  if (include_network == "true") {
    for (i = 1; i <= iface_count; i++) {
      print "    <interface type=\"" iface_types[i] "\">"
      if (iface_macs[i] != "") {
        print "      <mac address=\"" iface_macs[i] "\"/>"
      }
      if (iface_src_bridges[i] != "") {
        print "      <source bridge=\"" iface_src_bridges[i] "\"/>"
      } else if (iface_src_networks[i] != "") {
        print "      <source network=\"" iface_src_networks[i] "\"/>"
      } else if (iface_src_devs[i] != "") {
        print "      <source dev=\"" iface_src_devs[i] "\"/>"
      }
      if (iface_boot_orders[i] != "") {
        print "      <boot order=\"" iface_boot_orders[i] "\"/>"
      }
      if (iface_models[i] != "") {
        print "      <model type=\"" iface_models[i] "\"/>"
      }
      if (iface_target_devs[i] != "") {
        print "      <target dev=\"" iface_target_devs[i] "\"/>"
      }
      print "    </interface>"
    }
  }
  print "  </devices>"
  print "</domain>"
}
' "$TMP_XML" > "$OUT_XML"

if [[ "$USE_DEV_PATH" == "1" ]]; then
  # Convert host-specific blockSD image path to stable LV path.
  sed -i -E "s#/rhev/data-center/mnt/blockSD/([^/]+)/images/[^/]+/([^\"']+)#/dev/\\1/\\2#g" "$OUT_XML"
fi

log "DONE make_v2v_xml created=${OUT_XML}"
