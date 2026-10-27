# SuperThumbnail-MacOS 작업 규칙

작업 전에 `/Users/armsone/git/AGENTS.md`를 먼저 읽고 이 규칙을 함께 적용한다.

- 이 저장소는 macOS 14 이상을 지원하는 독립 네이티브 Mac 앱이다.
- 변경 검증은 `swift test`를 통과한 뒤 `./build_app.sh` 순서로 수행한다.
- iPhone·iPad NasFinder의 `.NasFinder-Vault` 형식과 호환성을 유지한다.
- 영상 원본은 새 MP4와 그 출력 기준 수퍼썸네일이 정상 저장됐고 원본의 식별 정보와 작업 소유권이 유지됨을 확인한 뒤에만 삭제한다. 확인 실패·취소·불확실한 상태에서는 원본을 보존하며, 새 변환에는 `_원본` 파일을 만들지 않는다. 기존 `_원본`은 앱 생성 기록과 현재 결과물이 검증된 승인 대상만 정리한다. 이미지 원본은 수정·삭제하지 않는다.
- claim, atomic write, 경로 containment 보호를 약화하지 않는다.
- 설치 요청이 있을 때는 검증을 통과한 동일 앱만 `/Applications/NasFinder Super Thumbnail.app`에 교체 설치한다.
- GitHub 저장소는 `armsone/SuperThumbnail-MacOS`이다.
