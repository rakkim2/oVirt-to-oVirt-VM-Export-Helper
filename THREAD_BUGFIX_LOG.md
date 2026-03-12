# oVirt VM Export/Import Thread Bugfix Log (핵심 요약판)

작성일: 2026-03-07  
범위: 초기 스레드 로그 + 현재 스레드 로그 병합본(운영 영향이 큰 항목만 유지)

## 1) 목적
- oVirt VM을 XML 기반으로 추출/변환하여 OVA로 가져가는 과정에서, 재현된 장애와 확정 조치를 기록한다.
- 이후 동일 작업 시 "무엇을 먼저 확인해야 하는지"를 빠르게 찾는 용도로 사용한다.

## 2) 현재 표준 구조 (정착안)

### 설정 파일
- 기본: `/data/script/v2v.conf`

### 산출물
- `/data/xml/<vm>.xml`
- `/data/v2v/qemu/<vm>/<vm>-diskN.qcow2`
- `/data/v2v/ova/ova_stag/<vm>/...`
- `/data/v2v/<vm>.ova`

### 로그
- `/data/v2v_log/<vm>/pipeline-*.log`
- `/data/v2v_log/<vm>/nohup-*.log`
- `/data/v2v_log/<vm>/convert_disks_from_xml-*.log`
- `/data/v2v_log/<vm>/qemu/<vm>-diskN.log`
- `/data/v2v_log/<vm>/make_ovirt_ova-*.log`
- `/data/v2v_log/<vm>/toggle_lv_from_xml-*.log`

## 3) 핵심 이슈/조치 (중요도순)

| ID | 이슈 | 영향 | 최종 조치 | 상태 |
|---|---|---|---|---|
| C-01 | `INPUT_FORMAT=raw` 고정 | qcow2 소스 오해석, import 후 부팅 실패 가능 | `INPUT_FORMAT=auto`로 전환, 디스크별 `qemu-img info` 감지 | 해결 |
| C-02 | OVF 메타 불일치(`format`, `fileRef`, interface) | OVA import 실패/껍데기 import | OVF 디스크 메타와 실제 파일/포맷 정합성 보정 | 해결 |
| C-03 | `VirtIO_SCSI` 미지원 클러스터 | `CANNOT_PERFORM_ACTION_VIRTIO_SCSI_IS_DISABLED` | 클러스터 설정 또는 OVF disk-interface를 `VirtIO`로 변경 | 해결 |
| C-04 | 스냅샷 VM에서 과거 데이터 복제 | 최신 상태 아닌 오래된 시점 복구 | snapshot 체인/활성 레이어 기준 소스 확인 절차 명문화 | 해결(운영 절차) |
| C-05 | `No bootable device` / 데이터 0 import | 컷오버 실패 | 변환/OVF/import 검증 단계를 분리하고 매핑 재검증 | 해결(케이스별) |
| C-06 | conf 로드 시 env override 소실 | 원격 타겟/옵션 전달 실패 | 스크립트별 env 우선 재적용 로직 추가 | 해결 |
| C-07 | `virtio-scsi` 디스크 XML에서 컨트롤러/serial 누락 | import 실패 또는 guest 디스크 식별 불일치 | `scsi` bus 유지 시 controller 자동 추가, disk serial 보존 | 해결 |
| C-08 | import 단계가 소스 호스트에서 실행됨 | RHV direct import 실패 가능 | pipeline에서 target 원격 실행으로 변경 + precheck 강제 | 해결 |
| O-01 | LV up/down 멱등성 부족 | 재실행 시 실패/중단 | active 상태 처리, down retry/권한 검증 강화 | 해결 |
| O-02 | 동일 VM 중복 실행 | 데이터/락 충돌 위험 | VM lock 도입 + stale lock 자동 정리 | 해결 |
| O-03 | nohup 종료 불편 | 운영자가 수동 kill 절차 부담 | `run_qemu_ova_pipeline.sh --stop <vm>` 추가(트리 종료) | 해결 |
| O-04 | 단계별 로그 가시성 부족 | 원인 분리 어려움 | 모든 주요 스크립트에 실행 명령/rc/경로 로그 강화 | 해결 |
| O-05 | 실패 시 원인 추적 지연 | 장애 분석 시간 증가 | pipeline 실패 시 최신 스크립트/qemu 로그 tail 자동 덤프 | 해결 |

## 4) 운영 표준 명령

### 기본 실행
```bash
bash make_v2v_xml.sh <VM_NAME>
bash run_qemu_ova_pipeline.sh /data/xml/<VM_NAME>.xml
```

### 중지 (편의)
```bash
bash run_qemu_ova_pipeline.sh --stop <VM_NAME>
```

### 중요 옵션 (현재)
- `CONFIG_FILE=/data/script/v2v.conf` (기본값도 `v2v.conf`)
- `VIRTIOSCSITOVIRTIO_CHANGE=false` (기본: `scsi` 강제 변경 안 함)
- `BUILD_OVA=true|false`
- `RUN_WITH_NOHUP=true|false`
- `FAILURE_TAIL_LINES` (실패 시 tail 라인 수)
- `FAILURE_QEMU_LOG_COUNT` (실패 시 덤프할 qemu 로그 개수)
- `STOP_WAIT_SECONDS` (`--stop`에서 TERM 대기 시간)

## 5) 트러블슈팅 우선 체크리스트

1. 소스 VM이 완전히 꺼졌는지 확인 (`virsh -r list`).
2. 변환 로그에서 실제 입력 포맷 감지값 확인 (`input format:`).
3. OVA 로그에서 스테이징 방식 확인 (`ln`/`cp`, `tar` command).
4. 실패 시 pipeline 로그의 자동 tail 덤프 구간부터 먼저 확인.
5. snapshot VM은 활성 레이어 기준인지 재확인.
6. 타깃 클러스터의 `VirtIO_SCSI` 지원 여부 확인.

## 6) 문서 사용 원칙
- 이 파일은 "핵심 장애 + 확정 조치"만 유지한다.
- 경미한 로그 파싱 튜닝, 일시적 실수, 반복 대화성 항목은 제외한다.
- 신규 이슈 추가 시 반드시 아래 형식으로만 기록한다:
  - 이슈 / 영향 / 최종 조치 / 상태
