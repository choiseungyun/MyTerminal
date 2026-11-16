# 0006. 자동 업데이트는 Sparkle 로, 업데이트 목록은 GitHub 릴리스에 둔다

- 날짜: 2026-11-16
- 상태: 채택

## 배경

App Store 밖에서 배포하므로(ADR 0005) 새 버전을 알리고 설치하는 방법을 앱이 직접 가져야 한다.

## 결정

- **Sparkle 2** (MIT, Swift Package)를 쓴다. App Store 밖 macOS 앱의 사실상 표준이고, 한국어 화면이 있다.
- 업데이트 목록 `appcast.xml` 은 **릴리스 첨부 파일**로 올리고, 앱은 `https://github.com/choiseungyun/MyTerminal/releases/latest/download/appcast.xml` 을 본다.
  GitHub 가 항상 최신 릴리스로 연결해 주므로 서버를 따로 두지 않는다.
- 받은 DMG 는 **EdDSA 서명**(앱의 `SUPublicEDKey`)이 맞아야 설치한다. 비밀 키는 릴리스하는 Mac 의 로그인 키체인(계정 이름 `myterminal`)에만 두고 저장소에 올리지 않는다.
- 사용 환경 정보(시스템 프로파일)는 보내지 않는다 (`SUEnableSystemProfiling = false`).
- 개발 빌드(Debug)와 테스트에서는 업데이트를 켜지 않는다.
- `scripts/release.sh` 가 Sparkle 의 도우미 프로그램(Autoupdate, Updater.app, XPC 서비스)을 Developer ID 로 다시 서명한다.
  Sparkle 이 임시 서명으로 넣어 주므로 그대로 두면 공증이 거절된다. 이어서 `generate_appcast` 로 서명된 `appcast.xml` 을 만든다
  (변경 내용은 CHANGELOG 의 해당 버전 부분).

## 결과

- 0.1.2 부터 자동 업데이트. 0.1.0·0.1.1 사용자는 0.1.2 를 한 번 직접 받아야 한다.
- 비밀 키를 잃으면 기존 사용자에게 업데이트를 보낼 수 없다 → 백업 필요 (`generate_keys --account myterminal -x <파일>`, 안전한 곳에 보관).

## 확인 (2026-11-16)

- 이 Mac 에서만 열리는 시험용 업데이트 목록(127.0.0.1)으로, Developer ID 서명된 0.1.2(빌드 3) → 0.1.3(빌드 4) 실제 업데이트: 목록 확인 → DMG 받기 → 서명 확인 → 앱 종료 시 교체(약 2초), 교체된 앱 서명 정상
