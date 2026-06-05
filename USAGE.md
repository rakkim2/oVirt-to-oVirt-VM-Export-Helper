# VirtShift (ZeroTouch OLV Migration Engine) USAGE

## 1. 목적
이 문서는 `VirtShift (ZeroTouch OLV Migration Engine)`의 운영 사용 방법을 SOP 관점으로 정리한 문서입니다.

## 2. 사전 점검
| 항목 | 확인 내용 |
|---|---|
| VM 상태 | 소스 VM이 완전히 종료되어 있어야 함 (`virsh -r list` 미노출) |
| 공유 볼륨 경로 | 소스/타깃 모두 공유 볼륨으로 접근 가능 (기본: `/data`) |
| 필수 사전 설정 | `/data/script/v2v.conf` 작성은 `CONFIG_GUIDE.md` 참고 |
| Import VM 정보 입력 | `/data/script/vmlist.csv` 입력 필요 (수동 설정은 8.2 참고) |

## 3. 표준 운영 절차
### 3.1 XML 생성
```bash
cd /data/script
bash make_v2v_xml.sh <VM_NAME>
```

### 3.2 One-click 파이프라인 실행 (권장)
```bash
cd /data/script
bash run_virtshift.sh <VM_NAME> (or XML 지정 /data/xml/<VM_NAME>.xml)
```

### 3.3 상태 확인
```bash
bash show_v2v_status.sh <VM_NAME>
watch -n 1 "bash show_v2v_status.sh <VM_NAME>"
```

### 3.4 중지
```bash
bash run_virtshift.sh --stop <VM_NAME>
```

## 4. 운영 모드

### 4.1 Import 단독 실행
파이프라인 실행 후 Import 단계가 실패한 경우, 아래 명령으로 단독 재실행합니다.
```bash
bash import_v2v.sh --run-location=remote <VM_NAME>
```

## 5. 로그 및 산출물 경로
| 구분 | 경로 |
|---|---|
| XML | `/data/xml/<VM_NAME>.xml` |
| 변환 산출물 | `/data/v2v/qemu/<VM_NAME>/` |
| 로그 루트 | `/data/v2v_log/<VM_NAME>/` |
| 전체 결과 | `/data/v2v_log/result.log` |
| 상태 집계 | `/data/v2v_log/status_board.log` |
| 파이프라인 로그 | `/data/v2v_log/<VM_NAME>/pipeline_<YYYY-mm-dd_HHMMSS>.log` |
| Import 로그 | `/data/v2v_log/<VM_NAME>/import_v2v-<YYYY-mm-dd_HHMMSS>.log` |
| qemu 로그 | `/data/v2v_log/<VM_NAME>/qemu/<VM_NAME>-diskN.log` |

## 6. 장애 발생 시 우선 확인
| 증상 | 1차 원인 후보 | 조치 |
|---|---|---|
| `failed to get "write" lock` | 기존 변환 프로세스가 출력 파일 점유 | 기존 PID 종료 후 실패 디스크 파일 정리, 단일 VM 재실행 |
| `HTTP 409 duplicates in target MAC pool` | 타깃 엔진 MAC pool 충돌 | 타깃 VM NIC MAC 확인/조정 후 재시도 |
| `${SCRIPT_BASE_DIR}/... not found` | 설정 경로 치환 실패 | `v2v.conf`에 절대 경로(`/data/script/...`) 명시 |
| `The storage domain '' does not exist` | CSV 매핑 누락 | `vmlist.csv`의 `vm,cluster,storage` 매핑 수정 |

## 7. 운영 권장 순서 요약
1. VM 종료 확인
2. `make_v2v_xml.sh` 실행
3. `run_virtshift.sh` 실행
4. `show_v2v_status.sh`로 상태 추적
5. 실패 시 로그 우선 확인 후 재실행

## 8. 수동 인자 입력 예시 (고급, 문서 뒤쪽)
기본 운영은 `v2v.conf + CSV`를 사용하고, 아래는 1회성 수동 오버라이드가 필요할 때만 사용합니다.

### 8.1 run qemu 파이프라인 수동 인자
```bash
CONFIG_FILE=/data/script/v2v.conf \
MAX_JOBS=6 \
IMPORT_TO_RHV=true \
bash run_virtshift.sh <VM_NAME>
```

### 8.2 import 수동 인자
```bash
RHV_ENGINE_URL="https://10.4.157.38/ovirt-engine/api" \
RHV_USERNAME="admin@internal" \
RHV_PASS_FILE="/data/script/engine-passwd" \
RHV_CLUSTER_DEFAULT="OSS-CA-4S1606-Cluster" \
RHV_STORAGE_DEFAULT="OSS-CA-4S1606-VM-Repo01" \
bash import_v2v.sh --run-location=targetspm <VM_NAME>
```
