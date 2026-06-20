# LittleRip for Mac

A macOS app that turns a live camera feed into **autonomous robot navigation with collision avoidance** — no car/RC hardware involved.

## How it works

1. **Stream** — `CameraService` opens an RTSP stream with `ffmpeg` and writes one frame per second (`fps=1`) to `/tmp/littlerip_latest.jpg`.
2. **Analyze** — `VisionService` watches that file; whenever a new frame lands, it base64-encodes the image and sends it to a vision-capable LLM (`gemma4:31b-cloud` via the local Ollama `/v1/chat/completions` endpoint) with a prompt that forces a single-word direction answer: `forward | left | right | back`.
3. **Act** — the returned direction is mapped to an arrow key (`CGEvent`) and pressed for ~1 s. Those arrow-key presses drive whatever robot/game/teleop interface has keyboard focus — i.e. the **robot moves to avoid collisions**, one frame at a time at 1 FPS.

## What's inside

- **`LittleRip/CameraService.swift`** — RTSP → ffmpeg → 1 FPS frame file, plus a preview `NSImage`.
- **`LittleRip/VisionService.swift`** — per-frame vision-LLM call → arrow-key press loop, with live stats (frames analyzed, latency, current direction).
- **`LittleRip/KeySimulator.swift`** — arrow-key (`CGEvent`) helper.
- **`LittleRip/ContentView.swift`** — UI: live frame preview, a D-pad that lights up to show the AI-chosen direction, and pipeline toggle cards for Camera / Vision.

## Building

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
xcodebuild -project LittleRip.xcodeproj -scheme LittleRip \
  -destination 'platform=macOS' -allowProvisioningUpdates build
```

## Configuration

- **Bundle ID:** `com.maxautomize.LittleRipMac`
- **Vision model:** `gemma4:31b-cloud` (Ollama-compatible endpoint, default `http://localhost:11434`)
- **Camera secrets (not in the repo):** copy `camera.example.json` to `~/.littlerip/camera.json` and fill in your real RTSP URL + relay activator path. The app reads that file at launch; if it's missing, harmless placeholders are used so the app still builds and runs.
- **Code signing:** the `DEVELOPMENT_TEAM` in `project.yml` is required for signing — it's an Apple Team ID (not a credential) and is intentionally committed.