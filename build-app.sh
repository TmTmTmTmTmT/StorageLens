#!/bin/bash
#
# StorageLens.app 빌드 + 서명.
# 서명 정책:
#   1) SIGN_ID 명시 시 그 ID 만 사용 (없으면 실패, "-" 거부).
#   2) 미지정 시 기본 Apple Development 해시를 기본 검색 목록 -> 실제 사용자 로그인 키체인 순으로 찾음
#      (brew 빌드처럼 HOME 이 임시 경로여도 로그인 키체인을 명시해 재검색).
#   3) 그래도 없으면 ad-hoc(-) 서명 + 경고. FDA 허용은 서명 요구사항에 묶여 업데이트마다 다시 허용해야 함.
#
set -euo pipefail
shopt -s nullglob

ROOT="$(cd "$(dirname "$0")" && pwd)"
# 버전은 여기 한 곳에서만 관리 (번들 Info.plist 에 PlistBuddy 로 주입). 빌드 번호는 BUILD_NUMBER 환경변수로 덮어쓸 수 있음.
VERSION="1.2.0"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
DEFAULT_SIGN_ID="422125C67A778CB23480AFBFE25A0EB7B8C91902"

# --- 서명 ID 결정 ---
USER_HOME="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
LOGIN_KEYCHAIN="${USER_HOME:+$USER_HOME/Library/Keychains/login.keychain-db}"
KEYCHAIN_ARGS=()
ADHOC=0

has_identity() { # $1=hash, $2...=키체인 (생략 시 기본 검색 목록)
    local id="$1"; shift
    security find-identity -v -p codesigning "$@" 2>/dev/null | grep -q "$id"
}
# HOME 이 임시 경로면 -v(유효성 검증)가 신뢰 설정/중간 인증서를 못 찾아 실패하므로, 로그인 키체인은 -v 없이 존재 여부만 확인
has_identity_loose() {
    local id="$1"; shift
    security find-identity -p codesigning "$@" 2>/dev/null | grep -q "$id"
}
locate_identity() { # 기본 목록 -> 로그인 키체인 순. 성공 시 0, KEYCHAIN_ARGS 설정
    if has_identity "$1"; then
        return 0
    elif [ -n "$LOGIN_KEYCHAIN" ] && [ -f "$LOGIN_KEYCHAIN" ] \
         && { has_identity "$1" "$LOGIN_KEYCHAIN" || has_identity_loose "$1" "$LOGIN_KEYCHAIN"; }; then
        KEYCHAIN_ARGS=(--keychain "$LOGIN_KEYCHAIN")
        return 0
    fi
    return 1
}

if [ -n "${SIGN_ID:-}" ]; then
    if [ "$SIGN_ID" = "-" ]; then
        echo "error: ad-hoc signing must not be requested explicitly (SIGN_ID=-)" >&2
        exit 1
    fi
    if ! locate_identity "$SIGN_ID"; then
        echo "error: signing identity '$SIGN_ID' not found in keychain (security find-identity -v -p codesigning)." >&2
        exit 1
    fi
elif locate_identity "$DEFAULT_SIGN_ID"; then
    SIGN_ID="$DEFAULT_SIGN_ID"
else
    SIGN_ID="-"
    ADHOC=1
fi

# --- 사전 검사 (실패 시 빌드 전에 중단) ---
echo "==> Preflight checks"
for f in catalog.json attribution-rules.json Info.plist; do
    if [ ! -f "$ROOT/Resources/$f" ]; then
        echo "error: required resource missing: Resources/$f" >&2
        exit 1
    fi
done
for f in catalog.json attribution-rules.json; do
    if ! python3 -m json.tool "$ROOT/Resources/$f" >/dev/null 2>&1; then
        echo "error: invalid JSON syntax: Resources/$f" >&2
        python3 -m json.tool "$ROOT/Resources/$f" >/dev/null || true
        exit 1
    fi
done
if ! plutil -lint "$ROOT/Resources/Info.plist" >/dev/null 2>&1; then
    echo "error: invalid Info.plist: Resources/Info.plist" >&2
    exit 1
fi

APP="$ROOT/build/StorageLens.app"
CONTENTS="$APP/Contents"
RES="$CONTENTS/Resources"

echo "==> Building (release)"
# shellcheck disable=SC2086
swift build -c release --package-path "$ROOT" ${SWIFT_BUILD_FLAGS:-}
EXE="$ROOT/.build/release/StorageLens"

echo "==> Assembling StorageLens.app"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$RES"
cp "$EXE" "$CONTENTS/MacOS/StorageLens"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS/Info.plist"
echo "    version $VERSION (build $BUILD_NUMBER)"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$RES/AppIcon.icns"
else
    echo "warning: Resources/AppIcon.icns not found (generate with: swift scripts/make-icon.swift); continuing without icon" >&2
fi
for f in "$ROOT"/Resources/*.json; do
    cp "$f" "$RES/"
done

if [ "$ADHOC" = 1 ]; then
    echo "" >&2
    echo "!!! 경고: Apple Development 인증서 없음 → ad-hoc 서명. 전체 디스크 접근 권한은 업데이트마다 다시 허용해야 함" >&2
    echo "" >&2
    echo "==> Signing (ad-hoc)"
    codesign --force --options runtime --sign - "$APP"
else
    echo "==> Signing with $SIGN_ID"
    codesign --force --options runtime --sign "$SIGN_ID" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

echo ""
echo "==> Done: $APP"
echo "    Run with: open \"$APP\""
