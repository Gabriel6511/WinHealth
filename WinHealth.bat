@echo off
setlocal EnableExtensions
title WinHealth
color 0B
rem Launcher: copia o WinHealth.ps1 para uma pasta LOCAL e roda de la.
rem Uso: WinHealth.bat        (menu no console)
rem      WinHealth.bat gui    (janela)
rem Isso permite rodar direto de um compartilhamento de rede (\servidor\...) sem pendrive,
rem porque a ExecutionPolicy RemoteSigned bloqueia scripts executados de caminho UNC.
set "TMPPS=%TEMP%\winhealth_%RANDOM%.ps1"

if not exist "%~dp0WinHealth.ps1" (
    echo.
    echo ERRO: WinHealth.ps1 nao encontrado ao lado deste arquivo:
    echo   %~dp0
    echo.
    pause
    exit /b 1
)

echo Preparando o WinHealth...
copy /y "%~dp0WinHealth.ps1" "%TMPPS%" >nul
if not exist "%TMPPS%" (
    echo.
    echo ERRO: nao consegui copiar o Kit para %TEMP%.
    echo.
    pause
    exit /b 1
)

set "WHGUI="
if /i "%~1"=="gui" (
    set "WHGUI=-Gui"
    rem Titulo diferente do da janela WPF ("WinHealth"): o programa procura por ESTE
    rem titulo pra esconder tambem a janela do Windows Terminal (que hospeda este console
    rem em vez do conhost classico, e nao responde ao esconder do console sozinho).
    title WinHealth (console)
)

powershell -NoProfile -ExecutionPolicy RemoteSigned -File "%TMPPS%" -PastaKit "%~dp0." %WHGUI%

del "%TMPPS%" >nul 2>&1

rem Modo janela: o console foi escondido pelo programa; nao ha o que pausar.
if defined WHGUI exit /b

echo.
echo ============================================
echo  WinHealth finalizado.
echo ============================================
pause
exit /b
