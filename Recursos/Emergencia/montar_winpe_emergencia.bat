@echo off
setlocal enabledelayedexpansion
title Montar WinPE - Modo Emergencia (zero clique)
color 0B

echo ========================================================================
echo   MONTAR ISO DO MODO EMERGENCIA (WinPE - boot automatico, zero clique)
echo ========================================================================
echo.
echo Isto so precisa ser feito UMA VEZ (ou quando voce quiser atualizar).
echo Precisa rodar como ADMINISTRADOR, numa maquina Windows com o Windows
echo ADK + o complemento "WinPE add-on" instalados.
echo.
echo Baixe (gratis, site oficial da Microsoft) se ainda nao tiver:
echo   ADK:          https://learn.microsoft.com/windows-hardware/get-started/adk-install
echo   WinPE add-on: mesmo link acima, e a segunda opcao de download.
echo.
pause

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo ERRO: precisa rodar como administrador. Feche e abra de novo com
    echo botao direito - "Executar como administrador".
    pause
    exit /b 1
)

rem ------------------------------------------------------------------
rem localizar o copype.cmd do ADK (caminho padrao de instalacao)
rem ------------------------------------------------------------------
set "COPYPE=C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\copype.cmd"

if not exist "%COPYPE%" (
    echo.
    echo ERRO: nao encontrei o copype.cmd em:
    echo   %COPYPE%
    echo.
    echo Isso significa que o "WinPE add-on" do ADK nao esta instalado
    echo ^(ou foi instalado em outro caminho^). Instale o complemento e
    echo rode este arquivo de novo.
    pause
    exit /b 1
)

set "PASTA_WORK=%~dp0WinPE_Emergencia_Build"
set "PASTA_MEDIA=%PASTA_WORK%\media"
set "PASTA_MOUNT=%PASTA_WORK%\mount"

echo.
echo Pasta de trabalho: %PASTA_WORK%
if exist "%PASTA_WORK%" (
    echo Pasta ja existe de uma tentativa anterior - removendo...
    rmdir /s /q "%PASTA_WORK%" 2>nul
)

echo.
echo [1/5] Criando ambiente WinPE base (arquitetura amd64)...
call "%COPYPE%" amd64 "%PASTA_WORK%"
if not exist "%PASTA_MEDIA%\sources\boot.wim" (
    echo ERRO: copype nao gerou o boot.wim esperado. Abortando.
    pause
    exit /b 1
)

echo.
echo [2/5] Montando a imagem boot.wim para edicao...
mkdir "%PASTA_MOUNT%" 2>nul
Dism /Mount-Image /ImageFile:"%PASTA_MEDIA%\sources\boot.wim" /index:1 /MountDir:"%PASTA_MOUNT%"
if %errorlevel% neq 0 (
    echo ERRO ao montar a imagem. Abortando.
    pause
    exit /b 1
)

echo.
echo [3/5] Instalando o script de auto-inicio (startnet_emergencia.cmd)...
copy /y "%~dp0startnet_emergencia.cmd" "%PASTA_MOUNT%\Windows\System32\startnet.cmd"
if %errorlevel% neq 0 (
    echo ERRO ao copiar o startnet.cmd. Desmontando sem salvar...
    Dism /Unmount-Image /MountDir:"%PASTA_MOUNT%" /Discard
    pause
    exit /b 1
)

echo.
echo [4/5] Salvando e desmontando a imagem...
Dism /Unmount-Image /MountDir:"%PASTA_MOUNT%" /Commit
if %errorlevel% neq 0 (
    echo ERRO ao salvar a imagem. Abortando.
    pause
    exit /b 1
)

echo.
echo [5/5] Gerando o arquivo ISO final...
set "ISO_FINAL=%~dp0WinPE_Emergencia.iso"
call "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\MakeWinPEMedia.cmd" /ISO "%PASTA_WORK%" "%ISO_FINAL%"

if exist "%ISO_FINAL%" (
    echo.
    echo ========================================================================
    echo   PRONTO!
    echo ========================================================================
    echo.
    echo ISO gerada em:
    echo   %ISO_FINAL%
    echo.
    echo PROXIMO PASSO:
    echo   1. Abra o Ventoy2Disk no seu pendrive ^(se ainda nao instalou o
    echo      Ventoy nele^)
    echo   2. Copie o arquivo WinPE_Emergencia.iso para dentro do pendrive
    echo      ^(junto com os outros arquivos, como se fosse um arquivo comum^)
    echo   3. Copie tambem o EMERGENCIA.ps1 e o EMERGENCIA.cmd para a RAIZ
    echo      do pendrive ^(fora da ISO - ficam soltos no pendrive mesmo^)
    echo   4. De boot pelo pendrive, escolha "WinPE_Emergencia" no menu do
    echo      Ventoy - o resto acontece sozinho
    echo.
) else (
    echo.
    echo ERRO: a ISO nao foi gerada. Revise as mensagens acima.
)

pause
