# OLV (oVirt) VM Export Helper (XML -> qemu -> OVA)

This document explains how to use `make_v2v_xml.sh` and `run_qemu_ova_pipeline.sh` for oVirt-to-oVirt VM migration.  
Run from the directory where the scripts are located (example: `/data/script`).

To improve performance limited by non-parallel OLV VM Export behavior, this workflow manually converts block storage images in parallel on Linux and migrates them in a format recognized by another OLV environment.

## 0) Shared Config (v2v.conf)

- Default config file: `v2v.conf`
- Default artifact base path: `V2V_BASE_DIR=/data/v2v` (xml/qemu/ova/ova_stag files)
- Default log base path: `V2V_LOG_BASE_DIR=/data/v2v_log` (VM-only logs)
- Default XML output directory: `/data/xml`
- Scripts auto-load `v2v.conf` by default. Change values by editing `v2v.conf`, or use `CONFIG_FILE=/path/to/file.conf` to load an alternate config.
- `v2v.conf` keeps only required keys uncommented by default; optional keys are documented as commented defaults in the same file.

## 1) Recommended Workflow

1. In oVirt, migrate the target VM to the export host (node), or start it on that node.
2. Confirm the VM is running with `virsh -r list`.
3. Generate XML (on the Linux node where the VM is located, `/data/script`):
   ```bash
   bash make_v2v_xml.sh <VM_NAME>
   ```
4. Confirm `/data/xml/<VM_NAME>.xml` exists, then shut down the VM.
5. Confirm the VM is fully powered off (`virsh -r list`).
6. Run the pipeline (on the Linux node where the VM is located, from `/data/script`; output stored under `/data`):
   ```bash
   bash run_qemu_ova_pipeline.sh /data/xml/<VM_NAME>.xml
   ```
   - The script aborts immediately if the VM is found in `virsh -r list`.
   - Direct RHV import mode (skip OVA build):
     ```bash
     IMPORT_TO_RHV=true bash run_qemu_ova_pipeline.sh /data/xml/<VM_NAME>.xml
     ```
     - `REMOTE_TARGET_HOST` and related settings are read from `v2v.conf`.
     - Precheck is disabled by default (`PRECHECK=false`); enable it only when needed.
7. Check outputs:
   - OVA: `/data/v2v/ova/<VM_NAME>.ova`
   - Pipeline log: `/data/v2v_log/<VM_NAME>/pipeline-YYYY-mm-dd_HHMMSS.log`
   - Disk conversion logs: `/data/v2v_log/<VM_NAME>/qemu/<VM_NAME>-diskN.log`
   - Summary status board (current stage/disk progress only):
     ```bash
     bash show_v2v_status.sh
     bash show_v2v_status.sh --watch=5
     ```
8. In oVirt UI, import OVA from `/data/v2v/<VM_NAME>.ova`.
9. Attach network and manually set the existing MAC address (`NIC > Edit > Manual`).

Pipeline internals:
1. `toggle_lv_from_xml.sh up`
2. `convert_disks_from_xml.sh` (parallel disk conversion)
3. `make_ovirt_ova.sh` (OVA packaging)
4. `toggle_lv_from_xml.sh down` automatically on exit

## 2) Manual Execution (Purpose / Main Command / Options)

| Purpose (Script) | Main Command | Options / Defaults |
|---|---|---|
| VM XML generation (`make_v2v_xml.sh`) | `bash make_v2v_xml.sh <VM_NAME>` | `XML_OUT_DIR` (default `/data/xml`), `LIBVIRT_URI` (default `qemu:///system`), `USE_DEV_PATH` (default `1`), `VIRTIOSCSITOVIRTIO_CHANGE` (default `false`), `INCLUDE_NETWORK` (default `true`) |
| LV activate/deactivate/status (`toggle_lv_from_xml.sh`) | `bash toggle_lv_from_xml.sh /data/xml/<VM_NAME>.xml up` | Action: `up/down/status` (default `up`), `UP_MODE` (default `ro`), `SET_PERM_ON_ACTIVE_LV` (default `0`), `DEACTIVATE_RETRY_COUNT` (default `5`), `DEACTIVATE_RETRY_SLEEP` (default `1`) |
| Disk conversion (`convert_disks_from_xml.sh`) | `bash convert_disks_from_xml.sh /data/xml/<VM_NAME>.xml` | `QEMU_BASE_DIR` (default `/data/v2v/qemu`), `V2V_LOG_BASE_DIR` (default `/data/v2v_log`), `PROGRESS_INTERVAL` (default `30`) |
| OVA build (`make_ovirt_ova.sh`) | `bash make_ovirt_ova.sh /data/xml/<VM_NAME>.xml` | `QEMU_BASE_DIR` (default `/data/v2v/qemu`), `OVA_STAGING_BASE_DIR` (default `/data/v2v/ova/ova_stag`), `OVA_OUTPUT_DIR` (default `/data/v2v/ova`), `FORCE_BOOT_DISK_INDEX`, `TAR_PROGRESS_INTERVAL` (default `5`) |
| Full automated run (`run_qemu_ova_pipeline.sh`) | `bash run_qemu_ova_pipeline.sh /data/xml/<VM_NAME>.xml` | `V2V_BASE_DIR` (default `/data/v2v`), `V2V_LOG_BASE_DIR` (default `/data/v2v_log`), `LIBVIRT_URI` (default `qemu:///system`), `PIPELINE_LOG_ENABLE` (default `1`), `BUILD_OVA` (default `true`), `RUN_WITH_NOHUP` (default `true`), `VM_LOCK_BASE_DIR` (default `${V2V_BASE_DIR}/locks`) |
| Remote target import (`import_v2v.sh --run-location=remote`) | `bash import_v2v.sh --run-location=remote <VM_NAME>` | `REMOTE_TARGET_HOST` (required), `REMOTE_TARGET_USER` (default `root`), `REMOTE_SSH_PORT` (default `22`), `REMOTE_IMPORT_SCRIPT` (default `/data/script/import_v2v.sh`), `REMOTE_CSV_PATH` (default `<REMOTE_IMPORT_SCRIPT dir>/vmlist.csv`) |

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
| `XML_OUT_DIR` | `/data/xml` | XML output directory | `XML_OUT_DIR=/data/custom/xml bash make_v2v_xml.sh ppcpap02` |
| `LIBVIRT_URI` | `qemu:///system` | URI used for `dumpxml` | `LIBVIRT_URI=qemu:///system bash make_v2v_xml.sh ppcpap02` |
| `USE_DEV_PATH` | `1` | If `1`, converts `/rhev/...` paths to `/dev/<SD>/<VOL>` | `USE_DEV_PATH=0 bash make_v2v_xml.sh ppcpap02` |
| `VIRTIOSCSITOVIRTIO_CHANGE` | `false` | If `false` (default), keep `scsi` bus (preserve controller/serial); if `true`, force conversion to `virtio` | `VIRTIOSCSITOVIRTIO_CHANGE=true bash make_v2v_xml.sh ppcpap02` |
| `INCLUDE_NETWORK` | `true` | Include network interfaces (`<interface>`) in generated XML | `INCLUDE_NETWORK=false bash make_v2v_xml.sh ppcpap02` |

### `toggle_lv_from_xml.sh`
Default run:
```bash
bash toggle_lv_from_xml.sh /data/xml/ppcpap02.xml up
```

| Option / Arg | Default | Description | Command Example |
|---|---|---|---|
| Action arg (`up/down/status`) | `up` | LV activate/deactivate/status | `bash toggle_lv_from_xml.sh /data/xml/ppcpap02.xml status` |
| `UP_MODE` | `ro` | Permission mode during `up` (`ro`/`rw`) | `UP_MODE=rw bash toggle_lv_from_xml.sh /data/xml/ppcpap02.xml up` |
| `SET_PERM_ON_ACTIVE_LV` | `0` | Re-apply permission even if LV is already active | `SET_PERM_ON_ACTIVE_LV=1 UP_MODE=ro bash toggle_lv_from_xml.sh /data/xml/ppcpap02.xml up` |
| `DEACTIVATE_RETRY_COUNT` | `5` | Number of retries for LV deactivation during `down` | `DEACTIVATE_RETRY_COUNT=10 bash toggle_lv_from_xml.sh /data/xml/ppcpap02.xml down` |
| `DEACTIVATE_RETRY_SLEEP` | `1` | Retry interval in seconds during `down` | `DEACTIVATE_RETRY_SLEEP=2 bash toggle_lv_from_xml.sh /data/xml/ppcpap02.xml down` |

### `convert_disks_from_xml.sh`
Default run:
```bash
bash convert_disks_from_xml.sh /data/xml/ppcpap02.xml
```

| Option | Default | Description | Command Example |
|---|---|---|---|
| `QEMU_BASE_DIR` | `/data/v2v/qemu` | Base path for qcow2 image output | `QEMU_BASE_DIR=/data/v2v/qemu bash convert_disks_from_xml.sh /data/xml/ppcpap02.xml` |
| `V2V_LOG_BASE_DIR` | `/data/v2v_log` | Base path for conversion logs | `V2V_LOG_BASE_DIR=/data/v2v_log bash convert_disks_from_xml.sh /data/xml/ppcpap02.xml` |
| `INPUT_FORMAT` | `auto` | Auto-detect source disk format (`raw`/`qcow2`, etc.) | `INPUT_FORMAT=qcow2 bash convert_disks_from_xml.sh /data/xml/ppcpap02.xml` |
| `PROGRESS_INTERVAL` | `30` | Progress print interval (seconds) | `PROGRESS_INTERVAL=10 bash convert_disks_from_xml.sh /data/xml/ppcpap02.xml` |

Note: values like `MAX_JOBS`, `OUTPUT_FORMAT`, and `OUTPUT_OPTIONS` are tuned in `v2v.conf` (or an alternate `CONFIG_FILE`).

### `make_ovirt_ova.sh`
Default run:
```bash
bash make_ovirt_ova.sh /data/xml/ppcpap02.xml
```

Specify disk files directly:
```bash
bash make_ovirt_ova.sh /data/xml/ppcpap02.xml \
  /data/v2v/qemu/ppcpap02/ppcpap02-disk1.qcow2 \
  /data/v2v/qemu/ppcpap02/ppcpap02-disk2.qcow2
```

| Option | Default | Description | Command Example |
|---|---|---|---|
| `QEMU_BASE_DIR` | `/data/v2v/qemu` | Auto disk discovery path | `QEMU_BASE_DIR=/data/custom/qemu bash make_ovirt_ova.sh /data/xml/ppcpap02.xml` |
| `OVA_STAGING_BASE_DIR` | `/data/v2v/ova/ova_stag` | Temporary OVA staging path | `OVA_STAGING_BASE_DIR=/data/custom/ova_stag bash make_ovirt_ova.sh /data/xml/ppcpap02.xml` |
| `OVA_OUTPUT_DIR` | `/data/v2v/ova` | OVA file output path (`<vm>.ova`) | `OVA_OUTPUT_DIR=/data/custom/ova bash make_ovirt_ova.sh /data/xml/ppcpap02.xml` |
| `V2V_LOG_BASE_DIR` | `/data/v2v_log` | OVA build log base path | `V2V_LOG_BASE_DIR=/data/custom/v2v_log bash make_ovirt_ova.sh /data/xml/ppcpap02.xml` |
| `ENGINE_VSYSTEM_TYPE` | `ENGINE 4.1.0.0` | OVF VirtualSystemType | `ENGINE_VSYSTEM_TYPE='ENGINE 4.1.0.0' bash make_ovirt_ova.sh /data/xml/ppcpap02.xml` |
| `TAR_PROGRESS_INTERVAL` | `5` | Packing progress interval (seconds) | `TAR_PROGRESS_INTERVAL=2 bash make_ovirt_ova.sh /data/xml/ppcpap02.xml` |
| `FORCE_BOOT_DISK_INDEX` | auto | Force boot disk index | `FORCE_BOOT_DISK_INDEX=1 bash make_ovirt_ova.sh /data/xml/ppcpap02.xml` |
| `FORCE_OVF_DISK_FORMAT_URI` | auto | Force OVF disk format URI | `FORCE_OVF_DISK_FORMAT_URI='http://www.gnome.org/~markmc/qcow-image-format.html' bash make_ovirt_ova.sh /data/xml/ppcpap02.xml` |
| `FORCE_OVF_VOLUME_FORMAT` | auto | Force OVF volume format | `FORCE_OVF_VOLUME_FORMAT=COW bash make_ovirt_ova.sh /data/xml/ppcpap02.xml` |
| `FORCE_OVF_VOLUME_TYPE` | auto | Force OVF volume type | `FORCE_OVF_VOLUME_TYPE=Sparse bash make_ovirt_ova.sh /data/xml/ppcpap02.xml` |

### `run_qemu_ova_pipeline.sh`
Default run:
```bash
bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml
```

Stop a running VM pipeline:
```bash
bash run_qemu_ova_pipeline.sh --stop ppcpap02
```

| Option | Default | Description | Command Example |
|---|---|---|---|
| `V2V_BASE_DIR` | `/data/v2v` | Artifact base path (xml/qemu/ova/ova_stag) | `V2V_BASE_DIR=/data/v2v bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `V2V_LOG_BASE_DIR` | `/data/v2v_log` | VM-specific log base path | `V2V_LOG_BASE_DIR=/data/v2v_log bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `LIBVIRT_URI` | `qemu:///system` | URI used for active-VM check (`virsh -r list`) | `LIBVIRT_URI=qemu:///system bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `QEMU_BASE_DIR` | `/data/v2v/qemu` | Optional override for qcow2 image path | `QEMU_BASE_DIR=/data/custom/qemu bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `OVA_STAGING_BASE_DIR` | `/data/v2v/ova/ova_stag` | Optional override for OVA temporary staging path | `OVA_STAGING_BASE_DIR=/data/custom/ova_stag bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `OVA_OUTPUT_DIR` | `/data/v2v/ova` | Optional override for OVA output path | `OVA_OUTPUT_DIR=/data/custom/ova bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `PIPELINE_LOG_ENABLE` | `1` | Disable tee logging if set to `0` | `PIPELINE_LOG_ENABLE=0 bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `FAILURE_TAIL_LINES` | `120` | Tail line count dumped on failure (`0` disables dump) | `FAILURE_TAIL_LINES=200 bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `FAILURE_QEMU_LOG_COUNT` | `3` | Number of newest qemu disk logs to tail on failure | `FAILURE_QEMU_LOG_COUNT=5 bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `BUILD_OVA` | `true` | If `false`, skip OVA packaging and run qemu conversion only | `BUILD_OVA=false bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `RUN_WITH_NOHUP` | `true` | If `true`, launch in `nohup` background mode and return immediately | `RUN_WITH_NOHUP=false bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `VM_LOCK_BASE_DIR` | `/data/v2v/locks` | Lock directory for same-VM duplicate run prevention | `VM_LOCK_BASE_DIR=/tmp/v2v-locks bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `STOP_WAIT_SECONDS` | `10` | Wait seconds after TERM in `--stop`, then force KILL | `STOP_WAIT_SECONDS=20 bash run_qemu_ova_pipeline.sh --stop ppcpap02` |

### `import_v2v.sh --run-location=remote`
Default run:
```bash
REMOTE_TARGET_HOST=10.0.0.22 bash import_v2v.sh --run-location=remote ppcpap02
```

| Option | Default | Description | Command Example |
|---|---|---|---|
| `REMOTE_TARGET_HOST` | none (required) | Target host/IP | `REMOTE_TARGET_HOST=10.0.0.22 bash import_v2v.sh --run-location=remote ppcpap02` |
| `REMOTE_TARGET_USER` | `root` | SSH login user | `REMOTE_TARGET_HOST=10.0.0.22 REMOTE_TARGET_USER=admin bash import_v2v.sh --run-location=remote ppcpap02` |
| `REMOTE_SSH_PORT` | `22` | SSH port | `REMOTE_TARGET_HOST=10.0.0.22 REMOTE_SSH_PORT=2222 bash import_v2v.sh --run-location=remote ppcpap02` |
| `REMOTE_SSH_OPTS` | empty | Additional SSH options string | `REMOTE_TARGET_HOST=10.0.0.22 REMOTE_SSH_OPTS='-i /root/.ssh/id_rsa -o StrictHostKeyChecking=no' bash import_v2v.sh --run-location=remote ppcpap02` |
| `REMOTE_SSH_PASS_FILE` | empty | `sshpass` password file path (non-interactive SSH) | `REMOTE_TARGET_HOST=10.0.0.22 REMOTE_SSH_PASS_FILE=/data/script/ovirt-passwd bash import_v2v.sh --run-location=remote ppcpap02` |
| `REMOTE_IMPORT_SCRIPT` | `/data/script/import_v2v.sh` | Remote script path on target | `REMOTE_TARGET_HOST=10.0.0.22 REMOTE_IMPORT_SCRIPT=/opt/v2v/import_v2v.sh bash import_v2v.sh --run-location=remote ppcpap02` |
| `REMOTE_CSV_PATH` | empty (auto) | If empty, uses `vmlist.csv` in the same directory as `REMOTE_IMPORT_SCRIPT` | `REMOTE_TARGET_HOST=10.0.0.22 REMOTE_CSV_PATH=/data/script/vmlist.csv bash import_v2v.sh --run-location=remote ppcpap02` |

## 4) Sample Output

### 4-1. XML Generation
```text
[2026-02-19 08:57:01] START make_v2v_xml vm=ppcpap02 uri=qemu:///system output=/data/xml/ppcpap02.xml
[2026-02-19 08:57:02] DONE make_v2v_xml created=/data/xml/ppcpap02.xml
```

### 4-2. Pipeline Run
```text
[2026-02-19 08:57:06] START run_qemu_ova_pipeline xml=/data/xml/ppcpap02.xml
[2026-02-19 08:57:06] [1/3] activate lv
[2026-02-19 08:57:25] [2/3] convert disks (parallel)
[2026-02-19 09:11:40] [3/3] build ova
[2026-02-19 09:18:10] [4/4] deactivate lv
[2026-02-19 09:18:11] DONE run_qemu_ova_pipeline
[2026-02-19 09:18:11] ova : /data/v2v/ppcpap02.ova
```

### 4-3. Manual Run Example
```bash
bash toggle_lv_from_xml.sh /data/xml/ppcpap02.xml up
bash convert_disks_from_xml.sh /data/xml/ppcpap02.xml
bash make_ovirt_ova.sh /data/xml/ppcpap02.xml
bash toggle_lv_from_xml.sh /data/xml/ppcpap02.xml down
```
