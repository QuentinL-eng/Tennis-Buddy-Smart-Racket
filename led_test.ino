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

