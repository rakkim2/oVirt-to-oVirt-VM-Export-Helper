# VirtShift (ZeroTouch OLV Migration Engine)

## 프로젝트 소개
`VirtShift (ZeroTouch OLV Migration Engine)`는 OLV 간 대량 VM 이관을 위한 **멀티 실행 엔진**입니다.
핵심은 다음 2가지 병렬화입니다.

- **다중 VM 동시 실행**: VM별 독립 파이프라인을 동시에 운영
- **VM 내부 디스크 병렬 변환**: `MAX_JOBS` 기반 `qemu-img convert` 병렬 처리

즉, 기존의 “한 대씩 수동 처리” 방식을 “배치 단위 동시 처리”로 바꿔, 운영 속도와 재현성을 함께 확보하는 것이 목적입니다.

## 왜 만들었는지
- OLV에서 Export/Import Job을 여러 개 제출해도 실제 디스크 처리 구간은 직렬화되는 사례가 반복됨
- 수동 절차(메타데이터 확인, 디스크 변환, Import, 검증)로 인해 인적 오류와 재작업이 누적됨
- 대개체 이관에서 VM 수 증가에 따라 총 소요 시간과 운영 리스크가 함께 커짐

## 이 프로젝트의 의미 (운영 관점)
- **처리량 관점**: 단일 작업 최적화가 아니라, “동시 실행 가능한 총 VM 수”를 늘리는 구조
- **예측 가능성 관점**: 단계/로그/실패 포인트가 표준화되어 배치 일정 산정이 쉬움
- **안정성 관점**: lock, stop, stale 정리로 동시 실행 중 충돌/중복 리스크를 관리
- **운영성 관점**: 담당자마다 방식이 달라도 결과가 달라지지 않도록 실행 경로를 고정

## 무엇을 바꿨는지 (핵심 구현)
- VM 메타데이터(XML/런타임 Import XML) 생성/보정 자동화
- `qemu-img` 병렬 변환(`MAX_JOBS`) 기반 처리량 확대
- 원격 Import 표준화 및 중복 실행 방지(lock/stale 정리)
- `run_virtshift.sh` 중심 단일 진입 실행 모델 정착

## 문서 안내
- 운영 사용 방법(SOP): `USAGE.md`
- 설정/튜닝 가이드: `CONFIG_GUIDE.md`
- 개발 이력/개선 내용: `DEV.md`
- 운영 공유본 요약(KR): `CONFLUENCE_SOP_KR.md`
- English README: `README.en.md`
