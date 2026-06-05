# VirtShift (ZeroTouch OLV Migration Engine) 개발 이력

기준일: 2026-03-21

## 0. 이 개발이 의미하는 것 (핵심)
- 이 프로젝트의 핵심 가치는 **멀티 실행 가능성**입니다.
- 개선 포인트는 “개별 스크립트 기능 추가”가 아니라, 아래 2가지를 운영 표준으로 만든 것입니다.
  - **다중 VM 동시 실행**
  - **VM 내부 디스크 병렬 변환(`MAX_JOBS`)**
- 결과적으로 이관 운영 단위가 “VM 1대”에서 “배치 전체 처리량”으로 바뀌었습니다.

## 1. 개발 목표
- OLV 기본 Export/Import 경로의 직렬 처리 병목 완화
- 수동 절차를 파이프라인으로 통합해 운영 리드타임 단축
- 대개체 이관에서 재실행 안정성과 장애 분석 속도 향상

## 2. 아키텍처 개선 내역
| 구분 | 기존 | 개선 |
|---|---|---|
| 실행 진입점 | 단계별 수동 실행 | `run_virtshift.sh` 단일 진입 |
| 메타데이터 처리 | 수동/정적 XML 의존 | 런타임 XML 생성/보정 자동화 |
| 변환 처리 | 체감상 직렬 중심 | 디스크 단위 병렬 변환(`MAX_JOBS`) |
| Import 위치 | 실행 위치 편차 | 원격 타깃 실행 표준화 |
| 운영 제어 | 중복 실행/중지 제어 취약 | lock/stale 정리, `--stop` 지원 |

운영적 의미:
- 파이프라인 단일 진입 + lock 체계 덕분에 **여러 VM을 동시에 돌려도 충돌을 관리 가능한 구조**가 됨
- 변환 병렬화 덕분에 **VM 단위 소요시간 단축 + 배치 총 처리량 증가**를 동시에 노릴 수 있게 됨

## 3. 로직 단계 (XML -> QEMU -> OVA/Import)

### 3.1 표준 실행 진입점
```bash
bash run_virtshift.sh <VM_NAME>
```

### 3.2 단계별 처리 로직 (전체 파이프라인 기준)
| 단계 | 스크립트 | 입력 | 출력 | 핵심 로직 |
|---|---|---|---|---|
| 1. VM 메타 추출/정규화 | `make_v2v_xml.sh` | VM 이름, libvirt 메타 | `/data/xml/<VM_NAME>.xml` | 디스크/버스/네트워크 정보를 이관 기준 XML로 정리 |
| 2. 소스 디스크 활성화 | `toggle_lv_from_xml.sh up` | VM XML | 활성 LV 디바이스 | 변환 대상 LV를 읽기 가능 상태로 활성화 |
| 3. 디스크 변환 (병렬) | `convert_disks_from_xml.sh` | VM XML, LV 디바이스 | `/data/v2v/qemu/<VM_NAME>/<VM_NAME>-diskN.qcow2` | `qemu-img convert` 병렬 수행(`MAX_JOBS`), 포맷 자동 감지 |
| 4. OVA 스테이징/패키징 | `make_ovirt_ova.sh` | VM XML, 변환 디스크 | `/data/v2v/<VM_NAME>.ova` | OVF 메타 생성/보정 후 tar 패키징 |
| 5. 타깃 Import | `import_v2v.sh` | VM 이름, 변환 디스크, 타깃 설정값 | 타깃 OLV VM/디스크 등록 | `virt-v2v -o rhv-upload` 기반 원격 Import 실행/검증 |
| 6. 후처리 | `toggle_lv_from_xml.sh down` | VM XML | 비활성 LV, 로그 | LV down 및 실행 결과 로그 정리 |

### 3.3 OVA 단계에서 보정한 핵심 항목
- OVF의 `format/fileRef/interface`를 실제 산출물과 일치하도록 정합성 보정
- `virtio-scsi` 관련 controller/serial 누락 방지 로직 반영
- 패키징 실패 시 재시도 가능한 스테이징 구조 유지

### 3.4 운영 모드 분기
- OVA 산출물 모드: 1 -> 2 -> 3 -> 4 -> 6
- Direct Import 모드(`IMPORT_TO_RHV=true`): 1 -> 2 -> 3 -> 5 -> 6
- 혼합 운영 시: OVA 생성 후 필요 시 Import 단계를 별도 수행 가능

### 3.5 Import 단계 상세 (운영 기준)
- 실행 위치: 원격 타깃 노드(`--run-location=remote`) 기준으로 표준화
- 입력 매핑: VM/Cluster/Storage 매핑 정보(`vmlist.csv`) 기반 타깃 배치
- 보호 로직: import lock으로 중복 실행 차단, 실패 시 tail 로그 자동 수집

## 4. 주요 버그 수정 이력
| ID | 이슈 | 영향 | 수정 내용 |
|---|---|---|---|
| C-01 | `INPUT_FORMAT=raw` 고정 | qcow2 오해석, 부팅 실패 가능 | `INPUT_FORMAT=auto` + `qemu-img info` 자동 감지 |
| C-02 | OVF 메타 불일치(`format/fileRef/interface`) | OVA import 실패/불완전 import | 실제 산출물 기준 메타 정합성 보정 |
| C-03 | `virtio-scsi` 컨트롤러/serial 누락 | import 실패 또는 디스크 식별 오류 | controller 자동 추가, serial 보존 |
| C-05 | `No bootable device`/데이터 0 import | 컷오버 실패 | 변환-메타-Import 검증 단계 분리 |
| C-06 | conf 로드 시 env override 소실 | 원격 타깃/옵션 오적용 | env 우선 재적용 + fallback 파서 |
| C-08 | import가 소스에서 실행되는 경로 | RHV direct import 실패 가능 | 타깃 원격 실행 표준화 + precheck |
| O-01 | LV up/down 멱등성 부족 | 재실행 실패/중단 | active 처리 + down retry/권한 검증 강화 |
| O-02 | 동일 VM 중복 실행 | 데이터/락 충돌 위험 | VM/import lock 분리 + stale lock 정리 |
| O-03 | nohup 작업 종료 불편 | 운영자 수동 kill 부담 | `--stop` 기반 프로세스 트리 종료 추가 |
| O-05 | 실패 원인 추적 지연 | 분석 시간 증가 | 실패 시 스크립트/qemu 로그 tail 자동 수집 |

## 5. 성능 개선 항목
| 항목 | 개선 포인트 | 기대 효과 |
|---|---|---|
| 변환 병렬화 | `qemu-img convert` 병렬 실행 | Export 구간 처리량 향상 |
| OVA 단계 최적화 | `IMPORT_TO_RHV=true` 시 OVA skip | 불필요 I/O 제거 |
| Import 표준화 | remote import 단일 경로화 | 재시도/실패율 감소 |
| 장애 분석 자동화 | 실패 컨텍스트 자동 덤프 | MTTR 단축 |

해석 포인트:
- 이 표의 의미는 “개별 기능 개선”이 아니라, **동시 처리량(throughput) 중심 운영 모델로 전환**되었다는 점입니다.
- 즉, 성능 개선의 기준이 단일 VM 속도만이 아니라 **차수당 처리 가능한 VM 수**로 이동했습니다.

## 6. 운영 안정화 항목
| 항목 | 내용 |
|---|---|
| 실행 충돌 방지 | lock 체계 도입 및 stale lock 정리 |
| 중지 제어 | `run_virtshift.sh --stop <VM_NAME>` |
| 상태 관측 | `show_v2v_status.sh`, `status_board.log` |
| 결과 집계 | `result.log` 기반 성공/실패 추적 |

## 7. 관련 문서
- 운영 SOP: `USAGE.md`
- 설정 가이드: `CONFIG_GUIDE.md`
- 원본 장애 로그(히스토리): `THREAD_BUGFIX_LOG.md`
