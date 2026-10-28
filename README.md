# NasFinder Super Thumbnail for Mac

Finder에 마운트된 NAS 또는 Mac 폴더를 직접 읽어 NasFinder의 `.NasFinder-Vault` 형식으로 수퍼썸네일을 만들고, 레거시 포맷 영상을 고화질 MP4로 변환하는 macOS 전용 앱입니다.

## 주요 기능

### 1. 이미지 수퍼썸네일 생성
- 사진과 영상 재귀 검색 및 iPhone·iPad NasFinder 호환 `.NasFinder-Vault` JPEG 생성
- 기존 썸네일 건너뛰기와 중단 후 재검사 방식의 이어하기
- 최신 생성 항목 우선 접이식 가로 오버플로우 미리보기 및 1~16개 동시 작업자 자동/수동 조절
- 폴더 수퍼썸네일 자식 폴더 우선 처리 및 피부색 비율 기반 스마트 블러

### 2. 온디맨드 로컬 영상 변환 ('영상 변환')
- 변환 가용 슬롯(1~4개, 기본값 2개)이 비는 즉시 폴더별 유지형 커서로 대상 파일을 한 번에 하나씩 온디맨드 탐색
- 전체 폴더 사전 인벤토리나 공유 대기 큐 없이 실시간 백프레셔 적용
- **볼륨 적격성 및 배타적 연산 검증**: `fgetattrlist` 기반 `VOL_CAP_INT_RENAME_EXCL` 지원 여부를 검증하여 지원 볼륨(APFS, 호환 SMB)에서 안전하게 원자적 직접 변환 수행
- **공통 비디오 소유권 클레임**: `.NasFinder-Video-v1/<key>.claim` 원자적 디렉터리 생성 및 불변 소유자/하트비트 기반 동시성 보호 (시간 기반 가로채기 없음, NAS 공통 계약 준수)
- **MP4 변환 대상 확장자 정책**: `avi`, `mkv`, `wmv`, `vob`, `mpg`, `mpeg`, `asf`, `mov`, `flv`, `mts`, `m2ts`, `ts`, `3gp`, `webm`, `rm`, `rmvb`, `divx`, `m4v` (이미 변환된 `.mp4`, `_원본` 포함 경로, 숨김·패키지·심볼릭 링크, nlink > 1 다중 링크 파일, 출력 충돌 파일은 자동 제외)
- **변환·수퍼썸네일·원본 정리**: 최종 `STEM.mp4`를 원자적으로 배타적 발행하고 새 MP4의 수퍼썸네일을 자동 생성합니다. 두 결과의 정상 상태와 원본 파일이 바뀌지 않았음을 확인한 뒤 원본을 삭제합니다. 확인 실패·취소·불명확한 상태에서는 원본을 남기며, 새 변환에는 `_원본` 복사본을 만들지 않습니다.
- 직관적인 탐색 상태 및 정직한 누적 카운터(발견/완료/진행 중/실패/건너뜀) 제공, 5가지 병기 테마 지원

### 3. NAS 협업 헬퍼 및 브릿지
- NAS 분산 영상 변환을 위한 협업 프로토콜 v1 (`.NasFinder-Handoff/v1`)
- 단일 폴더 선택을 통해 지원되지 않는 마운트 스토리지는 등록된 NAS 협업 경로로 자동 브릿지 라우팅
- 인증된 참여 응답의 `video_claim_1` 기능 검증 후 안전하게 협업 수행 (구형 백엔드는 'NAS 업데이트 후 협업 가능' 상태 유지)

## 개발 및 빌드

```sh
swift test
swift build -c release
./build_app.sh
```

- 영상 변환 도구는 앱에 내장됩니다: `Resources/Runtime/{arm64,x86_64}/bin/{ffmpeg,ffprobe}`와 `Resources/Runtime/{arm64,x86_64}/python/bin/python3`(독립 Python 트리)가 두 아키텍처 모두 있어야 `build_app.sh`가 진행되며, 없으면 Swift 빌드 전에 중단합니다. 런타임 내용물은 Git에 올리지 않고(`README.md`·`MANIFEST.json`만 예외) 빌드 때 앱에 복사하며, 모든 Mach-O는 바깥 앱보다 먼저 서명합니다. 앱은 내장 런타임을 먼저 쓰고 개발용으로만 Homebrew/시스템 폴더를 대신 사용합니다.
- 변환 기록 창의 '진단 내용 복사'는 앱 버전·macOS·도구 위치·모든 실패/건너뜀 사유를 클립보드에 복사합니다(자동 전송 없음).
- 최소 지원 버전: macOS 14 (Sonoma) 이상
- `build_app.sh`는 기본적으로 버전 `2.7.18`의 유니버설 바이너리(`arm64` + `x86_64`) 앱 번들을 생성합니다.
- Sparkle 2.9.4 기반 자동 업데이트 지원
- 업데이트 확인·다운로드는 언제든 진행하지만, 설치(종료 후 재실행)는 수퍼썸네일 생성·파일 검색·보관함 정리·영상 변환/준비/복구·NAS 영상 변환 돕기가 모두 끝난 뒤로 미룹니다. 대기 중에는 앱 메뉴에 "업데이트 x.y.z 설치 대기 중" 상태가 표시되고, 유휴가 되면 Sparkle 델리게이트로 자동 설치합니다(창이 열려 있지 않아도 동작). 사용자가 직접 앱을 종료하면 Sparkle이 예약된 업데이트를 설치합니다.

### 자동 업데이트 배포 (받는 Mac에는 키·설정이 필요 없음)

받는 Mac은 앱에 들어 있는 공개키(`SUPublicEDKey`)로 업데이트를 검증하므로 별도 키나 설정이 필요 없습니다. 앱은 6시간마다 확인하고, 자동 다운로드 설정이 켜져 있으면 내려받아 작업이 없을 때 설치·재실행합니다. 배포하는 Mac에는 아래가 필요합니다.

- 로그인 Keychain에 `Developer ID Application` 인증서와 Sparkle EdDSA 개인키(`Sparkle/sparkle_ed_public_key.txt`의 공개키와 짝). 개인키가 없으면 `make_appcast.sh`가 서명 단계에서 멈춥니다.
- `xcrun notarytool store-credentials`로 등록한 공증 프로필 이름(`NOTARY_PROFILE`).

```sh
# 입력만 점검(빌드·공증 없음)
CODESIGN_IDENTITY="Developer ID Application: ..." NOTARY_PROFILE="프로필이름" ./package_update.sh --check

# 빌드 → 앱 공증 → DMG 서명·공증 → 최종 DMG 기준 appcast 서명·검증을 한 번에
CODESIGN_IDENTITY="Developer ID Application: ..." NOTARY_PROFILE="프로필이름" ./package_update.sh
```

- `package_update.sh`는 `APP_VERSION`(생략 시 `build_app.sh` 기본값)·`BUILD_NUMBER`(생략 시 현재 시각, 기존 빌드·appcast보다 커야 함)를 쓰며 `dist/NasFinder-Super-Thumbnail-<버전>.dmg`와 `dist/nasfinder-super-thumbnail.xml`을 만듭니다. 업로드·게시는 하지 않습니다.
- `build_app.sh`는 `SIGN_IDENTITY` 또는 `CODESIGN_IDENTITY`가 있을 때만 hardened runtime + 보안 타임스탬프로 서명하며, 없으면 기존처럼 ad-hoc 로컬 빌드입니다.
- `make_appcast.sh`는 DMG 안 앱의 버전·`SUPublicEDKey`가 공개키 파일과 같은지 확인하고, 기존 항목을 보존한 채 새 항목을 추가한 뒤, 서명이 공개키로 검증될 때만 `dist/`에 반영합니다.
- 게시 순서: ① GitHub 릴리스 `v<버전>`에 DMG와 `release.json` 업로드 → ② appcast를 `SUFeedURL`(`https://nasfinder.com/appcasts/nasfinder-super-thumbnail.xml`) 위치에 게시. 이 순서를 지켜야 appcast가 아직 없는 파일을 가리키지 않습니다.
- 기존 `make_dmg.sh`는 구버전 기본값이 남은 단독 도구이며 업데이트 배포에는 `package_update.sh`를 사용합니다.
