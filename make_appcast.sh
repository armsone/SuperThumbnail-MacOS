#!/bin/zsh
set -euo pipefail

# dist의 DMG 하나를 Sparkle로 서명해 appcast에 항목을 추가한다.
# 입력: APP_VERSION(생략하면 dist 앱의 버전), SPARKLE_BIN_DIR(생략하면 .build-release의 Sparkle 도구),
#       SPARKLE_KEY_ACCOUNT 또는 SPARKLE_ED_KEY_FILE(개인키 파일 경로만 전달, 이 스크립트는 읽지 않음),
#       DOWNLOAD_URL_PREFIX, RELEASE_NOTES_LINK, SPARKLE_PUBLIC_KEY(생략하면 Sparkle/sparkle_ed_public_key.txt)

package_root="${0:A:h}"
dist_dir="${package_root}/dist"
appcast_path="${dist_dir}/nasfinder-super-thumbnail.xml"
key_account="${SPARKLE_KEY_ACCOUNT:-NasFinderSuperThumbnail}"
sparkle_bin_dir="${SPARKLE_BIN_DIR:-${package_root}/.build-release/artifacts/sparkle/Sparkle/bin}"
dist_app="${dist_dir}/NasFinder Super Thumbnail.app"

app_version="${APP_VERSION:-}"
if [[ -z "${app_version}" && -f "${dist_app}/Contents/Info.plist" ]]; then
  app_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "${dist_app}/Contents/Info.plist")"
fi
if [[ ! "${app_version}" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 "APP_VERSION(예: 2.7.16)을 지정하거나 먼저 build_app.sh로 dist 앱을 만드세요."
  exit 1
fi

download_url_prefix="${DOWNLOAD_URL_PREFIX:-https://github.com/armsone/SuperThumbnail-MacOS/releases/download/v${app_version}/}"
release_notes_link="${RELEASE_NOTES_LINK:-https://github.com/armsone/SuperThumbnail-MacOS/releases/tag/v${app_version}}"
dmg_name="NasFinder-Super-Thumbnail-${app_version}.dmg"
dmg_path="${dist_dir}/${dmg_name}"

if [[ ! -x "${sparkle_bin_dir}/generate_appcast" ]]; then
  print -u2 "Sparkle 도구를 찾지 못했습니다: ${sparkle_bin_dir}/generate_appcast"
  print -u2 "SPARKLE_BIN_DIR에 Sparkle 2.9.4 릴리스의 bin 디렉터리를 지정하세요."
  exit 1
fi
if [[ ! -f "${dmg_path}" ]]; then
  print -u2 "DMG를 찾지 못했습니다: ${dmg_path}"
  exit 1
fi

expected_public_key="${SPARKLE_PUBLIC_KEY:-}"
public_key_file="${package_root}/Sparkle/sparkle_ed_public_key.txt"
if [[ -z "${expected_public_key}" && -f "${public_key_file}" ]]; then
  expected_public_key="$(<"${public_key_file}")"
fi
expected_public_key="${expected_public_key//$'\r'/}"
expected_public_key="${expected_public_key//$'\n'/}"
if [[ ! "${expected_public_key}" =~ '^[A-Za-z0-9+/]{43}=$' ]]; then
  print -u2 "Sparkle 공개키를 찾지 못했거나 형식이 올바르지 않습니다: ${public_key_file}"
  exit 1
fi

work_dir="$(mktemp -d "${dist_dir}/.appcast.XXXXXX")"
mount_dir="${work_dir}/mount"
mounted=0
cleanup() {
  if (( mounted )); then
    /usr/bin/hdiutil detach "${mount_dir}" -quiet >/dev/null 2>&1 || /usr/bin/hdiutil detach "${mount_dir}" -force -quiet >/dev/null 2>&1 || true
  fi
  rm -rf -- "${work_dir}"
}
trap cleanup EXIT

# DMG 안의 앱이 이 버전·공개키로 만들어졌는지 서명 전에 확인한다(읽기 전용 마운트).
mkdir -p "${mount_dir}"
/usr/bin/hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "${mount_dir}" "${dmg_path}" >/dev/null
mounted=1
bundled_plist="${mount_dir}/NasFinder Super Thumbnail.app/Contents/Info.plist"
if [[ ! -f "${bundled_plist}" ]]; then
  print -u2 "DMG 안에서 앱을 찾지 못했습니다: ${dmg_name}"
  exit 1
fi
bundled_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "${bundled_plist}")"
bundled_build="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "${bundled_plist}")"
bundled_key="$(/usr/bin/plutil -extract SUPublicEDKey raw -o - "${bundled_plist}" 2>/dev/null || true)"
bundled_feed="$(/usr/bin/plutil -extract SUFeedURL raw -o - "${bundled_plist}" 2>/dev/null || true)"
/usr/bin/hdiutil detach "${mount_dir}" -quiet >/dev/null
mounted=0

if [[ "${bundled_version}" != "${app_version}" ]]; then
  print -u2 "DMG 앱 버전(${bundled_version})이 APP_VERSION(${app_version})과 다릅니다."
  exit 1
fi
if [[ ! "${bundled_build}" =~ '^[0-9]+$' ]]; then
  print -u2 "DMG 앱의 빌드 번호가 숫자가 아닙니다: ${bundled_build}"
  exit 1
fi
if [[ "${bundled_key}" != "${expected_public_key}" ]]; then
  print -u2 "DMG 앱의 SUPublicEDKey가 공개키 파일과 다릅니다. 이 키로 서명한 appcast는 설치된 앱이 거부합니다."
  exit 1
fi
if [[ -z "${bundled_feed}" ]]; then
  print -u2 "DMG 앱에 SUFeedURL이 없습니다."
  exit 1
fi

# generate_appcast는 EdDSA 개인키를 Keychain(또는 지정한 키 파일)에서 직접 찾아 서명한다.
# 이 스크립트는 개인키 값을 읽거나 출력하지 않는다.
# 기존 appcast를 작업 폴더에 복사해 이전 항목을 보존하고, 검증을 마친 뒤에만 dist에 반영한다.
ditto "${dmg_path}" "${work_dir}/${dmg_name}"
if [[ -f "${appcast_path}" ]]; then
  ditto "${appcast_path}" "${work_dir}/appcast.xml"
fi

key_args=(--account "${key_account}")
if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
  key_args=(--ed-key-file "${SPARKLE_ED_KEY_FILE}")
fi

"${sparkle_bin_dir}/generate_appcast" \
  "${key_args[@]}" \
  --download-url-prefix "${download_url_prefix}" \
  --link "${release_notes_link}" \
  --maximum-deltas 0 \
  --maximum-versions 3 \
  -o "${work_dir}/appcast.xml" \
  "${work_dir}"

# 생성된 항목이 DMG의 버전·빌드·크기·주소와 맞고, 공개키로 서명이 검증되는지 확인한다.
item_xpath="//*[local-name()='item'][*[local-name()='version']='${bundled_build}']"
appcast_field() {
  /usr/bin/xmllint --xpath "string(${item_xpath}/$1)" "${work_dir}/appcast.xml"
}
item_short="$(appcast_field "*[local-name()='shortVersionString']")"
item_url="$(appcast_field "*[local-name()='enclosure']/@url")"
item_length="$(appcast_field "*[local-name()='enclosure']/@length")"
item_signature="$(appcast_field "*[local-name()='enclosure']/@*[local-name()='edSignature']")"
dmg_length="$(/usr/bin/stat -f %z "${dmg_path}")"

if [[ "${item_short}" != "${app_version}" ]]; then
  print -u2 "appcast에 ${app_version}(빌드 ${bundled_build}) 항목이 없습니다."
  exit 1
fi
if [[ "${item_url}" != "${download_url_prefix}${dmg_name}" || "${item_length}" != "${dmg_length}" ]]; then
  print -u2 "appcast 항목의 주소 또는 크기가 DMG와 다릅니다: ${item_url} / ${item_length} (DMG ${dmg_length})"
  exit 1
fi
if [[ -z "${item_signature}" ]]; then
  print -u2 "appcast 항목에 EdDSA 서명이 없습니다."
  exit 1
fi

verifier="${work_dir}/verify_ed_signature.swift"
cat > "${verifier}" <<'SWIFT'
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 7,
      let key = Data(base64Encoded: args[1]), key.count == 32,
      let signature = Data(base64Encoded: args[3]), signature.count == 64,
      let file = FileManager.default.contents(atPath: args[2]),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key)
else {
    FileHandle.standardError.write(Data("서명 검증 입력 형식 오류\n".utf8))
    exit(2)
}
guard publicKey.isValidSignature(signature, for: file) else { exit(1) }
// A replacement build uses the same download URL. Its old signature/length must not remain in the feed.
let feedURL = URL(fileURLWithPath: args[4])
let feed = try XMLDocument(contentsOf: feedURL)
for node in try feed.nodes(forXPath: "/rss/channel/item") {
    guard let item = node as? XMLElement,
          item.elements(forName: "enclosure").first?.attribute(forName: "url")?.stringValue == args[5]
    else { continue }
    let version = try item.nodes(forXPath: "*[local-name()='version']").first?.stringValue
    if version != args[6] { item.detach() }
}
try feed.xmlData(options: .nodePrettyPrint).write(to: feedURL, options: .atomic)
SWIFT
if ! /usr/bin/swift "${verifier}" "${expected_public_key}" "${dmg_path}" "${item_signature}" "${work_dir}/appcast.xml" "${item_url}" "${bundled_build}"; then
  print -u2 "appcast 서명이 앱의 SUPublicEDKey로 검증되지 않습니다. Keychain의 개인키가 이 공개키와 짝이 맞는지 확인하세요."
  exit 1
fi

if [[ -f "${appcast_path}" ]]; then
  ditto "${appcast_path}" "${appcast_path}.previous"
fi
ditto "${work_dir}/appcast.xml" "${appcast_path}.new"
mv -f -- "${appcast_path}.new" "${appcast_path}"

print "appcast 항목 검증 완료: ${app_version} (빌드 ${bundled_build}), 공개키 서명 일치"
print "완료: ${appcast_path}"
