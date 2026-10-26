# Smart-Tennis-Racket

# Introduction
In recent times, there has been a monumental increase in the role of new technology in sports. Tennis necessitates a finer attention to identifying aspects such as shot accuracy, speed, and spin. We designed a smart tennis racket in consultation with an ex-national-level tennis player, who provided insights into the challenges athletes face in analyzing their gameplay.
Our aim was to make data analysis more accessible for tennis players, helping them pinpoint improvements and optimize their gameplay. Using accelerometers, we measured shot acceleration in three dimensions, with different shot intensities displayed via LED indicators. In the long run, the device is planned to incorporate parameters such as impact, type of swing, and timing, making it a versatile tool for coaching assistance and professional player strategy analysis.

# Hardware Components Used
#MPU6050 (Accelerometer and Gyroscope)
#ESP32 (Client and Server Nodes)
#LED RGB Strip 
#5V Battery (Power Supply)
#Supporting Electronics (Wires, Connectors, Resistors, etc.)

# Libraries Used
Wire.h - I2C Communication
Adafruit_MPU6050.h - MPU6050 Library
Adafruit_Sensor.h - Sensor Data Handling
WiFi.h - ESP32 WiFi Communication
WiFiClient.h - WiFi Client Functionality
WiFiServer.h - WiFi Server Functionality

# Implementation Stages
1. Initial Testing: MPU6050 Sensor Data Collection
Objective: Test the accelerometer and gyroscope values for acceleration in X, Y, and Z axes. This test ensures that the MPU6050 is properly calibrated and provides accurate readings. The data collected will serve as the foundation for further calculations related to shot intensity.
Code: MPU6050 Testing

#include <Wire.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
Adafruit_MPU6050 mpu;
void setup() {
    Serial.begin(115200);
    while (!Serial) {
        delay(10);
    }
    if (!mpu.begin()) {
        Serial.println("Failed to find MPU6050 chip!");
        while (1);
    }
    Serial.println("MPU6050 Initialized!");
    mpu.setAccelerometerRange(MPU6050_RANGE_2_G);
    mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);
}
void loop() {
    sensors_event_t a, g, temp;
    mpu.getEvent(&a, &g, &temp);
    Serial.print("Acceleration (m/s²) - X: ");
    Serial.print(a.acceleration.x);
    Serial.print(", Y: ");
    Serial.print(a.acceleration.y);
    Serial.print(", Z: ");
    Serial.println(a.acceleration.z);
    delay(500);
}

2. LED Testing
Objective: Test LED indicators to ensure proper visual feedback on shot intensity.
Code: LED Testing

// Define GPIO pins for the LEDs
const int greenPin = __ ;
const int redPin = __ ;
void setup() {
  // Initialize Serial Monitor
  Serial.begin(115200);
  Serial.println("Starting LED Test...");

  // Set pin modes for the LEDs
  pinMode(greenPin, OUTPUT);
  pinMode(redPin, OUTPUT);

  // Start with LEDs off
  digitalWrite(greenPin, LOW);
  digitalWrite(redPin, LOW);
}

void loop() {
  // Turn on the Green LED, turn off the Red LED
  Serial.println("Green LED ON, Red LED OFF");
  digitalWrite(greenPin, HIGH);
  digitalWrite(redPin, LOW);
  delay(1000);

  // Turn on the Red LED, turn off the Green LED
  Serial.println("Red LED ON, Green LED OFF");
  digitalWrite(greenPin, LOW);
  digitalWrite(redPin, HIGH);
  delay(1000);
}

3. ESP32 Client-Server Communication via Wi-Fi
Objective: Enable real-time data transmission from the racket (ESP32 client) to a computer (ESP32 server) for further processing and visualization.
Client Code (ESP32 on Racket):
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
Server Code (ESP32 on Computer):
#include <WiFi.h>
#include <WiFiServer.h>

const char* ssid = "";
const char* password = "";
WiFiServer server(8080);

void setup() {
  Serial.begin(115200);
  WiFi.begin(ssid, password);
  while (WiFi.status() != WL_CONNECTED) {
    delay(1000);
    Serial.println("Connecting to WiFi...");
  }
  Serial.println("Connected to WiFi!");
  server.begin();
  Serial.println("Server started!");
  Serial.print("Server IP: ");
  Serial.println(WiFi.localIP());
}

void loop() {
  WiFiClient client = server.available();
  if (client) {
    Serial.println("Client connected!");
    while (client.connected()) {
      if (client.available()) {
        String receivedData = client.readStringUntil('\n');
        Serial.print("Received: ");
        Serial.println(receivedData);
      }
    }
    client.stop();
    Serial.println("Client disconnected!");
  }
}
