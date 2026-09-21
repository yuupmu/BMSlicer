# BMSlicer

macOS용 키음 분할 도구입니다. WAV·OGG Vorbis·MP3를 열고 BPM 그리드에 맞춰 편집한 뒤 여러 WAV로 내보냅니다.

- BPM 설정 기억, 자동/고정 그리드, 1/2–1/32 및 Triplet
- ⌘스크롤 확대·축소, ⌘E 분할, ⌘J 합치기, 실행 취소
- 선택/전체 클립 WAV 내보내기 및 제목 띠에서 파일 드래그
- `pluck_top_\n` 양식과 시작 번호로 제목 일괄 변경
- 원본 샘플레이트·채널 수 유지, PCM 16/24비트 출력

## 빌드

macOS와 Apple Command Line Tools가 필요합니다. 외부 패키지 다운로드 없이 빌드합니다.

```sh
./build.sh
```

생성된 `dist/BMSlicer.app`을 실행하거나 응용 프로그램 폴더로 옮기세요. 현재 Apple Silicon/macOS 26.5.1에서 실행을 확인했으며, 빌드 대상은 macOS 13 이상입니다. 배포용 공증은 포함하지 않습니다.

## 검사

```sh
./test.sh
./test.sh --drop
```

`--drop`은 macOS 세션에서 개별 테스트 클립보드를 사용하는 수신 단계 검사입니다. 실제 앱 간 드롭 검사를 대신하지 않습니다. 디코더 검사는 자신의 파일을 읽기 전용으로 지정할 수 있습니다.

```sh
./test.sh --ogg /path/to/audio.ogg --mp3 /path/to/audio.mp3
```

## 참고

- [한국어 사용 설명 및 변경 내역](README.ko.md)
- [외부 오픈소스 구성 요소와 라이선스](THIRD-PARTY.md)

편집한 분할 위치와 클립 제목은 현재 세션에만 유지됩니다. 종료 전에 필요한 WAV를 내보내세요. Ogg Opus, Live Clip(.alc), MIDI 및 Live Set 파일은 직접 지원하지 않습니다. Wine판 uBMSC까지의 실제 드롭 등록은 아직 별도 확인이 필요합니다.

소스와 검사 코드만 포함하며, 음원·데모·실행 앱·빌드 캐시는 저장소에 포함하지 않습니다. Ableton과 무관한 독립 앱입니다.
