# 2. 기반 기술과 아키텍처

Ghostty 저장소를 통째로 포크하지 않습니다. 내 Swift 앱 저장소를 따로 만들고, Ghostty는 서브모듈로 넣어 엔진(GhosttyKit.xcframework)만 빌드해 씁니다. 이 결정의 근거는 [ADR 0001](../decisions/0001-ghostty-as-submodule.md)에 있습니다.

## Ghostty의 구성

- **libghostty**: Zig로 작성된 엔진입니다. 터미널 제어 문자 해석, Metal 렌더링, PTY 관리를 맡습니다.
- **macOS 앱(`macos/` 폴더)**: Swift로 작성된 겉모습입니다. 창, 탭, 분할, 설정을 담당합니다.

키 입력, 한글 IME, 화면 분할 같은 연결 코드는 Ghostty macOS 앱 코드를 참고하거나 가져옵니다. MIT 라이선스라 고지만 남기면 됩니다.

## 계층 구조

```text
┌──────────────────────────────────────────────────────────────┐
│ UI          사이드바(호스트 / 히스토리) · 탭 · 분할          │
│             SFTP 패널 · AI 패널(⌘K)                          │
├──────────────────────────────────────────────────────────────┤
│ Services    SessionManager · HistoryStore · ConnectionStore  │
│             SFTPService · AIService                          │
├──────────────────────────────────────────────────────────────┤
│ Storage     SQLite(GRDB.swift) · Keychain(비밀번호, API 키)   │
├──────────────────────────────────────────────────────────────┤
│ GhosttyAdapter   libghostty C API 호출을 한 곳에 모은 계층    │
├──────────────────────────────────────────────────────────────┤
│ GhosttyKit.xcframework  ← vendor/ghostty (릴리스 태그 고정)   │
└──────────────────────────────────────────────────────────────┘
```

libghostty의 C API는 외부 앱이 쓰도록 안정화된 공개 API가 아닙니다. 그래서 Ghostty 버전을 태그로 고정하고, 엔진 호출은 `GhosttyAdapter` 한 곳에만 둡니다. Ghostty가 바뀌어도 고칠 곳이 그 계층뿐입니다.

## 저장소 구조

```text
MyTerminal/
├─ docs/               계획서, 기능 설계, 결정 기록(ADR)
├─ Sources/
│  ├─ App/             앱 진입점, 창·메뉴 구성
│  │  ├─ UI/           SwiftUI·AppKit 화면
│  │  ├─ Services/     탭·분할, 호스트, 접속 이력, SFTP, AI 로직
│  │  └─ Storage/      SQLite, Keychain 접근
│  └─ GhosttyAdapter/  libghostty 연결 계층
├─ Tests/              단위 테스트, 호환성 테스트
├─ scripts/            빌드·릴리스 스크립트
└─ vendor/ghostty/     Ghostty 서브모듈
```

## 방식 비교

| 비교 항목 | 별도 앱 + 서브모듈 (선택) | 전체 포크 후 `macos/` 수정 |
| --- | --- | --- |
| 시작 속도 | 느림 (연결 코드 이식 필요) | 빠름 |
| UI 자유도 | 높음 (사이드바, SFTP, AI 패널을 처음부터 설계) | 기존 구조에 맞춰야 함 |
| Ghostty 업데이트 반영 | 서브모듈 태그만 올리면 됨 | 병합 충돌이 계속 발생 |
| 오픈소스 정체성 | "Powered by libghostty"인 독립 프로젝트 | Ghostty 변형판으로 보임 |
