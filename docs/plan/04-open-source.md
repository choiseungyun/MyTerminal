# 4. 오픈소스 공개 준비

v0.1(M6)에서 GitHub에 공개합니다. 아래 항목은 공개 전에 모두 갖춥니다.

## 라이선스와 이름

- MIT 라이선스로 공개합니다. Ghostty와 같은 라이선스입니다.
- Ghostty의 LICENSE 고지를 반드시 포함합니다. Ghostty 코드를 가져온 파일에는 출처를 주석으로 남깁니다.
- "Ghostty" 이름과 로고는 사용하지 않습니다. 설명에 "Powered by libghostty" 정도만 표기합니다.

## 앱 아이콘

- [x] MyTerminal 고유 아이콘 (2026-11-13, `scripts/make-app-icon.swift`)

## 코드 서명

| 용도 | 인증서 | 설정 위치 |
| --- | --- | --- |
| 개발 (Debug) | Apple Development | `Config/Signing.local.xcconfig` (개인, git 제외). 없으면 임시 서명 |
| 배포 (Release) | **Developer ID Application** + Hardened Runtime(Release 에서 켜짐) + 공증 | Xcode Organizer > Distribute App > **Direct Distribution**. App Store Connect 는 샌드박스 필수라 불가 ([ADR 0005](../decisions/0005-direct-distribution.md)) |

- 번들 ID: `kr.weare.myterminal` (2026-11-13 변경, 이전 `dev.myterminal.app` 의 앱 설정은 첫 실행 때 자동으로 옮김)
- 팀 ID 는 공용 설정에 넣지 않는다 (기여자가 자기 팀이나 임시 서명으로 빌드할 수 있게)

## 배포

- 다른 사람이 경고 없이 설치하려면 Apple Developer Program(연 $99) 서명과 공증이 필요합니다.
- DMG를 GitHub Release에 올리고, 이후 Sparkle 자동 업데이트와 Homebrew Cask를 추가합니다.
- GitHub Actions의 macOS 러너로 빌드와 릴리스를 자동화합니다.

## 보안

- API 키와 비밀번호는 모두 Keychain에 저장합니다. 설정 파일과 저장소에는 두지 않습니다.
- AI 기능은 사용자가 자기 API 키를 넣는 방식(BYOK)입니다.

## 공개 시 필요한 문서

- [x] README (소개, 스크린샷, 설치 방법) — 화면 사진은 가짜 데이터로 만든다
- [x] LICENSE (MIT, MyTerminal contributors) + THIRD_PARTY_NOTICES (Ghostty, GRDB, 글꼴, 테마). 앱 안에도 넣고 도움말 메뉴에서 연다
- [x] CONTRIBUTING (빌드 방법, 코드 규칙, PR 규칙)
- [x] SECURITY (GitHub 비공개 취약점 신고)
- [x] CHANGELOG

## 자동화

- [x] GitHub Actions CI (`.github/workflows/ci.yml`): macos-26 러너, 엔진 캐시, 빌드·단위 테스트. 비공개일 때는 수동 실행만 (macOS 분 10배)
- [x] 배포 스크립트 `scripts/release.sh`: universal Release 빌드 → Developer ID 서명 → 공증·스테이플 → DMG + sha256

## 공개 전 점검 (2026-11-14)

- 현재 파일: 서버 이름·팀 ID·홈 폴더 경로 없음. 스크린샷에서 온 내부 IP·키 이름·백업 파일 이름은 문서용 예시 값으로 바꿈
- 커밋 기록: 작성자 이메일과 예전 값이 남아 있어, 공개는 **새 기록(커밋 1개, GitHub noreply 이메일)** 으로 한다 (사용자 결정). 전체 기록은 비공개 저장소에 남긴다
