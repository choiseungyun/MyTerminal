#!/usr/bin/env bash
# vendor/ghostty 빌드 결과(zig-out/share)에서 앱에 넣을 리소스를 Frameworks/GhosttyResources 로 복사합니다.
# build-ghosttykit.sh 가 자동으로 호출합니다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHARE="$ROOT/vendor/ghostty/zig-out/share"
OUT="$ROOT/Frameworks/GhosttyResources"

for dir in terminfo ghostty; do
  if [[ ! -d "$SHARE/$dir" ]]; then
    echo "없음: $SHARE/$dir (먼저 scripts/build-ghosttykit.sh 를 실행하세요)" >&2
    exit 1
  fi
done

rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$SHARE/terminfo" "$OUT/terminfo"
cp -R "$SHARE/ghostty" "$OUT/ghostty"

echo "완료: $OUT ($(ls "$OUT/ghostty/themes" | wc -l | tr -d ' ')개 테마)"
