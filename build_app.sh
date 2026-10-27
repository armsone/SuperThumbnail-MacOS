#!/bin/zsh
set -euo pipefail

package_root="${0:A:h}"
build_root="${package_root}/.build-native-helper-v240"
legacy_build_root="${package_root}/.build-release"
output_app="${1:-${package_root}/dist/NasFinder Super Thumbnail.app}"
icon_source="${package_root}/Resources/AppIcon-1024.png"
current_stamp="$(date +%Y%m%d%H%M)"
app_version="${APP_VERSION:-2.7.1}"
build_number="${BUILD_NUMBER:-${current_stamp}}"
build_stamp="${DISPLAY_BUILD_NUMBER:-${current_stamp}}"

mkdir -p "${build_root}"
if [[ -d "${legacy_build_root}" ]]; then
  for item in checkouts artifacts repositories workspace-state workspace-state.json; do
    if [[ -e "${legacy_build_root}/${item}" && ! -e "${build_root}/${item}" ]]; then
      print "기존 빌드 캐시 재사용 복사: ${item}"
      cp -R "${legacy_build_root}/${item}" "${build_root}/${item}"
    fi
  done
fi

swift_build="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-build"
if [[ ! -x "${swift_build}" ]]; then
  swift_build="swift-build"
fi

print "arm64 아키텍처 빌드 중..."
CLANG_MODULE_CACHE_PATH="${build_root}/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="${build_root}/module-cache" \
"${swift_build}" \
  --build-system native \
  -c release \
  --package-path "${package_root}" \
  --scratch-path "${build_root}" \
  --cache-path "${build_root}/cache" \
  --config-path "${build_root}/config" \
  --security-path "${build_root}/security" \
  --disable-sandbox \
  --arch arm64

print "x86_64 아키텍처 빌드 중..."
CLANG_MODULE_CACHE_PATH="${build_root}/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="${build_root}/module-cache" \
"${swift_build}" \
  --build-system native \
  -c release \
  --package-path "${package_root}" \
  --scratch-path "${build_root}" \
  --cache-path "${build_root}/cache" \
  --config-path "${build_root}/config" \
  --security-path "${build_root}/security" \
  --disable-sandbox \
  --arch x86_64

find_arch_bin() {
  local arch="$1"
  local direct="${build_root}/${arch}-apple-macosx/release/NasFinderSuperThumbnailMac"
  if [[ -x "${direct}" ]]; then
    print "${direct}"
    return 0
  fi
  local found
  found="$(/usr/bin/find "${build_root}" -type f -name 'NasFinderSuperThumbnailMac' -path "*${arch}*/release/*" -print -quit)"
  if [[ -n "${found}" && -x "${found}" ]]; then
    print "${found}"
    return 0
  fi
  return 1
}

arm64_bin="$(find_arch_bin arm64)" || {
  print -u2 "arm64 바이너리를 찾지 못했습니다."
  exit 1
}

x86_64_bin="$(find_arch_bin x86_64)" || {
  print -u2 "x86_64 바이너리를 찾지 못했습니다."
  exit 1
}

mkdir -p "${build_root}/apple/Products/Release"
executable="${build_root}/apple/Products/Release/NasFinderSuperThumbnailMac"
rm -f "${executable}"
/usr/bin/lipo -create -output "${executable}" "${arm64_bin}" "${x86_64_bin}"

if [[ ! -x "${executable}" ]]; then
  print -u2 "유니버설 실행 파일을 찾지 못했습니다: ${executable}"
  exit 1
fi

sparkle_framework="$(/usr/bin/find "${build_root}/artifacts" -type d -name 'Sparkle.framework' -print -quit)"
if [[ -z "${sparkle_framework}" ]]; then
  print -u2 "Sparkle.framework 아티팩트를 찾지 못했습니다. swift build가 Sparkle 패키지를 내려받았는지 확인하세요."
  exit 1
fi

if [[ "${output_app}" != *.app || "${output_app}" == "/" ]]; then
  print -u2 "안전하지 않은 앱 출력 경로입니다: ${output_app}"
  exit 2
fi

rm -rf -- "${output_app}"
mkdir -p "${output_app}/Contents/MacOS" "${output_app}/Contents/Resources" "${output_app}/Contents/Frameworks"
ditto "${executable}" "${output_app}/Contents/MacOS/NasFinderSuperThumbnailMac"
ditto "${icon_source}" "${output_app}/Contents/Resources/AppIcon.png"
ditto "${sparkle_framework}" "${output_app}/Contents/Frameworks/Sparkle.framework"

conversion_engine_source="${package_root}/Resources/ConversionEngine"
if [[ -d "${conversion_engine_source}" ]]; then
  print "ConversionEngine (engine_cli.py + worker.py) 번들 복사 중: ${conversion_engine_source}"
  ditto "${conversion_engine_source}" "${output_app}/Contents/Resources/ConversionEngine"
  # 실행 중 생성된 Python 캐시는 배포 앱에 포함하지 않는다.
  rm -rf -- "${output_app}/Contents/Resources/ConversionEngine/__pycache__"
else
  print "참고: Resources/ConversionEngine (engine_cli.py, worker.py) 디렉토리가 아직 없어 번들에 포함하지 않습니다. (새 helper 모드에서 엔진 미포함으로 표시됩니다)"
fi

# SwiftPM 실행 파일의 기본 rpath는 ../lib이므로 앱 번들에 넣은 Frameworks도 명시한다.
install_name_tool -add_rpath '@executable_path/../Frameworks' \
  "${output_app}/Contents/MacOS/NasFinderSuperThumbnailMac"

info_plist="${output_app}/Contents/Info.plist"
plutil -create xml1 "${info_plist}"
plutil -insert CFBundleDevelopmentRegion -string ko "${info_plist}"
plutil -insert CFBundleDisplayName -string "NasFinder Super Thumbnail" "${info_plist}"
plutil -insert CFBundleExecutable -string NasFinderSuperThumbnailMac "${info_plist}"
plutil -insert CFBundleIconFile -string AppIcon.png "${info_plist}"
plutil -insert CFBundleIdentifier -string com.armsone.nasfinder.superthumbnail.mac "${info_plist}"
plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "${info_plist}"
plutil -insert CFBundleName -string "NasFinder Super Thumbnail" "${info_plist}"
plutil -insert CFBundlePackageType -string APPL "${info_plist}"
plutil -insert CFBundleShortVersionString -string "${app_version}" "${info_plist}"
plutil -insert CFBundleVersion -string "${build_number}" "${info_plist}"
plutil -insert BuildStamp -string "${build_stamp}" "${info_plist}"
plutil -insert LSMinimumSystemVersion -string 14.0 "${info_plist}"
plutil -insert NSHighResolutionCapable -bool true "${info_plist}"
plutil -insert NSPrincipalClass -string NSApplication "${info_plist}"

# Sparkle 업데이터 설정: 6시간 주기 자동 확인/설치, EdDSA 공개키는 비밀이 아니므로
# 저장소에 커밋된 파일이나 환경변수에서 읽어온다. 개인키는 절대 여기서 다루지 않는다.
plutil -insert SUFeedURL -string "https://nasfinder.com/appcasts/nasfinder-super-thumbnail.xml" "${info_plist}"
plutil -insert SUEnableAutomaticChecks -bool true "${info_plist}"
plutil -insert SUScheduledCheckInterval -integer 21600 "${info_plist}"
plutil -insert SUAutomaticallyUpdate -bool true "${info_plist}"

sparkle_public_key="${SPARKLE_PUBLIC_KEY:-}"
sparkle_public_key_file="${package_root}/Sparkle/sparkle_ed_public_key.txt"
if [[ -z "${sparkle_public_key}" && -f "${sparkle_public_key_file}" ]]; then
  sparkle_public_key="$(<"${sparkle_public_key_file}")"
fi
sparkle_public_key="${sparkle_public_key//$'\r'/}"
sparkle_public_key="${sparkle_public_key//$'\n'/}"

if [[ -n "${sparkle_public_key}" && ! "${sparkle_public_key}" =~ '^[A-Za-z0-9+/]{43}=$' ]]; then
  print -u2 "Sparkle 공개키 형식이 올바르지 않습니다. generate_keys가 출력한 EdDSA 공개키를 사용하세요."
  exit 3
fi

if [[ -n "${sparkle_public_key}" ]]; then
  plutil -insert SUPublicEDKey -string "${sparkle_public_key}" "${info_plist}"
elif [[ -n "${SIGN_IDENTITY:-}" ]]; then
  print -u2 "Sparkle 공개키가 없어 Developer ID 배포 빌드를 중단합니다."
  print -u2 "Sparkle/sparkle_ed_public_key.txt를 추가하거나 SPARKLE_PUBLIC_KEY를 지정하세요."
  exit 4
else
  print -u2 "경고: Sparkle 공개키가 없어 SUPublicEDKey를 생략합니다. 로컬/미서명 빌드에서만 허용됩니다."
fi

codesign_target() {
  local target="$1"
  if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${target}"
  else
    codesign --force --sign - "${target}"
  fi
}

# Sparkle 프레임워크 내부의 헬퍼(XPC 서비스, Autoupdate, Updater.app)는
# 바깥쪽 프레임워크/앱보다 먼저 개별 서명해야 한다.
sparkle_bundle="${output_app}/Contents/Frameworks/Sparkle.framework"
while IFS= read -r -d '' nested; do
  codesign_target "${nested}"
done < <(/usr/bin/find "${sparkle_bundle}" \( -name '*.xpc' -o -name 'Autoupdate' -o -name 'Updater.app' \) -print0)

codesign_target "${sparkle_bundle}"
codesign_target "${output_app}"

codesign --verify --deep --strict --verbose=2 "${output_app}"
print "완료: ${output_app}"

print "=== 최종 lipo -info ==="
/usr/bin/lipo -info "${output_app}/Contents/MacOS/NasFinderSuperThumbnailMac"

print "=== 최종 번들 엔진 sha256 ==="
/usr/bin/shasum -a 256 \
  "${output_app}/Contents/Resources/ConversionEngine/engine_cli.py" \
  "${output_app}/Contents/Resources/ConversionEngine/worker.py"
