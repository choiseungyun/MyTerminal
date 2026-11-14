# 기여 안내 (Contributing)

MyTerminal 에 관심을 가져 주셔서 감사합니다. 버그 신고, 기능 제안, 코드 기여 모두 환영합니다.

## 버그 신고 · 기능 제안

- GitHub Issues 에 남겨 주세요. 버그는 macOS 버전, 재현 순서, 기대한 동작과 실제 동작을 적어 주세요.
- **서버 주소, 사용자 이름, 비밀번호, 키, 화면에 보이는 개인 파일 이름은 지우고** 올려 주세요.
- 보안 문제는 Issues 가 아니라 [SECURITY.md](SECURITY.md) 의 방법으로 알려 주세요.

## 개발 환경

[README 의 빌드](README.md#빌드) 순서를 따릅니다. 요약:

```sh
git submodule update --init
brew install zig xcodegen
xcodebuild -downloadComponent MetalToolchain
scripts/build-ghosttykit.sh --native     # 개발용은 이 Mac 아키텍처만 (빠름)
xcodegen generate
xcodebuild -project MyTerminal.xcodeproj -scheme MyTerminal -destination 'platform=macOS' test
```

- `MyTerminal.xcodeproj` 와 `Resources/Info.plist` 는 `project.yml` 에서 생성되므로 커밋하지 않습니다. 설정은 `project.yml` 을 고칩니다.
- 기본은 임시 서명이라 Apple 개발자 계정 없이 빌드됩니다. 자기 팀으로 서명하려면 `Config/Signing.local.xcconfig` (git 제외)를 만듭니다.

## 코드 규칙

- Swift 5 모드, macOS 14 이상. SwiftUI + 필요한 곳만 AppKit.
- 주석과 화면 문구는 한국어로 씁니다. 짧고 쉬운 말을 씁니다.
- Ghostty 코드를 참고하거나 가져온 파일에는 머리 주석에 출처를 남깁니다 (MIT 고지).
- 새 기능과 버그 수정에는 테스트를 붙입니다 (`Tests/Unit`). 버그 수정은 그 버그를 다시 잡는 회귀 테스트를 함께 넣습니다.
- 테스트는 사용자의 실제 데이터(호스트 목록, 접속 이력, 키체인, `~/.ssh`)를 건드리지 않게 씁니다 (`WorkspaceStore.forTesting()`, 메모리 데이터베이스, 메모리 키 저장소).
- 실제 sshd 가 필요한 통합 테스트(`LiveSSHTests`)는 평소에는 건너뜁니다. 실행 방법은 그 파일 머리 주석에 있습니다.

## Pull Request

1. 이슈에서 먼저 방향을 이야기하면 좋습니다 (작은 수정은 바로 PR 도 괜찮습니다).
2. 브랜치를 만들어 작업하고, 테스트가 모두 통과하는지 확인합니다.
3. PR 설명에 무엇을 왜 바꿨는지, 어떻게 확인했는지 적습니다. 화면이 바뀌면 스크린샷을 붙입니다.
4. CI(GitHub Actions)가 빌드와 테스트를 돌립니다.

기여한 코드는 이 저장소의 [MIT 라이선스](LICENSE)로 배포됩니다.
