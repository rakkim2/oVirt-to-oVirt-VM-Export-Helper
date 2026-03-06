# OLV (oVirt) VM Export Helper (XML -> qemu -> OVA)

This document explains how to use `make_v2v_xml.sh` and `run_qemu_ova_pipeline.sh` for oVirt-to-oVirt VM migration.  
Run from the directory where the scripts are located (example: `/root/v2v`).

To improve performance limited by non-parallel OLV VM Export behavior, this workflow manually converts block storage images in parallel on Linux and migrates them in a format recognized by another OLV environment.

## 0) Shared Config (import.conf)

- Default config file: `import.conf`
- Default XML output directory: `/data/v2v/xml`
- Scripts auto-load `import.conf` by default. Override with `CONFIG_FILE=/path/to/file.conf` when needed.

## 1) Recommended Workflow

1. In oVirt, migrate the target VM to the export host (node), or start it on that node.
2. Confirm the VM is running with `virsh -r list`.
3. Generate XML (on the Linux node where the VM is located, `/root/v2v`):
   ```bash
   bash make_v2v_xml.sh <VM_NAME>
   ```
4. Confirm `/data/v2v/xml/<VM_NAME>.xml` exists, then shut down the VM.
5. Confirm the VM is fully powered off (`virsh -r list`).
6. Run the pipeline (on the Linux node where the VM is located, from `/root/v2v`; output stored under `/data`):
   ```bash
   bash run_qemu_ova_pipeline.sh /data/v2v/xml/<VM_NAME>.xml
   ```
7. Check outputs:
   - OVA: `/data/ova/<VM_NAME>/<VM_NAME>.ova`
   - Pipeline log: `/data/v2v/<VM_NAME>/logs/pipeline-YYYY-mm-dd_HHMMSS.log`
   - Disk conversion logs: `/data/v2v/<VM_NAME>/logs/qemu/<VM_NAME>-diskN.log`
8. In oVirt UI, import OVA from `/data/ova/<VM_NAME>/`.
9. Attach network and manually set the existing MAC address (`NIC > Edit > Manual`).

Pipeline internals:
1. `toggle_lv_from_xml.sh up`
2. `convert_disks_from_xml.sh` (parallel disk conversion)
3. `make_ovirt_ova.sh` (OVA packaging)
4. `toggle_lv_from_xml.sh down` automatically on exit

## 2) Manual Execution (Purpose / Main Command / Options)

| Purpose (Script) | Main Command | Options / Defaults |
|---|---|---|
| VM XML generation (`make_v2v_xml.sh`) | `bash make_v2v_xml.sh <VM_NAME>` | `XML_OUT_DIR` (default `/data/v2v/xml`), `LIBVIRT_URI` (default `qemu:///system`), `USE_DEV_PATH` (default `1`) |
| LV activate/deactivate/status (`toggle_lv_from_xml.sh`) | `bash toggle_lv_from_xml.sh /data/v2v/xml/<VM_NAME>.xml up` | Action: `up/down/status` (default `up`), `UP_MODE` (default `ro`), `SET_PERM_ON_ACTIVE_LV` (default `0`) |
| Disk conversion (`convert_disks_from_xml.sh`) | `bash convert_disks_from_xml.sh /data/v2v/xml/<VM_NAME>.xml` | `RAW_BASE_DIR` (default `/data/v2v`), `PROGRESS_INTERVAL` (default `30`) |
| OVA build (`make_ovirt_ova.sh`) | `bash make_ovirt_ova.sh /data/v2v/xml/<VM_NAME>.xml` | `OVA_BASE_DIR` (default `/data/ova`), `RAW_BASE_DIR` (default `/data/v2v`), `FORCE_BOOT_DISK_INDEX`, `TAR_PROGRESS_INTERVAL` (default `5`) |
| Full automated run (`run_qemu_ova_pipeline.sh`) | `bash run_qemu_ova_pipeline.sh /data/v2v/xml/<VM_NAME>.xml` | `RAW_BASE_DIR` (default `/data/v2v`), `OVA_BASE_DIR` (default `/data/ova`), `PIPELINE_LOG_ENABLE` (default `1`) |

## 3) Options + Command Usage (Per Script)

Common syntax:
```bash
OPTION1=value OPTION2=value bash script.sh args
```

### `make_v2v_xml.sh`
Default run:
```bash
bash make_v2v_xml.sh ppcpap02
```

| Option | Default | Description | Command Example |
|---|---|---|---|
| `XML_OUT_DIR` | `/data/v2v/xml` | XML output directory | `XML_OUT_DIR=/data/custom/xml bash make_v2v_xml.sh ppcpap02` |
| `LIBVIRT_URI` | `qemu:///system` | URI used for `dumpxml` | `LIBVIRT_URI=qemu:///system bash make_v2v_xml.sh ppcpap02` |
| `USE_DEV_PATH` | `1` | If `1`, converts `/rhev/...` paths to `/dev/<SD>/<VOL>` | `USE_DEV_PATH=0 bash make_v2v_xml.sh ppcpap02` |

### `toggle_lv_from_xml.sh`
Default run:
```bash
bash toggle_lv_from_xml.sh /data/v2v/xml/ppcpap02.xml up
```

| Option / Arg | Default | Description | Command Example |
|---|---|---|---|
| Action arg (`up/down/status`) | `up` | LV activate/deactivate/status | `bash toggle_lv_from_xml.sh /data/v2v/xml/ppcpap02.xml status` |
| `UP_MODE` | `ro` | Permission mode during `up` (`ro`/`rw`) | `UP_MODE=rw bash toggle_lv_from_xml.sh /data/v2v/xml/ppcpap02.xml up` |
| `SET_PERM_ON_ACTIVE_LV` | `0` | Re-apply permission even if LV is already active | `SET_PERM_ON_ACTIVE_LV=1 UP_MODE=ro bash toggle_lv_from_xml.sh /data/v2v/xml/ppcpap02.xml up` |

### `convert_disks_from_xml.sh`
Default run:
```bash
bash convert_disks_from_xml.sh /data/v2v/xml/ppcpap02.xml
```

| Option | Default | Description | Command Example |
|---|---|---|---|
| `RAW_BASE_DIR` | `/data/v2v` | Base path for image/log output | `RAW_BASE_DIR=/data/v2v bash convert_disks_from_xml.sh /data/v2v/xml/ppcpap02.xml` |
| `PROGRESS_INTERVAL` | `30` | Progress print interval (seconds) | `PROGRESS_INTERVAL=10 bash convert_disks_from_xml.sh /data/v2v/xml/ppcpap02.xml` |

Note: values like `MAX_JOBS`, `OUTPUT_FORMAT`, and `OUTPUT_OPTIONS` can be tuned via `import.conf` or environment variables.

### `make_ovirt_ova.sh`
Default run:
```bash
bash make_ovirt_ova.sh /data/v2v/xml/ppcpap02.xml
```

Specify disk files directly:
```bash
bash make_ovirt_ova.sh /data/v2v/xml/ppcpap02.xml \
  /data/v2v/ppcpap02/images/ppcpap02-disk1.qcow2 \
  /data/v2v/ppcpap02/images/ppcpap02-disk2.qcow2
```

| Option | Default | Description | Command Example |
|---|---|---|---|
| `RAW_BASE_DIR` | `/data/v2v` | Base path for auto disk discovery | `RAW_BASE_DIR=/data/v2v bash make_ovirt_ova.sh /data/v2v/xml/ppcpap02.xml` |
| `OVA_BASE_DIR` | `/data/ova` | OVA output base path | `OVA_BASE_DIR=/data/ova bash make_ovirt_ova.sh /data/v2v/xml/ppcpap02.xml` |
| `ENGINE_VSYSTEM_TYPE` | `ENGINE 4.1.0.0` | OVF VirtualSystemType | `ENGINE_VSYSTEM_TYPE='ENGINE 4.1.0.0' bash make_ovirt_ova.sh /data/v2v/xml/ppcpap02.xml` |
| `TAR_PROGRESS_INTERVAL` | `5` | Packing progress interval (seconds) | `TAR_PROGRESS_INTERVAL=2 bash make_ovirt_ova.sh /data/v2v/xml/ppcpap02.xml` |
| `FORCE_BOOT_DISK_INDEX` | auto | Force boot disk index | `FORCE_BOOT_DISK_INDEX=1 bash make_ovirt_ova.sh /data/v2v/xml/ppcpap02.xml` |
| `FORCE_OVF_DISK_FORMAT_URI` | auto | Force OVF disk format URI | `FORCE_OVF_DISK_FORMAT_URI='http://www.gnome.org/~markmc/qcow-image-format.html' bash make_ovirt_ova.sh /data/v2v/xml/ppcpap02.xml` |
| `FORCE_OVF_VOLUME_FORMAT` | auto | Force OVF volume format | `FORCE_OVF_VOLUME_FORMAT=COW bash make_ovirt_ova.sh /data/v2v/xml/ppcpap02.xml` |
| `FORCE_OVF_VOLUME_TYPE` | auto | Force OVF volume type | `FORCE_OVF_VOLUME_TYPE=Sparse bash make_ovirt_ova.sh /data/v2v/xml/ppcpap02.xml` |

### `run_qemu_ova_pipeline.sh`
Default run:
```bash
bash run_qemu_ova_pipeline.sh /data/v2v/xml/ppcpap02.xml
```

| Option | Default | Description | Command Example |
|---|---|---|---|
| `RAW_BASE_DIR` | `/data/v2v` | Base path for converted images/logs | `RAW_BASE_DIR=/data/v2v bash run_qemu_ova_pipeline.sh /data/v2v/xml/ppcpap02.xml` |
| `OVA_BASE_DIR` | `/data/ova` | Base path for OVA output | `OVA_BASE_DIR=/data/ova bash run_qemu_ova_pipeline.sh /data/v2v/xml/ppcpap02.xml` |
| `PIPELINE_LOG_ENABLE` | `1` | Disable tee logging if set to `0` | `PIPELINE_LOG_ENABLE=0 bash run_qemu_ova_pipeline.sh /data/v2v/xml/ppcpap02.xml` |

## 4) Sample Output

### 4-1. XML Generation
```text
[2026-02-19 08:57:01] START make_v2v_xml vm=ppcpap02 uri=qemu:///system output=/data/v2v/xml/ppcpap02.xml
[2026-02-19 08:57:02] DONE make_v2v_xml created=/data/v2v/xml/ppcpap02.xml
```

### 4-2. Pipeline Run
```text
[2026-02-19 08:57:06] START run_qemu_ova_pipeline xml=/data/v2v/xml/ppcpap02.xml
[2026-02-19 08:57:06] [1/3] activate lv
[2026-02-19 08:57:25] [2/3] convert disks (parallel)
[2026-02-19 09:11:40] [3/3] build ova
[2026-02-19 09:18:10] [4/4] deactivate lv
[2026-02-19 09:18:11] DONE run_qemu_ova_pipeline
[2026-02-19 09:18:11] ova : /data/ova/ppcpap02/ppcpap02.ova
```

### 4-3. Manual Run Example
```bash
bash toggle_lv_from_xml.sh /data/v2v/xml/ppcpap02.xml up
bash convert_disks_from_xml.sh /data/v2v/xml/ppcpap02.xml
bash make_ovirt_ova.sh /data/v2v/xml/ppcpap02.xml
bash toggle_lv_from_xml.sh /data/v2v/xml/ppcpap02.xml down
```
