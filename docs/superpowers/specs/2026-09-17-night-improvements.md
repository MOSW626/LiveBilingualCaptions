# 2026-09-17 야간 보완 계획

사용자 취침 중 무인 실행. 구현 sonnet, 리뷰 범위 한정. 순서는 의존성 순.

## 1. 실행 정체성을 청크 생산 시점에 찍는다 (잔여 결함 2건 동시 해소)

**증상**: `switchLanguage`가 `setLanguage` 성공 전에 `run.id`를 올리고 실패 시 되돌리지 않는다.
실패한 hot swap의 유령 청크가 새 Run과 같은 `runID`를 가질 수 있다(리뷰 확인, Medium).
같은 뿌리로 `run.language`도 emit 시점에 live로 읽어 전환 창에서 오표기된다.

**수정**: `TranscriptionChunk`(또는 결과 생산 지점)에 `runID`·`language`를 **생산 시점에** 찍고,
emit은 찍힌 값만 쓴다. `run.id`/`run.language`를 emit 경로에서 live로 읽지 않는다.
`run.id`는 swap 성공이 확정된 뒤에만 갱신한다.

**검증**: 실패하는 swap을 가짜 세션으로 만들어 유령 청크의 runID가 새 Run과 다름을 고정.
전환 직전 구제된 final이 옛 언어로 찍힘도 고정. 돌연변이(live 읽기 복원) 시 실패 확인.

## 2. 자동 언어 모드 — 파이프라인 두 벌 (사용자 선택: "제대로", 기본값 = 자동)

**제약(실측)**: 한 `SpeechAnalyzer`에 `SpeechTranscriber` 둘을 물리면 `setWorkers`에서 SIGTRAP.
→ 분석기·전사기·pump를 언어별로 **두 벌** 두고, 변환된 오디오를 양쪽에 fan-out.

**선택 규칙**: 발화 단위. 양쪽 final의 `transcriptionConfidence` 평균을 비교해 높은 쪽을 채택.
partial 단계에서는 직전 발화의 승자 언어를 임시 표시하고, final에서 확정. 채택되지 않은 쪽 결과는 버린다.
동점·둘 다 낮음이면 직전 승자 유지.

**UI**: 자동 모드가 기본. `자동 (실험)` 표기 제거 → `자동`. 상태줄에 현재 채택 언어 표시.
설정의 자동 모드 경고 문구는 "연산 2배" 안내로 교체.

**성능**: 인식 연산 2배. `AudioInputQueue` 상한(2초)은 언어별 큐에 각각 적용.
`LBC_TIMING`에 양쪽 지연을 따로 찍는다.

**검증**: 가짜 엔진 두 개로 신뢰도 우열 → 채택, 동점 → 유지, 한쪽 실패 → 다른 쪽 유지를 고정.
`./smoke.sh` 통과. 실제 음성은 `say` 파일로 ko/en 각각 올바른 언어가 채택되는지 프로브.

## 3. 정리

- 사용 안 하는 필드 제거: `TranscriptEvent.revision`, `CaptionEntry.sourceLanguageID`,
  `CaptionState.isRunning`, `AudioSourceError.permissionDenied`, `Settings.panelHeight`(디코드 호환 유지).
- README: 문장 끊기·폭 조절·자동 모드 반영. SMOKE: 자동 모드 항목 추가.

## 하지 않는 것
- 로그인 시 자동 실행(사용자: 써보고 결정).
- 설정 창 폭 숫자 입력(드래그로 충분).
