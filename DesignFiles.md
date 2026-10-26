This folder contains all the design-related resources and documentation for the Smart Tennis Racket project. Here, you will find circuit diagrams, hardware requirements, and assembly instructions to help you replicate or improve the build.

---

## 📁 Folder Structure

| File / Folder            | Description                                              |
|--------------------------|----------------------------------------------------------|
| `Circuit_Diagram.png`     | The wiring diagram showing the connection between ESP32, MPU6050, LED RGB Strip, and power supply. |
| `Bill_of_Materials.md`    | List of all hardware and software components required for the build. |
| `Assembly_Guide.md`       | Step-by-step guide to assembling the hardware components and wiring the system. |

---

## 🛠️ Tools Used
- **Circuit Design**: EasyEDA
- **Programming IDE**: Arduino IDE
- **Microcontroller Platform**: ESP32

---

# 📋 Bill of Materials (BOM)

A comprehensive list of components needed to build the Smart Tennis Racket.

---

## 🔹 Hardware Requirements

| Component               | Description                         | Quantity |
|-------------------------|-------------------------------------|----------|
| ESP32                   | Microcontroller                    | 1        |
| MPU6050                | Accelerometer & Gyroscope Sensor   | 1        |
| LED RGB Strip          | For visual shot intensity feedback | 1        |
| Battery (5V)           | Power Source                       | 1        |
| Capacitors           | 1000µF                      | 1        |
| Wires | Miscellaneous components        | As needed |

---

## 🔹 Software Requirements

| Software/Library        | Purpose                         |
|-------------------------|---------------------------------|
| Arduino IDE             | Programming the ESP32          |
| Wire.h                  | I2C Communication               |
| Adafruit_MPU6050.h      | MPU6050 Sensor Handling         |
| Adafruit_Sensor.h       | Sensor Data Interface           |
| WiFi.h                  | ESP32 Wi-Fi Communication       |
| WiFiClient.h            | Wi-Fi Client Functionality      |
| WiFiServer.h            | Wi-Fi Server Functionality      |

---

## Circuit Diagram : 

![image](https://github.com/user-attachments/assets/33419769-9524-431a-9cc0-07e09bf930fe)

## Connections

### ESP32 to MPU6050
| ESP32 Pin  | MPU6050 Pin | Function          |
|------------|-------------|-------------------|
| 3V3        | VCC (Pin 6) | Power Supply      |
| GND        | GND (Pin 5) | Ground            |
| IO21       | SDA (Pin 4) | I2C Data          |
| IO22       | SCL (Pin 3) | I2C Clock         |

### ESP32 to LED Strip (WS2812)
| ESP32 Pin  | LED Strip Pin | Function          |
|------------|---------------|-------------------|
| IO23       | DIN           | Data Input        |
| GND        | GND           | Ground            |
| 5V (BAT1)  | VCC           | Power Supply (+5V)|

### Capacitor
- Connect **1000uF** capacitor **across** the **+5V** and **GND** lines of the **LED strip**.
- This helps stabilize voltage and protect the strip from sudden current changes.

---

## Step-by-Step Assembly

### 1. **Power the ESP32**
- Connect the **5V battery pack** to the **5V** pin on the ESP32 and **GND**.
- Verify your battery provides a stable **5V** output.

### 2. **Connect MPU6050 to ESP32**
- Use jumper wires to connect **VCC, GND, SDA, and SCL**.
- Ensure your connections are secure; loose connections can cause communication issues.

### 3. **Wire the LED Strip**
- Connect the **DIN** pin of the LED strip to **IO23** on the ESP32.
- Provide **5V power** from the battery to the **VCC** of the LED strip.
- Ground the LED strip to the ESP32 **GND**.

### 4. **Add Capacitor**
- Solder or connect the **1000uF capacitor** between **+5V** and **GND** as close to the LED strip as possible.

### 5. **Check All Connections**
- Double-check polarity (especially for power connections).
- Ensure I2C lines (SDA/SCL) are not swapped.

---

## Power Supply Details

- **ESP32** runs on **5V** (provided by BAT1 in the schematic).
- **MPU6050** gets **3.3V** from the ESP32.
- **LED strip** needs a stable **5V** with enough current (calculate your LED current draw).
- If your LED strip draws high current, consider adding a separate power source for it, sharing the **common ground** with ESP32.

---

## Best Practices

- **Solder connections** for a permanent, reliable setup.
- Add **heat shrink tubing** around joints for protection.
- Use **Velcro straps** or **cable ties** to mount components securely on the racket.
- Isolate the electronics from vibrations and shocks during gameplay

## Photos & Videos of the Project

(![image](https://github.com/user-attachments/assets/733b7f64-188d-49b1-b0d4-37f2bbe2e856))
