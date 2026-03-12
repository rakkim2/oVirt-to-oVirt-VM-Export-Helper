# OLV (oVirt) VM Export Helper (XML -> qemu -> OVA)

> 중요: `main` 브랜치는 **Export + Import(원격 virt-v2v 포함)** 기준입니다.  
> Export 전용 고정 버전은 `codex/export-only` 브랜치 또는 `v1.0.0` 태그를 사용하세요.

이 문서는 oVirt VM to oVirt VM을 수행하는 `make_v2v_xml.sh`, `run_qemu_ova_pipeline.sh` 기준 사용법입니다.  
기본 실행 위치는 스크립트가 있는 디렉터리(예: `/root/v2v`)입니다.

OLV VM Export 기능의 병렬 처리 한계로 인한 성능 저하를 개선하기 위해, Linux에서 블록 스토리지 이미지를 병렬로 수동 변환하여 타 OLV에서 인식 가능한 형식으로 이관하는 방식입니다.

## 0) 공통 설정 (import.conf)

- 기본 설정 파일: `import.conf`
- 기본 XML 출력 경로: `/data/v2v/xml`
- 스크립트는 기본적으로 `import.conf`를 자동 로드하며, 필요 시 `CONFIG_FILE=/path/to/file.conf`로 교체할 수 있습니다.

## 1) 권장 순서

1. oVirt에서 대상 VM을 내보낼 호스트(노드)로 마이그레이션하거나 해당 노드에서 기동
2. `virsh -r list`로 VM 실행 상태 확인
3. XML 생성  (VM이 위치한 리눅스 노드 - /root/v2v)
   ```bash
   bash make_v2v_xml.sh <VM_NAME>
   ```
4. `/data/v2v/xml/<VM_NAME>.xml` 생성 확인 후 VM 종료
5. `virsh -r list`로 VM 완전 종료 확인
6. 파이프라인 실행 (VM이 위치한 리눅스 노드 -  /root/v2v에서 실행, /data로 저장)
   ```bash
   bash run_qemu_ova_pipeline.sh /data/v2v/xml/<VM_NAME>.xml
   ```
7. 결과 확인
   - OVA: `/data/ova/<VM_NAME>/<VM_NAME>.ova`
   - 파이프라인 로그: `/data/v2v/<VM_NAME>/logs/pipeline-YYYY-mm-dd_HHMMSS.log`
   - 디스크 변환 로그: `/data/v2v/<VM_NAME>/logs/qemu/<VM_NAME>-diskN.log`
8. oVirt UI에서 `/data/ova/<VM_NAME>/` OVA Import
9. 네트워크 연결 및 기존 MAC Address 수동 설정 (`NIC > Edit > Manual`)

파이프라인 내부 순서:
1. `toggle_lv_from_xml.sh up`
2. `convert_disks_from_xml.sh` (디스크 병렬 변환)
3. `make_ovirt_ova.sh` (OVA 패키징)
4. 종료 시 `toggle_lv_from_xml.sh down` 자동 실행

## 2) 수동 실행 (목적 / 대표 명령어 / 옵션)

| 목적 (쉘파일) | 대표 명령어 | 옵션/기본값 |
|---|---|---|
| VM XML 생성 (`make_v2v_xml.sh`) | `bash make_v2v_xml.sh <VM_NAME>` | `XML_OUT_DIR` (기본 `/data/v2v/xml`), `LIBVIRT_URI` (기본 `qemu:///system`), `USE_DEV_PATH` (기본 `1`) |
| LV 활성/비활성/상태 (`toggle_lv_from_xml.sh`) | `bash toggle_lv_from_xml.sh /data/v2v/xml/<VM_NAME>.xml up` | 액션: `up/down/status` (기본 `up`), `UP_MODE` (기본 `ro`), `SET_PERM_ON_ACTIVE_LV` (기본 `0`) |
| 디스크 변환 (`convert_disks_from_xml.sh`) | `bash convert_disks_from_xml.sh /data/v2v/xml/<VM_NAME>.xml` | `RAW_BASE_DIR` (기본 `/data/v2v`), `PROGRESS_INTERVAL` (기본 `30`) |
| OVA 생성 (`make_ovirt_ova.sh`) | `bash make_ovirt_ova.sh /data/v2v/xml/<VM_NAME>.xml` | `OVA_BASE_DIR` (기본 `/data/ova`), `RAW_BASE_DIR` (기본 `/data/v2v`), `FORCE_BOOT_DISK_INDEX`, `TAR_PROGRESS_INTERVAL` (기본 `5`) |
| 전체 자동 실행 (`run_qemu_ova_pipeline.sh`) | `bash run_qemu_ova_pipeline.sh /data/v2v/xml/<VM_NAME>.xml` | `RAW_BASE_DIR` (기본 `/data/v2v`), `OVA_BASE_DIR` (기본 `/data/ova`), `PIPELINE_LOG_ENABLE` (기본 `1`) |

## 3) 옵션 + 명령어 사용법 (스크립트별)

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
| `XML_OUT_DIR` | `/data/v2v/xml` | XML 출력 디렉터리 | `XML_OUT_DIR=/data/custom/xml bash make_v2v_xml.sh ppcpap02` |
| `LIBVIRT_URI` | `qemu:///system` | dumpxml 조회 URI | `LIBVIRT_URI=qemu:///system bash make_v2v_xml.sh ppcpap02` |
| `USE_DEV_PATH` | `1` | `1`이면 `/rhev/...`를 `/dev/<SD>/<VOL>`로 치환 | `USE_DEV_PATH=0 bash make_v2v_xml.sh ppcpap02` |

### `toggle_lv_from_xml.sh`
기본 실행:
```bash
bash toggle_lv_from_xml.sh /data/v2v/xml/ppcpap02.xml up
```

| 옵션/인자 | 기본값 | 설명 | 명령어 예시 |
|---|---|---|---|
| 액션 인자 (`up/down/status`) | `up` | LV 활성/비활성/상태 조회 | `bash toggle_lv_from_xml.sh /data/v2v/xml/ppcpap02.xml status` |
| `UP_MODE` | `ro` | `up` 시 권한 (`ro`/`rw`) | `UP_MODE=rw bash toggle_lv_from_xml.sh /data/v2v/xml/ppcpap02.xml up` |
| `SET_PERM_ON_ACTIVE_LV` | `0` | 이미 active인 LV에도 권한 재설정 시도 | `SET_PERM_ON_ACTIVE_LV=1 UP_MODE=ro bash toggle_lv_from_xml.sh /data/v2v/xml/ppcpap02.xml up` |

### `convert_disks_from_xml.sh`
기본 실행:
```bash
bash convert_disks_from_xml.sh /data/v2v/xml/ppcpap02.xml
```

| 옵션 | 기본값 | 설명 | 명령어 예시 |
|---|---|---|---|
| `RAW_BASE_DIR` | `/data/v2v` | 이미지/로그 저장 base 경로 | `RAW_BASE_DIR=/data/v2v bash convert_disks_from_xml.sh /data/v2v/xml/ppcpap02.xml` |
| `PROGRESS_INTERVAL` | `30` | 진행률 출력 주기(초) | `PROGRESS_INTERVAL=10 bash convert_disks_from_xml.sh /data/v2v/xml/ppcpap02.xml` |

참고: `MAX_JOBS`, `OUTPUT_FORMAT`, `OUTPUT_OPTIONS` 등은 `import.conf` 또는 환경변수로 조정할 수 있습니다.

### `make_ovirt_ova.sh`
기본 실행:
```bash
bash make_ovirt_ova.sh /data/v2v/xml/ppcpap02.xml
```

디스크 직접 지정:
```bash
bash make_ovirt_ova.sh /data/v2v/xml/ppcpap02.xml \
  /data/v2v/ppcpap02/images/ppcpap02-disk1.qcow2 \
  /data/v2v/ppcpap02/images/ppcpap02-disk2.qcow2
```

| 옵션 | 기본값 | 설명 | 명령어 예시 |
|---|---|---|---|
| `RAW_BASE_DIR` | `/data/v2v` | 자동 디스크 탐색 경로 | `RAW_BASE_DIR=/data/v2v bash make_ovirt_ova.sh /data/v2v/xml/ppcpap02.xml` |
| `OVA_BASE_DIR` | `/data/ova` | OVA 출력 경로 | `OVA_BASE_DIR=/data/ova bash make_ovirt_ova.sh /data/v2v/xml/ppcpap02.xml` |
| `ENGINE_VSYSTEM_TYPE` | `ENGINE 4.1.0.0` | OVF 내 VirtualSystemType | `ENGINE_VSYSTEM_TYPE='ENGINE 4.1.0.0' bash make_ovirt_ova.sh /data/v2v/xml/ppcpap02.xml` |
| `TAR_PROGRESS_INTERVAL` | `5` | 패킹 진행률 출력 주기(초) | `TAR_PROGRESS_INTERVAL=2 bash make_ovirt_ova.sh /data/v2v/xml/ppcpap02.xml` |
| `FORCE_BOOT_DISK_INDEX` | 자동 | 부팅 디스크 순번 강제 | `FORCE_BOOT_DISK_INDEX=1 bash make_ovirt_ova.sh /data/v2v/xml/ppcpap02.xml` |
| `FORCE_OVF_DISK_FORMAT_URI` | 자동 | OVF format URI 강제 | `FORCE_OVF_DISK_FORMAT_URI='http://www.gnome.org/~markmc/qcow-image-format.html' bash make_ovirt_ova.sh /data/v2v/xml/ppcpap02.xml` |
| `FORCE_OVF_VOLUME_FORMAT` | 자동 | OVF volume format 강제 | `FORCE_OVF_VOLUME_FORMAT=COW bash make_ovirt_ova.sh /data/v2v/xml/ppcpap02.xml` |
| `FORCE_OVF_VOLUME_TYPE` | 자동 | OVF volume type 강제 | `FORCE_OVF_VOLUME_TYPE=Sparse bash make_ovirt_ova.sh /data/v2v/xml/ppcpap02.xml` |

### `run_qemu_ova_pipeline.sh`
기본 실행:
```bash
bash run_qemu_ova_pipeline.sh /data/v2v/xml/ppcpap02.xml
```

| 옵션 | 기본값 | 설명 | 명령어 예시 |
|---|---|---|---|
| `RAW_BASE_DIR` | `/data/v2v` | 변환 이미지/로그 base 경로 | `RAW_BASE_DIR=/data/v2v bash run_qemu_ova_pipeline.sh /data/v2v/xml/ppcpap02.xml` |
| `OVA_BASE_DIR` | `/data/ova` | OVA 출력 base 경로 | `OVA_BASE_DIR=/data/ova bash run_qemu_ova_pipeline.sh /data/v2v/xml/ppcpap02.xml` |
| `PIPELINE_LOG_ENABLE` | `1` | `0`이면 tee 로그 비활성 | `PIPELINE_LOG_ENABLE=0 bash run_qemu_ova_pipeline.sh /data/v2v/xml/ppcpap02.xml` |

## 4) 예시 출력

### 4-1. XML 생성
```text
[2026-02-19 08:57:01] START make_v2v_xml vm=ppcpap02 uri=qemu:///system output=/data/v2v/xml/ppcpap02.xml
[2026-02-19 08:57:02] DONE make_v2v_xml created=/data/v2v/xml/ppcpap02.xml
```

### 4-2. 파이프라인 실행
```text
[2026-02-19 08:57:06] START run_qemu_ova_pipeline xml=/data/v2v/xml/ppcpap02.xml
[2026-02-19 08:57:06] [1/3] activate lv
[2026-02-19 08:57:25] [2/3] convert disks (parallel)
[2026-02-19 09:11:40] [3/3] build ova
[2026-02-19 09:18:10] [4/4] deactivate lv
[2026-02-19 09:18:11] DONE run_qemu_ova_pipeline
[2026-02-19 09:18:11] ova : /data/ova/ppcpap02/ppcpap02.ova
```

### 4-3. 수동 실행 예시
```bash
bash toggle_lv_from_xml.sh /data/v2v/xml/ppcpap02.xml up
bash convert_disks_from_xml.sh /data/v2v/xml/ppcpap02.xml
bash make_ovirt_ova.sh /data/v2v/xml/ppcpap02.xml
bash toggle_lv_from_xml.sh /data/v2v/xml/ppcpap02.xml down
```
