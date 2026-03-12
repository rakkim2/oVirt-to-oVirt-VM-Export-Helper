# OLV (oVirt) VM Export Helper (XML -> qemu -> OVA)

이 문서는 oVirt VM to oVirt VM을 수행하는 `make_v2v_xml.sh`, `run_qemu_ova_pipeline.sh` 기준 사용법입니다.  
기본 실행 위치는 스크립트가 있는 디렉터리(예: `/data/script`)입니다.

OLV VM Export 기능의 병렬 처리 한계로 인한 성능 저하를 개선하기 위해, Linux에서 블록 스토리지 이미지를 병렬로 수동 변환하여 타 OLV에서 인식 가능한 형식으로 이관하는 방식입니다.

## 0) 초보자 SOP (먼저 보기)

이 섹션만 따라하면 기본 작업이 됩니다.  
실행 위치는 `/data/script` 기준입니다.

### 0-1. 필수 전제

1. `v2v.conf` 필수값 확인
   - `REMOTE_TARGET_HOST`
   - `RHV_ENGINE_URL`
   - `RHV_PASS_FILE`
   - `IMPORT_TO_RHV="true"` (기본 import 파이프라인 사용 시)
2. XML 파일 준비
   - `/data/xml/<VM_NAME>.xml`
3. 소스 VM 완전 종료 확인
   - `virsh -r list`에 대상 VM이 없어야 함

### 0-2. 대표 실행 명령어

1. run qemu pipeline 실행
   ```bash
   cd /data/script
   bash run_qemu_ova_pipeline.sh <VM_NAME>
   # 또는
   bash run_qemu_ova_pipeline.sh /data/xml/<VM_NAME>.xml
   ```
2. 중간 중지
   ```bash
   bash run_qemu_ova_pipeline.sh --stop <VM_NAME>
   ```
3. import만 따로 실행
   ```bash
   # 소스에서 타깃으로 원격 실행
   bash import_v2v.sh --run-location=remote <VM_NAME>

   # precheck만
   bash import_v2v.sh --run-location=remote --check <VM_NAME>
   ```

### 0-3. 현 상태/결과 확인

1. 현 상태 보기
   ```bash
   bash show_v2v_status.sh
   watch -n 1 "bash show_v2v_status.sh"
   ```
2. 결과 로그 위치
   - 전체 집계: `/data/v2v_log/result.log`
     - 성공/실패, `start/end`, `reason` 포함
   - VM 실행별: `/data/v2v_log/<VM_NAME>/result-YYYY-mm-dd_HHMMSS.log`
3. 상태판 로그 위치
   - 전역 1개: `/data/v2v_log/status_board.log`
4. 실행 상세 로그 위치
   - `/data/v2v_log/<VM_NAME>/pipeline_<YYYY-mm-dd_HHMMSS>.log`
   - `/data/v2v_log/<VM_NAME>/qemu/<VM_NAME>-diskN.log`

### 0-4. 기본 동작 우선순위

1. `IMPORT_TO_RHV=true` 이면 `BUILD_OVA`는 자동으로 `false`로 강제되어 OVA 패키징을 건너뜁니다.
2. OVA 임시 스테이징 기본 경로는 `/data/v2v/ova/ova_stag` 입니다.

## 1) 수동 실행 (목적 / 대표 명령어 / 옵션)

| 목적 (쉘파일) | 대표 명령어 | 옵션/기본값 |
|---|---|---|
| VM XML 생성 (`make_v2v_xml.sh`) | `bash make_v2v_xml.sh <VM_NAME>` | `XML_OUT_DIR` (기본 `/data/xml`), `LIBVIRT_URI` (기본 `qemu:///system`), `USE_DEV_PATH` (기본 `1`), `VIRTIOSCSITOVIRTIO_CHANGE` (기본 `false`), `INCLUDE_NETWORK` (기본 `true`) |
| LV 활성/비활성/상태 (`toggle_lv_from_xml.sh`) | `bash toggle_lv_from_xml.sh /data/xml/<VM_NAME>.xml up` | 액션: `up/down/status` (기본 `up`), `UP_MODE` (기본 `ro`), `SET_PERM_ON_ACTIVE_LV` (기본 `0`), `DEACTIVATE_RETRY_COUNT` (기본 `5`), `DEACTIVATE_RETRY_SLEEP` (기본 `1`) |
| 디스크 변환 (`convert_disks_from_xml.sh`) | `bash convert_disks_from_xml.sh /data/xml/<VM_NAME>.xml` | `QEMU_BASE_DIR` (기본 `/data/v2v/qemu`), `V2V_LOG_BASE_DIR` (기본 `/data/v2v_log`), `PROGRESS_INTERVAL` (기본 `30`) |
| OVA 생성 (`make_ovirt_ova.sh`) | `bash make_ovirt_ova.sh /data/xml/<VM_NAME>.xml` | `QEMU_BASE_DIR` (기본 `/data/v2v/qemu`), `OVA_STAGING_BASE_DIR` (기본 `/data/v2v/ova/ova_stag`), `OVA_OUTPUT_DIR` (기본 `/data/v2v/ova`), `FORCE_BOOT_DISK_INDEX`, `TAR_PROGRESS_INTERVAL` (기본 `5`) |
| 전체 자동 실행 (`run_qemu_ova_pipeline.sh`) | `bash run_qemu_ova_pipeline.sh /data/xml/<VM_NAME>.xml` | `V2V_BASE_DIR` (기본 `/data/v2v`), `V2V_LOG_BASE_DIR` (기본 `/data/v2v_log`), `LIBVIRT_URI` (기본 `qemu:///system`), `PIPELINE_LOG_ENABLE` (기본 `1`), `IMPORT_TO_RHV` (기본: `REMOTE_TARGET_HOST` 설정 시 `true`, 아니면 `false`), `BUILD_OVA` (기본 `true`, 단 `IMPORT_TO_RHV=true`면 자동 skip), `RUN_WITH_NOHUP` (기본 `true`), `VM_LOCK_BASE_DIR` (기본 `${V2V_BASE_DIR}/locks`) |
| 타겟 import 원격 실행 (`import_v2v.sh --run-location=remote`) | `bash import_v2v.sh --run-location=remote <VM_NAME>` | `REMOTE_TARGET_HOST` (필수), `REMOTE_TARGET_USER` (기본 `root`), `REMOTE_SSH_PORT` (기본 `22`), `REMOTE_IMPORT_SCRIPT` (기본 `/data/script/import_v2v.sh`), `REMOTE_CSV_PATH` (기본 `<REMOTE_IMPORT_SCRIPT dir>/vmlist.csv`) |

## 2) 옵션 + 명령어 사용법 (스크립트별, 상세)

공통 문법:
```bash
옵션1=값 옵션2=값 bash script.sh 인자
```

### `make_v2v_xml.sh`
기본 실행:
```bash
bash make_v2v_xml.sh ppcpap02
```

| 옵션 | 기본값 | 설명 | 명령어 예시 |
|---|---|---|---|
| `XML_OUT_DIR` | `/data/xml` | XML 출력 디렉터리 | `XML_OUT_DIR=/data/custom/xml bash make_v2v_xml.sh ppcpap02` |
| `LIBVIRT_URI` | `qemu:///system` | dumpxml 조회 URI | `LIBVIRT_URI=qemu:///system bash make_v2v_xml.sh ppcpap02` |
| `USE_DEV_PATH` | `1` | `1`이면 `/rhev/...`를 `/dev/<SD>/<VOL>`로 치환 | `USE_DEV_PATH=0 bash make_v2v_xml.sh ppcpap02` |
| `VIRTIOSCSITOVIRTIO_CHANGE` | `false` | `false`(기본)이면 `scsi` bus를 유지(컨트롤러/serial 보존), `true`면 `virtio` bus로 변경 | `VIRTIOSCSITOVIRTIO_CHANGE=true bash make_v2v_xml.sh ppcpap02` |
| `INCLUDE_NETWORK` | `true` | XML에 네트워크 인터페이스(`<interface>`) 포함 여부 | `INCLUDE_NETWORK=false bash make_v2v_xml.sh ppcpap02` |

### `toggle_lv_from_xml.sh`
기본 실행:
```bash
bash toggle_lv_from_xml.sh /data/xml/ppcpap02.xml up
```

| 옵션/인자 | 기본값 | 설명 | 명령어 예시 |
|---|---|---|---|
| 액션 인자 (`up/down/status`) | `up` | LV 활성/비활성/상태 조회 | `bash toggle_lv_from_xml.sh /data/xml/ppcpap02.xml status` |
| `UP_MODE` | `ro` | `up` 시 권한 (`ro`/`rw`) | `UP_MODE=rw bash toggle_lv_from_xml.sh /data/xml/ppcpap02.xml up` |
| `SET_PERM_ON_ACTIVE_LV` | `0` | 이미 active인 LV에도 권한 재설정 시도 | `SET_PERM_ON_ACTIVE_LV=1 UP_MODE=ro bash toggle_lv_from_xml.sh /data/xml/ppcpap02.xml up` |
| `DEACTIVATE_RETRY_COUNT` | `5` | `down` 시 LV 비활성화 재시도 횟수 | `DEACTIVATE_RETRY_COUNT=10 bash toggle_lv_from_xml.sh /data/xml/ppcpap02.xml down` |
| `DEACTIVATE_RETRY_SLEEP` | `1` | `down` 재시도 간격(초) | `DEACTIVATE_RETRY_SLEEP=2 bash toggle_lv_from_xml.sh /data/xml/ppcpap02.xml down` |

### `convert_disks_from_xml.sh`
기본 실행:
```bash
bash convert_disks_from_xml.sh /data/xml/ppcpap02.xml
```

| 옵션 | 기본값 | 설명 | 명령어 예시 |
|---|---|---|---|
| `QEMU_BASE_DIR` | `/data/v2v/qemu` | qcow2 이미지 저장 base 경로 | `QEMU_BASE_DIR=/data/v2v/qemu bash convert_disks_from_xml.sh /data/xml/ppcpap02.xml` |
| `V2V_LOG_BASE_DIR` | `/data/v2v_log` | 변환 로그 저장 base 경로 | `V2V_LOG_BASE_DIR=/data/v2v_log bash convert_disks_from_xml.sh /data/xml/ppcpap02.xml` |
| `INPUT_FORMAT` | `auto` | 소스 디스크 포맷 자동 감지(`raw`/`qcow2` 등) | `INPUT_FORMAT=qcow2 bash convert_disks_from_xml.sh /data/xml/ppcpap02.xml` |
| `PROGRESS_INTERVAL` | `30` | 진행률 출력 주기(초) | `PROGRESS_INTERVAL=10 bash convert_disks_from_xml.sh /data/xml/ppcpap02.xml` |

참고: `MAX_JOBS`, `OUTPUT_FORMAT`, `OUTPUT_OPTIONS` 등은 `v2v.conf`(또는 별도 `CONFIG_FILE`)에서 조정합니다.

### `make_ovirt_ova.sh`
기본 실행:
```bash
bash make_ovirt_ova.sh /data/xml/ppcpap02.xml
```

디스크 직접 지정:
```bash
bash make_ovirt_ova.sh /data/xml/ppcpap02.xml \
  /data/v2v/qemu/ppcpap02/ppcpap02-disk1.qcow2 \
  /data/v2v/qemu/ppcpap02/ppcpap02-disk2.qcow2
```

| 옵션 | 기본값 | 설명 | 명령어 예시 |
|---|---|---|---|
| `QEMU_BASE_DIR` | `/data/v2v/qemu` | 자동 디스크 탐색 경로 | `QEMU_BASE_DIR=/data/custom/qemu bash make_ovirt_ova.sh /data/xml/ppcpap02.xml` |
| `OVA_STAGING_BASE_DIR` | `/data/v2v/ova/ova_stag` | OVA 임시 스테이징 경로 | `OVA_STAGING_BASE_DIR=/data/custom/ova_stag bash make_ovirt_ova.sh /data/xml/ppcpap02.xml` |
| `OVA_OUTPUT_DIR` | `/data/v2v/ova` | OVA 파일 출력 경로 (`<vm>.ova`) | `OVA_OUTPUT_DIR=/data/custom/ova bash make_ovirt_ova.sh /data/xml/ppcpap02.xml` |
| `V2V_LOG_BASE_DIR` | `/data/v2v_log` | OVA 생성 로그 base 경로 | `V2V_LOG_BASE_DIR=/data/custom/v2v_log bash make_ovirt_ova.sh /data/xml/ppcpap02.xml` |
| `ENGINE_VSYSTEM_TYPE` | `ENGINE 4.1.0.0` | OVF 내 VirtualSystemType | `ENGINE_VSYSTEM_TYPE='ENGINE 4.1.0.0' bash make_ovirt_ova.sh /data/xml/ppcpap02.xml` |
| `TAR_PROGRESS_INTERVAL` | `5` | 패킹 진행률 출력 주기(초) | `TAR_PROGRESS_INTERVAL=2 bash make_ovirt_ova.sh /data/xml/ppcpap02.xml` |
| `FORCE_BOOT_DISK_INDEX` | 자동 | 부팅 디스크 순번 강제 | `FORCE_BOOT_DISK_INDEX=1 bash make_ovirt_ova.sh /data/xml/ppcpap02.xml` |
| `FORCE_OVF_DISK_FORMAT_URI` | 자동 | OVF format URI 강제 | `FORCE_OVF_DISK_FORMAT_URI='http://www.gnome.org/~markmc/qcow-image-format.html' bash make_ovirt_ova.sh /data/xml/ppcpap02.xml` |
| `FORCE_OVF_VOLUME_FORMAT` | 자동 | OVF volume format 강제 | `FORCE_OVF_VOLUME_FORMAT=COW bash make_ovirt_ova.sh /data/xml/ppcpap02.xml` |
| `FORCE_OVF_VOLUME_TYPE` | 자동 | OVF volume type 강제 | `FORCE_OVF_VOLUME_TYPE=Sparse bash make_ovirt_ova.sh /data/xml/ppcpap02.xml` |

### `run_qemu_ova_pipeline.sh`
기본 실행:
```bash
bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml
```

실행 중지(편의 명령):
```bash
bash run_qemu_ova_pipeline.sh --stop ppcpap02
```

| 옵션 | 기본값 | 설명 | 명령어 예시 |
|---|---|---|---|
| `V2V_BASE_DIR` | `/data/v2v` | 산출물 base 경로 (xml/qemu/ova/ova_stag) | `V2V_BASE_DIR=/data/v2v bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `V2V_LOG_BASE_DIR` | `/data/v2v_log` | VM별 로그 base 경로 | `V2V_LOG_BASE_DIR=/data/v2v_log bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `LIBVIRT_URI` | `qemu:///system` | 실행 중 VM 체크(`virsh -r list`)에 사용할 URI | `LIBVIRT_URI=qemu:///system bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `QEMU_BASE_DIR` | `/data/v2v/qemu` | qcow2 이미지 경로 별도 오버라이드(선택) | `QEMU_BASE_DIR=/data/custom/qemu bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `OVA_STAGING_BASE_DIR` | `/data/v2v/ova/ova_stag` | OVA 임시 스테이징 경로 별도 오버라이드(선택) | `OVA_STAGING_BASE_DIR=/data/custom/ova_stag bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `OVA_OUTPUT_DIR` | `/data/v2v/ova` | OVA 출력 경로 별도 오버라이드(선택) | `OVA_OUTPUT_DIR=/data/custom/ova bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `PIPELINE_LOG_ENABLE` | `1` | `0`이면 tee 로그 비활성 | `PIPELINE_LOG_ENABLE=0 bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `FAILURE_TAIL_LINES` | `120` | 실패 시 스크립트/디스크 로그 tail 라인 수 (`0`이면 비활성) | `FAILURE_TAIL_LINES=200 bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `FAILURE_QEMU_LOG_COUNT` | `3` | 실패 시 tail 덤프할 최신 qemu 디스크 로그 개수 | `FAILURE_QEMU_LOG_COUNT=5 bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `IMPORT_TO_RHV` | `REMOTE_TARGET_HOST` 설정 시 `true`, 아니면 `false` | `true`면 타깃에서 import 실행, OVA 패키징은 자동 skip | `IMPORT_TO_RHV=true bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `BUILD_OVA` | `true` | `false`면 OVA 패키징 단계를 건너뛰고 qemu 변환만 수행 (`IMPORT_TO_RHV=true`면 자동 skip) | `BUILD_OVA=false bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `RUN_WITH_NOHUP` | `true` | `true`면 `nohup` 백그라운드 실행으로 즉시 반환 | `RUN_WITH_NOHUP=false bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `VM_LOCK_BASE_DIR` | `/data/v2v/locks` | 동일 VM 중복 실행 방지 lock 디렉터리 | `VM_LOCK_BASE_DIR=/tmp/v2v-locks bash run_qemu_ova_pipeline.sh /data/xml/ppcpap02.xml` |
| `STOP_WAIT_SECONDS` | `10` | `--stop` 시 TERM 후 대기 시간(초), 초과 시 KILL | `STOP_WAIT_SECONDS=20 bash run_qemu_ova_pipeline.sh --stop ppcpap02` |

### `import_v2v.sh --run-location=remote`
기본 실행:
```bash
REMOTE_TARGET_HOST=10.0.0.22 bash import_v2v.sh --run-location=remote ppcpap02
```

| 옵션 | 기본값 | 설명 | 명령어 예시 |
|---|---|---|---|
| `REMOTE_TARGET_HOST` | 없음(필수) | 타겟 호스트/IP | `REMOTE_TARGET_HOST=10.0.0.22 bash import_v2v.sh --run-location=remote ppcpap02` |
| `REMOTE_TARGET_USER` | `root` | SSH 접속 사용자 | `REMOTE_TARGET_HOST=10.0.0.22 REMOTE_TARGET_USER=admin bash import_v2v.sh --run-location=remote ppcpap02` |
| `REMOTE_SSH_PORT` | `22` | SSH 포트 | `REMOTE_TARGET_HOST=10.0.0.22 REMOTE_SSH_PORT=2222 bash import_v2v.sh --run-location=remote ppcpap02` |
| `REMOTE_SSH_OPTS` | 빈값 | 추가 SSH 옵션 문자열 | `REMOTE_TARGET_HOST=10.0.0.22 REMOTE_SSH_OPTS='-i /root/.ssh/id_rsa -o StrictHostKeyChecking=no' bash import_v2v.sh --run-location=remote ppcpap02` |
| `REMOTE_SSH_PASS_FILE` | 비어있음 | `sshpass` 비밀번호 파일 경로 (설정 시 비대화형 SSH) | `REMOTE_TARGET_HOST=10.0.0.22 REMOTE_SSH_PASS_FILE=/data/script/ovirt-passwd bash import_v2v.sh --run-location=remote ppcpap02` |
| `REMOTE_IMPORT_SCRIPT` | `/data/script/import_v2v.sh` | 타겟에서 실행할 import 스크립트 경로 | `REMOTE_TARGET_HOST=10.0.0.22 REMOTE_IMPORT_SCRIPT=/opt/v2v/import_v2v.sh bash import_v2v.sh --run-location=remote ppcpap02` |
| `REMOTE_CSV_PATH` | 빈값(자동) | 비어있으면 `REMOTE_IMPORT_SCRIPT`와 같은 디렉터리의 `vmlist.csv` 사용 | `REMOTE_TARGET_HOST=10.0.0.22 REMOTE_CSV_PATH=/data/script/vmlist.csv bash import_v2v.sh --run-location=remote ppcpap02` |

## 3) 예시 출력

### 4-1. XML 생성
```text
[2026-02-19 08:57:01] START make_v2v_xml vm=ppcpap02 uri=qemu:///system output=/data/xml/ppcpap02.xml
[2026-02-19 08:57:02] DONE make_v2v_xml created=/data/xml/ppcpap02.xml
```

### 4-2. 파이프라인 실행
```text
[2026-02-19 08:57:06] START run_qemu_ova_pipeline xml=/data/xml/ppcpap02.xml
[2026-02-19 08:57:06] [1/3] activate lv
[2026-02-19 08:57:25] [2/3] convert disks (parallel)
[2026-02-19 09:11:40] [3/3] build ova
[2026-02-19 09:18:10] [4/4] deactivate lv
[2026-02-19 09:18:11] DONE run_qemu_ova_pipeline
[2026-02-19 09:18:11] ova : /data/v2v/ppcpap02.ova
```

### 4-3. 수동 실행 예시
```bash
bash toggle_lv_from_xml.sh /data/xml/ppcpap02.xml up
bash convert_disks_from_xml.sh /data/xml/ppcpap02.xml
bash make_ovirt_ova.sh /data/xml/ppcpap02.xml
bash toggle_lv_from_xml.sh /data/xml/ppcpap02.xml down
```
