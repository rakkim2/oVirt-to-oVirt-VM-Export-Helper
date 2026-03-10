# oVirt-to-oVirt 최소 운영 공유본

## 필수 조건
- 공유 스토리지: `/data` (소스/타겟 모두 마운트)
- 스크립트: `/data/script`
- XML: `/data/xml/<VM_NAME>.xml`
- VM 전원 OFF 확인: `virsh -r list`
- `v2v.conf` 필수 값:
  - `RHV_ENGINE_URL`
  - `RHV_PASS_FILE`
  - `REMOTE_TARGET_HOST`
  - `REMOTE_SSH_PASS_FILE`
  - `IMPORT_TO_RHV="true"`

## 대표 명령
```bash
cd /data/script

# 1) 전체 실행 (convert + remote import)
bash run_qemu_ova_pipeline.sh <VM_NAME>

# 2) 중지
bash run_qemu_ova_pipeline.sh --stop <VM_NAME>

# 3) import만 단독 실행 (remote)
bash import_v2v.sh --run-location=remote <VM_NAME>

# 4) 상태 확인
bash show_v2v_status.sh <VM_NAME>
watch -n 1 "bash show_v2v_status.sh <VM_NAME>"

# 5) 강제 종료 (부모/자식 전체)
pkill -TERM -P <PPID>; kill -TERM <PPID>
```

## 동작 핵심
- `IMPORT_TO_RHV=true`이면 OVA 생성은 자동 skip.
- 동일 VM 중복 실행은 lock으로 차단.
- `import_v2v.sh --run-location=remote` 단독 실행은 기본 `nohup` 백그라운드.

## 로그 위치
- 파이프라인: `/data/v2v_log/<VM_NAME>/pipeline_<YYYY-mm-dd_HHMMSS>.log`
- import: `/data/v2v_log/<VM_NAME>/import_v2v-<YYYY-mm-dd_HHMMSS>.log`
- qemu convert: `/data/v2v_log/<VM_NAME>/qemu/<VM_NAME>-diskN.log`
- 전체 결과: `/data/v2v_log/result.log`
- 상태 집계: `/data/v2v_log/status_board.log`

## 자주 나는 오류 3개
- `failed to get "write" lock`
  - 기존 변환 프로세스 점유. 기존 PID 종료 후 실패 디스크 파일 삭제하고 재실행.
- `HTTP 409 ... duplicates in target MAC pool`
  - MAC 중복 또는 MAC pool 범위 이슈. 엔진에서 MAC 사용 현황 확인 후 재시도.
- `${SCRIPT_BASE_DIR}/... not found`
  - `v2v.conf` 변수 치환 실패. 해당 경로를 절대경로(`/data/script/...`)로 지정.
