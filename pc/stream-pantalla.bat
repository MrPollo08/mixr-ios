@echo off
rem ---------------------------------------------------------------------------
rem  Manda la pantalla del PC al iPhone MiXR.
rem  Uso: doble clic y escribi la IP que muestra la ventana "PC" de la app.
rem  O pasala como argumento:  stream-pantalla.bat 192.168.0.42
rem ---------------------------------------------------------------------------
setlocal

set IP=%~1
if not "%IP%"=="" goto run

:ask
set /p IP=Escribi la IP del iPhone: 
if "%IP%"=="" goto empty

:run
echo.
echo Conectando a %IP% puerto 47295 ...
echo Abortar con Ctrl+C.
echo.

ffmpeg -f gdigrab -framerate 60 -i desktop ^
  -vf "scale=-2:1080" ^
  -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p -g 60 ^
  -bsf:v dump_extra -flush_packets 1 ^
  -f h264 tcp://%IP%:47295

echo.
echo Stream terminado.
pause
exit /b 0

:empty
echo Falta la IP.
pause
exit /b 1
