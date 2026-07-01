# LittleRip for Mac

LittleRip for Mac is a retro robot **Control Center** for camera-frame robot control. It keeps the LittleRip chrome/black/white robot branding and turns live camera frames plus an HC-SR04 ultrasonic sensor readout into a compact launch-console style dashboard.

## Current app experience

- App name: **LittleRip**
- Bundle ID: `com.maxautomize.LittleRipMac`
- Responsive dashboard: the full control center scales down when the window is resized.
- Robot branding matches the iOS LittleRip robot.
- Camera switch for the frame feed.
- Sensor switch for HC-SR04 ultrasonic distance data.
- Frame AI switch for camera-frame → movement decisions.
- Bottom foot controls:
  - **Left Foot** → left arrow
  - **Right Foot** → right arrow

## How it works

1. **Camera frame feed** — `CameraService` runs the configured camera relay activator, reads the current `RTSP_URL`, opens the stream with `ffmpeg`, and writes the current frame to `/tmp/littlerip_latest.jpg`.
2. **Frame AI** — `VisionService` watches the latest frame, sends it to a vision-capable Ollama-compatible model, and asks for a single movement direction such as `left`, `right`, `forward`, or `back`.
3. **Robot output** — `KeySimulator` maps directions to arrow-key `CGEvent`s so whatever robot/game/teleop interface has keyboard focus receives movement commands.
4. **Ultrasonic sensor display** — `SensorService.swift` watches `/tmp/littlebot_hcsr04.txt` and displays the latest HC-SR04 distance value when available.

## What's inside

- **`LittleRip/ContentView.swift`** — responsive robot control center UI.
- **`LittleRip/CameraService.swift`** — camera relay / ffmpeg frame capture.
- **`LittleRip/VisionService.swift`** — frame analysis and movement selection.
- **`LittleRip/SensorService.swift`** — HC-SR04 placeholder/readout service.
- **`LittleRip/KeySimulator.swift`** — arrow-key output helper.
- **`LittleRip/Assets.xcassets/`** — LittleRip robot icon and macOS app icon.

## Building

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
xcodebuild -project LittleRip.xcodeproj -scheme LittleRip \
  -destination 'platform=macOS' -allowProvisioningUpdates build
```

## Configuration

- **Camera secrets:** copy `camera.example.json` to `~/.littlerip/camera.json` and fill in your relay activator path plus camera list. Real camera URLs/secrets should not be committed.
- **Latest frame path:** `/tmp/littlerip_latest.jpg`
- **HC-SR04 sensor path:** `/tmp/littlebot_hcsr04.txt`
- **Vision model:** configured in `VisionService.swift` for an Ollama-compatible endpoint.
- **Code signing:** `DEVELOPMENT_TEAM` in `project.yml` is an Apple Team ID, not a secret.

## GitHub

This repo is pushed to:

`https://github.com/MaxAutomize/LittleRip-Mac.git`
