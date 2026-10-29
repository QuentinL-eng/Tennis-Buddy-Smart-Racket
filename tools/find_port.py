"""Find the racket's serial port automatically (ESP32-C3 native USB or a common USB-serial bridge)."""
from serial.tools import list_ports

# Espressif native USB, CH340/CH343, CP210x, FTDI
KNOWN_VIDS = {0x303A, 0x1A86, 0x10C4, 0x0403}


def find_port():
    ports = list(list_ports.comports())
    hits = [p for p in ports if p.vid in KNOWN_VIDS]
    if len(hits) == 1:
        print(f"Using {hits[0].device} ({hits[0].description})")
        return hits[0].device
    if not hits and len(ports) == 1:
        print(f"Using {ports[0].device} ({ports[0].description})")
        return ports[0].device
    found = "\n".join(f"  {p.device}: {p.description}" for p in (hits or ports)) or "  (none)"
    raise SystemExit(f"Could not pick a serial port automatically. Candidates:\n{found}\nPass one with --port.")
