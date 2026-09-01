#!/bin/bash
# RallyTrack Pi 배포 스크립트 — GitHub에서 pull 후 재빌드/재기동
# 사용: ~/RallyTrack/devops/pi/deploy.sh   (Pi에서 실행)
set -e

ROOT="$HOME/RallyTrack"

echo "=== git pull ==="
git -C "$ROOT/backend"  pull --ff-only
git -C "$ROOT/frontend" pull --ff-only
git -C "$ROOT/devops"   pull --ff-only

echo "=== docker compose up ==="
cd "$ROOT/devops"
docker compose -f docker-compose.pi.yml --env-file .env up -d --build

echo "=== 상태 ==="
docker compose -f docker-compose.pi.yml ps
