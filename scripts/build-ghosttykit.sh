#!/usr/bin/env bash
# vendor/ghostty 에서 GhosttyKit.xcframework 를 빌드해 Frameworks/ 로 복사합니다.
#
# 사용법: scripts/build-ghosttykit.sh [debug|release] [--native]
#   기본: release, universal (Apple Silicon arm64 + Intel x86_64)
#   --native : 이 Mac 아키텍처만 (빌드가 빠르지만 Xcode 의 "Any Mac"·Archive·Release 빌드가 링크 실패)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$ROOT/vendor/ghostty"
OUT="$ROOT/Frameworks"
MODE="release"
XCTARGET="universal"
for arg in "$@"; do
  case "$arg" in
    release|debug) MODE="$arg" ;;
    --native) XCTARGET="native" ;;
    *) echo "사용법: $0 [debug|release] [--native]"; exit 1 ;;
  esac
done

case "$MODE" in
  release) OPT=(-Doptimize=ReleaseFast) ;;
  debug)   OPT=() ;;
  *) echo "사용법: $0 [debug|release]"; exit 1 ;;
esac

# xcode-select 가 Command Line Tools 를 가리켜도 Xcode 로 빌드되게 합니다.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

"$ROOT/scripts/bootstrap.sh"

echo "GhosttyKit 빌드 ($MODE, $XCTARGET)..."
(
  cd "$GHOSTTY"
  zig build \
    -Demit-macos-app=false \
    -Demit-xcframework=true \
    -Dxcframework-target="$XCTARGET" \
    ${OPT[@]+"${OPT[@]}"}
)

SRC="$GHOSTTY/macos/GhosttyKit.xcframework"
if [[ ! -d "$SRC" ]]; then
  echo "빌드 결과를 찾을 수 없습니다: $SRC" >&2
  exit 1
fi

mkdir -p "$OUT"
rm -rf "$OUT/GhosttyKit.xcframework"
cp -R "$SRC" "$OUT/"
echo "완료: $OUT/GhosttyKit.xcframework"

# 엔진이 앱 번들의 Contents/Resources 에서 찾는 리소스
#   terminfo/  : xterm-ghostty terminfo (TERM=xterm-ghostty 를 쓰려면 필요)
#   ghostty/   : 테마, 셸 통합 스크립트
"$ROOT/scripts/copy-ghostty-resources.sh"
