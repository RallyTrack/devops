# RallyTrack DevOps

RallyTrack 서비스의 **배포 구성 저장소**입니다. 애플리케이션 코드는 각 서비스 저장소에 있고,
여기에는 컨테이너 오케스트레이션 · 리버스 프록시 · 서비스 유닛 · 배포 스크립트만 둡니다.

## 서비스 구성

| 서비스 | 역할 | 포트 |
|---|---|---|
| `frontend` | React SPA (nginx, `/api`는 backend로 프록시) | 8082 |
| `backend` | Spring Boot API | 8080 |
| `db` | MariaDB 11.4 | 3307 (로컬 전용) |
| `minio` | 영상 오브젝트 스토리지 (S3 호환) | 9000 / 콘솔 9001 |
| `cloudflared` | Cloudflare Tunnel 커넥터 (외부 포트 개방 없이 공개) | — |
| AI 분석 서버 | FastAPI, 별도 호스트에서 systemd로 구동 | 8000 |

영상은 presigned URL로 직접 업로드/재생하며, DB에는 URL이 아닌 **object key만** 저장합니다.
따라서 MinIO ↔ S3 전환 시 DB 변경이 없습니다.

## 저장소 구성

| 경로 | 설명 |
|---|---|
| `docker-compose.yml` | 로컬 개발용 (MySQL, AI 서버 포함 전체 스택) |
| `docker-compose.pi.yml` | 실서버(Raspberry Pi) 배포용 — 헬스체크 · 메모리 제한 · MinIO · 터널 포함 |
| `.env.example` | 환경 변수 템플릿 (실제 값은 `.env`, 커밋 금지) |
| `pi/deploy.sh` | 서버 배포 스크립트 — 각 저장소 pull 후 재빌드 · 재기동 |
| `pi/nginx-rallytrack.conf` | 호스트 nginx vhost 템플릿 (도메인 직접 연결 시 사용) |
| `ml-server/deploy-ai.sh` | AI 서버 배포 스크립트 |
| `ml-server/rallytrack-ai.service` | AI 분석 서버 systemd 유닛 템플릿 |
| `docs/CI-CD.md` | CI 선택 근거, GitHub 설정, 배포·롤백, 서버 규모 트레이드오프 |
| `db/` | 운영 DB forward/rollback migration과 적용 절차 |

`backend` / `frontend` / `aiAnalysis-server` 를 이 저장소와 같은 상위 폴더에 두고 clone해야
compose의 `build:` 상대 경로와 배포 스크립트가 맞습니다.

```
RallyTrack/
├── devops/        ← 이 저장소
├── backend/
├── frontend/
└── aiAnalysis-server/
```

## 시작하기

```bash
cp .env.example .env          # 값 채우기 (시크릿 생성: openssl rand -hex 32)

# 로컬 개발
docker compose up -d --build

# 서버 최초 기동
docker compose -f docker-compose.pi.yml --env-file .env up -d --build

# 이후 배포는 스크립트로
pi/deploy.sh
```

상태 확인은 `docker compose -f <compose 파일> ps`, 로그는 `... logs -f backend`.

GitHub Actions 기반 CI/CD 구조와 최초 runner 설정은 [`docs/CI-CD.md`](docs/CI-CD.md)를
따릅니다. PR에서는 검증만 수행하고, 검증된 기본 브랜치 커밋만 사설 서버 runner가 배포합니다.

## 환경 변수

모든 시크릿과 호스트 주소는 `.env`로 주입하며 저장소에 커밋하지 않습니다.
필요한 키와 설명은 [`.env.example`](.env.example)을 참고하세요.
스키마 최초 생성 시에만 `DDL_AUTO=update`, 이후에는 `validate`로 되돌립니다.
수동 스키마 변경은 [`db/README.md`](db/README.md)의 백업 및 migration 순서를 따릅니다.

## 관련 저장소

- [RallyTrack/backend](https://github.com/RallyTrack/backend) — Spring Boot API
- [RallyTrack/frontend](https://github.com/RallyTrack/frontend) — React 클라이언트
- [RallyTrack/aiAnalysis-server](https://github.com/RallyTrack/aiAnalysis-server) — FastAPI 분석 서버

---

> 실제 운영 정보(호스트 주소, 백업 · 복구 절차, 장애 대응)는 공개 저장소에 두지 않고
> 별도 런북으로 관리합니다.
