# SuperThumbnail-MacOS 작업 규칙

작업 전에 `/Users/armsone/git/AGENTS.md`를 먼저 읽고 이 규칙을 함께 적용한다.

- 이 저장소는 macOS 14 이상을 지원하는 독립 네이티브 Mac 앱이다.
- 변경 검증은 `swift test`를 통과한 뒤 `./build_app.sh` 순서로 수행한다.
- iPhone·iPad NasFinder의 `.NasFinder-Vault` 형식과 호환성을 유지한다.
- 원본 미디어를 수정하거나 삭제하지 않으며 claim, atomic write, 경로 containment 보호를 약화하지 않는다.
- 설치 요청이 있을 때는 검증을 통과한 동일 앱만 `/Applications/NasFinder Super Thumbnail.app`에 교체 설치한다.
- GitHub 저장소는 `armsone/SuperThumbnail-MacOS`이다.
