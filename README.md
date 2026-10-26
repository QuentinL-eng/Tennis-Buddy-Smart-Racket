# Smart-Tennis-Racket

### **📜 Project Description**
A smart tennis racket designed to analyze shot acceleration using an MPU6050 accelerometer and ESP32 for wireless data transmission. The project aims to assist players and coaches in refining techniques by providing real-time feedback and analytics. Furthermore, it displays the intensity of the shot played by displaying different colors on an LED RGB Strip.

### **🔹 Features**
- ✅ **Real-time acceleration tracking** using MPU6050 (accelerometer and gyroscope).
- ✅ **Wireless data transmission** via ESP32 Wi-Fi communication.
- ✅ **LED indicators** to visually represent shot intensity.
- ✅ **Open-source and customizable** for further development.
- ✅ **Potential for integration** with ML-based analytics for deeper insights.

---

### **🛠 Hardware Requirements**
- **🖥 Microcontroller:** ESP32
- **📟 Sensors:** MPU6050 (Accelerometer & Gyroscope)
- **📺 Display:** LED RGB Strips (Adafruit_SSD1306)
- **🔋 Power Source:** 5V Battery
- **📡 Additional Components:** Wires, Connectors, Resistors

---

### **💾 Software Requirements**
- **🛠 Arduino IDE**
- **📚 Libraries:**
  - `Wire.h` - I2C Communication
  - `Adafruit_MPU6050.h` - MPU6050 Library
  - `Adafruit_Sensor.h` - Sensor Data Handling
  - `WiFi.h` - ESP32 Wi-Fi Communication
  - `WiFiClient.h` - WiFi Client Functionality
  - `WiFiServer.h` - WiFi Server Functionality

---

### **🚀 Getting Started**
1. **Clone the repository:**
   ```sh
   git clone https://github.com/YOUR_GITHUB_USERNAME/smart-tennis-racket.git
   cd smart-tennis-racket
   ```
2. **Install the required libraries** in Arduino IDE.
3. **Flash the ESP32** with the provided firmware.
4. **Assemble the hardware** according to the circuit diagram.
5. **Start testing** the system and analyze data.

### **Installation Guide**
- **Setting up Arduino IDE**: Download and install Arduino IDE from [here](https://www.arduino.cc/en/software).
- **Adding ESP32 Board Support**: Follow [this guide](https://github.com/espressif/arduino-esp32).
- **Uploading Code**: Connect ESP32, select the correct COM port, and upload the provided scripts.

### **Usage Instructions**
- **Basic setup**: Turn on the racket and ensure Wi-Fi connectivity.
- **Data transmission**: Observe motion data in the serial monitor or via the server.
- **LED indications**:
  - Green LED: Low impact shot
  - Red LED: High impact shot

### **Circuit Diagram & Wiring Instructions**
![image](https://github.com/user-attachments/assets/33419769-9524-431a-9cc0-07e09bf930fe)


### **Contributing**
We welcome contributions! Follow these steps:
1. **Fork the repository**
2. **Create a feature branch**
3. **Commit changes and push to GitHub**
4. **Submit a pull request**

### **License**
This project is licensed under the **MIT License**. See the `LICENSE` file for details.

}




# 🎾 Smart Tennis Racket

## 📖 Overview
The **Smart Tennis Racket** project aims to enhance tennis training using **IoT technology**. This project integrates sensors with a tennis racket to **measure swing acceleration, impact force, and other performance metrics**. The data is transmitted wirelessly to a **server**, where it can be logged, analyzed, and visualized.

---

## 📌 Project Architecture
This project follows a **Client-Server** model:
- **Client (Racket)**: An ESP32 mounted on the tennis racket, connected to an **MPU6050** sensor.
- **Server**: Another ESP32 or a laptop-based server that receives data over WiFi and logs it.

---

## ⚙️ Technology Stack

| Component          | Details |
|------------------|------------------|
| Microcontroller   | ESP32 |
| Sensor            | MPU6050 (Accelerometer + Gyroscope) |
| Communication     | WiFi (ESP32 Client-Server) |
| Software          | Arduino IDE (Firmware) + Python (Data Analysis - Optional) |

---

## 🚀 Features
✅ Real-time swing acceleration monitoring  
✅ Wireless data transmission via WiFi  
✅ Simple Client-Server architecture  
✅ Data logging for performance analysis  
✅ Easy extension for other sensors like Force Sensors or Vibration Sensors  

---

## 📂 Repository Structure
```plaintext
/
├── Client/                  # Code for the racket-mounted ESP32
│   └── client_code.ino
├── Server/                  # Code for the receiving ESP32/laptop server
│   └── server_code.ino
├── DataAnalysis/           # Optional Python scripts for analyzing swing data
│   └── analysis_script.py
├── TROUBLESHOOTING.md    # Troubleshooting guide and FAQs
├── CONTRIBUTING.md        # Contribution guidelines
├── CODE_OF_CONDUCT.md     # Code of Conduct for contributors
└── README.md              # This file
```

---

## 🛠️ Hardware Requirements
| Component          | Quantity |
|------------------|---------|
| ESP32              | 2 (One for client, one for server) |
| MPU6050            | 1 |
| Tennis Racket      | 1 |
| Power Source       | 1 (Li-Po battery recommended for racket) |

---

## 🔌 Wiring Diagram
| MPU6050 Pin | ESP32 Pin |
|---|---|
| VCC | 3.3V |
| GND | GND |
| SDA | GPIO 21 |
| SCL | GPIO 22 |

---

## 📲 Setup Instructions

### 1. Clone Repository
```bash
git clone https://github.com/AahanPrajapati/Smart-Tennis-Racket.git
```

### 2. Configure WiFi Credentials
Edit both **client** and **server** files to add your WiFi credentials:
```cpp
const char* ssid = "YourWiFiSSID";
const char* password = "YourWiFiPassword";
```

### 3. Upload Code
- Upload `client_code.ino` to the racket ESP32.
- Upload `server_code.ino` to the server ESP32.

### 4. Run Server
Monitor the **Server ESP32 Serial Monitor** to get its IP address:
```
Server IP: 192.168.x.x
```

### 5. Set Server IP in Client
Edit `client_code.ino` to match the server’s IP:
```cpp
const char* serverIP = "192.168.x.x";
```

### 6. Start Swinging!
The client will send data to the server, which logs it to the serial monitor.

---

## 📊 Sample Output
```
Received: Acceleration Magnitude: 9.81
Received: Acceleration Magnitude: 14.25
```

---

## 💡 Future Enhancements
- Add **Force Sensors** to calculate impact force.
- Add **Mobile App** for real-time graphing.
- Use **Cloud Storage** for remote data access.
- Apply **Machine Learning** to classify different strokes.

---

## 🙌 Contribution
We welcome contributions! See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

---

## ❓ Troubleshooting
For common issues and solutions, refer to [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## 📜 License
This project is licensed under the [MIT License](LICENSE).

---

## 📞 Contact
For queries, reach out to:  
📧 **aahanprajapati@gmail.com**  
🌐 [GitHub Profile](https://github.com/AahanPrajapati)

---

**🎾 Let’s make tennis smarter together!**

