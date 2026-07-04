# LittleRip for Mac

LittleRip for Mac is a retro robot **Control Center** for low-latency ESP robot control. It uses the LittleRip chrome/black/white robot branding and combines:

- keyboard/foot controls → direct UDP packets to ESP32
- camera frames → Ollama Cloud `gemma4:31b-cloud`
- ultrasonic + sound sensor text files → Ollama Cloud `glm-5.1:cloud`

Thinking/reasoning is explicitly disabled on both Ollama model calls with `think: false`.

## Current app experience

- App name: **LittleRip**
- Bundle ID: `com.maxautomize.LittleRipMac`
- Responsive dashboard: the full control center scales down when the window is resized.
- Camera switch for the frame feed.
- Sensor switch for HC-SR04 + sound sensor readings.
- Frame AI switch for camera-frame → movement decisions.
- Bottom foot controls:
  - **Left Foot Forward** → key `Q` → ESP UDP `Q`
  - **Left Foot Back** → key `A` → ESP UDP `A`
  - releasing Q/A sends `q` to stop only the left foot
  - **Right Foot Forward** → key `O` → ESP UDP `O`
  - **Right Foot Back** → key `L` → ESP UDP lowercase `l`
  - releasing O/L sends `o` to stop only the right foot
- Arrow keys still work for whole-robot movement:
  - ↑ `F`
  - ↓ `B`
  - ← `L`
  - → `R`
  - key-up sends `S` stop

## Lowest-latency ESP control path

The fastest path is **Mac app → UDP → ESP32**, not fake keyboard events through another app/browser.

Default endpoint:

`udp://192.168.4.1:4210`

Copy `robot.example.json` to:

`~/.littlerip/robot.json`

Example:

```json
{
  "espHost": "192.168.4.1",
  "espPort": 4210,
  "commands": {
    "forward": "F",
    "back": "B",
    "left": "L",
    "right": "R",
    "leftFootForward": "Q",
    "leftFootBack": "A",
    "leftFootStop": "q",
    "rightFootForward": "O",
    "rightFootBack": "l",
    "rightFootStop": "o",
    "stop": "S"
  }
}
```

An ESP32 receiver sketch is included at:

`ESP32/udp_robot_control_example.ino`

For the least latency, put the ESP32 in SoftAP mode, connect the Mac to that Wi-Fi network, disable Wi-Fi sleep on the ESP, and use one-byte latest-state commands.

## How it works

1. **Manual keyboard control** — `KeyMonitor` captures arrow keys plus Q/A/O/L foot keys. `RobotControlService` immediately sends one-byte UDP movement commands to the ESP.
2. **Camera frame feed** — `CameraService` runs the configured camera relay activator, reads the current `RTSP_URL`, opens the stream with `ffmpeg`, and writes the current frame to `/tmp/littlerip_latest.jpg`.
3. **Frame AI** — `VisionService` sends the latest frame to local Ollama’s native API using cloud model `gemma4:31b-cloud`, `think: false`, `stream: false`, and asks for one movement word. The result is sent to the ESP via `RobotControlService`.
4. **Sensor AI** — `SensorService.swift` watches `/tmp/littlebot_hcsr04.txt` and `/tmp/littlebot_sound.txt`, sends readings to `glm-5.1:cloud` with `think: false`, and displays a one-word safety status.

## What's inside

- **`LittleRip/ContentView.swift`** — responsive robot control center UI and keyboard capture wiring.
- **`LittleRip/RobotControlService.swift`** — low-latency UDP command sender for ESP32.
- **`LittleRip/CameraService.swift`** — camera relay / ffmpeg frame capture.
- **`LittleRip/VisionService.swift`** — Gemma 4 Cloud frame analysis and movement selection.
- **`LittleRip/SensorService.swift`** — HC-SR04 + sound sensor readout and GLM 5.1 Cloud classifier.
- **`LittleRip/KeySimulator.swift`** — fallback arrow-key output helper.
- **`LittleRip/Assets.xcassets/`** — LittleRip robot icon and macOS app icon.
- **`ESP32/udp_robot_control_example.ino`** — minimal ESP32 UDP receiver sketch.

## Building

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
xcodebuild -project LittleRip.xcodeproj -scheme LittleRip \
  -destination 'platform=macOS' -allowProvisioningUpdates build
```

## Configuration

- **ESP config:** `~/.littlerip/robot.json`
- **Camera secrets:** copy `camera.example.json` to `~/.littlerip/camera.json`. Real camera URLs/secrets should not be committed.
- **Latest frame path:** `/tmp/littlerip_latest.jpg`
- **HC-SR04 sensor path:** `/tmp/littlebot_hcsr04.txt`
- **Sound sensor path:** `/tmp/littlebot_sound.txt`
- **Camera model:** `gemma4:31b-cloud`
- **Sensor/sound model:** `glm-5.1:cloud`
- **Ollama endpoint:** local Ollama API at `http://127.0.0.1:11434/api/chat`, using your Ollama Cloud models.
- **Code signing:** `DEVELOPMENT_TEAM` in `project.yml` is an Apple Team ID, not a secret.

## GitHub

This repo is pushed to:

`https://github.com/MaxAutomize/LittleRip-Mac.git`
