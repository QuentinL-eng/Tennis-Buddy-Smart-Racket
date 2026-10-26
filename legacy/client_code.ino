#include <Wire.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include <WiFi.h>
#include <WiFiClient.h>

const char* ssid = "";
const char* password = "";
const char* serverIP = "";
const int serverPort = 8080;
Adafruit_MPU6050 mpu;
WiFiClient client;

void setup() {
  Serial.begin(115200);
  while (!Serial) delay(10);
  if (!mpu.begin()) {
    Serial.println("Failed to find MPU6050 chip!");
    while (1);
  }
  Serial.println("MPU6050 Initialized!");
  WiFi.begin(ssid, password);
  while (WiFi.status() != WL_CONNECTED) {
    delay(1000);
    Serial.println("Connecting to WiFi...");
  }
  Serial.println("Connected to WiFi!");
  while (!client.connect(serverIP, serverPort)) {
    Serial.println("Attempting to connect to server...");
    delay(1000);
  }
  Serial.println("Connected to server!");
}

void loop() {
  sensors_event_t a, g, temp;
  mpu.getEvent(&a, &g, &temp);
  float accelMagnitude = sqrt(pow(a.acceleration.x, 2) + pow(a.acceleration.y, 2) + pow(a.acceleration.z, 2));
  if (client.connected()) {
    client.print("Acceleration Magnitude: ");
    client.println(accelMagnitude);
  } else {
    Serial.println("Connection to server lost!");
  }
  delay(500);
}
