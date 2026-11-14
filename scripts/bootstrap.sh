#!/usr/bin/env bash
# 개발 환경 확인: Xcode, Zig, Ghostty 서브모듈
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$ROOT/vendor/ghostty"
XCODE_DEV="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ok=1

say()  { printf '  %-14s %s\n' "$1" "$2"; }
fail() { say "$1" "✗ $2"; ok=0; }

echo "MyTerminal 개발 환경 확인"

# Xcode
if [[ -d "$XCODE_DEV" ]]; then
  say "Xcode" "✓ $(DEVELOPER_DIR="$XCODE_DEV" xcodebuild -version | head -1)"
  if [[ "$(xcode-select -p)" != "$XCODE_DEV" ]]; then
    say "" "! xcode-select가 $(xcode-select -p) 를 가리킵니다."
    say "" "  해결: sudo xcode-select --switch /Applications/Xcode.app"
    say "" "  (그 전까지 스크립트는 DEVELOPER_DIR로 Xcode를 지정해 동작합니다)"
  fi
else
  fail "Xcode" "/Applications/Xcode.app 이 없습니다"
fi

# Ghostty 서브모듈
if [[ -f "$GHOSTTY/build.zig.zon" ]]; then
  tag="$(git -C "$GHOSTTY" describe --tags --exact-match 2>/dev/null || git -C "$GHOSTTY" rev-parse --short HEAD)"
  say "Ghostty" "✓ $tag"
else
  fail "Ghostty" "서브모듈이 없습니다. 실행: git submodule update --init"
fi

# Zig (Ghostty가 요구하는 최소 버전)
if command -v zig >/dev/null; then
  have="$(zig version)"
  need="$(sed -n 's/.*minimum_zig_version = "\(.*\)".*/\1/p' "$GHOSTTY/build.zig.zon" 2>/dev/null || true)"
  if [[ -n "$need" && "$(printf '%s\n%s\n' "$need" "$have" | sort -V | head -1)" != "$need" ]]; then
    fail "Zig" "$have (필요: $need 이상)"
  else
    say "Zig" "✓ $have (필요: ${need:-?} 이상)"
  fi
else
  fail "Zig" "없습니다. 실행: brew install zig"
fi

# Metal 컴파일러 (xcrun -f 는 구성요소가 없어도 성공하므로 실제로 실행해 본다)
if DEVELOPER_DIR="$XCODE_DEV" xcrun -sdk macosx metal --version >/dev/null 2>&1; then
  say "Metal" "✓ $(DEVELOPER_DIR="$XCODE_DEV" xcrun -sdk macosx metal --version 2>&1 | head -1)"
else
  fail "Metal" "Metal Toolchain이 없습니다. 실행: xcodebuild -downloadComponent MetalToolchain"
fi

[[ $ok == 1 ]] && echo "준비 완료" || { echo "위 항목을 해결해 주세요"; exit 1; }
