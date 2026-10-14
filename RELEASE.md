# NasFinder Super Thumbnail Mac 릴리스 절차

## Sparkle EdDSA 키

Sparkle 업데이트 서명에는 EdDSA 키 쌍이 필요합니다.

1. Sparkle 2.9.4 릴리스(`https://github.com/sparkle-project/Sparkle/releases`)의 `Sparkle-2.9.4.tar.xz`를 내려받아 `bin/generate_keys`를 실행합니다.
2. `generate_keys`는 개인키를 실행 계정의 로그인 Keychain에 저장하고, 공개키를 표준 출력으로 보여줍니다.
3. 공개키를 `Sparkle/sparkle_ed_public_key.txt`에 붙여넣고 커밋합니다. **공개키는 비밀이 아니므로 저장소에 커밋해도 안전합니다.**
4. 개인키는 절대 저장소나 CI 로그에 넣지 마세요. `generate_appcast`와 `sign_update`는 실행 시점에 로컬 Keychain에서 개인키를 직접 찾습니다.

공개키 파일을 저장소에 두면 어떤 빌드 머신에서든 `build_app.sh`가 추가 비밀 없이 `SUPublicEDKey`를 자동으로 채울 수 있다는 뜻입니다. 다만 appcast 서명(`make_appcast.sh`)은 개인키가 있는 Keychain을 가진 신뢰된 머신에서만 실행할 수 있어야 합니다. 여러 대의 빌드 머신을 쓴다면 개인키를 안전한 비밀 관리 도구로 옮기고, 필요할 때만 임시로 Keychain에 넣는 방식을 권장합니다.

## 빌드 순서

```sh
# 1. 유니버설 앱 빌드, Sparkle 프레임워크 임베드, Info.plist 업데이터 키 삽입, 서명
SIGN_IDENTITY="Developer ID Application: ..." \
APP_VERSION=2.3.2 \
BUILD_NUMBER=202608291428 \
DISPLAY_BUILD_NUMBER=202608291428 \
./build_app.sh

# 2. drag-to-Applications DMG 생성 (+ 서명 + 공증)
SIGN_IDENTITY="Developer ID Application: ..." \
NOTARY_PROFILE="notary-profile-name" \
APP_VERSION=2.3.2 \
./make_dmg.sh

# 3. 서명된 appcast 갱신
SPARKLE_BIN_DIR=/path/to/Sparkle-2.9.4/bin \
APP_VERSION=2.3.2 \
./make_appcast.sh
```

- `SIGN_IDENTITY`가 없으면 ad-hoc 서명(`codesign --sign -`)으로 로컬 실행만 가능한 빌드가 만들어지며, 이 경우 `SUPublicEDKey`가 없어도 빌드는 계속 진행되지만 경고만 출력합니다.
- `SIGN_IDENTITY`가 있는데 공개키가 없으면 `build_app.sh`는 공개 배포용 실수를 막기 위해 즉시 실패합니다.
- 공개 설치 패키지는 `NasFinder-Super-Thumbnail-<version>.dmg` 하나이며 ZIP은 만들지 않습니다. 이 DMG의 배포 정보 `release.json`을 릴리스에 함께 게시합니다.
- GitHub 릴리스는 `https://github.com/armsone/SuperThumbnail-MacOS`의 `v<version>` 태그를 사용합니다.
- `NOTARY_PROFILE`은 `xcrun notarytool store-credentials`로 미리 등록한 프로필 이름입니다.

## 작업 대기열과 병렬 처리

- 여러 폴더를 작업 대기열에 추가할 수 있으며 폴더 작업 자체는 충돌을 피하도록 한 번에 하나씩 처리합니다.
- 각 폴더 내부의 미디어 파일은 앱에서 `1~16개` 사이로 지정한 작업자 수만큼 병렬 처리합니다.
- `자동`을 켜면 여유가 있을 때는 지정한 수를 사용하고, 발열이 심하면 절반으로, 위험 수준이면 1개로 줄였다가 식으면 다시 늘립니다. 자동을 꺼도 위험 수준에서는 1개로 제한합니다.
- 작업자 수 설정이나 발열 상태가 실행 중에 바뀌면 이미 시작한 파일·폴더 작업은 취소하지 않고 끝까지 처리하며, 아직 시작하지 않은 항목부터 새 제한을 적용합니다. 제한을 높이면 대기 항목을 즉시 추가로 시작합니다.
- 폴더 수퍼썸네일은 깊은 폴더부터 처리하고 같은 깊이에서는 적용 중인 파일 작업자 수의 절반(최소 1개)만큼 병렬 처리합니다.

## 앱의 업데이트 동작

- 시작 시 Sparkle이 `SUScheduledCheckInterval`(21600초 = 6시간) 주기로 자동 확인/설치를 시도합니다.
- 메뉴의 "업데이트 확인…" 항목으로 언제든 수동 확인이 가능합니다.
- 다운로드, 서명 검증, 앱 종료, 교체, 재실행은 모두 Sparkle의 표준 업데이트 흐름을 사용하며 커스텀 다운로더/설치기는 없습니다.


## 홈페이지 배포 정보 자동 연결

이 제품의 홈페이지 등록 key: `NasFinder-Super-Thumbnail`. 기존 제품의 단순 버전업에서는 홈페이지 소스의 버전·빌드·다운로드·예비 주소를 수정하지 않습니다.

최종 서명·패키징 파일과 실제 제품 버전으로 `release.json`을 만들고 GitHub 릴리스 자산에 함께 게시합니다. 빌드·Android 내부 코드는 현재 빌드의 확인된 값만 넣습니다. 생성 도구는 파일명·크기·SHA-256을 기록하며 기존 앱 서명·업데이터·appcast 검증을 대체하지 않습니다. 파일과 배포 정보를 준비한 뒤 릴리스를 공개하고, 홈페이지의 표시 버전과 실제 다운로드가 일치하는지 확인합니다.

공통 절차와 스키마는 [홈페이지 다운로드 자동화 안내](https://github.com/armsone/Hanstree.com/blob/main/docs/automatic-downloads.md)를 따릅니다. 로컬 도구는 홈페이지 체크아웃의 `build/release-metadata.mjs`입니다.

```sh
node ../NasFinder.com/build/release-metadata.mjs \
  --version "$PRODUCT_VERSION" --artifact "NasFinder-Super-Thumbnail=$FINAL_PACKAGE" \
  --output "$RELEASE_DIRECTORY/release.json"
```

명령은 프로젝트 루트에서 실행하고, 위 변수는 실제 빌드의 값과 경로로 설정합니다. 확인된 빌드가 있으면 `--build`, Android 내부 코드가 있으면 `--version-code`를 추가합니다. 기존 `gh release create` 또는 초안 업로드 명령에 생성한 `release.json`도 포함합니다.

새 제품·플랫폼·파일명 규칙 등록, 기능 설명·이미지·지원 정책·개인정보 안내의 실제 변경이 있을 때만 홈페이지를 별도로 수정합니다. TestFlight는 기존 심사·공개 확인 절차를 유지합니다.
