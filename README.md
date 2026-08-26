# NasFinder Super Thumbnail for Mac

Finder에 마운트된 NAS 또는 Mac 폴더를 직접 읽어 NasFinder의 `.NasFinder-Vault` 형식으로 수퍼썸네일을 만드는 macOS 전용 앱입니다.

- 사진과 영상 재귀 검색
- iPhone·iPad NasFinder와 호환되는 JPEG 이름 및 저장 구조
- 기존 썸네일 건너뛰기와 중단 후 재검사 방식의 이어하기
- 새로하기 전 보관본 탐색·삭제 진행 막대와 완료/전체 개수 표시
- 사진·영상 파일과 하위 폴더를 찾는 동안 큰 검색 애니메이션과 진행 막대 표시
- 최신 생성 항목이 왼쪽에 오는 접이식 가로 오버플로우 미리보기
- 위아래로 끌어 이미지와 함께 확대·축소하고 선택한 높이를 기억하는 미리보기
- 진행률, 예상시간, 원본 확인 용량, 생성 썸네일 용량 표시
- 여러 폴더를 등록하고 차례대로 처리하는 작업 대기열
- 폴더 내부 미디어를 `자동 / 1 / 2 / 4 / 8개` 작업자로 병렬 처리
- 자동 모드는 로컬 저장소 4개, NAS·외장 저장소 2개를 사용하고 발열이 높으면 1개로 축소, 발열이 내려가면 다시 원래 상한으로 복귀
- 작업자 수 설정과 발열 변화는 실행 중에도 반영: 이미 시작한 항목은 끝까지 처리하고 다음 항목부터 새 제한 적용(높이면 대기 항목 즉시 추가 시작)
- 폴더 수퍼썸네일은 자식 폴더를 먼저 처리하며 같은 깊이에서 최대 2개 병렬 처리
- 동시 작업 충돌을 줄이는 worker/claim 기록

## 개발

```sh
swift test
swift build -c release
./build_app.sh
```

최소 지원 버전은 macOS 14이며 AVFoundation과 ImageIO만 사용합니다.

`build_app.sh`는 기본적으로 버전 `2.3.0`, 빌드 `202608270616`(표시 빌드 `202608270616`)의 `dist/NasFinder Super Thumbnail.app`을 arm64+x86_64 유니버설 바이너리로 만들고 ad-hoc 서명합니다. Developer ID 배포본은 `SIGN_IDENTITY`, `APP_VERSION`, `BUILD_NUMBER`, `DISPLAY_BUILD_NUMBER` 환경변수를 지정한 뒤 Apple 공증을 진행합니다.

앱은 Sparkle 2.9.4로 시작 시 자동 업데이트 확인(6시간 주기)과 메뉴의 "업데이트 확인…" 수동 확인을 제공합니다. 릴리스/서명 절차는 `RELEASE.md`를 참고하세요.
