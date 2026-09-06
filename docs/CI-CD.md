# RallyTrack CI/CD 운영 설계

## 1. 목표와 완료 기준

CI는 Pull Request와 모든 브랜치 push에서 애플리케이션 계약을 검증합니다. CD는 각 저장소의
기본 브랜치에 합쳐진 **검증된 커밋 SHA**만 사설 서버에 반영합니다.

| 저장소 | 기본 브랜치 | CI 검증 | CD 대상 |
|---|---|---|---|
| frontend | `develop` | Node 22, 잠금 파일 설치, 단위 테스트, Vite 운영 빌드 | Pi 5 |
| backend | `main` | Java 17, H2 격리 테스트, 실행 JAR 빌드 | Pi 5 |
| aiAnalysis-server | `main` | Python 3.12 구문 검사, 모드/라벨 계약 테스트 | ML 서버 |
| devops | `main` | 셸 구문, 로컬/Pi Compose 구성 검증 | Pi 5 |

서버가 켜졌다는 사실만으로 성공 처리하지 않습니다. Pi 배포는 API 문서와 프론트 HTTP 응답을,
ML 배포는 systemd 상태와 `/health` 응답을 확인해야 성공합니다.

## 2. 이 구조를 선택한 이유

- CI는 GitHub-hosted runner에서 실행합니다. 개발자 PC나 운영 서버 상태와 무관하게 동일한
  도구 버전으로 재현할 수 있고, 운영 서버의 CPU·메모리를 테스트가 점유하지 않습니다.
- CD는 `rallytrack-pi` 또는 `rallytrack-ml` 라벨을 가진 self-hosted runner에서만 실행합니다.
  두 서버가 `192.168.219.x` 사설망에 있어 GitHub-hosted runner가 직접 접근할 수 없기 때문입니다.
- 배포 job은 PR에서 절대 실행하지 않고 기본 브랜치 push에서만 실행합니다. 권한은 기본값을
  없앤 뒤 `contents: read`만 부여했습니다. 저장소는 private으로 유지하고 외부 fork 코드를
  self-hosted runner에서 실행하지 않습니다.
- 앱별 배포는 변경된 서비스만 순차 빌드합니다. Pi에서 backend와 frontend를 동시에 빌드해
  메모리 피크가 커지는 것을 피하면서 배포 시간도 전체 재빌드보다 줄입니다.
- 컨테이너 레지스트리와 다중 아키텍처 이미지 배포는 현재 단계에서 제외했습니다. 지금 규모에는
  source build가 운영 복잡도와 시크릿을 줄이는 이점이 큽니다. 배포 빈도나 Pi 빌드 시간이
  병목이 되면 GHCR의 ARM64 이미지 빌드로 전환하는 것이 다음 단계입니다.
- AI CI는 수 GB 가중치와 GPU 추론을 매번 실행하지 않습니다. hosted CI에서는 순수 계약과
  Python 구문을 빠르게 검사하고, 배포 서버에서 실제 venv import와 헬스 체크를 수행합니다.
  대표 영상 정확도 회귀는 모델/라벨 변경 시 별도 수동 검증 항목입니다.

## 3. GitHub 최초 설정

각 저장소의 Settings에서 다음을 한 번 설정해야 합니다.

1. `production-pi`, `production-ml` Environment를 만들고 필요한 경우 승인자를 지정합니다.
2. Pi에 조직 또는 각 저장소용 self-hosted runner를 설치하고 `rallytrack-pi` 라벨을 추가합니다.
3. ML 서버 runner에는 `rallytrack-ml` 라벨을 추가합니다. ML 서버가 x86_64인 현재 구성에 맞춰
   workflow는 `self-hosted, linux, x64, rallytrack-ml`을 요구합니다.
4. 두 Environment에 `RALLYTRACK_ROOT=/home/junmin/RallyTrack` 변수를 등록합니다. 경로가
   기본값과 같으면 생략해도 됩니다.
5. 기본 브랜치 보호 규칙에 해당 저장소의 `verify` job을 필수 상태 검사로 지정하고,
   직접 push 대신 PR을 요구합니다.

runner 사용자는 Pi에서 GitHub 저장소를 fetch하고 Docker를 실행할 수 있어야 합니다. ML 서버에서는
비밀번호 입력 없이 아래 두 명령만 수행할 수 있도록 sudoers 권한을 좁게 부여합니다.

```text
/usr/bin/systemctl restart rallytrack-ai
/usr/bin/systemctl is-active rallytrack-ai
```

설정 후 `workflow_dispatch`로 CI/CD를 한 번 실행해 runner 라벨, 환경 승인, 작업 경로를 검증합니다.

## 4. 배포 동작과 롤백

Pi 스크립트는 다음 순서로 동작합니다.

1. 중복 배포를 파일 잠금으로 차단하고, 대상 저장소에 로컬 변경이 있으면 중단합니다.
2. 기본 브랜치에 포함된 workflow의 검증 SHA인지 확인하고 fast-forward합니다.
3. Compose 구성을 검사하고 변경 서비스의 이미지만 빌드합니다.
4. 컨테이너를 재기동한 뒤 backend/frontend HTTP 헬스 체크를 반복합니다.
5. 실패하면 이전 Git SHA와 이전 이미지 태그를 복원하고 스택을 다시 기동합니다.

ML 스크립트는 requirements가 바뀐 경우에만 기존 venv를 갱신하고 `pip check`, 계약 테스트,
FastAPI import를 확인한 뒤 systemd를 재시작합니다. 헬스 체크 실패 시 이전 SHA와 이전 requirements로
되돌린 뒤 서비스를 다시 시작합니다.

자동 롤백은 Git 코드와 애플리케이션 이미지에만 적용됩니다. MariaDB/MinIO 볼륨은 배포 중 삭제하지
않지만, 호환되지 않는 DB 스키마 변경은 자동 복구하지 않습니다. 운영 중에는 `DDL_AUTO=validate`를
유지하고 스키마 변경은 백업, 호환 가능한 선행 migration, 앱 배포, 구버전 제거 순서로 수행해야 합니다.

## 5. 현재 서버 규모의 트레이드오프

Pi compose의 상한은 MariaDB 600 MB, MinIO 512 MB, backend 1.2 GB, frontend 128 MB,
cloudflared 128 MB입니다. Java heap은 768 MB로 제한됩니다. 이 구성은 소규모 데모/팀 테스트와
낮은 동시 접속에는 적합하지만 아래 기능은 같은 Pi에 추가하지 않는 편이 안전합니다.

- 영상 인코딩이나 AI 추론: ML 서버에서 처리
- 대규모 로그/메트릭 스택: 외부 서비스 또는 가벼운 단일 에이전트 사용
- Pi에서 병렬 Docker 빌드: 배포 스크립트가 의도적으로 순차 실행
- 무중단 다중 replica: 현재 단일 호스트 메모리와 고정 컨테이너 이름에서는 비용 대비 이점이 작음

실사용 트래픽이 늘면 먼저 Pi 빌드를 GHCR 사전 빌드 이미지 pull로 바꾸고, 그다음 backend replica와
외부 managed DB/object storage를 검토합니다. 평균/최대 요청 지연, 메모리 OOM, 업로드 처리량을
관측하지 않은 상태에서 replica 수나 heap을 임의로 늘리지는 않습니다.

## 6. 트러블슈팅 기록

구축 전 기준 테스트에서 다음 문제가 확인됐습니다.

- backend `contextLoads`가 개발자 PC의 MariaDB `localhost:3307`에 연결해 실패했습니다.
  테스트 프로필을 H2(MariaDB 호환 모드)로 분리하고 JWT/S3 테스트 값을 주입해 외부 서비스 없이
  컨텍스트가 올라오도록 수정했습니다.
- frontend는 `framer-motion`을 직접 선언하지 않은 채 transitive dependency에 의존했습니다.
  npm과 pnpm의 설치 구조 차이에서 빌드가 깨졌고, 이미 직접 의존 중인 `motion/react` 경로로 바꿨습니다.
- 로컬 sandbox에서 Gradle의 파일 잠금 소켓과 dependency 다운로드가 차단됐습니다. 이는 코드 실패와
  분리해 허용된 환경에서 다시 실행했고 전체 테스트 통과를 확인했습니다.
- Python compileall의 기본 캐시 경로가 workspace 밖이라 실패했습니다. CI/배포 모두 전용 임시
  `PYTHONPYCACHEPREFIX`를 사용하게 해 소스와 무관한 권한 문제를 제거했습니다.
- 프론트 번들은 정상 빌드되지만 약 1 MB의 단일 JS chunk 경고가 남습니다. 기능 오류는 아니므로
  이번 배포의 차단 조건은 아니며, 초기 로딩 지표를 측정한 뒤 route 단위 code splitting을 적용합니다.

## 7. 운영 확인 명령

```bash
# Pi
cd /home/junmin/RallyTrack/devops
docker compose -p rallytrack -f docker-compose.pi.yml --env-file .env ps
docker compose -p rallytrack -f docker-compose.pi.yml --env-file .env logs --tail=200 backend frontend

# ML 서버
systemctl status rallytrack-ai
journalctl -u rallytrack-ai -n 200 --no-pager
curl -fsS http://127.0.0.1:8000/health
```
