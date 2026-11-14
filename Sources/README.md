# Sources

앱 소스 코드입니다.

| 폴더 | 용도 | 주요 파일 |
| --- | --- | --- |
| `App/` | 앱 진입점, 메뉴 | `MyTerminalApp.swift` |
| `App/UI/` | SwiftUI 화면 | `MainView`, `TabBar`, `Theme` |
| `App/UI/Home/` | 홈 탭 (왼쪽 메뉴, 호스트 화면, 호스트 편집·가져오기) | `HomeView`, `HostsView`, `HostDetailPanel`, `SSHConfigImportView`, `HostTransferViews` |
| `App/UI/Terminal/` | 터미널 탭 | `TerminalTabView` |
| `App/UI/Settings/` | 설정 창 (⌘,) | `SettingsView` |
| `App/UI/Files/` | 원격 파일 탐색기 (SFTP) | `FileBrowserPanel` |
| `App/Services/` | UI와 무관한 로직 (탭·분할, 호스트, ssh 명령, 비밀번호 자동 입력, 설정, `SFTP/`) | `WorkspaceStore`, `SplitTree`, `HostStore`, `HostForm`, `HostTransfer`, `SSHCommand`, `SSHConfigParser`, `AskpassServer`, `TerminalSettings` |
| `App/Storage/` | SQLite(GRDB.swift), Keychain 접근 | `AppDatabase`, `SSHHost`, `Keychain` |
| `GhosttyAdapter/` | libghostty C API 호출을 모은 계층. **엔진 호출은 여기에만 둔다** | `GhosttyRuntime`, `TerminalSurfaceView` |

`GhosttyAdapter/`의 일부 코드는 Ghostty macOS 앱 코드를 참고해 작성했으며, 해당 파일 맨 위에 출처와 MIT 고지가 있습니다.

계층 구조는 [docs/plan/02-architecture.md](../docs/plan/02-architecture.md)를 보세요.
