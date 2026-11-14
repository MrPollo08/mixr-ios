"""
pc_input.py - mouse virtual para MiXR (Windows).

Escucha los eventos que manda el iPhone por UDP (puerto 47300) y mueve el
cursor real del PC. No necesita instalar nada: usa la API de Windows.

    python pc_input.py

Dejalo corriendo mientras usás el modo "Control" en la app.
Ojo: si el juego corre como administrador, ejecutá esto también como
administrador, si no Windows ignora los eventos.
"""

import ctypes
import socket
import struct
import sys

PORT = 47300

user32 = ctypes.windll.user32
user32.SetProcessDPIAware()          # coordenadas reales con escalado de Windows

SCREEN_W = user32.GetSystemMetrics(0)
SCREEN_H = user32.GetSystemMetrics(1)

MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004
MOUSEEVENTF_WHEEL = 0x0800


def move(nx: float, ny: float) -> None:
    x = int(nx * (SCREEN_W - 1))
    y = int(ny * (SCREEN_H - 1))
    user32.SetCursorPos(x, y)


def button(down: bool) -> None:
    user32.mouse_event(MOUSEEVENTF_LEFTDOWN if down else MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)


def scroll(delta: int) -> None:
    user32.mouse_event(MOUSEEVENTF_WHEEL, 0, 0, delta * 120, 0)


def main() -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("0.0.0.0", PORT))
    except OSError as error:
        print(f"No pude abrir el puerto UDP {PORT}: {error}")
        sys.exit(1)

    print(f"MiXR input escuchando en UDP {PORT}  (pantalla {SCREEN_W}x{SCREEN_H})")
    print("Ctrl+C para salir.\n")

    while True:
        try:
            data, address = sock.recvfrom(64)
        except KeyboardInterrupt:
            print("\nChau.")
            break
        except OSError:
            break

        if not data:
            continue

        kind = data[0]

        if kind == 1 and len(data) >= 5:
            nx, ny = struct.unpack_from("<HH", data, 1)
            move(nx / 65535.0, ny / 65535.0)
        elif kind == 2:
            button(True)
        elif kind == 3:
            button(False)
        elif kind == 4 and len(data) >= 2:
            scroll(struct.unpack_from("<b", data, 1)[0])
        # tipos desconocidos se ignoran


if __name__ == "__main__":
    main()
