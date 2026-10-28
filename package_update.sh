#!/bin/zsh
set -euo pipefail

# 자동 업데이트용 배포 패키지를 처음부터 끝까지 한 번에 만든다:
#   빌드(Developer ID + hardened runtime) → 앱 공증·스테이플 → DMG 서명·공증·스테이플
#   → 최종 DMG 기준 Sparkle appcast 서명·검증(make_appcast.sh).
# 업로드·게시는 하지 않는다. 결과는 dist/에 남고, 마지막 출력에 게시할 파일이 나온다.
#
# 필수 환경변수
#   CODESIGN_IDENTITY   "Developer ID Application: ..." (SIGN_IDENTITY도 허용)
#   NOTARY_PROFILE      xcrun notarytool store-credentials로 등록한 Keychain 프로필 이름
# 선택 환경변수
#   APP_VERSION         생략하면 build_app.sh의 기본 버전
#   BUILD_NUMBER        생략하면 현재 시각(yyyyMMddHHmm). 기존 빌드보다 커야 한다
#   SPARKLE_BIN_DIR     생략하면 .build-release/artifacts/sparkle/Sparkle/bin
#   SPARKLE_KEY_ACCOUNT / SPARKLE_ED_KEY_FILE   make_appcast.sh 참고
# 옵션
#   --check             빌드 없이 입력·도구만 점검하고 끝낸다

package_root="${0:A:h}"
dist_dir="${package_root}/dist"
app_path="${dist_dir}/NasFinder Super Thumbnail.app"
appcast_path="${dist_dir}/nasfinder-super-thumbnail.xml"
identity="${CODESIGN_IDENTITY:-${SIGN_IDENTITY:-}}"
notary_profile="${NOTARY_PROFILE:-}"
sparkle_bin_dir="${SPARKLE_BIN_DIR:-${package_root}/.build-release/artifacts/sparkle/Sparkle/bin}"
check_only=0

case "${1:-}" in
  "") ;;
  --check) check_only=1 ;;
  *) print -u2 "사용법: $0 [--check]"; exit 64 ;;
esac

app_version="${APP_VERSION:-$(sed -n 's/^app_version="\${APP_VERSION:-\(.*\)}"$/\1/p' "${package_root}/build_app.sh")}"
build_number="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
dmg_name="NasFinder-Super-Thumbnail-${app_version}.dmg"
dmg_path="${dist_dir}/${dmg_name}"

fail() { print -u2 "오류: $*"; exit 1; }

# ---------- 1. 입력·도구 점검 ----------
[[ "${app_version}" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "APP_VERSION 형식이 올바르지 않습니다: ${app_version}"
[[ "${build_number}" =~ '^[0-9]+$' ]] || fail "BUILD_NUMBER는 숫자여야 합니다: ${build_number}"
[[ "${identity}" == "Developer ID Application:"* ]] || fail "CODESIGN_IDENTITY에 'Developer ID Application: ...' 신원이 필요합니다."
[[ -n "${notary_profile}" ]] || fail "NOTARY_PROFILE(notarytool Keychain 프로필 이름)이 필요합니다."
[[ -f "${package_root}/Sparkle/sparkle_ed_public_key.txt" || -n "${SPARKLE_PUBLIC_KEY:-}" ]] || fail "Sparkle 공개키가 없습니다."
[[ -x "${sparkle_bin_dir}/generate_appcast" ]] || fail "Sparkle 도구를 찾지 못했습니다: ${sparkle_bin_dir}"
for tool in xmllint swift hdiutil codesign ditto; do
  command -v "${tool}" >/dev/null || fail "필요한 도구가 없습니다: ${tool}"
done
xcrun --find notarytool >/dev/null || fail "notarytool을 찾지 못했습니다."
xcrun --find stapler >/dev/null || fail "stapler를 찾지 못했습니다."
if ! security find-identity -v -p codesigning | grep -F -- "${identity}" >/dev/null; then
  fail "서명 신원이 현재 Keychain에 없습니다: ${identity}"
fi

# 설치된 앱이 업데이트로 인식하려면 빌드 번호가 이전 빌드·appcast 항목보다 커야 한다.
previous_max=0
if [[ -f "${app_path}/Contents/Info.plist" ]]; then
  previous_max="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "${app_path}/Contents/Info.plist" 2>/dev/null || print 0)"
fi
if [[ -f "${appcast_path}" ]]; then
  for listed in $(/usr/bin/xmllint --xpath "//*[local-name()='item']/*[local-name()='version']/text()" "${appcast_path}" 2>/dev/null || true); do
    if [[ "${listed}" =~ '^[0-9]+$' ]] && (( listed > previous_max )); then
      previous_max="${listed}"
    fi
  done
fi
[[ "${previous_max}" =~ '^[0-9]+$' ]] || previous_max=0
(( build_number > previous_max )) || fail "BUILD_NUMBER(${build_number})가 기존 빌드(${previous_max})보다 커야 합니다."

print "점검 통과: 버전 ${app_version}, 빌드 ${build_number}, 신원 ${identity}"
if (( check_only )); then
  exit 0
fi

mkdir -p "${dist_dir}"
lock_dir="${dist_dir}/.package_update.lock"
mkdir "${lock_dir}" 2>/dev/null || fail "다른 package_update.sh가 실행 중이거나 잠금이 남아 있습니다: ${lock_dir}"
work_dir=""
mount_dir=""
cleanup() {
  if [[ -n "${mount_dir}" ]]; then
    /usr/bin/hdiutil detach "${mount_dir}" -quiet >/dev/null 2>&1 || /usr/bin/hdiutil detach "${mount_dir}" -force -quiet >/dev/null 2>&1 || true
  fi
  if [[ -n "${work_dir}" ]]; then
    rm -rf -- "${work_dir}"
  fi
  rmdir "${lock_dir}" 2>/dev/null || true
}
trap cleanup EXIT
work_dir="$(mktemp -d "${dist_dir}/.package.XXXXXX")"

# ---------- 함수 ----------
notarize() {
  local artifact="$1" result="${work_dir}/notary-$2.json" status
  xcrun notarytool submit "${artifact}" --keychain-profile "${notary_profile}" --wait --output-format json > "${result}"
  status="$(/usr/bin/plutil -extract status raw -o - "${result}")"
  if [[ "${status}" != "Accepted" ]]; then
    /usr/bin/plutil -p "${result}" >&2
    fail "Apple 공증이 거부되었거나 완료되지 않았습니다(${status}): $2. 제출 ID로 'xcrun notarytool log'를 확인하세요."
  fi
  print "공증 승인: $2"
}

# 앱 안의 모든 Mach-O가 Developer ID + hardened runtime + 보안 타임스탬프이고 팀이 하나뿐인지 확인한다.
verify_nested_signatures() {
  local root="$1" checked=0 file details team
  local -a teams unique_teams
  while IFS= read -r -d '' file; do
    [[ "$(/usr/bin/file -b "${file}")" == *Mach-O* ]] || continue
    details="$(codesign -dvvv "${file}" 2>&1)" || fail "서명 정보를 읽지 못했습니다: ${file#${root}/}"
    [[ "${details}" == *"Authority=Developer ID Application:"* ]] || fail "Developer ID 서명이 아닙니다: ${file#${root}/}"
    [[ "${details}" == *"(runtime)"* ]] || fail "hardened runtime이 없습니다: ${file#${root}/}"
    [[ "${details}" == *"Timestamp="* ]] || fail "보안 타임스탬프가 없습니다: ${file#${root}/}"
    team="$(print -r -- "${details}" | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/sed -n 1p)"
    [[ -n "${team}" ]] || fail "TeamIdentifier가 없습니다: ${file#${root}/}"
    teams+=("${team}")
    checked=$((checked + 1))
  done < <(/usr/bin/find "${root}" -type f -print0)
  (( checked > 0 )) || fail "검사할 Mach-O를 찾지 못했습니다: ${root}"
  unique_teams=(${(u)teams})
  (( ${#unique_teams} == 1 )) || fail "서로 다른 팀 서명이 섞여 있습니다: ${unique_teams}"
  print "중첩 Mach-O ${checked}개 서명 확인 (팀 ${unique_teams[1]})"
}

verify_distribution_policy() {
  if command -v syspolicy_check >/dev/null 2>&1; then
    syspolicy_check distribution "$1"
  else
    spctl --assess --type execute --verbose=4 "$1"
  fi
}

# ---------- 2. 빌드·서명 ----------
print "=== 1/5 빌드 및 Developer ID 서명 ==="
SIGN_IDENTITY="${identity}" APP_VERSION="${app_version}" BUILD_NUMBER="${build_number}" DISPLAY_BUILD_NUMBER="${build_number}" \
  "${package_root}/build_app.sh"
built_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "${app_path}/Contents/Info.plist")"
built_build="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "${app_path}/Contents/Info.plist")"
[[ "${built_version}" == "${app_version}" && "${built_build}" == "${build_number}" ]] || fail "빌드 결과 버전(${built_version}/${built_build})이 요청과 다릅니다."
/usr/bin/plutil -extract SUPublicEDKey raw -o - "${app_path}/Contents/Info.plist" >/dev/null || fail "빌드된 앱에 SUPublicEDKey가 없습니다."
verify_nested_signatures "${app_path}"

# ---------- 3. 앱 공증 ----------
print "=== 2/5 앱 공증 ==="
ditto -c -k --keepParent "${app_path}" "${work_dir}/app.zip"
notarize "${work_dir}/app.zip" app
xcrun stapler staple "${app_path}"
xcrun stapler validate "${app_path}"
codesign --verify --deep --strict --verbose=2 "${app_path}"

# ---------- 4. DMG ----------
print "=== 3/5 DMG 생성·서명·공증 ==="
staging_dir="${work_dir}/staging"
mkdir -p "${staging_dir}"
ditto "${app_path}" "${staging_dir}/NasFinder Super Thumbnail.app"
ln -s /Applications "${staging_dir}/Applications"
new_dmg="${work_dir}/${dmg_name}"
hdiutil create -volname "NasFinder Super Thumbnail" -srcfolder "${staging_dir}" -fs HFS+ -format UDZO -ov "${new_dmg}"
hdiutil verify "${new_dmg}"
codesign --force --timestamp --sign "${identity}" "${new_dmg}"
codesign --verify --strict --verbose=2 "${new_dmg}"
notarize "${new_dmg}" dmg
xcrun stapler staple "${new_dmg}"
xcrun stapler validate "${new_dmg}"

# ---------- 5. 최종 DMG 검증 ----------
print "=== 4/5 최종 DMG 검증 ==="
mount_dir="${work_dir}/mount"
mkdir -p "${mount_dir}"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "${mount_dir}" "${new_dmg}" >/dev/null
mounted_app="${mount_dir}/NasFinder Super Thumbnail.app"
codesign --verify --deep --strict --verbose=2 "${mounted_app}"
xcrun stapler validate "${mounted_app}"
verify_nested_signatures "${mounted_app}"
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "${mounted_app}/Contents/Info.plist")" == "${app_version}" ]] || fail "DMG 안 앱 버전이 다릅니다."
[[ "$(/usr/bin/plutil -extract CFBundleVersion raw -o - "${mounted_app}/Contents/Info.plist")" == "${build_number}" ]] || fail "DMG 안 앱 빌드가 다릅니다."
main_archs="$(/usr/bin/lipo -archs "${mounted_app}/Contents/MacOS/NasFinderSuperThumbnailMac")"
[[ " ${main_archs} " == *" arm64 "* && " ${main_archs} " == *" x86_64 "* ]] || fail "유니버설(arm64+x86_64) 실행 파일이 아닙니다: ${main_archs}"
hdiutil detach "${mount_dir}" -quiet
mount_dir=""
verify_distribution_policy "${new_dmg}"
verify_distribution_policy "${app_path}"

mv -f -- "${new_dmg}" "${dmg_path}"

# ---------- 6. appcast ----------
print "=== 5/5 Sparkle appcast 서명·검증 ==="
APP_VERSION="${app_version}" SPARKLE_BIN_DIR="${sparkle_bin_dir}" "${package_root}/make_appcast.sh"

print ""
print "=== 게시할 파일 (이 스크립트는 업로드하지 않습니다) ==="
print "DMG      : ${dmg_path}"
print "DMG sha256: $(/usr/bin/shasum -a 256 "${dmg_path}" | cut -d' ' -f1)"
print "appcast  : ${appcast_path}"
print "게시 순서: ① GitHub 릴리스 v${app_version}에 DMG(+release.json) 업로드 → ② appcast를 SUFeedURL 위치에 게시"
