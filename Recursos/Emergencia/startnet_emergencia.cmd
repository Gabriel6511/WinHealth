@echo off
rem ======================================================================
rem  Este arquivo SUBSTITUI o startnet.cmd padrao dentro da imagem WinPE.
rem  Ele roda AUTOMATICAMENTE assim que o WinPE termina de carregar -
rem  e o que da o efeito "so plugar e esperar", sem clicar em nada.
rem
rem  Ele NAO carrega o EMERGENCIA.ps1 embutido na imagem. Em vez disso,
rem  procura o script no proprio pendrive (fora da imagem). Vantagem:
rem  para atualizar o script no futuro, basta trocar o arquivo no
rem  pendrive - nao precisa remontar a imagem WinPE de novo.
rem ======================================================================

wpeinit

echo.
echo MODO EMERGENCIA - procurando o pendrive...
echo.

set ENCONTROU=0
for %%d in (D E F G H I J K L M N O P Q R S T U V W X Y Z C) do (
    if exist %%d:\EMERGENCIA.ps1 (
        echo Encontrado em %%d:\
        powershell -NoProfile -ExecutionPolicy Bypass -File %%d:\EMERGENCIA.ps1
        set ENCONTROU=1
        goto :fim
    )
)

:fim
if "%ENCONTROU%"=="0" (
    echo.
    echo Nao foi encontrado o arquivo EMERGENCIA.ps1 em nenhum pendrive.
    echo Verifique se o pendrive com o WinHealth esta espetado.
    echo.
    echo Abrindo o prompt de comando manual...
)

cmd.exe
