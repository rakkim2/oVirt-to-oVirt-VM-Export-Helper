# VirtShift (ZeroTouch OLV Migration Engine)

## Abstract
- `VirtShift (ZeroTouch OLV Migration Engine)` is built to reduce migration bottlenecks and manual effort in OLV-to-OLV VM migration.
- Instead of relying only on the default OLV Export/Import path, it parallelizes disk conversion on Linux and automates import orchestration.
- In day-to-day operations, migration is typically executed with two commands: `make_v2v_xml.sh` and `run_virtshift.sh`.

## What This Project Solves
- Throughput limits when multiple jobs are submitted but effective processing remains constrained
- Import failures caused by XML/OVF metadata mismatches
- Operational conflicts during stop/retry/re-run
- Slow incident analysis due to fragmented logs

## Quick Start (Recommended)
1. Generate VM XML:
```bash
cd /data/script
bash make_v2v_xml.sh <VM_NAME>
```
2. Run pipeline:
```bash
cd /data/script
bash run_virtshift.sh <VM_NAME>
# or
bash run_virtshift.sh /data/xml/<VM_NAME>.xml
```

## What the Pipeline Does
1. Normalize source XML
2. Activate LVs (`up`)
3. Convert disks in parallel (`qemu-img`, `MAX_JOBS`)
4. Build OVA or run remote import (depending on mode)
5. Deactivate LVs (`down`) and write result logs

## Performance Improvements
- Parallel disk conversion (`MAX_JOBS`)
- Skip unnecessary OVA stage when `IMPORT_TO_RHV=true`
- Execution collision control via VM/import locks
- Faster failure analysis with automatic tail dump of critical logs

## Major Bug Fixes (Summary)
- Fixed hardcoded `INPUT_FORMAT=raw` behavior by enabling auto-detect
- Fixed OVF metadata mismatches (`format/fileRef/interface`) to match real outputs
- Fixed `virtio-scsi` controller/serial omission
- Standardized import execution location (remote target path)
- Added process-tree stop control (`--stop`)

Detailed history: `THREAD_BUGFIX_LOG.md`

## Operational Controls
Stop:
```bash
bash run_virtshift.sh --stop <VM_NAME>
```

Status:
```bash
bash show_v2v_status.sh
watch -n 1 "bash show_v2v_status.sh"
```

## Paths and Logs
- Scripts: `/data/script`
- XML: `/data/xml/<VM_NAME>.xml`
- Artifacts: `/data/v2v`
- Logs: `/data/v2v_log`
- Global result: `/data/v2v_log/result.log`
- Status board: `/data/v2v_log/status_board.log`
- Pipeline logs: `/data/v2v_log/<VM_NAME>/pipeline_<YYYY-mm-dd_HHMMSS>.log`

## Document Map
- Operations SOP: `USAGE.md`
- Config and tuning guide: `CONFIG_GUIDE.md`
- Development history: `DEV.md`
- KR operations summary: `CONFLUENCE_SOP_KR.md`
- Historical bugfix log: `THREAD_BUGFIX_LOG.md`
