@echo off
setlocal enabledelayedexpansion
title Dreamspace - Pantalla del PC
cd /d "%~dp0"

set "IPFILE=%LOCALAPPDATA%\dreamspace-ip.txt"
set "LASTIP="
if exist "%IPFILE%" set /p LASTIP=<"%IPFILE%"

echo.
echo  Dreamspace - mandar la pantalla del PC al iPhone
echo  -----------------------------------------------
echo  En el iPhone: abri el tile "PC". Arriba muestra una IP
echo  (por ejemplo 192.168.1.3). Esa es la que va aca.
echo.
if defined LASTIP echo  Ultima IP: %LASTIP%
set "IP="
set /p IP=Escribi la IP del iPhone y Enter: 
if "%IP%"=="" set "IP=%LASTIP%"
if "%IP%"=="" goto noip
>"%IPFILE%" echo %IP%

rem --- ffmpeg: PATH o carpeta de hermes ---
where ffmpeg >nul 2>&1
if not errorlevel 1 goto run
for /d %%D in ("%LOCALAPPDATA%\hermes\tools\ffmpeg-*") do (
  if exist "%%D\bin\ffmpeg.exe" set "PATH=%%D\bin;!PATH!"
)
where ffmpeg >nul 2>&1
if errorlevel 1 goto noffmpeg

:run
echo.
echo Conectando a %IP%:47295 ...
echo Si tarda o falla: abri el tile "PC" en el iPhone antes de esto.
echo Cortar con Ctrl+C.
echo.
ffmpeg -hide_banner -f gdigrab -framerate 60 -i desktop ^
  -vf "scale=-2:1080" ^
  -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p -g 60 ^
  -bsf:v dump_extra -flush_packets 1 ^
  -f h264 tcp://%IP%:47295
echo.
echo Stream terminado.
pause
exit /b 0

:noip
echo.
echo Falta la IP del iPhone.
pause
exit /b 1

:noffmpeg
echo.
echo No encuentro ffmpeg.
echo   Opcion 1: cerra esta ventana y volve a abrirla (para que tome el PATH).
echo   Opcion 2: winget install Gyan.FFmpeg
pause
exit /b 1
