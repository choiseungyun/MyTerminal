# 0001. Ghostty를 서브모듈로 사용하고 앱은 별도로 만든다

- 날짜: 2026-11-13
- 상태: 채택

## 배경

Ghostty 기반으로 자체 UI/UX(사이드바, SFTP 패널, AI 패널)를 가진 터미널을 만들고, 이후 오픈소스로 공개하려 한다.

## 결정

Ghostty 저장소 전체를 포크하지 않는다. 별도 Swift 앱 저장소를 만들고 Ghostty는 `vendor/ghostty` 서브모듈로 넣어 GhosttyKit.xcframework만 빌드해 쓴다. 엔진 호출은 `Sources/GhosttyAdapter`에만 둔다.

## 근거

- UI를 처음부터 설계할 수 있다.
- Ghostty 업데이트는 서브모듈 태그만 올리면 된다. 포크 방식의 병합 충돌이 없다.
- 오픈소스 공개 시 Ghostty 변형판이 아닌 독립 프로젝트가 된다.

## 감수하는 점

- 키 입력, 한글 IME, 분할 같은 연결 코드를 Ghostty macOS 앱에서 이식해야 해서 시작이 느리다.
- libghostty C API가 외부 앱용으로 안정화되지 않았다. 버전 고정과 어댑터 계층으로 대응한다.
