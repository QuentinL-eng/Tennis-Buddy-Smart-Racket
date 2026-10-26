# Troubleshooting & FAQs - Smart Tennis Racket (ESP32 Client-Server)

This document covers common issues and solutions for the **client-server communication setup** using **ESP32 and MPU6050** in the Smart Tennis Racket project.

---

## Basic Architecture Recap

- **Client (Racket)**: Reads data from MPU6050 and sends acceleration magnitude to the server.
- **Server**: Listens on port `8080`, receives data from the client, and displays it on the serial monitor.

---

# Common Issues & Solutions

## 1. ESP32 Fails to Connect to WiFi
**Symptoms:**
- "Connecting to WiFi..." repeats continuously in the serial monitor.

**Possible Causes & Fixes:**
- **Wrong SSID/Password**: Double-check `ssid` and `password` in both client and server code.
- **WiFi Signal Issues**: Place ESP32 closer to the router.
- **ESP32 Not Configured Properly**: Ensure ESP32 board is correctly selected in Arduino IDE (`Tools > Board`).
- **Power Supply Issues**: Use a stable 5V power source for ESP32.

---

## 2. Client Fails to Connect to Server
**Symptoms:**
- "Attempting to connect to server..." repeats on the client serial monitor.

**Possible Causes & Fixes:**
- **Wrong IP Address**: Ensure the `serverIP` in client code matches the server's actual IP (printed by `WiFi.localIP()` on the server side).
- **Port Mismatch**: Confirm both client and server use port `8080`.
- **WiFi Network Issue**: Ensure both client and server are on the **same WiFi network**.
- **Server Not Running**: Start the server first and ensure it prints "Server started!".
- **Firewall/Router Blocking**: Check your router’s firewall settings (allow devices to communicate locally).

---

## 3. MPU6050 Initialization Fails
**Symptoms:**
- Client prints "Failed to find MPU6050 chip!" and gets stuck.

**Possible Causes & Fixes:**
- **Wiring Issues**: Check if SDA and SCL are correctly connected.
    - SDA → GPIO 21 (ESP32)
    - SCL → GPIO 22 (ESP32)
- **Sensor Power**: Ensure the sensor is powered correctly (3.3V or 5V based on your module).
- **Faulty Sensor**: Replace with a working MPU6050 if needed.

---

## 4. Client-Server Disconnects Frequently
**Symptoms:**
- "Connection to server lost!" appears on the client.
- Server logs "Client disconnected!" too often.

**Possible Causes & Fixes:**
- **WiFi Signal Weakness**: Improve placement or add a repeater.
- **Inconsistent Power Supply**: Ensure ESP32 gets a steady supply.
- **Missing Keep-Alive Mechanism**: You can enhance the code to send regular heartbeats from client to server to keep the connection alive.

---

## 5. Data Received by Server is Corrupted/Incomplete
**Symptoms:**
- Server prints garbled or incomplete messages.

**Possible Causes & Fixes:**
- **Print vs. Println Confusion**: Make sure client uses `client.println()` to properly terminate each data packet.
- **Buffer Overflow**: Add a small delay (like `delay(500)`) between consecutive sends to avoid flooding.
- **Serial Baudrate Mismatch**: Both client and server must use the **same baud rate** (115200).

---

# Frequently Asked Questions (FAQs)

### Q1: Why do both client and server need WiFi credentials?
Both need to join the **same WiFi network** to communicate directly.

---

### Q2: How do I find the server’s IP address?
When the server starts, it prints:
```
Server IP: xxx.xxx.xxx.xxx
```
Use this IP in the `serverIP` variable in the client code.

---

### Q3: Can I run the server on a laptop instead of ESP32?
Yes, but you need to write a Python/Node.js server script to listen on a port and handle the incoming data. The ESP32 client code would remain mostly the same.

---

### Q4: How do I debug communication issues?
- Check **WiFi connection** on both client and server.
- Confirm **server IP and port** are correct.
- Use **Serial.print()** at every important step (connection, data send, data receive).
- Test using a **simple hardcoded message** first, before adding sensor data.

---

### Q5: Can this work with another sensor?
Yes, you can replace MPU6050 with any sensor (e.g., force sensor, gyroscope) as long as you modify the data acquisition part of the client code.

---

### Q6: How to extend this for multiple rackets (multi-client)?
You can modify the server to handle **multiple clients** using a list of connected sockets. This requires restructuring the server’s `loop()` to poll all connected clients and read data from each.

---

### Q7: What tools can help me debug faster?
- **ESP32 Serial Monitor** (Arduino IDE).
- **Ping Command** to check if ESP32 and server can reach each other.
- **Wireshark** (advanced) to monitor network traffic between devices.

---

### Need Further Help?
For more assistance, contact:  
📧 **aahanprajapati@gmail.com**

---

Thank you for using and contributing to the Smart Tennis Racket project!
