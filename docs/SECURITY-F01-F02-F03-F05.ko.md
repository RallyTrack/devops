# F01·F02·F03·F05 보안 변경 운영 안내

작성: 2026-09-16. 코드·로컬 테스트용 브랜치: `fix/security-f01-f02-f03-f05`.
Backend, Frontend, DevOps에 같은 이름의 브랜치를 사용한다. 운영 배포와 기존 키 폐기는 별도 적용 단계다.

## 변경과 계약

- F01: 브라우저의 Gemini SDK·키·직접 호출을 제거했다. 브라우저는 access 토큰으로 `POST /api/v1/videos/{videoId}/briefing`에 `{"player":"top"}` 또는 `bottom`만 전달한다. 서버가 소유권·분석 상태를 확인하고 DB 리포트로 프롬프트를 만든다. 제공자 오류 원문·헤더는 응답하지 않는다.
- F02: 영상 상세·리포트·브리핑은 `videoId + userId + deletedAt IS NULL + status != DELETED`를 만족해야 조회한다. 권한 확인 전에 S3 URL을 서명하거나 제공자를 호출하지 않는다.
- F03: 일반 API는 만료되지 않은 `token_type=access`만, 갱신은 DB 검증과 `token_type=refresh`를 함께 요구한다. 타입·만료·사용자 ID가 없는 토큰도 거부한다. 같은 초의 정상 갱신에서 발생한 unique 충돌은 삭제 flush 순서로 수정했다.
- F05: 두 파일과 메타데이터를 모두 검사한 후 저장한다. 실제 영상 컨테이너·스트림 검사, 썸네일 JPEG 재인코딩, UUID 객체 키, 서버가 정한 MIME, 파일 스트리밍 업로드를 사용한다. 기존 미디어에도 강제 CSP sandbox·nosniff·위험 형식 attachment·no-store를 적용한다.

성공 응답의 기존 필드와 AI 콜백 계약, DB 스키마는 유지한다. 오류에는 선택적 `errorCode`가 추가된다.

| 상태 | HTTP | errorCode |
|---|---:|---|
| 타인·삭제·없는 영상·소유자 없음 | 404 | RESOURCE_NOT_FOUND |
| 본인 영상 분석 중 | 404 | ANALYSIS_NOT_READY |
| 분석 실패 | 409 | ANALYSIS_FAILED |
| 완료지만 결과 없음 | 409 | ANALYSIS_RESULT_UNAVAILABLE |
| 브리핑 비활성·키 없음 | 503 | BRIEFING_UNAVAILABLE |
| 브리핑 한도 초과 | 429 | BRIEFING_RATE_LIMIT |
| 제공자 실패·잘못된 응답 | 502 | BRIEFING_PROVIDER_ERROR |
| 제공자 시간 초과 | 504 | BRIEFING_TIMEOUT |

## 데이터 흐름과 저장

원본과 썸네일의 DB `s3Url`, `thumbnailUrl`은 객체 키다. Backend가 검증 파일을 저장하고 키를 DB에 넣는다. 브라우저에는 소유권 확인 후 1시간 presigned GET을 발급한다. AI 서버에는 별도 LAN presigned GET/PUT을 전달하고, AI 콜백은 스켈레톤·미니맵 **객체 키**를 저장한다. 일반 URL과 객체 키를 서로 대체하지 않는다.

검증 실패는 DB/S3/AI 쓰기 전에 종료한다. 저장 도중 실패하면 이미 쓴 객체 삭제를 시도한다. 기존 AI 요청 실패의 PROCESSING 잔류와 스토리지/DB 전체 분산 트랜잭션 문제는 이번 수정에서 해결한 것으로 간주하지 않는다.

브리핑 캐시는 소유권 확인 뒤에만 읽는다. 사용자·영상·선수·모델·프롬프트 버전·실제 프롬프트 digest를 키로 사용하므로 점수·분석값 변경 시 이전 결과를 재사용하지 않는다. 프론트의 기존 localStorage 브리핑 캐시는 더 이상 읽지 않는다. 최신 UI의 5개 H2 섹션과 선수별 타격 분류를 서버에 옮겼다. 모델 선택도 최신 develop의 `gemini-3.6-flash`를 유지한다.

## 고정된 자원 제한

- 브리핑: 생성 요청 사용자별 분당 6회, 프로세스 전체 분당 30회, 동시에 2개. 동일 요청은 합친다. 캐시 최대 256개·30분. 입력 12,000자, 제공자 응답 64KiB, 결과 8,000자, 생성 1,500 토큰, 전체 요청 30초 제한.
- 제한·캐시는 단일 프로세스 메모리 기준이며 재시작 시 초기화된다. 다중 인스턴스 전환 전 공유 제한기를 도입해야 한다. 지속적인 일일 비용 상한이 아니므로 Google 프로젝트 쿼터·알림은 별도 설정한다.
- 영상: 최대 500MiB, MP4/MOV/WebM, 최대 7680×4320. 실제 ftyp/EBML 헤더와 제한된 ffprobe 결과가 모두 필요하다. 오래된 ftyp 없는 MOV 등은 거부될 수 있다.
- 썸네일: JPEG/PNG만, 최대 5MiB·가로세로 4096·8,388,608픽셀, 디코딩 전 크기 검사, JPEG 재인코딩.
- 검사 동시 실행 2개, ffprobe 최대 15초·출력 64KiB·단일 할당 32MiB·스트림 32개. 서버 임시 파일만 허용하고 외부 참조를 비활성화한다. 검사기 부재나 실패 시 업로드를 허용하는 대체 경로가 없다.
- 전체 multipart 요청 상한 510MiB. 실제 길이와 좌표에 대한 기존 계약은 유지하고 기본 범위만 먼저 검증한다.

## 키와 호환 배포 순서

`GEMINI_API_KEY`, `GEMINI_ENABLED`, `GEMINI_MODEL`은 Backend 실행 환경 전용이다. Compose 예시는 기본 비활성이다. 실제 키는 `.env`에만 저장하며 파일 권한 600·Git 제외 상태를 유지한다. Frontend 빌드 인수·VITE 변수·이미지 레이어·커밋에 넣지 않는다. 키 없이도 서버는 기동되고 브리핑만 503을 반환한다.

1. Backend 이미지에 ffprobe가 있고 새 API·기존 access 인증·업로드 검사가 동작하는지 스테이징에서 확인한다.
2. Backend와 새 Frontend를 같은 점검 시간에 적용한다. 새 Frontend만 먼저 적용하면 브리핑 API가 없으므로 실패한다. 기존 프론트의 직접 호출을 장기간 유지하지 않는다.
3. Frontend의 미디어 정책을 활성화한다. 별도 호스트 Nginx 템플릿의 미디어 location은 MinIO 직결 대신 Frontend로 전달해 동일한 정책을 거치도록 수정했다. Host(포트 포함)와 서명 query를 보존한다.
4. 새 서버 키·기능을 활성화하고 정상 브리핑을 확인한다. 노출된 현재·과거 키는 Google 관리자에서 폐기한다. 과거 번들의 사본은 키 폐기로 무력화한다.
5. CDN의 기존 미디어 응답 캐시를 갱신하고 운영 응답의 CSP, 206, 오류, 직접 링크, 영상·썸네일을 재확인한다. 서로 다른 두 테스트 계정으로 조회 차단도 확인한다.

장애 시 브리핑만 `GEMINI_ENABLED=false`로 중단한다. 업로드 검사나 미디어 sandbox를 제거해 우회하지 않는다. DB migration은 없다. 권한 검증 없는 조회, refresh의 일반 인증, 브라우저 키 호출로 되돌리는 롤백은 사용하지 않는다.

## 검증 구분과 잔여 항목

로컬 자동 테스트는 실제 H2·JWT 필터를 사용한다. S3/AI/Gemini는 테스트 종류에 따라 명시적으로 mock으로 분리하며, 별도 통합 검사는 실제 Nginx·MinIO와 합성 객체로 수행한다. 상세 실행 결과와 CI 링크는 별도 결과 보고서에 기록한다.

- 운영 서버 배포·기존 키 폐기·CDN purge·운영의 두 계정 검증은 이 커밋에 포함되지 않는다.
- 이미 발급된 presigned URL은 소유권 수정만으로 즉시 폐기되지 않는다. 기존 유효기간과 캐시를 고려해야 한다.
- 정상 access 토큰의 로그아웃 직후 즉시 폐기나 refresh 회전 체계 전면 개선은 F15 범위로 남는다.
- 실제 AI 모델 추론, 운영 Pi 성능/디스크 여유, 실제 Safari/iOS 기기 검증은 로컬 합성 시험과 별개다.
- 기존 npm 감사 결과 13건(critical 1, high 9, moderate 2, low 1)은 이번 네 항목의 수정 범위 밖이다. 의존성 일괄 업데이트를 섞지 않았다.
- 원본 작업 폴더의 미완성 hit 로깅/AI 변경은 커밋하지 않았다. 로깅 호환 테스트는 임시 사본에서 소유자 fixture와 새 조회 인자를 반영해 별도로 실행한다.

참고: [Gemini 모델](https://ai.google.dev/gemini-api/docs/models), [ffprobe](https://ffmpeg.org/ffprobe.html).
