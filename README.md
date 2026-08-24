# RallyTrack DevOps — Raspberry Pi 배포

## 현재 구성 (2026-08)

| 노드 | 역할 | 위치 |
|---|---|---|
| Raspberry Pi 5 (`192.168.219.156`) | MariaDB 11.4 · Spring backend(:8080) · React frontend(:8082) · MinIO(:9000, 콘솔 :9001 로컬) | `~/RallyTrack/devops` (docker compose) |
| ml-server (`192.168.219.150`) | FastAPI AI 분석 서버(:8000) | `~/RallyTrack/aiAnalysis-server` (venv + systemd `rallytrack-ai`) |

- **공개 주소: https://app.rallytrack.win** — Cloudflare Tunnel(`rally-proxmox`, 커넥터는 Proxmox 호스트)의 public hostname → `http://192.168.219.156:8082`. 포트 개방 없음, HTTPS는 Cloudflare 엣지가 처리
- LAN 직결 주소: `http://192.168.219.156:8082` (큰 영상 업로드는 이쪽으로 — Cloudflare 무료 플랜은 **요청 본문 100MB 제한**이라 100MB 초과 업로드는 도메인 경유 시 실패)
- presigned URL은 `S3_PUBLIC_ENDPOINT`(현재 `https://app.rallytrack.win`)로 서명되고, frontend nginx가 `/rallytrack-videos/` → MinIO로 프록시 (`pi/nginx-rallytrack.conf`는 호스트 nginx 대안, 현재 미사용)
- DB에는 스토리지 URL 대신 **object key만 저장** → MinIO↔S3 전환 시 DB 불변
- KISIA 프로젝트와 공존: 80/5672/6379/8001/15672 사용하지 않음

## 운영 명령 (Pi)

```bash
cd ~/RallyTrack/devops
docker compose -f docker-compose.pi.yml --env-file .env up -d          # 기동
docker compose -f docker-compose.pi.yml ps                             # 상태
docker compose -f docker-compose.pi.yml logs -f backend                # 로그
docker compose -f docker-compose.pi.yml --env-file .env up -d --build  # 코드 반영
```

- 시크릿: `.env` (gitignore, 템플릿은 `.env.example`)
- 스키마 변경 시: `.env`의 `DDL_AUTO=update`로 1회 기동 → 다시 `validate`
- DB 백업: 매일 04:20 cron → `~/RallyTrack/backups/` 7일 롤링 (`backup-db.sh`)
- MinIO 콘솔: `ssh -L 9001:localhost:9001 pi-local` 후 http://localhost:9001

## 운영 명령 (ml-server)

```bash
sudo systemctl status rallytrack-ai      # 상태
journalctl -u rallytrack-ai -f           # 분석 로그
sudo systemctl restart rallytrack-ai     # 재시작 (GPU 드라이버 복구 후에도 이것만)
```

- 유닛 템플릿: `ml-server/rallytrack-ai.service` (`ANALYSIS_CALLBACK_SECRET`는 Pi `.env`와 동일 값으로 교체해 설치)
- 필수 자산: `tracknetv3/`(ckpts 포함), `weights/stroke/` — 레포에 없음, 서버에 직접 배치됨

## 클라우드 복귀 / 도메인 도입

- **S3 복귀**: `.env`에서 `S3_ENDPOINT`·`S3_PUBLIC_ENDPOINT` 비우고 AWS 키 입력, `S3_PATH_STYLE=false` → 재기동. 데이터 이전은 `mc mirror`
- **AI 위치 이동**: `AI_SERVER_URL`(Pi)과 `BACKEND_URL`(ml-server 유닛) 두 값만 교체
- **도메인 도입**: `pi/nginx-rallytrack.conf` 설치 + `S3_PUBLIC_ENDPOINT`/`CORS_ALLOWED_ORIGINS`를 도메인으로 교체
