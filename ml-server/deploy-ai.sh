#!/bin/bash
# RallyTrack AI 서버 배포 스크립트 — GitHub에서 pull 후 서비스 재시작
# 사용: ~/RallyTrack/aiAnalysis-server 클론 후 이 스크립트 실행 (ml-server에서)
set -e

ROOT="$HOME/RallyTrack/aiAnalysis-server"

echo "=== git pull ==="
git -C "$ROOT" pull --ff-only

echo "=== 의존성 갱신 ==="
"$ROOT/.venv/bin/pip" install -q -r "$ROOT/requirements.txt"

echo "=== 서비스 재시작 ==="
sudo systemctl restart rallytrack-ai
sleep 3
systemctl is-active rallytrack-ai && curl -s http://localhost:8000/health && echo
