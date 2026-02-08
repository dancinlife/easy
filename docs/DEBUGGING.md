# Easy App — Debugging Guide

## Log System

Easy uses Apple's unified logging system (`os.Logger`) with subsystem `com.ghost.easy`.

### Log Categories

| Category   | File                     | Description                              |
|------------|--------------------------|------------------------------------------|
| `speech`   | SpeechService.swift      | Wake word detection, VAD, Whisper STT    |
| `relay`    | RelayService.swift       | WebSocket, E2E encryption, relay comms   |
| `tts`      | TTSService.swift         | OpenAI TTS playback                      |
| `voicevm`  | VoiceViewModel.swift     | App lifecycle, session, listening flow   |

### Log Levels Used

- **debug** — Audio tap counts, dB levels, SFSpeech partials
- **info** — Engine start/stop, captures, server info, normal flow
- **notice** — Wake word detected, Whisper recognized, pairing complete
- **warning** — Ping failures, missing API key
- **error** — SFSpeech errors, Whisper errors, decryption failures

## Viewing Logs

### Option 1: `idevicesyslog` (recommended for real device)

```bash
# Install
brew install libimobiledevice

# Stream all Easy logs
idevicesyslog | grep "com.ghost.easy"

# Filter by category
idevicesyslog | grep "category:speech"
idevicesyslog | grep "category:relay"
idevicesyslog | grep "category:tts"
idevicesyslog | grep "category:voicevm"
```

### Option 2: macOS Console.app

1. Connect iPhone via USB
2. Open Console.app on Mac
3. Select your iPhone from the left sidebar
4. In the search bar, type: `subsystem:com.ghost.easy`
5. Optional: add category filter, e.g. `category:speech`
6. Click "Start Streaming"

### Option 3: `log` CLI (macOS)

```bash
# Stream from connected device
log stream --predicate 'subsystem == "com.ghost.easy"' --style compact

# Filter by category
log stream --predicate 'subsystem == "com.ghost.easy" AND category == "speech"'

# Include debug level (hidden by default)
log stream --predicate 'subsystem == "com.ghost.easy"' --level debug
```

### Option 4: In-App Debug Display

The app shows the last 5 debug lines at the bottom of VoiceView (small gray monospaced text). This is fed by `onDebugLog` callbacks from SpeechService.

## Common Debug Scenarios

### 1. Wake Word Not Recognized

**What to look for:**
```
[speech] SFSpeech ok, onDevice=true/false
[speech] SFSpeech partial: "..."
[speech] heard: ...
```

**Common issues:**
- SFSpeechRecognizer not available → check speech recognition permission in Settings
- No `heard:` logs after `PASSIVE tap#N` → SFSpeech recognition task died, should auto-restart
- `heard: eating` instead of `heard: easy` → already handled by fuzzy matching (triggerVariants set)

**Trigger variants recognized:** easy, eazy, ease, eezy, e z, izi, izzy, easey, ezee, eating, is it

**Prefix matching:** words starting with `eas`, `eaz`, or `eez` are also accepted.

### 2. Ding Sound Not Playing

**What to look for:**
```
[speech] Engine stopped for ding
[speech] Ding playing
[speech] Engine restarted for active mode
```

**If ding doesn't play:**
- Check if `Engine stopped for ding` appears — AVAudioPlayer cannot play while AVAudioEngine is recording
- Check Bluetooth/speaker routing — audio may be routed to earpiece
- After ding, `Engine restarted for active mode` must appear for VAD+Whisper to work

### 3. Response Not Arriving

**What to look for (relay category):**
```
[relay] Received: type=message payload.type=text_answer
[relay] text_answer received, sessionKey=true, continuation=true
[relay] text_answer decrypted: ...
```

**Common issues:**
- `text_answer received, sessionKey=true, continuation=false` → continuation was consumed or timed out (120s)
- `text_answer guard failed` → sessionKey is nil or encrypted data is malformed
- `text_answer decryption failed` → key mismatch (re-pair by scanning QR again)
- No `Received: type=message` at all → WebSocket disconnected, check `peer_left` logs

### 4. Whisper Not Transcribing

**What to look for:**
```
[speech] Captured: 2.3s, 36800 samples
[speech] Whisper recognized: "..."
```

**Common issues:**
- `avgDB=-55.0 too quiet, skip` → audio too quiet, VAD threshold (-50 dB) not reached
- `Whisper error:` → API key invalid or network issue
- `Hallucination filter: "..." → skip` → Whisper returned a known hallucination phrase
- `WhisperService not configured` → whisperService not injected

### 5. Connection Issues

**What to look for:**
```
[relay] Connecting: wss://... room: ...
[relay] Pairing complete
[relay] peer_left — server disconnected
[relay] server_shutdown received
```

**Common issues:**
- Stuck at `Connecting` → relay server unreachable
- `Ping failed` → WebSocket connection degraded
- `peer_left` → Mac server went offline
- `server_shutdown` → Mac server explicitly shut down

## Voice Flow State Machine

```
IDLE → [tap mic] → LISTENING (passive, wake word)
  → [say "easy"] → DING → LISTENING (active, VAD+Whisper)
    → [speak command + silence] → THINKING (send to server)
      → [response received] → SPEAKING (TTS playback)
        → [TTS done] → LISTENING (passive, wake word)
```

## Build & Install for Debugging

```bash
cd /Users/ghost/Dev/easy

# Generate Xcode project
xcodegen generate

# Build for real device
xcodebuild -scheme Easy \
  -destination 'id=00008101-000E0C6902F0801E' \
  -allowProvisioningUpdates \
  CODE_SIGN_IDENTITY="Apple Development" \
  DEVELOPMENT_TEAM=4Z6TFQZ78C \
  build

# Install on device
xcrun devicectl device install app \
  --device D93E50A0-2B32-54EF-A1CE-ED596918F847 \
  ~/Library/Developer/Xcode/DerivedData/Easy-*/Build/Products/Debug-iphoneos/Easy.app
```
