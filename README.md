# Easy

Hands-free voice interface for Claude Code on iPhone.

Talk to Claude Code while driving, walking, or doing anything with your hands busy. Speak your coding instructions through AirPods, get responses read back via TTS.

## How It Works

```
iPhone (Easy app)                 Relay Server              Mac (easy server)
    |                          (WebSocket relay)                   |
    |-- wss:// (E2E encrypted) --> room-based relay <-- wss:// ---|
    |                                                              |
    |-- QR scan (easy://pair)              <-- Terminal QR code ---|
    |                                                              |
    |  STT: OpenAI Whisper API                   claude --print    |
    |  TTS: OpenAI gpt-4o-mini-tts              (runs locally)    |
```

1. Run `easy` on your Mac — a QR code appears in terminal
2. Scan the QR from the iPhone app — E2E encrypted pairing established
3. Speak naturally — Whisper transcribes, sends to Mac, Claude responds, TTS reads it back
4. Continuous loop: listen → transcribe → think → speak → listen again

## Features

- **E2E Encryption**: Curve25519 ECDH key exchange + AES-256-GCM for all messages
- **Barge-in**: Interrupt TTS mid-speech with a new voice command
- **Session Management**: Multiple sessions, auto-cleanup on server disconnect
- **OpenAI Whisper STT**: Accurate transcription with hallucination filtering
- **OpenAI TTS**: Natural speech with gpt-4o-mini-tts (10 voice options)
- **Background Handling**: Auto-pause on background, reconnect on foreground
- **No VPN Required**: Works over any network via WebSocket relay

## Quick Start

### 1. Install the server

```bash
npm install -g easy-server
```

### 2. Run on Mac

```bash
easy
```

This connects to the default relay server and displays a QR code.

Options:
```bash
easy --relay wss://your-relay.fly.dev   # Custom relay server
easy --new                               # Generate new pairing key
```

### 3. iPhone App

- Open Easy app
- Tap the QR scanner icon
- Scan the QR code from your Mac terminal
- Set your OpenAI API key in Settings
- Start talking

## Build from Source

### iOS App

```bash
# Generate Xcode project
brew install xcodegen  # if not installed
cd /path/to/easy
xcodegen generate

# Build for simulator
xcodebuild -scheme Easy -destination 'platform=iOS Simulator,name=iPhone 16' build

# Build for device
xcodebuild -scheme Easy \
  -destination 'id=YOUR_IPHONE_UDID' \
  -allowProvisioningUpdates \
  CODE_SIGN_IDENTITY="Apple Development" \
  build
```

### Relay Server (self-hosted)

```bash
cd relay
npm install
npm start
# Listens on ws://0.0.0.0:8080
```

## Architecture

### iOS App (Swift 6 / SwiftUI)

```
Easy/
├── EasyApp.swift              # App entry + URL scheme handler
├── Models/
│   ├── Message.swift          # Chat message model
│   ├── PairingInfo.swift      # QR pairing data + Base64URL
│   └── Session.swift          # Session model + SessionStore
├── Services/
│   ├── RelayService.swift     # WebSocket + E2E encryption (actor)
│   ├── SpeechService.swift    # VAD + audio capture + Whisper STT
│   ├── WhisperService.swift   # OpenAI Whisper API client (actor)
│   └── TTSService.swift       # OpenAI TTS API + AVAudioPlayer
├── ViewModels/
│   └── VoiceViewModel.swift   # Main business logic + utterance queue
└── Views/
    ├── VoiceView.swift        # Voice conversation screen
    ├── SessionListView.swift  # Session list + QR scanner
    ├── SettingsView.swift     # API key, voice, language settings
    └── QRScannerView.swift    # Camera QR scanner
```

### Server (Node.js)

```
server/
├── index.js                   # CLI entry + relay connector + Claude runner
└── package.json
```

### Key Exchange Flow

```
Mac:     Generate Curve25519 keypair → embed public key in QR
iPhone:  Scan QR → extract Mac's public key
iPhone:  Generate ephemeral Curve25519 keypair
iPhone:  ECDH(iPhone private, Mac public) → HKDF → derived key
iPhone:  Generate random session key → AES-GCM encrypt with derived key
iPhone:  Send ephemeral public key + encrypted session key via relay
Mac:     ECDH(Mac private, iPhone public) → same derived key → decrypt session key
Both:    All subsequent messages encrypted with session key (AES-256-GCM)
```

## Requirements

- **iOS**: 17.0+
- **Mac**: macOS with Claude Code CLI installed
- **API Key**: OpenAI API key (for Whisper STT + TTS)

## Tech Stack

- Swift 6 / SwiftUI (zero dependencies — iOS frameworks only)
- CryptoKit (Curve25519 ECDH + AES-GCM)
- AVFoundation (audio capture + playback)
- Node.js + ws (server + relay)

## Settings

| Setting | Description | Default |
|---------|-------------|---------|
| OpenAI API Key | Required for Whisper STT and TTS | — |
| Language | STT input language (en/ko) | en |
| Silence Detection | Seconds of silence before capture | 1.5s |
| Voice | TTS voice (10 options) | nova |
| Auto Listen | Resume listening after TTS | on |

## License

MIT
