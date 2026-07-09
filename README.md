# LittleRip for Mac

LittleRip for Mac is a retro robot **Control Center** for fast sensor/IMU → model → robot-action control.

The camera system has been removed from the current app flow. The main loop is now:

1. read HC-SR04 range + sound sensor text
2. optionally read GY-521 / MPU6050 6-axis IMU data
3. send a very short prompt to `glm-5.1:cloud` with `think: false`
4. show the exact input and output in the UI
5. send the resulting one-word/short command to the ESP over UDP

## Current app experience

- App name: **LittleRip**
- Bundle ID: `com.maxautomize.LittleRipMac`
- Responsive dashboard that scales down when the window is resized.
- **Model Input Window** shows the compact data string sent to GLM.
- **Raw Output** shows the model response.
- **Quick Command** shows the parsed command being sent to robot control.
- **Control Switchboard**:
  - `RANGE/SOUND` — reads `/tmp/littlebot_hcsr04.txt` and `/tmp/littlebot_sound.txt`
  - `MPU6050` — reads `/tmp/littlebot_mpu6050.json`
  - `GLM WALKER` — runs the 1 Hz action loop

## GLM controller

Only one model is hooked up for the action loop right now:

- Model: `glm-5.1:cloud`
- Endpoint: `http://127.0.0.1:11434/api/chat`
- Thinking/reasoning: `think: false`
- Streaming: `false`
- Prediction budget: tiny (`num_predict: 4`) for speed
- Loop rate: 1 call per second

The prompt is intentionally short. The model can output only:

`LF, RF, LB, RB, WL, WR, LS, RS, WS, STOP, NONE`

Mappings:

- `LF` → left foot forward
- `RF` → right foot forward
- `LB` → left foot back
- `RB` → right foot back
- `WL` → weight shift left
- `WR` → weight shift right
- `LS` → stop left foot
- `RS` → stop right foot
- `WS` → stop/hold weight shift
- `STOP` → stop all robot movement
- `NONE` → no output packet

## Manual controls

Manual controls still send direct UDP packets to the ESP:

- **Left Foot Forward** → key `Q` → ESP UDP `Q`
- **Left Foot Back** → key `A` → ESP UDP `A`
- releasing Q/A sends `q` to stop only the left foot
- **Right Foot Forward** → key `O` → ESP UDP `O`
- **Right Foot Back** → key `L` → ESP UDP lowercase `l`
- releasing O/L sends `o` to stop only the right foot
- **Weight Left** → key `Z` → ESP UDP `Z`
- **Weight Right** → key `X` → ESP UDP `X`
- releasing Z/X sends `z` to stop/hold the weight-shift mechanism

## Sensor file inputs

The app expects other hardware/ESP scripts to write fresh sensor values here:

- Range: `/tmp/littlebot_hcsr04.txt`
- Sound: `/tmp/littlebot_sound.txt`
- MPU6050 IMU: `/tmp/littlebot_mpu6050.json`

Example MPU6050 JSON:

```json
{"ax":0.01,"ay":0.02,"az":0.98,"gx":0.4,"gy":-0.2,"gz":0.1,"pitch":1.2,"roll":-0.8}
```

## Lowest-latency ESP control path

The control path is **Mac app → UDP → ESP32**.

Default endpoint:

`udp://192.168.4.1:4210`

Copy `robot.example.json` to:

`~/.littlerip/robot.json`

An ESP32 receiver sketch is included at:

`ESP32/udp_robot_control_example.ino`

For the least latency, put the ESP32 in SoftAP mode, connect the Mac to that Wi-Fi network, disable Wi-Fi sleep on the ESP, and use one-byte latest-state commands.

## What's inside

- **`LittleRip/ContentView.swift`** — model I/O dashboard and manual controls.
- **`LittleRip/MotionAIService.swift`** — fast GLM 5.1 action loop.
- **`LittleRip/RobotControlService.swift`** — UDP command sender for ESP32.
- **`LittleRip/KeySimulator.swift`** — fallback arrow-key helper.
- **`LittleRip/Assets.xcassets/`** — LittleRip robot icon and macOS app icon.
- **`ESP32/udp_robot_control_example.ino`** — minimal ESP32 UDP receiver sketch.

## Building

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
xcodebuild -project LittleRip.xcodeproj -scheme LittleRip \
  -destination 'platform=macOS' -allowProvisioningUpdates build
```

## GitHub

`https://github.com/MaxAutomize/LittleRip-Mac.git`
