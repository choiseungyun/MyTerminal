# 릴리스와 자동 업데이트

새 버전을 만들어 GitHub 릴리스에 올리고, 설치된 앱이 자동 업데이트로 받게 하는 절차입니다.
왜 이렇게 하는지는 [ADR 0005](decisions/0005-direct-distribution.md)(Developer ID 직접 배포)와 [ADR 0006](decisions/0006-sparkle-auto-update.md)(Sparkle)에 있습니다.

> **코드를 `main` 에 푸시하는 것만으로는 업데이트되지 않습니다.**
> 앱은 **최신 GitHub 릴리스에 첨부된 `appcast.xml`** 만 봅니다. 버전을 올리고, 서명된 DMG 와 `appcast.xml` 을 릴리스에 올려야 사용자에게 알림이 갑니다.

## 동작 원리

```
설치된 앱 (Sparkle, 하루 한 번 또는 "업데이트 확인…")
  │  GET https://github.com/choiseungyun/MyTerminal/releases/latest/download/appcast.xml
  ▼     (GitHub 가 "Latest" 릴리스의 첨부 파일로 연결)
appcast.xml ── 새 빌드 번호(sparkle:version) · DMG 주소 · EdDSA 서명 · 변경 내용(CHANGELOG)
  │  앱의 CFBundleVersion 보다 빌드 번호가 크면 업데이트 창을 띄운다
  ▼
MyTerminal-<버전>.dmg 받기 → EdDSA 서명 확인(앱의 SUPublicEDKey) → 앱을 끌 때 교체
```

| 항목 | 값 | 위치 |
| --- | --- | --- |
| 업데이트 목록 주소 | `releases/latest/download/appcast.xml` | `project.yml` `SUFeedURL` |
| 업데이트 서명 공개 키 | `SUPublicEDKey` | `project.yml` |
| 업데이트 서명 비밀 키 | 로그인 키체인, 계정 이름 `myterminal` | 릴리스하는 Mac 에만 |
| 버전 / 빌드 번호 | `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` | `project.yml` |
| 업데이트 창의 변경 내용 | `## [<버전>]` 부분 | `CHANGELOG.md` |
| 앱 쪽 코드 | 확인 주기·자동 받기 설정, 메뉴 | `Sources/App/Services/AppUpdater.swift` |

- Sparkle 이 비교하는 것은 **빌드 번호**(`CURRENT_PROJECT_VERSION` → `CFBundleVersion` → `sparkle:version`)입니다. 버전 이름만 올리고 빌드 번호를 그대로 두면 업데이트가 뜨지 않습니다.
- Debug 빌드와 테스트에서는 업데이트를 켜지 않습니다 (개발 중인 앱이 공개 버전으로 바뀌지 않도록).
- 자동 업데이트는 0.1.2 부터 들어 있습니다. 0.1.0·0.1.1 사용자는 한 번 직접 받아 설치해야 합니다.

## 처음 한 번만: 준비

자세한 명령은 [`scripts/release.sh`](../scripts/release.sh) 머리 주석에 있습니다. `release.sh` 는 시작할 때 아래 준비가 되어 있는지 검사하고, 빠진 것이 있으면 몇 번 준비인지 알려 줍니다.

1. **Developer ID Application 인증서**: 팀의 계정 소유자가 발급합니다. Keychain Access 로 넣다가 `-25294` 오류가 나면
   `security import <인증서.cer> -k ~/Library/Keychains/login.keychain-db`
2. **`Config/Signing.local.xcconfig`** 에 `DEVELOPMENT_TEAM` (`Signing.local.xcconfig.example` 참고, git 에 올리지 않음)
3. **공증 자격 증명**을 키체인 프로필 `myterminal-notary` 로 저장 (`xcrun notarytool store-credentials …`)
4. **업데이트 서명 키** (Sparkle EdDSA): 비밀 키는 로그인 키체인 계정 `myterminal`, 공개 키는 `project.yml` 의 `SUPublicEDKey`
   - **비밀 키를 잃으면 기존 사용자에게 업데이트를 보낼 수 없습니다.** 반드시 백업해 안전한 곳에 둡니다 (저장소에 올리지 않음):
     `<DerivedData>/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account myterminal -x <백업 파일>`
   - 다른 Mac 에서 릴리스하려면 그 Mac 에 `generate_keys --account myterminal -f <백업 파일>` 로 가져옵니다.

## 매번: 릴리스 절차

예시는 0.1.4(빌드 5)입니다. 저장소 루트에서 실행합니다.

### 1. 출시할 코드 확인

```sh
git switch main && git pull
git status                     # 커밋 안 된 변경이 없어야 한다
xcodebuild -project MyTerminal.xcodeproj -scheme MyTerminal -destination 'platform=macOS' \
  -derivedDataPath build/dd-test test
```

- 테스트는 Xcode 와 다른 `-derivedDataPath`(`build/dd-test`)로 돌립니다. 같은 DerivedData 를 쓰면 서명 단계가 깨진 적이 있습니다.
- 앱에서 직접 확인해야 하는 항목은 [progress.md](progress.md)의 "사용자 확인 필요" 를 봅니다.

### 2. 버전 올리기

`project.yml`:

```yaml
MARKETING_VERSION: "0.1.4"         # 화면에 보이는 버전
CURRENT_PROJECT_VERSION: "5"       # 빌드 번호: 지난 릴리스보다 반드시 커야 한다
```

### 3. 변경 내용 쓰기 (`CHANGELOG.md`)

`## [Unreleased]` 를 `## [0.1.4] - YYYY-MM-DD` 로 바꾸고 내용을 다듬습니다.
**이 부분이 그대로 사용자의 업데이트 창에 나옵니다.** 사용자 입장의 문장으로 씁니다.
제목 형식(`## [0.1.4]`)이 다르면 `release.sh` 가 변경 내용 없이 `appcast.xml` 을 만듭니다 ("주의: CHANGELOG.md 에 … 부분이 없어" 가 출력됨).

### 4. 서명·공증·DMG·업데이트 목록 만들기

```sh
scripts/release.sh
```

하는 일 (10분 남짓, 대부분 Apple 공증 대기):

1. 준비 검사 (인증서, 팀, 공증 프로필)
2. 엔진(GhosttyKit)이 universal(arm64 + x86_64)인지 확인, 아니면 다시 빌드
3. Release 빌드(universal), Developer ID 서명, Hardened Runtime
4. **Sparkle 도우미 다시 서명**: Sparkle 이 임시 서명으로 넣어 주는 Installer/Downloader XPC, Autoupdate, Updater.app 을 Developer ID 로 다시 서명합니다. 안 하면 공증이 거절됩니다.
5. 서명 검사 (안쪽 코드까지 팀 ID·Hardened Runtime)
6. 앱 공증·스테이플 → DMG 만들기·서명 → DMG 공증·스테이플 → Gatekeeper 검사
7. `.sha256` 만들기
8. `generate_appcast` 로 `appcast.xml` 만들기: CHANGELOG 의 이 버전 부분을 넣고, 키체인의 비밀 키로 DMG 에 EdDSA 서명. 서명과 빌드 번호가 들어갔는지 검사

결과 (`build/release/`):

| 파일 | 용도 |
| --- | --- |
| `MyTerminal-0.1.4.dmg` | 설치·업데이트 파일 |
| `MyTerminal-0.1.4.dmg.sha256` | 체크섬 |
| `appcast.xml` | 자동 업데이트 목록 |

공증이 거절되면 스크립트가 공증 기록(`notarytool log`)을 출력하고 멈춥니다. 대부분 서명되지 않은 안쪽 코드가 원인입니다.

### 5. 버전 변경 커밋·푸시

```sh
git add project.yml CHANGELOG.md docs/progress.md
git commit -m "v0.1.4: …"
git push origin main
```

### 6. GitHub 릴리스 만들기

```sh
gh release create v0.1.4 --target main --title "MyTerminal 0.1.4" --notes-file <릴리스 노트 파일> \
  build/release/MyTerminal-0.1.4.dmg \
  build/release/MyTerminal-0.1.4.dmg.sha256 \
  build/release/appcast.xml
```

- **세 파일을 모두 올립니다.** `appcast.xml` 을 빠뜨리면 `latest/download/appcast.xml` 이 없는 파일이 되어 사용자의 업데이트 확인이 실패합니다.
- 초안(`--draft`)이나 시험판(`--prerelease`)으로 만들지 않습니다. `latest` 주소는 **정식 최신 릴리스**만 가리키므로 앱이 이 버전을 보지 못합니다.
- 릴리스 노트 형식 (지난 릴리스와 같게):
  1. 한두 줄 소개 ("… 버전입니다. 0.1.2 이상을 쓰고 있다면 앱이 이 버전을 알려 주고 설치합니다.")
  2. CHANGELOG 의 이 버전 부분 (`### 추가`, `### 수정` …)
  3. `### 설치`: DMG 를 Applications 로 끌어 넣기, macOS 14 이상, Apple Silicon · Intel, Developer ID 서명·공증, `.sha256`
  4. "`appcast.xml` 은 앱이 새 버전을 확인할 때 쓰는 파일입니다."
  5. 전체 변경 기록 링크

### 7. 공개된 것 확인

```sh
# 공개 주소의 업데이트 목록이 새 빌드를 가리키는지
curl -sL https://github.com/choiseungyun/MyTerminal/releases/latest/download/appcast.xml \
  | grep -E 'sparkle:(version|shortVersionString)|edSignature|url='

# 내려받은 DMG 의 체크섬과 Gatekeeper
curl -sLO https://github.com/choiseungyun/MyTerminal/releases/download/v0.1.4/MyTerminal-0.1.4.dmg
shasum -a 256 MyTerminal-0.1.4.dmg            # build/release/*.sha256 과 같아야 한다
spctl -a -t open --context context:primary-signature -vv MyTerminal-0.1.4.dmg   # accepted (Notarized Developer ID)
```

- `sparkle:version` 이 새 빌드 번호(5)이고, `url` 이 `releases/download/v0.1.4/MyTerminal-0.1.4.dmg` 이면 됩니다.
- 이전 버전 앱에서 메뉴 MyTerminal > **업데이트 확인…** 을 누르면 바로 확인할 수 있습니다.

### 8. 기록

[progress.md](progress.md) 의 상단 "현재 단계" 와 변경 기록에 릴리스 내용(버전·빌드, DMG 크기, 공증·Gatekeeper·appcast 확인)을 적고 커밋·푸시합니다.

## 사용자 쪽에서 일어나는 일

- 처음 실행 후 자동 확인을 켤지 한 번 묻습니다. 켜면 **하루에 한 번 정도** 확인합니다.
- 언제든 메뉴 MyTerminal > "업데이트 확인…", 또는 설정 > "업데이트" 탭(지금 버전, 마지막 확인, 자동 확인·미리 받기)에서 확인할 수 있습니다.
- 새 버전이 있으면 변경 내용(CHANGELOG)을 보여 주고, 받은 DMG 의 EdDSA 서명이 맞을 때만 설치합니다. 교체는 앱을 끌 때 이루어집니다 (약 2초).
- 사용 환경 정보는 보내지 않습니다 (`SUEnableSystemProfiling = false`).

## 문제가 생겼을 때

| 증상 | 원인·해결 |
| --- | --- |
| 업데이트가 뜨지 않음 | 빌드 번호를 올리지 않았거나, 릴리스가 초안·시험판이거나, `appcast.xml` 을 첨부하지 않음. 7단계의 `curl` 로 확인 |
| "업데이트 확인 중 오류" | `latest/download/appcast.xml` 이 없음(첨부 누락) 또는 형식 오류. 릴리스에 다시 첨부 |
| 받은 뒤 "서명이 올바르지 않음" | `appcast.xml` 을 다른 비밀 키로 만들었거나, DMG 를 다시 만든 뒤 `appcast.xml` 을 다시 만들지 않음. DMG 와 `appcast.xml` 은 **같은 실행 결과**를 함께 올린다 |
| 공증 거절 | 4단계 출력의 `notarytool log` 확인. Sparkle 도우미 다시 서명이 빠지면 거절된다 |
| 잘못된 버전을 냈음 | 이미 받은 사용자는 되돌릴 수 없습니다. 고친 버전을 **더 큰 빌드 번호**로 바로 다시 냅니다 |
| 다른 Mac 에서 릴리스 | 준비 1~4 를 그 Mac 에서 다시 합니다. 특히 업데이트 서명 비밀 키를 백업에서 가져와야 합니다 |

## 업데이트를 실제로 시험하기 (공개하지 않고)

공개 릴리스를 만들지 않고, 이 Mac 에서만 열리는 업데이트 목록으로 실제 교체까지 시험할 수 있습니다 (0.1.2 → 0.1.3 을 이렇게 확인함).

1. 낮은 버전으로 서명된 앱을 만들어 설치: `MYTERM_VERSION=0.1.3 MYTERM_BUILD=4 scripts/release.sh`
2. 높은 버전을 로컬 주소로 만들기: `MYTERM_VERSION=0.1.4 MYTERM_BUILD=5 DOWNLOAD_URL_PREFIX=http://127.0.0.1:8000/ scripts/release.sh`
3. `build/release/` 에서 `python3 -m http.server 8000` 으로 DMG 와 `appcast.xml` 을 내보낸다
4. 설치된 앱이 그 목록을 보게 한다: `defaults write kr.weare.myterminal SUFeedURL http://127.0.0.1:8000/appcast.xml`
5. 앱에서 "업데이트 확인…" → 설치 → 교체된 앱 버전·서명 확인 (`codesign -dv /Applications/MyTerminal.app`)
6. **끝나면 시험 설정을 지운다**: `defaults read kr.weare.myterminal` 에서 `SU` 로 시작하는 키를 `defaults delete kr.weare.myterminal <키>` 로 지우고, 시험으로 만든 `build/release/` 를 지운다 (공개 릴리스 전에 반드시 `scripts/release.sh` 를 다시 실행)
