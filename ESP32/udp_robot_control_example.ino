#include <WiFi.h>
#include <WiFiUdp.h>

// Lowest-latency setup: ESP32 creates its own Wi-Fi AP and listens for
// single-byte UDP movement packets from the Mac app.
// Mac config default: udp://192.168.4.1:4210

const char* AP_SSID = "LittleRipBot";
const char* AP_PASS = "littleripbot"; // use 8+ chars
const uint16_t UDP_PORT = 4210;

WiFiUDP udp;

// TODO: replace these with your motor driver pins.
const int LEFT_FORWARD_PIN = 25;
const int LEFT_BACK_PIN = 26;
const int RIGHT_FORWARD_PIN = 27;
const int RIGHT_BACK_PIN = 14;

unsigned long lastPacketMs = 0;
const unsigned long FAILSAFE_MS = 350;

void stopMotors() {
  digitalWrite(LEFT_FORWARD_PIN, LOW);
  digitalWrite(LEFT_BACK_PIN, LOW);
  digitalWrite(RIGHT_FORWARD_PIN, LOW);
  digitalWrite(RIGHT_BACK_PIN, LOW);
}

void forward() {
  digitalWrite(LEFT_FORWARD_PIN, HIGH);
  digitalWrite(LEFT_BACK_PIN, LOW);
  digitalWrite(RIGHT_FORWARD_PIN, HIGH);
  digitalWrite(RIGHT_BACK_PIN, LOW);
}

void back() {
  digitalWrite(LEFT_FORWARD_PIN, LOW);
  digitalWrite(LEFT_BACK_PIN, HIGH);
  digitalWrite(RIGHT_FORWARD_PIN, LOW);
  digitalWrite(RIGHT_BACK_PIN, HIGH);
}

void left() {
  digitalWrite(LEFT_FORWARD_PIN, LOW);
  digitalWrite(LEFT_BACK_PIN, HIGH);
  digitalWrite(RIGHT_FORWARD_PIN, HIGH);
  digitalWrite(RIGHT_BACK_PIN, LOW);
}

void right() {
  digitalWrite(LEFT_FORWARD_PIN, HIGH);
  digitalWrite(LEFT_BACK_PIN, LOW);
  digitalWrite(RIGHT_FORWARD_PIN, LOW);
  digitalWrite(RIGHT_BACK_PIN, HIGH);
}

void leftFootForward() {
  digitalWrite(LEFT_FORWARD_PIN, HIGH);
  digitalWrite(LEFT_BACK_PIN, LOW);
}

void leftFootBack() {
  digitalWrite(LEFT_FORWARD_PIN, LOW);
  digitalWrite(LEFT_BACK_PIN, HIGH);
}

void leftFootStop() {
  digitalWrite(LEFT_FORWARD_PIN, LOW);
  digitalWrite(LEFT_BACK_PIN, LOW);
}

void rightFootForward() {
  digitalWrite(RIGHT_FORWARD_PIN, HIGH);
  digitalWrite(RIGHT_BACK_PIN, LOW);
}

void rightFootBack() {
  digitalWrite(RIGHT_FORWARD_PIN, LOW);
  digitalWrite(RIGHT_BACK_PIN, HIGH);
}

void rightFootStop() {
  digitalWrite(RIGHT_FORWARD_PIN, LOW);
  digitalWrite(RIGHT_BACK_PIN, LOW);
}

void weightShiftLeft() {
  // TODO: drive your weight-shift mechanism left here.
  // Examples: set servo angle, run a linear actuator, move a sliding mass, etc.
}

void weightShiftRight() {
  // TODO: drive your weight-shift mechanism right here.
}

void weightShiftStop() {
  // TODO: stop/hold your weight-shift mechanism here.
}

void applyCommand(char c) {
  switch (c) {
    case 'F': forward(); break;
    case 'B': back(); break;
    case 'L': left(); break;
    case 'R': right(); break;
    case 'Q': leftFootForward(); break;
    case 'A': leftFootBack(); break;
    case 'q': leftFootStop(); break;
    case 'O': rightFootForward(); break;
    case 'l': rightFootBack(); break;
    case 'o': rightFootStop(); break;
    case 'Z': weightShiftLeft(); break;
    case 'X': weightShiftRight(); break;
    case 'z': weightShiftStop(); break;
    case 'S':
    default: stopMotors(); break;
  }
}

void setup() {
  pinMode(LEFT_FORWARD_PIN, OUTPUT);
  pinMode(LEFT_BACK_PIN, OUTPUT);
  pinMode(RIGHT_FORWARD_PIN, OUTPUT);
  pinMode(RIGHT_BACK_PIN, OUTPUT);
  stopMotors();

  WiFi.mode(WIFI_AP);
  WiFi.setSleep(false); // reduces Wi-Fi latency jitter
  WiFi.softAP(AP_SSID, AP_PASS);

  udp.begin(UDP_PORT);
  lastPacketMs = millis();
}

void loop() {
  int packetSize = udp.parsePacket();
  if (packetSize > 0) {
    char c = udp.read();
    applyCommand(c);
    lastPacketMs = millis();

    // Drain any extra bytes; protocol is intentionally one-byte latest-state.
    while (udp.available()) udp.read();
  }

  // Safety stop if the Mac/app disconnects or packets stop arriving.
  if (millis() - lastPacketMs > FAILSAFE_MS) {
    stopMotors();
  }
}
