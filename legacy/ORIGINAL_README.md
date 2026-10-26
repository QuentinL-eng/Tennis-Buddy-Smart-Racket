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


### Upload Code
- Upload `client_code.ino` to the racket ESP32.
- Upload `server_code.ino` to the server ESP32.

### Run Server
Monitor the **Server ESP32 Serial Monitor** to get its IP address:
```
Server IP: 192.168.x.x
```

### Set Server IP in Client
Edit `client_code.ino` to match the server’s IP:
```cpp
const char* serverIP = "192.168.x.x";
```

### Start Swinging!
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
}


---

**🎾 Let’s make tennis smarter together!**

