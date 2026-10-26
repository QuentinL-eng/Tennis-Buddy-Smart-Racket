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
