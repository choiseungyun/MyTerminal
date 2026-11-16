# scripts

빌드, 릴리스, 개발 환경 자동화 스크립트입니다.

- `bootstrap.sh` : 개발 환경 확인 (Xcode, Zig 버전, Metal). `DEVELOPER_DIR` 로 Xcode 를 고를 수 있다
- `build-ghosttykit.sh [release|debug] [--native]` : `vendor/ghostty`에서 GhosttyKit.xcframework 빌드 (기본 universal)
- `copy-ghostty-resources.sh` : 엔진 리소스(terminfo, 테마, 셸 통합)를 앱에 넣을 위치로 복사
- `release.sh [--skip-notarize] [--adhoc]` : Release 빌드(universal) → Developer ID 서명 → 공증·스테이플 → DMG → 자동 업데이트 목록 appcast.xml (사전 준비는 머리 주석)
- `make-app-icon.swift` : 앱 아이콘을 크기별 PNG 로 그려 `Resources/Assets.xcassets/AppIcon.appiconset` 에 넣는다
  (`swift scripts/make-app-icon.swift Resources/Assets.xcassets/AppIcon.appiconset`)
