# 문서

**진행 현황은 [progress.md](progress.md)에서 한눈에 볼 수 있습니다.**

| 문서 | 내용 |
| --- | --- |
| [plan/01-overview.md](plan/01-overview.md) | 프로젝트 개요, 핵심 기능 5가지, 배포 방향 |
| [plan/02-architecture.md](plan/02-architecture.md) | 기반 기술(Ghostty), 계층 구조, 저장소 구조 |
| [plan/03-roadmap.md](plan/03-roadmap.md) | 마일스톤 M0~M6, 일정, 완료 기준 |
| [plan/04-open-source.md](plan/04-open-source.md) | 오픈소스 공개 준비 |
| [plan/05-risks.md](plan/05-risks.md) | 위험 요소와 대응 |
| [design/01-ui-ux.md](design/01-ui-ux.md) | UI/UX 설계 (Termius식 화면 구성, 와이어프레임) |
| [analysis/01-ghostty-macos-app.md](analysis/01-ghostty-macos-app.md) | Ghostty macOS 앱 구조 분석, C API 흐름, 이식 대상 |
| [release.md](release.md) | 릴리스와 자동 업데이트 절차 (버전 올리기 → 서명·공증 → GitHub 릴리스 → 확인) |
| [features/](features/) | 기능별 설계 문서 |
| [decisions/](decisions/) | 주요 결정 기록 (ADR) |

## 기능별 설계

1. [접속 이력 (히스토리)](features/01-connection-history.md)
2. [접속 목록](features/02-connections.md)
3. [화면 분할](features/03-split-view.md)
4. [AI 명령 추천](features/04-ai-assist.md)
5. [쉬운 SFTP](features/05-sftp.md)

## 결정 기록 (ADR)

- [0001. Ghostty를 서브모듈로 사용하고 앱은 별도로 만든다](decisions/0001-ghostty-as-submodule.md)
- [0002. 화면 분할은 Ghostty 코드를 옮기지 않고 직접 구현한다](decisions/0002-own-split-tree.md)
- [0003. 비밀번호 자동 입력은 SSH_ASKPASS 와 로컬 소켓으로 한다](decisions/0003-askpass-password-autofill.md)
- [0004. SFTP 는 시스템 OpenSSH 위에서 프로토콜을 직접 구현한다](decisions/0004-sftp-over-openssh.md)
- [0005. Mac App Store 가 아니라 Developer ID 로 직접 배포한다](decisions/0005-direct-distribution.md)
- [0006. 자동 업데이트는 Sparkle 로, 업데이트 목록은 GitHub 릴리스에 둔다](decisions/0006-sparkle-auto-update.md)

새 결정은 `decisions/NNNN-제목.md` 형식으로 추가합니다.
