# 0005. Mac App Store 가 아니라 Developer ID 로 직접 배포한다

- 날짜: 2026-11-13
- 상태: 채택

## 배경

Xcode 에서 App Store Connect 로 업로드했더니 "App sandbox not enabled … must include com.apple.security.app-sandbox" 로 거절되었다. Mac App Store 앱은 App Sandbox 가 필수다.

## 샌드박스를 켤 수 없는 이유

- 샌드박스 앱이 실행한 셸·ssh 도 샌드박스를 물려받아, 앱 보관함 밖의 사용자 파일(홈 폴더, `~/.ssh` 키·설정)과 대부분의 시스템 명령을 쓸 수 없다. 터미널의 기본 기능이 깨진다.
- MyTerminal 의 핵심 구조가 샌드박스와 맞지 않는다: 시스템 OpenSSH 실행(ADR 0004), `/usr/bin/login` 으로 로그인 셸 실행, 연결 재사용 소켓(`/tmp/myterm-<uid>`), 비밀번호 자동 입력 도우미(ADR 0003)
- App Store 에 있는 터미널·SSH 앱(예: Termius)은 SSH 를 앱 안에 직접 구현한다. iTerm2, Ghostty, Warp 등 일반 터미널은 App Store 밖에서 배포한다.

## 결정

- 배포는 **Developer ID Application 서명 + Apple 공증(notarization)** 으로 한다 (Xcode Organizer 의 "Direct Distribution").
- 공증에 필요한 **Hardened Runtime** 은 Release 빌드에서 켠다. Debug 는 끈다 (임시 서명 환경에서도 테스트 번들을 불러오도록).
- 배포 파일은 DMG (GitHub Release). 이후 Sparkle 자동 업데이트, Homebrew Cask.

## 확인

- Release + Hardened Runtime 빌드에서 서명 플래그 `runtime`, arm64+x86_64, 로그인 셸 실행 정상 (2026-11-13)

## Xcode 배포 절차

1. 대상 "Any Mac" 으로 Product > Archive
2. Organizer > Distribute App > **Direct Distribution** (App Store Connect 아님)
3. Xcode 가 Developer ID Application 인증서를 만들어 서명하고 Apple 공증에 올린다 (Apple Developer Program 유료 회원, 계정 소유자·관리자 권한 필요)
4. 공증이 끝나면 Export → 공증된 MyTerminal.app → DMG 로 묶어 배포
