# VirtShift (ZeroTouch OLV Migration Engine) CONFIG GUIDE

## 1. 설정 파일 로드 원칙
- 기본 설정 파일: `v2v.conf`
- 기본 권장 위치: `/data/script/v2v.conf`
- 기본 로딩 위치: 스크립트 실행 디렉터리(일반적으로 `/data/script`)
- 대체 설정 파일 사용:
```bash
CONFIG_FILE=/path/to/file.conf bash run_virtshift.sh <VM_NAME>
```

초기 생성 예시:
```bash
cd /data/script
cp v2v.conf.origin v2v.conf
```

## 2. 필수 설정 키
아래 항목은 **전부 필수**입니다. 하나라도 비어 있으면 실행 중 실패할 수 있습니다.

| 키 | 설명 | 예시 |
|---|---|---|
| `DATA_BASE_DIR` | 데이터 루트 경로 | `/data` |
| `SCRIPT_BASE_DIR` | 스크립트 경로 | `/data/script` |
| `RHV_ENGINE_URL` | 타깃 RHV/OLV 엔진 주소 | `10.4.157.38` |
| `RHV_PASS_FILE` | 엔진 인증 파일 | `/data/script/engine-passwd` |
| `REMOTE_TARGET_HOST` | 타깃 실행 노드 | `10.4.157.236` |
| `REMOTE_SSH_PASS_FILE` | 타깃 SSH 인증 파일 | `/data/script/remote-target-passwd` |
| `IMPORT_CSV_PATH` | Import VM 매핑 CSV 경로 | `/data/script/vmlist.csv` |

권장 최소 템플릿:
```bash
DATA_BASE_DIR="/data"
SCRIPT_BASE_DIR="${DATA_BASE_DIR}/script"
RHV_ENGINE_URL="10.4.157.38"
RHV_PASS_FILE="${SCRIPT_BASE_DIR}/engine-passwd"
REMOTE_TARGET_HOST="10.4.157.236"
REMOTE_SSH_PASS_FILE="${SCRIPT_BASE_DIR}/remote-target-passwd"
IMPORT_CSV_PATH="${SCRIPT_BASE_DIR}/vmlist.csv"
```

## 2.1 CSV 키 입력 예제
`IMPORT_CSV_PATH`에 지정한 CSV 파일은 아래 형식으로 입력합니다.

```csv
vm_name,cluster,storage_domain
vmapp01,OSS-Cluster,OSS-Storage01
vmapp02,OSS-Cluster,OSS-Storage02
```

## 3. 파이프라인 제어 옵션
| 키 | 기본값 | 설명 |
|---|---|---|
| `IMPORT_TO_RHV` | `false` | `true`면 Import 수행, OVA 생성 단계 skip |
| `BUILD_OVA` | `true` | OVA 생성 여부 |
| `RUN_WITH_NOHUP` | `true` | 백그라운드 실행 여부 |
| `VM_LOCK_BASE_DIR` | `/data/v2v/locks` | 중복 실행 방지 lock 경로 |
| `FAILURE_TAIL_LINES` | `120` | 실패 시 로그 tail 라인 수 |
| `FAILURE_QEMU_LOG_COUNT` | `3` | 실패 시 덤프할 qemu 로그 개수 |
| `STOP_WAIT_SECONDS` | `10` | `--stop` 시 TERM 대기 시간 |

## 4. 성능 튜닝 옵션
| 키 | 기본값 | 운영 권장 |
|---|---|---|
| `MAX_JOBS` | `4` | 스토리지/CPU 상황에 맞춰 2~8 범위 조정 |
| `INPUT_FORMAT` | `auto` | 자동 감지 유지 권장 |
| `OUTPUT_FORMAT` | `qcow2` | 타깃 정책에 따라 조정 |
| `OUTPUT_OPTIONS` | `compat=1.1,lazy_refcounts=off,cluster_size=65536` | 기본 유지 권장 |
| `COROUTINES` | `8` | 고성능 노드에서 상향 검토 |
| `CACHE_MODE` | `writeback` | 기본 유지 |
| `SRC_CACHE_MODE` | `none` | 기본 유지 |
| `RECREATE_OUTPUT_ON_RETRY` | `1` | 재시도 시 출력 파일 재생성 |

## 5. Import 관련 옵션
| 키 | 기본값 | 설명 |
|---|---|---|
| `REMOTE_TARGET_USER` | `root` | 원격 실행 사용자 |
| `REMOTE_SSH_PORT` | `22` | SSH 포트 |
| `REMOTE_IMPORT_SCRIPT` | `${SCRIPT_BASE_DIR}/import_v2v.sh` | 원격 Import 실행 스크립트 |
| `IMPORT_CSV_PATH` | `${SCRIPT_BASE_DIR}/vmlist.csv` | VM별 cluster/storage 기본 매핑 CSV |
| `RHV_USERNAME` | `admin@internal` | RHV 로그인 사용자 |
| `RHV_DIRECT` | `true` | RHV direct import 사용 |
| `V2V_OUTPUT_FORMAT` | `raw` | import 대상 포맷 |
| `V2V_OUTPUT_ALLOCATION` | `preallocated` | 할당 정책 |
| `V2V_VERBOSE` | `true` | verbose 로그 여부 |

## 6. XML/디스크 관련 옵션
| 키 | 기본값 | 설명 |
|---|---|---|
| `USE_DEV_PATH` | `1` | 디스크 경로 해석 방식 |
| `VIRTIOSCSITOVIRTIO_CHANGE` | `false` | VirtIO-SCSI -> VirtIO 강제 변환 여부 |
| `INCLUDE_NETWORK` | `true` | XML에 네트워크 포함 여부 |

## 7. 스크립트별 자주 쓰는 오버라이드
### XML 생성
```bash
XML_OUT_DIR=/data/xml bash make_v2v_xml.sh <VM_NAME>
```

### 변환 병렬도 조정
```bash
MAX_JOBS=6 bash convert_disks_from_xml.sh /data/xml/<VM_NAME>.xml
```

### Import 포함 파이프라인
```bash
IMPORT_TO_RHV=true bash run_virtshift.sh <VM_NAME>
```

### 원격 Import 단독
```bash
bash import_v2v.sh --run-location=remote <VM_NAME>
```

## 8. 운영 권장값 (초기 기준)
- `INPUT_FORMAT=auto`
- `MAX_JOBS=4` (초기)
- `IMPORT_TO_RHV=true` (실운영 컷오버 배치 시)
- `RUN_WITH_NOHUP=true`
- 문제 재현/분석 시 `V2V_VERBOSE=true` 유지
