#!/usr/bin/env bash
# 배포용 DMG 를 만든다: Release 빌드(universal) → Developer ID 서명 → 공증 → 스테이플 → DMG
#
# 사용법: scripts/release.sh [--skip-notarize] [--adhoc]
#   --skip-notarize : 서명까지만 (공증·스테이플 생략, 다른 Mac 에서는 Gatekeeper 경고가 뜬다)
#   --adhoc         : 임시 서명으로 묶기만 (서명 인증서 없이 패키징 확인용, 배포용 아님)
#
# 사전 준비 (한 번):
#   1. Developer ID Application 인증서
#      Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application
#   2. Config/Signing.local.xcconfig 에 DEVELOPMENT_TEAM (Signing.local.xcconfig.example 참고)
#   3. 공증 자격 증명을 키체인에 저장 (앱 암호는 appleid.apple.com 에서 만든다)
#        xcrun notarytool store-credentials myterminal-notary \
#          --apple-id <Apple ID> --team-id <팀 ID> --password <앱 암호>
#      프로필 이름은 NOTARY_PROFILE 환경 변수로 바꿀 수 있다.
#   4. 자동 업데이트(Sparkle) 서명 키: 비밀 키는 키체인(계정 이름 myterminal), 공개 키는 project.yml 의 SUPublicEDKey
#        <DerivedData>/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account myterminal
#      키를 잃으면 기존 사용자에게 업데이트를 보낼 수 없다. 백업: generate_keys --account myterminal -x <파일>
#      (비밀 키 파일은 저장소에 올리지 않는다)
#
# 결과: build/release/MyTerminal-<버전>.dmg, .sha256, appcast.xml (릴리스에 함께 올린다)
#
# 시험용 환경 변수 (평소에는 쓰지 않는다):
#   MYTERM_VERSION / MYTERM_BUILD : project.yml 대신 이 버전·빌드 번호로 만든다 (업데이트 시험용)
#   DOWNLOAD_URL_PREFIX           : appcast.xml 의 내려받기 주소 앞부분 (기본: GitHub 릴리스)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
NOTARY_PROFILE="${NOTARY_PROFILE:-myterminal-notary}"
NOTARIZE=1
ADHOC=0
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) NOTARIZE=0 ;;
    --adhoc) ADHOC=1; NOTARIZE=0 ;;
    *) echo "사용법: $0 [--skip-notarize] [--adhoc]"; exit 1 ;;
  esac
done

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$ROOT"

step() { printf '\n==> %s\n' "$1"; }
fail() { echo "오류: $1" >&2; exit 1; }

VERSION="${MYTERM_VERSION:-$(sed -nE 's/^ *MARKETING_VERSION: *"?([^"]+)"?/\1/p' project.yml | head -1)}"
BUILD="${MYTERM_BUILD:-$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: *"?([^"]+)"?/\1/p' project.yml | head -1)}"
[[ -n "$VERSION" && -n "$BUILD" ]] || fail "project.yml 에서 MARKETING_VERSION·CURRENT_PROJECT_VERSION 을 찾지 못했습니다"
REPO="choiseungyun/MyTerminal"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/$REPO/releases/download/v$VERSION/}"
SPARKLE_ACCOUNT="myterminal"
echo "MyTerminal $VERSION ($BUILD)"

# --- 서명 설정 -------------------------------------------------------------
if [[ $ADHOC -eq 1 ]]; then
  IDENTITY="-"
  TEAM=""
  echo "임시 서명(--adhoc): 패키징 확인용입니다. 배포하지 마세요."
else
  TEAM="$(sed -nE 's/^ *DEVELOPMENT_TEAM *= *([A-Z0-9]+).*/\1/p' Config/Signing.local.xcconfig 2>/dev/null | head -1)"
  [[ -n "$TEAM" && "$TEAM" != "YOUR_TEAM_ID" ]] || fail "Config/Signing.local.xcconfig 에 DEVELOPMENT_TEAM 이 없습니다"
  IDENTITY="$(security find-identity -v -p codesigning | sed -nE "s/.*\"(Developer ID Application: .*\\($TEAM\\))\".*/\1/p" | head -1)"
  [[ -n "$IDENTITY" ]] || fail "팀 $TEAM 의 'Developer ID Application' 인증서가 키체인에 없습니다 (사전 준비 1)"
  echo "서명: $IDENTITY"
  if [[ $NOTARIZE -eq 1 ]]; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
      || fail "공증 자격 증명 '$NOTARY_PROFILE' 이 없습니다 (사전 준비 3)"
  fi
fi

# --- 엔진: universal 이어야 한다 --------------------------------------------
step "GhosttyKit 확인"
# (pipefail 에서 `명령 | grep -q` 는 grep 이 먼저 끝나면 앞 명령이 SIGPIPE 로 실패해 잘못 판단하므로 변수에 담아 검사한다)
LIB="$(find Frameworks/GhosttyKit.xcframework -name '*.a' 2>/dev/null | head -1 || true)"
ARCHS="$([[ -n "$LIB" ]] && lipo -archs "$LIB" || true)"
if [[ "$ARCHS" != *x86_64* || "$ARCHS" != *arm64* ]]; then
  echo "universal 엔진이 없어 빌드합니다 (몇 분 걸립니다)"
  scripts/build-ghosttykit.sh release
fi
lipo -archs "$(find Frameworks/GhosttyKit.xcframework -name '*.a' | head -1)"

# --- 빌드 -----------------------------------------------------------------
step "Release 빌드 (arm64 + x86_64)"
rm -rf "$OUT"
mkdir -p "$OUT"
xcodegen generate >/dev/null
xcodebuild -project MyTerminal.xcodeproj -scheme MyTerminal -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$OUT/DerivedData" \
  -archivePath "$OUT/MyTerminal.xcarchive" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  archive | grep -E "error:|warning: .*sign|ARCHIVE (SUCCEEDED|FAILED)" || true
APP="$OUT/MyTerminal.xcarchive/Products/Applications/MyTerminal.app"
[[ -d "$APP" ]] || fail "빌드 실패 (위 오류 확인)"

# Sparkle 의 도우미 프로그램(Autoupdate, Updater.app, XPC 서비스)은 임시 서명으로 들어와서
# 그대로 두면 공증이 거절된다. 안쪽부터 Developer ID 로 다시 서명하고, 마지막에 앱을 다시 서명한다. (Sparkle 문서의 절차)
if [[ $ADHOC -eq 0 ]]; then
  step "Sparkle 다시 서명"
  SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
  [[ -d "$SPARKLE_FW" ]] || fail "Sparkle.framework 가 앱에 없습니다"
  sign() { codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@"; }
  sign "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
  sign "$SPARKLE_FW/Versions/B/Autoupdate"
  sign "$SPARKLE_FW/Versions/B/Updater.app"
  sign "$SPARKLE_FW"
  sign --preserve-metadata=entitlements,requirements,flags "$APP"
fi

step "서명 확인"
codesign --verify --deep --strict --verbose=2 "$APP"
SIGN_INFO="$(codesign -dv "$APP" 2>&1)"
grep -E "Authority|TeamIdentifier|flags|Identifier=" <<<"$SIGN_INFO" || true
lipo -archs "$APP/Contents/MacOS/MyTerminal"
if [[ $ADHOC -eq 0 && "$SIGN_INFO" != *runtime* ]]; then
  fail "Hardened Runtime 이 꺼져 있습니다 (공증 불가)"
fi
if [[ $ADHOC -eq 0 ]]; then
  while IFS= read -r code; do
    INFO="$(codesign -dv "$code" 2>&1)"
    [[ "$INFO" == *"TeamIdentifier=$TEAM"* && "$INFO" == *runtime* ]] \
      || fail "Developer ID·Hardened Runtime 으로 서명되지 않은 코드: ${code#$APP/}"
  done < <(find "$APP/Contents/Frameworks" \( -name "*.framework" -o -name "*.app" -o -name "*.xpc" -o -name Autoupdate \) -not -path "*/Versions/Current/*" -not -path "*.framework/Autoupdate")
  echo "안쪽 코드 서명 확인됨"
fi

notarize() {
  local file="$1"
  echo "공증 제출: $(basename "$file") (몇 분 걸립니다)"
  xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist > "$OUT/notary.plist"
  local status
  status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$OUT/notary.plist" 2>/dev/null || echo unknown)"
  if [[ "$status" != "Accepted" ]]; then
    local id
    id="$(/usr/libexec/PlistBuddy -c 'Print :id' "$OUT/notary.plist" 2>/dev/null || true)"
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
    fail "공증 실패: $status"
  fi
}

if [[ $NOTARIZE -eq 1 ]]; then
  step "앱 공증·스테이플"
  ditto -c -k --keepParent "$APP" "$OUT/MyTerminal-app.zip"
  notarize "$OUT/MyTerminal-app.zip"
  xcrun stapler staple "$APP"
  rm -f "$OUT/MyTerminal-app.zip"
fi

# --- DMG ------------------------------------------------------------------
step "DMG 만들기"
DMG="$OUT/MyTerminal-$VERSION.dmg"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/MyTerminal.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "MyTerminal $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
if [[ $ADHOC -eq 0 ]]; then
  codesign --sign "$IDENTITY" --timestamp "$DMG"
fi

if [[ $NOTARIZE -eq 1 ]]; then
  step "DMG 공증·스테이플"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -vv "$DMG"
fi

(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

# --- 자동 업데이트 목록 ------------------------------------------------------
if [[ $ADHOC -eq 0 ]]; then
  step "업데이트 목록 (appcast.xml)"
  SPARKLE_BIN="$OUT/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
  [[ -x "$SPARKLE_BIN/generate_appcast" ]] || fail "Sparkle 도구를 찾지 못했습니다 ($SPARKLE_BIN)"
  "$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p >/dev/null 2>&1 \
    || fail "업데이트 서명 키가 키체인에 없습니다 (사전 준비 4)"
  FEED="$OUT/feed"
  rm -rf "$FEED"
  mkdir -p "$FEED"
  cp "$DMG" "$FEED/"
  # 업데이트 창에 보일 변경 내용: CHANGELOG 의 이 버전 부분
  awk -v v="$VERSION" '
    $0 ~ "^## \\[" v "\\]" { on = 1; next }
    on && /^## \[/ { exit }
    on { print }
  ' CHANGELOG.md > "$FEED/MyTerminal-$VERSION.md"
  [[ -s "$FEED/MyTerminal-$VERSION.md" ]] || echo "주의: CHANGELOG.md 에 $VERSION 부분이 없어 변경 내용 없이 만듭니다"
  "$SPARKLE_BIN/generate_appcast" --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    --full-release-notes-url "https://github.com/$REPO/releases/tag/v$VERSION" \
    --embed-release-notes "$FEED"
  cp "$FEED/appcast.xml" "$OUT/appcast.xml"
  grep -q "sparkle:edSignature" "$OUT/appcast.xml" || fail "appcast.xml 에 업데이트 서명이 없습니다"
  grep -q "<sparkle:version>$BUILD</sparkle:version>" "$OUT/appcast.xml" || fail "appcast.xml 의 빌드 번호가 $BUILD 가 아닙니다"
fi

step "완료"
echo "$DMG"
cat "$DMG.sha256"
[[ -f "$OUT/appcast.xml" ]] && echo "$OUT/appcast.xml  ← 릴리스에 DMG 와 함께 올린다 (자동 업데이트)"
if [[ $NOTARIZE -eq 0 ]]; then
  echo "주의: 공증하지 않았습니다. 다른 Mac 에서는 Gatekeeper 경고가 뜹니다."
fi
