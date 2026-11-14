# 0004. SFTP 는 시스템 OpenSSH 위에서 프로토콜을 직접 구현한다

- 날짜: 2026-11-13
- 상태: 채택 (계획서의 "Citadel 또는 libssh2" 후보를 대체)

## 배경

M4(SFTP)의 가장 큰 위험은 터미널과 별개로 접속하면서 생기는 문제였다 (계획서 위험 요소).

- 인증을 두 번 해야 한다 (비밀번호·OTP)
- `~/.ssh/config`, ssh-agent, ProxyJump, 키 설정을 SSH 라이브러리에서 다시 구현해야 한다

## 검토한 방법

| 방법 | 장점 | 단점 |
| --- | --- | --- |
| Citadel (Swift, SwiftNIO SSH) | Swift 친화적 | ssh config·agent·ProxyJump 호환을 직접 구현. 인증 두 번 |
| libssh2 (C) | 오래 검증됨 | C 래퍼 필요, 위와 같은 호환 문제 |
| `sftp` 명령 일괄 모드 + 출력 해석 | 구현 간단 | 출력 형식에 의존, 진행률·오류 처리 빈약 |
| **`ssh -s 호스트 sftp` + SFTP v3 직접 구현** | 터미널과 같은 OpenSSH 사용, 연결 재사용 가능, 의존성 없음 | 프로토콜 코드(약 500줄)를 직접 유지 |

## 결정

1. SFTP 전송로는 `/usr/bin/ssh -s <호스트 인자> sftp` 프로세스의 표준 입출력이다.
2. 그 위에서 SFTP 버전 3 (OpenSSH 가 쓰는 버전) 을 Swift 로 구현한다: 목록, stat, 읽기·쓰기(요청 16개 동시 전송), 폴더 만들기·지우기, 이름 바꾸기(`posix-rename@openssh.com` 우선).
3. 앱이 여는 모든 ssh 에 **연결 재사용(ControlMaster)** 을 켠다.
   - `-o ControlMaster=auto -o ControlPath=/tmp/myterm-<uid>/%C -o ControlPersist=600`
   - 터미널에서 이미 인증한 연결을 SFTP·분할 화면이 그대로 쓴다 → 비밀번호·OTP 재입력 없음, 즉시 연결
   - 소켓 폴더는 사용자 전용(0700). 경로를 짧게 두는 이유: Unix 소켓 경로 104바이트 제한 (ssh 가 임시 접미사 17자를 붙임)
4. 테스트는 macOS 기본 `/usr/libexec/sftp-server` 에 직접 연결해 서버 없이 실제 프로토콜을 검사한다.

## 감수하는 점

- SFTP 프로토콜 코드를 직접 유지해야 한다. 범위를 v3 의 기본 기능으로 제한한다.
- 연결 재사용 때문에 마지막 화면을 닫아도 ssh 연결이 최대 10분 백그라운드에 남는다 (OpenSSH 의 일반적인 설정과 같음).
- 사용자의 `~/.ssh/config` 에 있는 ControlMaster 설정보다 앱의 명령줄 옵션이 우선한다.
