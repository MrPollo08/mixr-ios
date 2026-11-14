# pc_input.ps1 - mouse virtual para MiXR (Windows, sin Python).
#
#   powershell -ExecutionPolicy Bypass -File pc_input.ps1
#
# Escucha en UDP 47300 lo que manda el iPhone y mueve el cursor real.
# Si el juego corre como administrador, ejecutá esto como administrador.

$ErrorActionPreference = "Stop"

Add-Type @"
using System;
using System.Runtime.InteropServices;

public class MixrMouse {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, int data, int extra);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@

[MixrMouse]::SetProcessDPIAware() | Out-Null

$W = [MixrMouse]::GetSystemMetrics(0)
$H = [MixrMouse]::GetSystemMetrics(1)

$LEFTDOWN = 0x0002
$LEFTUP = 0x0004
$WHEEL = 0x0800

$udp = New-Object System.Net.Sockets.UdpClient(47300)
$remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)

Write-Host "MiXR input escuchando en UDP 47300 (pantalla ${W}x${H})"
Write-Host "Ctrl+C para salir.`n"

while ($true) {
    try {
        $data = $udp.Receive([ref]$remote)
    } catch {
        break
    }

    if (-not $data -or $data.Length -lt 1) { continue }

    switch ($data[0]) {
        1 {
            if ($data.Length -ge 5) {
                $nx = [BitConverter]::ToUInt16($data, 1) / 65535.0
                $ny = [BitConverter]::ToUInt16($data, 3) / 65535.0
                [MixrMouse]::SetCursorPos([int]($nx * ($W - 1)), [int]($ny * ($H - 1))) | Out-Null
            }
        }
        2 { [MixrMouse]::mouse_event($LEFTDOWN, 0, 0, 0, 0) }
        3 { [MixrMouse]::mouse_event($LEFTUP, 0, 0, 0, 0) }
        4 {
            if ($data.Length -ge 2) {
                $delta = [sbyte]$data[1]
                [MixrMouse]::mouse_event($WHEEL, 0, 0, ($delta * 120), 0)
            }
        }
    }
}
