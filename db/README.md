# Database migrations

RallyTrack는 아직 Flyway를 사용하지 않습니다. Pi 배포 스크립트는 이 nullable 컬럼이 없을 때
`backups/db/`에 `videos` 테이블을 먼저 백업하고 forward migration을 한 번 적용합니다.
운영자가 앱 배포 전에 직접 적용하려면 아래 절차를 사용합니다.
기존 영상의 분석 모드는 근거가 없어 `NULL`로 유지되고, 배포 이후 업로드부터 `pro` 또는
`amateur`가 저장됩니다.

## 적용

```bash
cd /home/junmin/RallyTrack/devops

# 먼저 백업
docker compose -p devops -f docker-compose.pi.yml --env-file .env \
  exec -T db sh -c 'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" "$MARIADB_DATABASE" videos' \
  > videos-before-analysis-mode.sql

# forward migration
docker compose -p devops -f docker-compose.pi.yml --env-file .env \
  exec -T db sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" "$MARIADB_DATABASE"' \
  < db/migrations/20260906_add_video_analysis_mode.sql
```

## 확인

```bash
docker compose -p devops -f docker-compose.pi.yml --env-file .env \
  exec -T db sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" "$MARIADB_DATABASE" -e \
  "SELECT video_id, title, analysis_mode, video_status, upload_date FROM videos ORDER BY video_id DESC LIMIT 20"'
```

`analysis_mode IS NULL`은 migration 이전 영상이라는 의미입니다. `NULL`을 `pro`나 `amateur`로
일괄 보정하면 실제 선택값처럼 오해되므로 근거 없이 업데이트하지 않습니다.

## 롤백

먼저 이 필드를 사용하지 않는 백엔드 버전으로 롤백한 뒤 아래 SQL을 적용합니다.
앱 롤백 시 새 nullable 컬럼을 남겨둬도 구버전과 호환되므로 자동 롤백은 컬럼을 삭제하지 않습니다.

```bash
docker compose -p devops -f docker-compose.pi.yml --env-file .env \
  exec -T db sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" "$MARIADB_DATABASE"' \
  < db/rollback/20260906_drop_video_analysis_mode.sql
```
