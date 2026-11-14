# 0002. 화면 분할은 Ghostty 코드를 옮기지 않고 직접 구현한다

- 날짜: 2026-11-13
- 상태: 채택

## 배경

M1 계획은 Ghostty macOS 앱의 분할 코드(`Features/Splits/`, 약 2,000줄)를 이식하는 것이었다. 실제로 보니 `SplitTree.swift`(1,429줄)는 Ghostty 의 `SurfaceView`, 창 컨트롤러, 직렬화(창 복원) 등 Ghostty 앱 전용 타입에 넓게 묶여 있었다.

## 결정

구조(잎이 화면인 이진 트리, 비율 기반 분할)만 참고하고, MyTerminal 에 필요한 기능만 직접 구현한다.

- `Sources/App/Services/SplitTree.swift`: 값 타입 트리. 분할, 닫기, 비율 조절, 균등 분배
- `Sources/App/UI/Terminal/TerminalTabView.swift`: SwiftUI 로 트리를 그리고 구분선 끌기를 처리
- 잎 타입을 제네릭으로 두어 실제 터미널 없이 단위 테스트한다 (`Tests/Unit/SplitTreeTests.swift`)

## 근거

- 약 150줄로 필요한 기능을 모두 덮는다. 이식하면 Ghostty 전용 타입을 함께 끌어와야 한다.
- 이후 작업(Task)별 배치 저장·복원(M3)에 맞춰 직렬화 형식을 자유롭게 정할 수 있다.
- Ghostty 업데이트의 영향을 받지 않는다.

## 감수하는 점

- 방향키로 화면 이동(왼쪽·오른쪽 화면으로), 화면 확대(zoom) 같은 Ghostty 의 부가 기능은 필요할 때 직접 추가해야 한다. 현재는 순서 이동(⌘[ · ⌘])만 있다.
