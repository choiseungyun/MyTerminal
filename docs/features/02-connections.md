# 접속 목록

마일스톤: M2 (**구현됨**)

저장한 서버에 클릭 한 번으로 접속합니다. 접속은 시스템 OpenSSH(`ssh`)를 터미널 화면에서 실행하는 방식이라, ssh-agent·키·`~/.ssh/config`와 그대로 호환됩니다.

## 호스트 항목

| 항목 | 설명 |
| --- | --- |
| 이름 | 카드에 보이는 이름. 비우면 주소(또는 ssh config 별칭) |
| 주소, 포트, 사용자 | 포트 22는 생략 |
| 인증 방식 | **키 · 에이전트 (자동)**: 키 파일·ssh-agent·ssh 기본 동작. **비밀번호**: Keychain에 저장, 접속 때 자동 입력 |
| 키 파일 | `-i 키 -o IdentitiesOnly=yes` |
| 점프 호스트 | **저장된 호스트를 고르면** 그 호스트의 키·포트·사용자(와 그 호스트의 경유)로 터널을 만든다 (`-o ProxyCommand=ssh … -W %h:%p …`). 직접 쓰면 `-J user@host:port` (경유 서버에는 키가 적용되지 않음). 명령·공백은 입력 불가 |
| 접속 후 실행할 명령 | 로그인한 뒤 서버에서 실행 (`ssh -t 호스트 '명령'`). 예: 키가 경유 서버 안에만 있을 때 `ssh -i .ssh/key 내부IP`. 터미널에만 적용, SFTP 는 그 서버 자체의 파일 |
| 그룹, 태그, 메모 | 정리·검색용 |
| ssh config 별칭 | 가져온 호스트. 접속은 `ssh 별칭`으로 ssh 설정을 그대로 따른다 |

저장 위치: `~/Library/Application Support/MyTerminal/myterminal.sqlite` (비밀번호는 저장하지 않음)

## 접속이 끝났을 때

- **정상 로그아웃**(`exit`, `logout` — ssh 종료 코드 0): 화면(분할이면 그 칸, 마지막이면 탭)을 바로 닫는다
- **오류로 끝남**(접속 실패, 연결 끊김 등 — 0 이 아님): "Process exited. Press any key…" 를 남겨 메시지를 볼 수 있게 하고, 키를 누르면 닫는다
- 엔진이 알려 주는 종료 코드는 macOS 에서 `/usr/bin/login` 래퍼를 거쳐 항상 0 이다 (Ghostty 주석·실험으로 확인). 그래서 ssh 를 작은 셸로 감싸 실제 종료 코드를 화면별 임시 파일(`$TMPDIR/MyTerminal/exit/`)에 남기고 그 값으로 판단한다 (`ExitStatus`)

## 화면

- **홈 > 호스트**: 그룹별 카드, 검색(이름·주소·사용자·그룹·태그), 정렬(이름순·최근 접속순)
- **카드**: 클릭하면 선택(파란 테두리), 더블클릭하면 새 탭 접속. 마우스를 올리거나 선택하면 연필(편집) 버튼이 보인다. 우클릭 메뉴: 새 탭에서 연결, 분할 화면으로 연결, 편집, 복제, ssh 명령 복사, 삭제
- **편집 패널**: 연필 버튼·"새 호스트"·우클릭 "편집"으로 오른쪽에 밀려 나온다 (팝업 아님). 패널이 열린 채 다른 카드를 클릭하면 그 호스트로 바뀐다
  - 기존 호스트: 고치는 즉시 자동 저장 (입력이 멈추고 0.4초 뒤, 머리글에 "저장됨"), 아래 "연결" 버튼
  - 새 호스트: 아래 "추가" 버튼으로 저장 → 같은 패널이 편집 모드로 바뀜
  - 머리글 `…` 메뉴: 새 탭·분할 화면으로 연결, 복제, ssh 명령 복사, 삭제 / `→|` 또는 esc 로 닫기
- **검색창 Enter**: `user@host`나 `ssh …`는 빠른 연결, 그 밖에는 검색 결과의 첫 호스트에 연결. 검색창 아래에 Enter가 무엇을 할지 표시
- **최근 빠른 연결**: 저장하지 않은 접속. 우클릭 → "호스트로 저장"
- **ssh config 가져오기**: `~/.ssh/config`의 Host 항목을 골라 가져오기. 그룹 지정, 이미 가져온 항목 제외

## 내보내기 · 가져오기

도구 막대 **가져오기 · 내보내기** 메뉴: 파일에서 가져오기, `~/.ssh/config` 에서 가져오기, 내보내기

- **형식:** JSON 파일 (`"format": "myterminal.hosts"`, `"version": 1`). 기본 파일 이름 `MyTerminal-hosts-YYYYMMDD.json`
- **들어가는 것:** 이름, 주소, 포트, 사용자, 키 파일 경로, 점프 호스트, 그룹, 태그, 인증 방식, ssh config 별칭, 메모, id
- **들어가지 않는 것:** **비밀번호**(Keychain), 최근 접속 시간, 만든·고친 시각. 파일이 다른 사람에게 전달될 수 있기 때문
- **내보내기:** 그룹을 골라 내보낸다 (기본 전체). 저장 후 Finder 에서 파일을 보여 준다
- **가져오기:** 미리보기에서 호스트마다 "새 호스트 / 이미 있음"을 표시
  - 같은 호스트 판단: 같은 id, 또는 접속 대상(주소·사용자·포트·별칭)이 같으면
  - 이미 있는 호스트 처리: **건너뛰기**(기본) · **덮어쓰기**(기존 id 유지 → 저장된 비밀번호·최근 접속 기록 유지) · **복사본으로 추가**
  - 다른 JSON 파일, 더 새 버전 파일, 빈 파일은 이유를 알려 주고 가져오지 않는다
- 키 파일 경로(`~/.ssh/...`)는 가져온 Mac 에도 같은 키가 있어야 동작한다

## `~/.ssh/config` 해석 범위

- `Host` 블록. 여러 별칭은 각각 항목. `*`, `?`, `!` 패턴은 제외
- `키 값`, `키=값`, 대소문자 무시, 따옴표 값, 같은 키는 첫 값 우선 (ssh와 같음)
- `Include` (상대 경로는 `~/.ssh` 기준, 와일드카드, 순환 방지). `Match` 블록은 제외
- 읽는 값: HostName, User, Port, IdentityFile, ProxyJump (표시용. 접속은 `ssh 별칭`)

## 비밀번호 자동 입력

방식은 [ADR 0003](../decisions/0003-askpass-password-autofill.md)에 있습니다.

- 비밀번호는 macOS 로그인 Keychain에 저장 (`dev.myterminal.host-password`, 계정 = 호스트 id). 호스트를 삭제하면 함께 삭제
- 저장된 비밀번호가 틀리면 같은 비밀번호를 다시 보내지 않고 터미널에서 직접 묻는다
- 호스트 키 확인(yes/no), 키 암호, OTP 같은 다른 질문은 터미널에서 직접 묻는다
- 키 암호는 저장하지 않는다. macOS ssh의 `UseKeychain`·ssh-agent를 쓰는 것을 권장

## 코드

| 파일 | 내용 |
| --- | --- |
| `Sources/App/Storage/SSHHost.swift` | 호스트 모델 |
| `Sources/App/Storage/AppDatabase.swift` | SQLite(GRDB), 마이그레이션 |
| `Sources/App/Storage/Keychain.swift` | 비밀번호 저장 |
| `Sources/App/Services/HostStore.swift` | 호스트 목록, 저장·삭제·최근 접속 |
| `Sources/App/Services/SSHCommand.swift` | 호스트 → ssh 명령줄, 셸 따옴표 처리 |
| `Sources/App/Services/SSHConfigParser.swift` | `~/.ssh/config` 해석 |
| `Sources/App/Services/AskpassServer.swift` | 비밀번호 자동 입력 (SSH_ASKPASS 서버 + 도우미 스크립트) |
| `Sources/App/UI/Home/HostsView.swift` | 호스트 화면, 카드 |
| `Sources/App/UI/Home/HostDetailPanel.swift` | 오른쪽 편집 패널 (자동 저장) |
| `Sources/App/Services/HostForm.swift` | 편집 입력값 검증 (포트, 태그, 빈 값) |
| `Sources/App/UI/Home/SSHConfigImportView.swift` | ssh config 가져오기 창 |
| `Sources/App/Services/HostTransfer.swift` | 내보내기·가져오기 형식, 중복 판단·처리 |
| `Sources/App/UI/Home/HostTransferViews.swift` | 내보내기·가져오기 창 |

## 이후 과제

- 첫 접속 때 OS 감지해 카드 아이콘 표시
- 목록(테이블) 보기, 태그 필터
- 포트 포워딩, Known Hosts 관리 (Termius에 있는 기능, v0.1 이후 검토)
