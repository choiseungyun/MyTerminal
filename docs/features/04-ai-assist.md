# AI 도우미

마일스톤: M5 (**구현됨**, 실제 API 확인 대기)

AI 로 터미널 작업을 돕습니다. 제공자는 **Claude · ChatGPT · Gemini · EXAONE** 중에서 고릅니다 (설정 > AI). AI 가 고른 명령은 **입력줄에만 들어가고 자동으로 실행되지 않습니다.**

## 기능

### ① ⌘K 명령 추천

- 메뉴 AI > 명령 추천 (⌘K), 또는 상태 줄 "AI" 버튼.
- 하고 싶은 일을 자연어로 입력하고 Enter → 명령 1~5개, 설명, 위험도(안전·주의·위험)가 나옵니다.
- 지금 포커스된 화면의 **서버 이름·사용자·현재 폴더**를 함께 보내 그 환경에 맞는 명령을 받습니다 (로컬이면 macOS 버전·셸).
- ↑↓ 로 고르고 Enter, 또는 [입력] → 입력줄에 들어갑니다. 실행은 사용자가 Enter 를 눌러야 합니다.
- 질문을 아직 하지 않았을 때는 "선택한 내용 설명" / "지금 화면 설명" 바로 가기가 보입니다.
- 원래 ⌘K 였던 화면 지우기는 **⇧⌘K** (메뉴 화면 > 화면 지우기) 로 옮겼습니다.

### ② 선택한 출력·실패한 명령 설명

- 메뉴 AI > 선택한 내용·화면 설명 (⇧⌘E): 마우스로 선택한 글자가 있으면 그것, 없으면 마지막으로 실패한 명령, 그것도 없으면 지금 화면을 설명합니다.
- 로컬 셸에서 명령이 0 이 아닌 코드로 끝나면 상태 줄에 **"왜 실패했나요?"** 버튼이 생깁니다 (다음 명령이 성공하면 사라짐).
- 답은 오른쪽 아래 패널에 요약 · 원인 · 해결 방법(명령)으로 나옵니다.

### ③ SSH 접속 실패 진단

- ssh 가 오류로 끝나면 상태 줄에 **"접속 실패 진단"** 버튼이 생깁니다 (메뉴 AI > 접속 실패 진단).
- ssh 오류 메시지와 **저장된 호스트 설정**(주소·포트·사용자·인증 방식·키 파일·점프 호스트·접속 후 실행할 명령)을 함께 보내, 원인과 **호스트 설정의 어느 칸을 고치면 되는지** 알려 줍니다. 비밀번호는 보내지 않습니다.
- 해결 명령(예: `ssh-keygen -R`, `nc -vz`)은 이 Mac 에서 실행할 명령이라 [입력] 을 누르면 새 로컬 터미널에 들어갑니다.

## AI 에 보내는 정보

| 기능 | 보내는 것 |
| --- | --- |
| 명령 추천 | 입력한 질문, 환경(로컬 macOS·셸 또는 서버 이름·사용자), 현재 폴더 |
| 설명 | 위 환경 정보 + 선택한 글자 또는 화면에 보이는 마지막 80줄 (최대 12,000자, 뒤쪽 우선) |
| 접속 진단 | ssh 명령, 저장된 호스트 설정(비밀번호 제외), 화면의 오류 메시지 |

- 비밀번호·토큰·키로 보이는 문자열은 보내기 전에 `[가림]` 으로 바꿉니다 (`SecretRedactor`: `password=`, `Authorization:`, URL 의 `user:pass@`, 개인 키 블록, GitHub·AWS·Slack·Anthropic 토큰, JWT 등).
- 설명·진단은 기본으로 **보낼 내용을 먼저 보여 주고** "보내기" 를 눌러야 보냅니다 (설정에서 끌 수 있음).
- 화면 글자는 프롬프트에서 `<terminal_output>` 태그로 감싸 "지시가 아닌 데이터" 로 다룹니다.

## AI 제공자

설정(⌘,) > AI 에서 제공자를 고릅니다. 키와 모델은 제공자마다 따로 저장합니다.

| | Claude (Anthropic) | ChatGPT (OpenAI) | Gemini (Google) | EXAONE (LG AI연구원) |
| --- | --- | --- | --- | --- |
| API | Messages `POST /v1/messages` (`anthropic-version: 2026-10-21`) | Responses `POST /v1/responses` | Interactions `POST /v1beta/interactions` (`Api-Revision: 2026-05-20`) | Chat Completions `POST api.exaone.ai/v1/chat/completions` (OpenAI 호환) |
| 인증 | `x-api-key` | `Authorization: Bearer` | `x-goog-api-key` | `Authorization: Bearer` |
| JSON 응답 | `output_config.format` (json_schema) | `text.format` (json_schema, strict) | `response_format` (application/json + schema) | `response_format` (json_schema) + 시스템 프롬프트에 스키마 |
| 생각 깊이 | `output_config.effort` | `reasoning.effort` | `generation_config.thinking_level` | `reasoning_effort` (low→`low`, medium→`high`; 생각은 항상 켜짐) |
| 답 위치 | content 의 `text` 블록 (thinking 블록 무시) | output 의 message → `output_text` (reasoning 항목 무시) | steps 의 `model_output` → `text` (thought 무시) | 스트리밍(SSE) `delta.content` 를 모음 (`reasoning_content` 는 진행 표시에만) |
| 서버 저장 | — | `store: false` | `store: false` | 옵션 없음 |
| 기본 모델 | `claude-opus-5-5` | `gpt-6-astra` | `gemini-4-carbon` | `k-exaone_v2.5` |
| 목록 | Opus·Sonnet·Haiku 5.5 | gpt-6-astra · gpt-6.1-sol · gpt-6.1-terra · gpt-6-luna | gemini-4-carbon · gemini-4-argon · gemini-3.8-flash · gemini-3.5-flash-lite | k-exaone_v2.5 |

- 모든 제공자를 Swift 공식 SDK 없이 `URLSession` 으로 직접 부릅니다 (`AIClient` 프로토콜: `ClaudeClient`, `OpenAIClient`, `GeminiClient`, `ExaoneClient`).
- 요청·응답 모양과 모델 이름은 각 회사 공식 문서(2026-11) 기준입니다. 목록에 없는 모델은 "직접 입력…" 으로 쓸 수 있고, 이때는 지원 여부를 몰라 생각 깊이 값을 보내지 않습니다.
- ⌘K 는 생각 깊이 `low`, 설명·진단은 `medium`. 출력 한도는 생각 토큰을 포함해 ⌘K 8,000, 설명 16,000.
- EXAONE 은 생각이 항상 켜져 있고 속도가 느려(초당 약 30토큰) 답까지 보통 10~60초 걸립니다. 그래서 스트리밍으로 받아 120초 무응답 제한에 걸리지 않게 하고, 기다리는 동안 "생각하는 중… / 답을 쓰는 중…" 과 경과 초를 보여 줍니다 (다른 제공자는 경과 초만). 15초가 지나면 "생각이 길면 1분 넘게 걸릴 수 있습니다" 안내.
- EXAONE 은 문서에 "Structured outputs" 가 지원 기능으로만 적혀 있고 요청 형식은 없어, OpenAI 형식 `response_format` 과 함께 시스템 프롬프트에도 스키마를 넣고, 답에서 JSON 부분만 꺼내 읽습니다(앞 빈 줄·코드 블록 무시). 오류 본문 `{"result_code", "description"}` 의 description 을 서버 메시지로 보여 줍니다.
- Gemini 는 문서에 `additionalProperties` 지원이 명시되어 있지 않아 스키마에서 빼고 보내고, 응답은 디코딩으로 검사합니다.
- 오류 안내: 키 없음·잘못된 키(401)·**결제 필요(402: 계정 결제·크레딧 없음, 또는 모델이 지금 요금제에 없음)**·권한(403)·모델 없음(404)·요청 과다/한도(429)·서버 오류(5xx)·거절·길이 초과. 서버가 보낸 설명은 항상 "서버 메시지" 로 덧붙이고(Google 의 `[{"error": …}]` 배열, JSON 이 아닌 응답 포함), 오류 화면에서 바로 AI 설정을 열 수 있습니다.

## 오픈소스 배포 고려

- 사용자가 각자 API 키를 넣는 방식(BYOK)이며 키는 키체인(서비스 `kr.weare.myterminal.ai`, 계정 `anthropic-api-key` / `openai-api-key` / `gemini-api-key` / `exaone-api-key`)에 저장합니다. 요청 비용은 키의 계정에 청구됩니다.
- 다른 제공자나 로컬 모델은 `AIClient` 프로토콜을 구현하고 `AIProvider` 에 추가하면 붙일 수 있습니다.

## 안전장치

- 자동 실행 금지. 여러 줄 명령은 Enter 로 실행될 수 있어 [입력] 없이 복사만 됩니다.
- 위험 명령(`rm -rf`, `dd of=`, `mkfs`, `git push --force`, `curl | sh`, `shutdown`, `DROP DATABASE` 등)은 모델이 낮게 매겨도 **위험**으로 올리고 경고 문구를 보여 줍니다 (`DangerousCommand`).

## 셸 통합

"왜 실패했나요?" 와 현재 폴더 표시를 위해 Ghostty 셸 통합을 켰습니다 (`Resources/terminal-defaults.conf`: `shell-integration = detect`, `shell-integration-features = no-cursor,no-path`). 로컬 셸에만 적용되고, 커서 모양 설정과 PATH 는 건드리지 않습니다. SSH 화면의 원격 셸에는 적용되지 않으므로 서버에서는 ⇧⌘E(선택한 내용·화면 설명)를 씁니다.

## 코드

| 파일 | 내용 |
| --- | --- |
| `Sources/App/Services/AI/AIProvider.swift` | 제공자, 모델 목록, 키체인 계정 |
| `Sources/App/Services/AI/AIClient.swift` | 공통 요청·오류·HTTP |
| `Sources/App/Services/AI/ClaudeClient.swift` · `OpenAIClient.swift` · `GeminiClient.swift` · `ExaoneClient.swift` | 제공자별 호출 |
| `Sources/App/Services/AI/AIPrompts.swift` | 응답 형식·스키마, 프롬프트, 위험 명령, 화면 맥락 |
| `Sources/App/Services/AI/AIAssistant.swift` | 팔레트·패널 상태, 요청 흐름 |
| `Sources/App/Services/AI/AISettings.swift` | 제공자·모델·확인 설정, 제공자별 API 키(키체인) |
| `Sources/App/Services/AI/SecretRedactor.swift` | 민감 정보 가림 |
| `Sources/App/UI/AI/AIViews.swift` | ⌘K 팔레트, 결과 패널 |
| `Sources/GhosttyAdapter/TerminalSurfaceView.swift` | 화면·선택 글자 읽기, 입력줄에 넣기, 명령 종료 알림 |
| `Tests/Unit/AITests.swift` | 가림, 위험 명령, 요청 모양·응답 처리(네트워크 대역), 흐름, 실제 엔진 입력·셸 통합 |

## 다음 후보 (2차)

- 호스트 등록 도우미 (붙여넣은 ssh 명령·문장 → 호스트 칸 채우기)
- SFTP 로그 파일 요약, 원격 편집 중인 설정 파일 설명
- 분할 화면 두 서버 출력 비교
