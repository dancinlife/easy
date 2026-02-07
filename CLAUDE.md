# Easy

## 개요
iPhone + 에어팟으로 Claude Code와 핸즈프리 음성 대화하는 iOS 앱.
운전/이동 중 음성으로 코딩 지시, 응답을 TTS로 들을 수 있음.

## 아키텍처

### 직접 연결 모드 (Tailscale)
```
iPhone (Easy 앱)
├── SFSpeechRecognizer (상시 STT, 온디바이스)
├── AVSpeechSynthesizer (TTS, 한국어)
├── URLSession (HTTP 통신)
└── Background Audio Session (화면 꺼도 동작)
         ↓ Tailscale VPN (암호화)
Mac (easy-server)
├── HTTP API (포트 7777)
├── claude --print "질문" 실행
└── 응답 반환
```

### Relay 모드 (VPN 불필요)
```
iPhone (Easy 앱)                    Relay Server              Mac (easy-server --relay)
    │                            (Node.js, Fly.io)                    │
    │── WebSocket (wss://) ──→   room 기반 전달   ←── WebSocket ──│
    │   AES-GCM 암호화 메시지      (무상태, DB없음)    AES-GCM 암호화  │
    │                                                               │
    └── QR 스캔 (easy://pair?...)              ←── 터미널 QR 표시 ──┘
```

## 기술 스택
- **언어**: Swift 6 / SwiftUI
- **최소 버전**: iOS 17.0
- **빌드**: XcodeGen → xcodebuild CLI
- **의존성**: 없음 (전부 iOS 내장 프레임워크)
- **암호화**: CryptoKit (Curve25519 ECDH + AES-GCM)
- **Mac 서버**: Swift (NWListener + URLSessionWebSocketTask) — Claude Code HTTP/Relay 래퍼
- **Relay 서버**: Node.js (ws 라이브러리) — 무상태 WebSocket 중계

## 빌드 & 실행

```bash
# 1. XcodeGen으로 프로젝트 생성
cd /Users/ghost/Dev/easy
xcodegen generate

# 2. 시뮬레이터 빌드 & 실행
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
# === 직접 연결 모드 (기존, Tailscale 필요) ===

# 1. 컴파일 (최초 1회)
cd /Users/ghost/Dev/easy
swiftc server/EasyServer.swift -o server/easy-server

# 2. 서버 시작
./server/easy-server
# → http://0.0.0.0:7777

# 또는 컴파일 없이 직접 실행
swift server/EasyServer.swift

# 3. 테스트
curl -X POST http://localhost:7777/ask \
  -H "Content-Type: application/json" \
  -d '{"question": "hello"}'

# === Relay 모드 (VPN 불필요, E2E 암호화) ===

# 1. Relay 서버 시작 (별도 머신 또는 Fly.io 등)
cd relay && npm install && npm start
# → ws://0.0.0.0:8080

# 2. Mac 서버를 relay 모드로 시작
swift server/EasyServer.swift --relay wss://your-relay.fly.dev
# → QR 코드 표시 → iPhone에서 스캔
```

## 프로젝트 구조

```
Easy/
├── EasyApp.swift              # 앱 진입점 + onOpenURL (easy:// 스킴)
├── Info.plist                 # 권한 설정 (마이크, 음성인식, 카메라)
├── Models/
│   ├── Message.swift          # 대화 메시지 모델
│   └── PairingInfo.swift      # QR 페어링 데이터 + Base64URL
├── Services/
│   ├── ClaudeService.swift    # Mac HTTP API 통신 (직접 연결)
│   ├── RelayService.swift     # Relay WebSocket + E2E 암호화
│   ├── SpeechService.swift    # STT (SFSpeechRecognizer)
│   └── TTSService.swift       # TTS (AVSpeechSynthesizer)
├── ViewModels/
│   └── VoiceViewModel.swift   # 메인 비즈니스 로직 + ConnectionMode
└── Views/
    ├── VoiceView.swift        # 메인 음성 대화 화면
    ├── SettingsView.swift     # 연결 방식 선택 + 서버 설정
    └── QRScannerView.swift    # QR 코드 스캐너 (AVCaptureSession)

server/
├── EasyServer.swift           # Mac 서버 (HTTP + Relay 모드)
└── easy-server                # 컴파일된 바이너리

relay/
├── server.js                  # WebSocket 릴레이 서버 (Node.js)
└── package.json               # 의존성 (ws)
```

## iOS 권한 (Info.plist)
- `NSMicrophoneUsageDescription` — 음성 인식용 마이크
- `NSSpeechRecognitionUsageDescription` — 음성→텍스트 변환
- `NSCameraUsageDescription` — QR 코드 스캔용 카메라
- `UIBackgroundModes` — `audio` (백그라운드 오디오 세션)
- `CFBundleURLTypes` — `easy://` URL 스킴 (QR 페어링)

## 핵심 동작 흐름

1. 앱 실행 → Audio Session 활성화 (.playAndRecord)
2. "듣기 시작" → SFSpeechRecognizer 연속 인식
3. 침묵 감지 (1.5초) → 인식 텍스트 확정
4. 모드별 전송:
   - **직접**: HTTP POST → Mac의 easy-server → claude --print 실행
   - **Relay**: AES-GCM 암호화 → WebSocket → relay → Mac → claude --print
   - 응답 대기 중에도 마이크 열림 (barge-in)
   - 추가 발화 시 pendingInput에 누적
5. 응답 수신 (Relay: 복호화) → AVSpeechSynthesizer로 한국어 TTS
   - TTS 중에도 추가 발화 누적 가능
6. TTS 완료 → pendingInput 있으면 바로 전송, 없으면 다시 듣기 (자동 루프)

## Relay 모드: 키교환 흐름

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
- `connectionMode`: `direct` / `relay`
- `serverHost`: Mac Tailscale IP (예: 100.x.x.x) — 직접 모드
- `serverPort`: 7777 (기본값) — 직접 모드
- `pairedRelayURL`: relay 서버 URL — relay 모드
- `pairedRoom`: relay room ID — relay 모드
- `workDir`: Claude Code 작업 폴더
- `voiceId`: TTS 음성 (기본: ko-KR)
- `speechRate`: TTS 속도 (0.4 ~ 0.6)
- `silenceTimeout`: 침묵 감지 시간 (1.5초)
- `autoListen`: TTS 완료 후 자동 듣기 (기본: true)

## Tailscale 설정 (직접 연결 모드)
1. Mac + iPhone 모두 Tailscale 설치 & 같은 계정 로그인
2. Mac에서 `tailscale ip` → 100.x.x.x 확인
3. Easy 앱 설정에 해당 IP 입력
4. 어디서든 VPN 경유 통신 (암호화)

## 참고 프로젝트
- **mcp-voice-hooks**: Claude Code 음성 인터페이스 참고 구현
  - 경로: `/Users/ghost/dev/mcp-voice-hooks`
  - GitHub: https://github.com/johnmatthewtennant/mcp-voice-hooks
  - 음성 입력/출력 hooks 패턴, 중간 진입(barge-in) 등 참고
- **happy**: Claude Code 모바일/웹 클라이언트 (Tailscale 불필요)
  - 경로: `/Users/ghost/dev/happy`
  - GitHub: https://github.com/slopus/happy
  - E2E 암호화, 실시간 음성, 푸시 알림, npm 기반 서버 터널링 참고
