#!/usr/bin/env bash
set -euo pipefail

now_ts() {
  date '+%F %T'
}

log() {
  echo "[$(now_ts)] $*"
}

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <vm-name>" >&2
  exit 1
fi

VM_NAME="$1"
OUT_DIR="./xml"
CONN_URI="${LIBVIRT_URI:-qemu:///system}"
# 1: convert blockSD source path to /dev/<SD_UUID>/<VOL_UUID> in output XML
# 0: keep original /rhev/data-center/mnt/blockSD/.../images/... path
USE_DEV_PATH="${USE_DEV_PATH:-1}"

if ! command -v virsh >/dev/null 2>&1; then
  echo "error: virsh not found" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
OUT_XML="${OUT_DIR%/}/${VM_NAME}.xml"
TMP_XML=$(mktemp)
trap 'rm -f "$TMP_XML"' EXIT

log "START make_v2v_xml vm=${VM_NAME} uri=${CONN_URI} output=${OUT_XML}"

virsh -r -c "$CONN_URI" dumpxml "$VM_NAME" > "$TMP_XML"

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
  in_disk = 0
  disk_count = 0
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

  /^[[:space:]]*<disk[[:space:]>]/ {
    in_disk = (attr($0, "device") == "disk")
    if (in_disk) {
      dtype = attr($0, "type")
      if (dtype == "") dtype = "file"

      fmt = "raw"
      src_attr = ""
      src_path = ""
      tdev = ""
      bus = "virtio"
      disk_boot_order = ""
    }
  }

in_disk && /^[[:space:]]*<driver[[:space:]>]/ {
  x = attr($0, "type")
  if (x != "") fmt = x
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
      disk_count++
      disk_dtype[disk_count] = dtype
      disk_fmt[disk_count] = fmt
      disk_src_attr[disk_count] = src_attr
      disk_src_path[disk_count] = src_path
      disk_tdev[disk_count] = tdev
      disk_bus[disk_count] = bus
      disk_boot[disk_count] = disk_boot_order
    }
    in_disk = 0
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
  for (i = 1; i <= disk_count; i++) {
    print "    <disk type=\"" disk_dtype[i] "\" device=\"disk\">"
    print "      <driver name=\"qemu\" type=\"" disk_fmt[i] "\"/>"
    print "      <source " disk_src_attr[i] "=\"" disk_src_path[i] "\"/>"
    if (disk_boot[i] != "") {
      print "      <boot order=\"" disk_boot[i] "\"/>"
    }
    print "      <target dev=\"" disk_tdev[i] "\" bus=\"" disk_bus[i] "\"/>"
    print "    </disk>"
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
