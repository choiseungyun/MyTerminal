# Ghostty macOS 앱 구조 분석

기준: Ghostty `v1.4.0` (커밋 `83fb95624`, 2026-10-27) · 경로: `vendor/ghostty/macos/Sources`

결론: 엔진은 C API 92개로 열려 있습니다. 실행 명령, 환경변수, 작업 디렉터리를 터미널 화면 생성 시 넘길 수 있어, 접속 목록 기능은 엔진 수정 없이 구현할 수 있습니다. 이식 대상은 `Ghostty/` 폴더(Surface View 포함 약 11,800줄)와 `Features/Splits/`(약 2,000줄)입니다.

## 빌드 요구 사항

| 항목 | 버전 | 비고 |
| --- | --- | --- |
| Zig | 0.17.0 이상 (`build.zig.zon`의 `minimum_zig_version`) | Homebrew 0.17.1 사용 |
| Xcode | 26 이상 + macOS SDK | 현재 Xcode 27.2 |
| Metal Toolchain | Xcode 별도 구성요소 (약 840MB) | `xcodebuild -downloadComponent MetalToolchain` 으로 설치. 없으면 셰이더 컴파일에서 빌드 실패 |
| xcode-select | `/Applications/Xcode.app` 이어야 함 | 현재 CLT로 잡혀 있음. `DEVELOPER_DIR`로 우회 중 |

엔진만 빌드하는 명령 (`-Dxcframework-target=universal` 이면 arm64+x86_64 합본, `native` 면 이 Mac 만. native 로 빌드하면 Xcode 의 "Any Mac"·Archive·Release 빌드에서 x86_64 링크가 실패한다):

```sh
zig build -Demit-macos-app=false -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
```

## 폴더 구성

| 폴더 | 역할 | MyTerminal에서 |
| --- | --- | --- |
| `App/` | `main.swift`(`ghostty_init`), AppDelegate, 메인 메뉴 | 참고만 (앱 틀은 SwiftUI로 새로 작성) |
| `Ghostty/` | C API를 Swift로 감싼 핵심 계층: App, Config, Surface, Input, Action | **`Sources/GhosttyAdapter`로 이식** |
| `Ghostty/Surface View/` | 터미널 화면 NSView, 스크롤, 키·마우스·IME 처리 | **이식** (한글 IME 포함) |
| `Features/Splits/` | 분할 트리 자료구조와 분할 뷰 | **이식** |
| `Features/Terminal/` | 창·탭 컨트롤러 | 참고 (탭 바는 직접 구현) |
| `Features/Command Palette/` | 명령 팔레트 | 참고 (⌘K 팔레트 설계 시) |
| `Features/QuickTerminal`, `AppleScript`, `Update` 등 | 부가 기능 | 제외 |

## 핵심 파일

| 파일 | 줄 수 | 내용 |
| --- | --- | --- |
| `Ghostty/Surface View/SurfaceView_AppKit.swift` | 2,539 | 터미널 NSView. `ghostty_surface_new` 호출, 키 입력, `NSTextInputClient`(IME) |
| `Ghostty/Ghostty.App.swift` | 2,516 | `ghostty_app_new`, 런타임 콜백(wakeup, action, 클립보드), 액션 분기 |
| `Features/Splits/SplitTree.swift` | 1,429 | 분할 트리 자료구조 (값 타입, 직렬화 가능) |
| `Ghostty/Ghostty.Input.swift` | 1,392 | 키 코드·수정 키 변환 |
| `Ghostty/Surface View/SurfaceView.swift` | 1,185 | SwiftUI 쪽 래퍼 |
| `Ghostty/Ghostty.Config.swift` | 923 | `ghostty_config_new`, 설정 파일 로딩, 값 조회 |

## C API 사용 흐름

```text
ghostty_init()                       프로세스당 1번 (main.swift)
  └─ ghostty_config_new()            설정 객체 → load_default_files → finalize
      └─ ghostty_app_new(runtime, config)
            runtime = { wakeup_cb, action_cb, read/write_clipboard_cb, close_surface_cb }
          └─ ghostty_surface_new(app, surface_config)   터미널 화면 1개마다
```

`ghostty_surface_config_s`의 필드 중 MyTerminal에 중요한 것:

| 필드 | 쓰임 |
| --- | --- |
| `command` | 접속 목록에서 `ssh -p 22 user@host` 실행 |
| `env_vars`, `env_var_count` | SSH 화면의 `TERM` 덮어쓰기, 비밀번호 자동 입력(SSH_ASKPASS) 환경변수 |
| `working_directory` | 로컬 터미널 시작 위치 |
| `initial_input` | 접속 직후 자동 입력 (예: 원격 셸 통합 로드) |
| `context` | 창 / 탭 / 분할 구분 |

## 리소스와 TERM

- 엔진은 실행 파일 위치에서 `Contents/Resources/terminfo/78/xterm-ghostty`를 찾아 리소스 폴더를 정합니다 (`src/os/resourcesdir.zig`).
- 찾으면 `TERM=<term 설정, 기본 xterm-ghostty>`, `TERMINFO=<Resources>/terminfo`, `GHOSTTY_RESOURCES_DIR`를 설정하고, 못 찾으면 `TERM=xterm-256color`로 둡니다 (`src/termio/Exec.zig`).
- 화면을 만들 때 넘긴 환경변수(`env_vars`)는 그 **뒤에** 적용되어 TERM도 덮어쓸 수 있습니다. MyTerminal은 SSH 화면에서 `TERM=xterm-256color`로 덮어씁니다. 원격 서버에 `xterm-ghostty` terminfo가 없는 경우가 많기 때문입니다.
- **주의: setuid 프로그램과 sudo.** ncurses 는 보안상 setuid 프로그램에서 `TERMINFO`·`~/.terminfo` 를 무시하고 시스템 폴더(`/usr/share/terminfo`, SIP 보호로 추가 불가)만 봅니다. macOS 의 `/usr/bin/top` 은 setuid root 라서 `TERM=xterm-ghostty` 이면 "Error opening terminal" 로 실패합니다. 그래서 MyTerminal 은 기본 TERM 을 `xterm-256color` 로 하고(`term` 설정), `xterm-ghostty` 는 설정의 고급 옵션으로 둡니다. `term` 만 바꿔도 엔진은 `TERMINFO`·`COLORTERM=truecolor` 를 그대로 설정합니다.
- 번들에 넣는 리소스: `terminfo/`(8KB), `ghostty/`(테마 819개, 셸 통합 스크립트, 3.3MB). `scripts/copy-ghostty-resources.sh`가 `zig-out/share`에서 복사합니다.

## 설정 다시 읽기

- `ghostty_app_update_config(app, config)`는 열린 모든 화면에 새 설정을 보냅니다 (`src/App.zig` `updateConfig`).
- 테마 파일은 일반 설정 파일과 같은 형식이며, `background`·`foreground`·`palette`를 직접 지정하면 테마보다 우선합니다.

## 명령 종료와 종료 코드

- 명령이 끝나면 엔진이 `GHOSTTY_ACTION_SHOW_CHILD_EXITED`(종료 코드, 실행 시간)를 보낸다. 앱이 true 를 돌려주면 엔진은 "Process exited…" 문구를 쓰지 않는다 (`src/Surface.zig` `childExited`)
- **macOS 에서는 종료 코드가 항상 0** 이다. 명령이 `/usr/bin/login -flp … bash -c "exec -l 명령"` 으로 실행되기 때문 (Ghostty 주석: "exit code detection doesn't work, possibly because of our login wrapper"). 실험: `exit 3`, ssh 접속 실패(255) 모두 0 으로 전달됨
- MyTerminal 은 ssh 를 셸로 감싸 실제 종료 코드를 파일에 남겨 쓴다

## 이식 시 주의

- `Ghostty/` 코드는 Ghostty 앱 전역 객체(AppDelegate, 설정 경로 등)를 일부 참조합니다. 이식하면서 MyTerminal용 프로토콜로 바꿔야 합니다.
- 설정 파일 경로가 Ghostty 기본값(`~/.config/ghostty`)을 읽습니다. MyTerminal 전용 경로로 분리할지 M1에서 정합니다.
- 가져온 파일 맨 위에 출처와 MIT 고지를 주석으로 남깁니다.
