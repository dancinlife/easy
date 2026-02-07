# prepare

iPhone + 에어팟으로 음성 지시하며 코딩하는 환경 구축 가이드.

```
iPhone + 에어팟 🎧
  ↓ "Hey Siri, 이지 코딩" (또는 앱에서 음성 입력)
iOS 단축어 / Happy / Blink Shell
  ↓ SSH or 웹 인터페이스
서버 (Mac/Railway) — Claude Code 실행
  ↓ 응답
edge-tts (한국어 음성 생성)
  ↓ 오디오
iPhone 스피커 / 에어팟 🎧
```

---

## 1. iPhone에서 Claude Code 접근 방법

### 방법 A: Happy — 추천 (무료, 음성 지원)

음성으로 코딩 지시 가능한 Claude Code 모바일 클라이언트.

```bash
# Mac/서버에서
npm i -g happy-coder && happy
```

- App Store에서 "Happy - Claude Code Client" 설치
- 음성-to-action 기능 내장 (받아쓰기가 아니라 직접 실행)
- 에어팟 마이크로 hands-free 코딩
- 무료, 오픈소스 (MIT)
- https://happy.engineering

### 방법 B: Clauder — iOS 네이티브 앱

```bash
# Mac/서버에서
git clone https://github.com/zohaibahmed/clauder.git
cd clauder && make build
./out/clauder quickstart
# → 패스코드 표시 (예: "ALPHA-TIGER-OCEAN-1234")
# → iPhone 앱에서 패스코드 입력
```

- 네이티브 SwiftUI 앱
- 패스코드 기반 연결 (설정 간단)
- Cloudflare 터널로 암호화
- iOS 16.0+
- https://github.com/ZohaibAhmed/clauder

### 방법 C: Blink Shell + Tailscale + tmux — 가장 안정적

프로 개발자 추천 조합.

1. **Tailscale** (무료 VPN): iPhone + Mac 모두 설치
   - https://tailscale.com — 같은 계정으로 로그인하면 끝
   - 어디서든 Mac에 SSH 가능

2. **Blink Shell** (iOS 앱, 유료):
   - Mosh 지원 → 네트워크 전환/잠금 후에도 연결 유지
   - SSH 키 내장 관리

3. **tmux** (서버):
   ```bash
   # Mac에서 SSH 활성화
   # 시스템 설정 > 일반 > 공유 > 원격 로그인 켜기

   # iPhone Blink에서
   mosh mac-tailscale-ip
   tmux new -s coding
   claude
   ```

- 에어팟 + iOS 받아쓰기로 터미널에 음성 입력 가능
- 지하철/카페 등 네트워크 변경에도 끊기지 않음

### 방법 D: iOS 단축어 + Siri — 가장 간편한 호출

시리에게 말하면 SSH로 명령 실행:

1. 단축어 앱 열기
2. "SSH를 통해 스크립트 실행(Run Script over SSH)" 액션 추가
3. 서버 정보 입력 (호스트, 포트, 인증)
4. 실행할 명령: `claude --print "여기에 질문"`
5. 단축어 이름: "이지 코딩"

```
"Hey Siri, 이지 코딩"
  → 단축어 실행
  → SSH로 서버 접속
  → claude --print "사용자 음성 텍스트"
  → 결과를 "텍스트 말하기(Speak Text)" 액션으로 읽어주기
```

단축어 구성:
```
1. 받아쓰기 텍스트 (Dictate Text) — 에어팟 마이크로 입력
2. SSH 스크립트 실행 — claude --print "[받아쓴 텍스트]"
3. 텍스트 말하기 (Speak Text) — 결과를 에어팟으로 읽어줌
```

- 별도 앱 설치 불필요
- 잠금 화면에서도 "Hey Siri"로 호출 가능
- 다만 긴 응답은 잘릴 수 있음

---

## 2. 서버 환경 (Claude Code 실행)

### 옵션 A: 본인 Mac (Tailscale로 원격 접속)

```bash
# Mac에서
brew install tailscale tmux
# 시스템 설정 > 일반 > 공유 > 원격 로그인 켜기
# Tailscale 앱 설치 + 로그인
```

- Mac이 항상 켜져 있어야 함
- 가장 빠름 (로컬 자원 사용)

### 옵션 B: Railway SSH 서버

#### Dockerfile

```dockerfile
FROM python:3.11-slim
RUN apt-get update && apt-get install -y openssh-server ffmpeg && \
    pip install edge-tts && \
    mkdir -p /var/run/sshd /root/.ssh

RUN echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config && \
    echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config

CMD echo "$PUBLIC_KEY" > /root/.ssh/authorized_keys && \
    chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys && \
    /usr/sbin/sshd -D -p ${PORT:-22}
```

#### Railway 설정

1. TCP Proxy 활성화: Settings > Networking > TCP Proxy
2. 환경변수: `PUBLIC_KEY` = SSH 공개키
3. 접속: `ssh root@<domain> -p <port>`
4. 원클릭 템플릿: https://railway.com/deploy/ubuntu-sshd-1

---

## 3. TTS — edge-tts (서버에서 실행)

서버에서 응답을 음성으로 변환 → iPhone으로 전달.

### 설치

```bash
pip install edge-tts
```

### 한국어 음성

| Voice | 성별 | 특징 |
|-------|------|------|
| `ko-KR-SunHiNeural` | 여성 | 기본, 자연스러움 |
| `ko-KR-InJoonNeural` | 남성 | 기본, 자연스러움 |
| `ko-KR-HyunsuNeural` | 남성 | |
| `ko-KR-HyunsuMultilingualNeural` | 남성 | 다국어 지원 |
| `ko-KR-BongJinNeural` | 남성 | |
| `ko-KR-GookMinNeural` | 남성 | |
| `ko-KR-JiMinNeural` | 여성 | |
| `ko-KR-SeoHyeonNeural` | 여성 | |
| `ko-KR-SoonBokNeural` | 여성 | |
| `ko-KR-YuJinNeural` | 여성 | |

### CLI

```bash
edge-tts --text "안녕하세요" --voice ko-KR-SunHiNeural --write-media output.mp3

# 속도/볼륨/피치
edge-tts --rate=+30% --text "빠르게" --voice ko-KR-SunHiNeural --write-media fast.mp3
edge-tts --rate=-50% --text "느리게" --voice ko-KR-SunHiNeural --write-media slow.mp3
edge-tts --volume=+50% --text "크게" --voice ko-KR-SunHiNeural --write-media loud.mp3
edge-tts --pitch=+20Hz --text "높게" --voice ko-KR-SunHiNeural --write-media high.mp3

# 음성 목록
edge-tts --list-voices | grep ko-KR
```

### Python API

```python
import edge_tts
import asyncio

async def speak(text, voice="ko-KR-SunHiNeural"):
    comm = edge_tts.Communicate(text, voice)
    await comm.save("output.mp3")

# 동기 버전
def speak_sync(text):
    comm = edge_tts.Communicate(text, "ko-KR-SunHiNeural")
    comm.save_sync("output.mp3")

# 전체 파라미터
edge_tts.Communicate(
    text="텍스트",
    voice="ko-KR-SunHiNeural",
    rate="+0%",        # 속도 (-100% ~ +200%)
    volume="+0%",      # 볼륨
    pitch="+0Hz",      # 피치
    proxy=None,        # 프록시 URL
    connect_timeout=10,
    receive_timeout=60,
)
```

### 자막 동시 생성 (SubMaker)

```python
comm = edge_tts.Communicate(text, "ko-KR-SunHiNeural")
submaker = edge_tts.SubMaker()
with open("output.mp3", "wb") as f:
    for chunk in comm.stream_sync():
        if chunk["type"] == "audio":
            f.write(chunk["data"])
        elif chunk["type"] in ("WordBoundary", "SentenceBoundary"):
            submaker.feed(chunk)
with open("output.srt", "w", encoding="utf-8") as f:
    f.write(submaker.get_srt())
```

### 참고

- MS Edge 온라인 서비스 → 인터넷 필요, API 키 불필요, 무료
- 메모리 ~10MB (모델 로딩 없음)
- Railway 같은 경량 서버에 최적
- 라이선스: GPL-3.0

---

## 4. 응답 읽어주기 — 실제로 에어팟에서 소리 나게 하기

핵심 문제: 서버에서 edge-tts로 mp3를 만들어도 iPhone 에어팟으로 어떻게 재생하냐?

### 방법 1: iOS 내장 TTS (가장 간단, 추가 설치 없음)

edge-tts 없이 iOS "텍스트 말하기(Speak Text)" 액션만 쓰면 됨.
iOS 내장 한국어 음성도 충분히 자연스러움.

**iOS 단축어 구성 (4단계):**

```
1. [받아쓰기 텍스트]
   → 에어팟 마이크로 음성 입력

2. [SSH를 통해 스크립트 실행]
   → 호스트: Mac IP 또는 Tailscale IP
   → 스크립트: claude --print "받아쓰기 결과"

3. [텍스트 말하기]                    ← 이게 응답 읽어주는 부분
   → 입력: SSH 실행 결과
   → 언어: 한국어
   → 속도: 조절 가능

4. (선택) [클립보드에 복사]
   → 긴 응답은 나중에 텍스트로 확인
```

- "Hey Siri, 이지 코딩" 으로 호출
- 에어팟에서 바로 한국어로 응답이 들림
- edge-tts 서버 셋업 불필요

### 방법 2: edge-tts 음성을 iPhone으로 재생 (고품질)

서버에서 edge-tts로 mp3 생성 → HTTP로 iPhone에 전달 → 재생.

**서버 스크립트 (Mac/Railway):**

```python
#!/usr/bin/env python3
"""claude 응답을 edge-tts mp3로 변환 + HTTP 서빙"""

from http.server import HTTPServer, SimpleHTTPRequestHandler
import subprocess, edge_tts, asyncio, sys, os

VOICE = "ko-KR-SunHiNeural"
PORT = 8765
OUT = "/tmp/response.mp3"

async def generate(text):
    comm = edge_tts.Communicate(text, VOICE)
    await comm.save(OUT)

# claude 실행 → 응답 → mp3 생성
query = sys.argv[1] if len(sys.argv) > 1 else "안녕"
result = subprocess.run(["claude", "--print", query],
                       capture_output=True, text=True)
asyncio.run(generate(result.stdout.strip()))

# 간단한 HTTP 서버로 mp3 서빙
os.chdir("/tmp")
server = HTTPServer(("0.0.0.0", PORT), SimpleHTTPRequestHandler)
print(f"http://0.0.0.0:{PORT}/response.mp3")
server.handle_request()  # 한 번 서빙하고 종료
```

**iOS 단축어 구성:**

```
1. [받아쓰기 텍스트]
2. [SSH 스크립트 실행] → python3 serve_tts.py "받아쓰기 결과"
3. [URL 가져오기] → http://서버IP:8765/response.mp3
4. [사운드 재생] → 가져온 MP3 파일
```

### 방법 3: Happy 앱 (음성 응답 내장)

```
Happy 앱 열기 → 음성 버튼 탭 (또는 에어팟 탭)
  ↓
음성 인식 → Claude Code 실행 → 결과 표시 + 음성 응답 (자동)
```

- TTS 응답이 앱에 내장되어 있어서 별도 설정 불필요
- https://happy.engineering

### 방법 4: Blink + Wispr Flow (터미널 음성 입력)

```
Blink Shell에서 SSH 접속
  → Wispr Flow 키보드로 음성 입력 (에어팟 마이크)
  → claude 실행
  → 응답은 화면으로 읽기 (TTS 없음, 텍스트만)
```

- Wispr Flow: 앱 상관없이 음성→텍스트 변환하는 AI 키보드
- 응답을 "듣는" 게 아니라 "보는" 방식
- 가장 자유롭지만 핸즈프리는 아님

---

### 비교: 응답을 어떻게 듣냐

| 방법 | 응답 읽어줌? | 음질 | 난이도 |
|------|-------------|------|--------|
| iOS Speak Text | O (자동) | iOS 내장 (괜찮음) | 쉬움 |
| edge-tts + HTTP | O (고품질) | MS Neural (좋음) | 보통 |
| Happy 앱 | O (자동) | 앱 내장 | 쉬움 |
| Blink + Wispr | X (텍스트만) | - | 보통 |

---

## 5. 추천 셋업 (빠른 시작 순서)

### Tier 1: 지금 바로 (5분)

iOS 단축어만으로 시작:
1. Mac에서 원격 로그인 켜기
2. 단축어 앱 → "받아쓰기" + "SSH 실행" + "말하기" 조합
3. "Hey Siri, 이지 코딩"

### Tier 2: 제대로 (30분)

Happy 앱 설치:
1. `npm i -g happy-coder && happy` (Mac)
2. App Store에서 Happy 설치 (iPhone)
3. 음성 버튼으로 코딩

### Tier 3: 프로 (1시간)

Blink + Tailscale + tmux:
1. Mac + iPhone에 Tailscale 설치
2. Blink Shell 설치 + SSH 키 설정
3. tmux + claude 세션 유지
4. Wispr Flow 키보드로 음성 입력

---

## 참고 링크

- Happy: https://happy.engineering
- Clauder: https://github.com/ZohaibAhmed/clauder
- Blink Shell: https://blink.sh
- Tailscale: https://tailscale.com
- Wispr Flow: https://wispr.com
- edge-tts: https://github.com/rany2/edge-tts
- Railway SSH 템플릿: https://railway.com/deploy/ubuntu-sshd-1
- VoiceMode MCP: https://github.com/mbailey/voicemode
