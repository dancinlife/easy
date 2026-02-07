# Easy

## 개요
iPhone + 에어팟으로 Claude Code와 핸즈프리 음성 대화하는 iOS 앱.
운전/이동 중 음성으로 코딩 지시, 응답을 TTS로 들을 수 있음.

## 아키텍처

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

## 기술 스택
- **언어**: Swift 6 / SwiftUI
- **최소 버전**: iOS 17.0
- **빌드**: XcodeGen → xcodebuild CLI
- **의존성**: 없음 (전부 iOS 내장 프레임워크)
- **Mac 서버**: Swift (NWListener) — Claude Code HTTP 래퍼

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
```

## 프로젝트 구조

```
Easy/
├── EasyApp.swift              # 앱 진입점
├── Info.plist                 # 권한 설정 (마이크, 음성인식)
├── Models/
│   └── Message.swift          # 대화 메시지 모델
├── Services/
│   ├── ClaudeService.swift    # Mac HTTP API 통신
│   ├── SpeechService.swift    # STT (SFSpeechRecognizer)
│   └── TTSService.swift       # TTS (AVSpeechSynthesizer)
├── ViewModels/
│   └── VoiceViewModel.swift   # 메인 비즈니스 로직
└── Views/
    ├── VoiceView.swift        # 메인 음성 대화 화면
    └── SettingsView.swift     # 서버 주소 등 설정

server/
├── EasyServer.swift           # Mac에서 실행하는 Claude Code HTTP 래퍼
└── easy-server                # 컴파일된 바이너리
```

## iOS 권한 (Info.plist)
- `NSMicrophoneUsageDescription` — 음성 인식용 마이크
- `NSSpeechRecognitionUsageDescription` — 음성→텍스트 변환
- `UIBackgroundModes` — `audio` (백그라운드 오디오 세션)

## 핵심 동작 흐름

1. 앱 실행 → Audio Session 활성화 (.playAndRecord)
2. "듣기 시작" → SFSpeechRecognizer 연속 인식
3. 침묵 감지 (1.5초) → 인식 텍스트 확정
4. HTTP POST → Mac의 easy-server → claude --print 실행
5. 응답 수신 → AVSpeechSynthesizer로 한국어 TTS
6. TTS 완료 → 다시 듣기 시작 (자동 루프)

## 설정 (UserDefaults)
- `serverHost`: Mac Tailscale IP (예: 100.x.x.x)
- `serverPort`: 7777 (기본값)
- `voiceId`: TTS 음성 (기본: ko-KR)
- `speechRate`: TTS 속도 (0.4 ~ 0.6)
- `silenceTimeout`: 침묵 감지 시간 (1.5초)
- `autoListen`: TTS 완료 후 자동 듣기 (기본: true)

## Tailscale 설정
1. Mac + iPhone 모두 Tailscale 설치 & 같은 계정 로그인
2. Mac에서 `tailscale ip` → 100.x.x.x 확인
3. Easy 앱 설정에 해당 IP 입력
4. 어디서든 VPN 경유 통신 (암호화)
