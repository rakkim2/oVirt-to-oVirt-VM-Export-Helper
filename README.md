# OLV (oVirt) VM Helper (Export + Import)

> 중요: `main` 브랜치는 **Export + Import** 사용법 기준입니다.  
> Export 전용 고정 버전은 `codex/export-only` 브랜치 또는 `v1.0.0` 태그를 사용하세요.

## 1) 빠른 시작

실행 위치 예시: `/data/script`

1. XML 생성
```bash
bash make_v2v_xml.sh <VM_NAME>
```

2. VM 종료 확인
```bash
virsh -r list
```

3. Export 파이프라인 실행 (LV up -> convert -> OVA -> LV down)
```bash
bash run_qemu_ova_pipeline.sh /data/v2v/xml/<VM_NAME>.xml
```

4. Import 실행 (remote: 소스에서 타겟 호스트로 원격 실행)
```bash
CONFIG_FILE=/data/script/v2v.conf \
bash import_v2v.sh --run-location=remote <VM_NAME>
```

5. Import 사전 점검만 실행
```bash
CONFIG_FILE=/data/script/v2v.conf \
bash import_v2v.sh --run-location=remote --check <VM_NAME>
```

## 2) 설정 파일

현재 `main`은 설정 파일이 2개 역할로 나뉩니다.

1. `import.conf`  
- Export 파이프라인(`run_qemu_ova_pipeline.sh`) 계열 기본값
- 예: `RAW_BASE_DIR`, `OVA_BASE_DIR`, `XML_OUT_DIR`

2. `v2v.conf`  
- Import(`import_v2v.sh`) 계열 설정
- 최소 필수값 예시:
```bash
DATA_BASE_DIR="/data"
SCRIPT_BASE_DIR="${DATA_BASE_DIR}/script"
IMPORT_CSV_PATH="${SCRIPT_BASE_DIR}/vmlist.csv"
RHV_ENGINE_URL="https://<engine>/ovirt-engine/api"
RHV_PASS_FILE="${SCRIPT_BASE_DIR}/engine-passwd"
REMOTE_TARGET_HOST="<target-host-ip>"
REMOTE_SSH_PASS_FILE="${SCRIPT_BASE_DIR}/remote-target-passwd"
```

## 3) 대표 명령어

1. 전체 Export 파이프라인
```bash
bash run_qemu_ova_pipeline.sh /data/v2v/xml/<VM_NAME>.xml
```

2. Import만 단독 실행 (remote)
```bash
CONFIG_FILE=/data/script/v2v.conf \
bash import_v2v.sh --run-location=remote <VM_NAME>
```

3. Import만 단독 실행 (target에서 직접)
```bash
CONFIG_FILE=/data/script/v2v.conf \
bash import_v2v.sh --run-location=targetspm <VM_NAME>
```

4. Import check-only
```bash
CONFIG_FILE=/data/script/v2v.conf \
bash import_v2v.sh --run-location=remote --check <VM_NAME>
```

## 4) 로그 위치

1. Export 파이프라인 로그  
`/data/v2v/<VM_NAME>/logs/pipeline-YYYY-mm-dd_HHMMSS.log`

2. 디스크 변환 로그  
`/data/v2v/<VM_NAME>/logs/qemu/<VM_NAME>-diskN.log`

3. Import 로그  
`/data/v2v_log/<VM_NAME>/import_v2v-YYYY-mm-dd_HHMMSS.log`

4. Import runtime XML (자동 생성)  
`/data/v2v_log/<VM_NAME>/<VM_NAME>-import-runtime-YYYY-mm-dd_HHMMSS.xml`

## 5) 자주 쓰는 점검

1. Import 옵션 도움말
```bash
bash import_v2v.sh --help
```

2. 원격 import 경로 점검
```bash
CONFIG_FILE=/data/script/v2v.conf \
bash import_v2v.sh --run-location=remote --check <VM_NAME>
```

3. 실패 시 우선 확인
- `RHV_ENGINE_URL` 형식 (`https://.../ovirt-engine/api`)
- `RHV_PASS_FILE`, `REMOTE_SSH_PASS_FILE` 파일 경로
- 타겟 호스트 SSH 접속 가능 여부
- CSV의 VM/Cluster/Storage 매핑
