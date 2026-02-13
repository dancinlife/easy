# Easy

## 개요
iPhone + 에어팟으로 Claude Code와 핸즈프리 음성 대화하는 iOS 앱.
운전/이동 중 음성으로 코딩 지시, 응답을 TTS로 들을 수 있음.

## 아키텍처

```
iPhone (Easy 앱)                    Relay Server              Mac (easy server)
    │                            (Socket.IO, Railway)                │
    │── Socket.IO (wss://) ──→   room 기반 전달   ←── Socket.IO ──│
    │   AES-GCM 암호화 메시지      (무상태, DB없음)    AES-GCM 암호화  │
    │                                                               │
    └── QR 스캔 (easy://pair?...)              ←── 터미널 QR 표시 ──┘
```

- **통신**: Socket.IO (자동 재연결 + HTTP long-polling fallback)
- **암호화**: CryptoKit (Curve25519 ECDH + AES-GCM) — E2E, relay 서버는 내용 열람 불가
- **STT**: OpenAI Whisper API
- **TTS**: OpenAI gpt-4o-mini-tts

## 기술 스택
- **언어**: Swift 6 / SwiftUI
- **최소 버전**: iOS 17.0
- **빌드**: XcodeGen → xcodebuild CLI
- **의존성**: socket.io-client-swift (SPM)
- **암호화**: CryptoKit (Curve25519 ECDH + AES-GCM)
- **Mac 서버**: Node.js + socket.io-client
- **Relay 서버**: Node.js + socket.io — 무상태 Socket.IO 중계

## 빌드 & 실행

```bash
# 1. XcodeGen으로 프로젝트 생성
cd /Users/ghost/Dev/easy
xcodegen generate

# 2. 시뮬레이터 빌드
xcodebuild -scheme Easy -destination 'platform=iOS Simulator,name=iPhone 16' build

# 3. 실기기 빌드 (USB 연결 필요)
xcodebuild -scheme Easy \
  -destination 'id=YOUR_IPHONE_UDID' \
  -allowProvisioningUpdates \
  CODE_SIGN_IDENTITY="Apple Development" \
  build

# 4. UDID 확인
xcrun devicectl list devices
```

## Mac 서버 실행

```bash
# 설치
cd server && npm install

# 실행 (기본 relay 서버 사용)
node index.js
# → QR 코드 표시 → iPhone에서 스캔

# 옵션
node index.js --relay wss://your-relay.example.com  # 커스텀 relay
node index.js --title "my-project"                   # 세션 타이틀
node index.js --new                                  # 새 페어링 키 생성
```

## Relay 서버 (셀프호스팅)

```bash
cd relay && npm install && npm start
# → Socket.IO 서버 on port 8080
```

## 프로젝트 구조

```
Easy/
├── EasyApp.swift              # 앱 진입점 + onOpenURL (easy:// 스킴)
├── Info.plist                 # 권한 설정 (마이크, 음성인식, 카메라)
├── CarPlay/
│   └── CarPlaySceneDelegate.swift  # CarPlay 지원
├── Models/
│   ├── Message.swift          # 대화 메시지 모델
│   ├── PairingInfo.swift      # QR 페어링 데이터 + Base64URL
│   ├── Session.swift          # 세션 모델 + SessionStore
│   └── EasyActivity.swift     # Live Activity 모델
├── Services/
│   ├── RelayService.swift     # Socket.IO + E2E 암호화 (actor)
│   ├── SpeechService.swift    # VAD + 오디오 캡처 + Whisper STT
│   ├── WhisperService.swift   # OpenAI Whisper API 클라이언트 (actor)
│   └── TTSService.swift       # OpenAI TTS + AVAudioPlayer
├── ViewModels/
│   └── VoiceViewModel.swift   # 메인 비즈니스 로직 + utterance queue
└── Views/
    ├── VoiceView.swift        # 메인 음성 대화 화면
    ├── SessionListView.swift  # 세션 목록 + QR 스캐너
    ├── SettingsView.swift     # API 키, 음성, 언어 설정
    └── QRScannerView.swift    # 카메라 QR 스캐너

EasyWidget/
├── EasyLiveActivity.swift     # Live Activity UI
└── EasyWidgetBundle.swift     # Widget 번들

server/
├── index.js                   # Mac 서버 (Socket.IO client + Claude runner)
└── package.json               # 의존성 (socket.io-client, qrcode-terminal)

relay/
├── server.js                  # Socket.IO 릴레이 서버
└── package.json               # 의존성 (socket.io)
```

## iOS 권한 (Info.plist)
- `NSMicrophoneUsageDescription` — 음성 인식용 마이크
- `NSSpeechRecognitionUsageDescription` — 음성→텍스트 변환
- `NSCameraUsageDescription` — QR 코드 스캔용 카메라
- `UIBackgroundModes` — `audio` (백그라운드 오디오 세션)
- `CFBundleURLTypes` — `easy://` URL 스킴 (QR 페어링)

## 핵심 동작 흐름

1. 앱 실행 → Audio Session 활성화 (.playAndRecord)
2. 패시브 대기 (마이크 ON, "easy" wake word 감지 대기)
3. "easy" 감지 → ding 알림음 → 액티브 모드 전환
4. 사용자 발화 → 침묵 감지 → Whisper 인식 → 텍스트 확정
5. AES-GCM 암호화 → Socket.IO → relay → Mac → claude --print
   - 응답 대기 중에도 마이크 열림 (barge-in)
   - 추가 발화 시 pendingUtterances에 누적
6. 응답 수신 (복호화) → OpenAI TTS 스트리밍 재생
   - TTS 중에도 추가 발화 누적 가능
7. TTS 완료 → pendingUtterances 있으면 바로 전송, 없으면 다시 2번 (패시브 대기)

## Socket.IO 이벤트 프로토콜

| 이벤트          | 방향        | 설명                     |
|----------------|-------------|--------------------------|
| `join`         | → relay     | room 입장 요청            |
| `joined`       | ← relay     | room 입장 확인            |
| `peer_joined`  | ← relay     | 상대방 입장               |
| `peer_left`    | ← relay     | 상대방 퇴장               |
| `relay`        | ↔ relay     | 암호화된 페이로드 중계     |
| `error_msg`    | ← relay     | 에러 (room full 등)       |

> `relay` 이벤트의 payload.type: `key_exchange`, `key_exchange_ack`, `server_info`, `ask_text`, `text_stream`, `text_done`, `text_answer`, `session_end`, `session_clear`, `session_compact`, `compact_needed`, `server_shutdown`

## 키교환 흐름

```
Mac: Curve25519 키페어 생성 → QR에 공개키 포함
iPhone: QR 스캔 → Mac 공개키 추출
iPhone: 임시 Curve25519 키페어 생성
iPhone: ECDH(iPhone비밀키, Mac공개키) → HKDF → 대칭키 도출
iPhone: 랜덤 세션키 생성 → 대칭키로 AES-GCM 암호화
iPhone: 임시 공개키 + 암호화된 세션키를 relay로 전송
Mac: ECDH(Mac비밀키, iPhone공개키) → 같은 대칭키 도출 → 세션키 복호화
이후: 모든 메시지를 세션키로 AES-GCM 암복호화
```

## 설정 (UserDefaults)
- `pairedRelayURL`: relay 서버 URL
- `pairedRoom`: relay room ID
- `pairedServerPubKey`: 서버 공개키 (Base64URL)
- `currentSessionId`: 현재 세션 ID
- `sttLanguage`: STT 언어 (en/ko)
- `openAIKey`: OpenAI API 키
- `ttsVoice`: TTS 음성 (nova 등)
- `ttsSpeed`: TTS 속도
- `silenceTimeout`: 침묵 감지 시간
- `speakerMode`: 스피커 출력 모드
- `theme`: 테마 (system/light/dark)

## 참고 프로젝트
- **mcp-voice-hooks**: Claude Code 음성 인터페이스 참고 구현
  - 경로: `/Users/ghost/dev/mcp-voice-hooks`
  - 음성 입력/출력 hooks 패턴, 중간 진입(barge-in) 등 참고
- **happy**: Claude Code 모바일/웹 클라이언트
  - 경로: `/Users/ghost/dev/happy`
  - E2E 암호화, Socket.IO 기반 실시간 통신 참고
