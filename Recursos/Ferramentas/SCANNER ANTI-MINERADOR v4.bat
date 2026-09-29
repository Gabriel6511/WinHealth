@echo off
setlocal EnableExtensions
title SCANNER ANTI-MINERADOR v4
color 0B
set "TMPPS=%TEMP%\scanner_antiminerador_%RANDOM%.ps1"

echo Preparando o scanner...
powershell -NoProfile -ExecutionPolicy RemoteSigned -Command "try { Get-Content -LiteralPath '%~f0' -Encoding UTF8 -ErrorAction Stop | Select-Object -Skip 33 | Set-Content -LiteralPath '%TMPPS%' -Encoding utf8 -ErrorAction Stop; Write-Host 'Preparado com sucesso.' -ForegroundColor Green } catch { Write-Host ('ERRO ao preparar: ' + $_.Exception.Message) -ForegroundColor Red }"

if not exist "%TMPPS%" (
    echo.
    echo ERRO: nao consegui preparar o arquivo do scanner.
    echo Copie a mensagem de erro acima e me avise.
    echo.
    pause
    exit /b 1
)

echo.
echo Iniciando verificacao, aguarde...
echo.
powershell -NoProfile -ExecutionPolicy RemoteSigned -File "%TMPPS%" -PastaSaida "%~1"

del "%TMPPS%" >nul 2>&1

echo.
echo ============================================
echo  Scanner finalizado.
echo ============================================
pause
exit /b

rem PSSTART_MARKER
param([string]$PastaSaida = ""); $ErrorActionPreference = 'SilentlyContinue'
$logfile = if ($PastaSaida -and (Test-Path -LiteralPath $PastaSaida)) { Join-Path $PastaSaida ("$env:COMPUTERNAME" + "_Scanner_" + (Get-Date -Format 'yyyy-MM-dd_HHmmss') + ".txt") } else { "$env:USERPROFILE\Desktop\resultado_scanner_antiminerador.txt" }
if (Test-Path $logfile) { Remove-Item $logfile -Force }
$alertas = 0
$alertasBaixos = 0
$acoes = New-Object System.Collections.ArrayList

function W {
    param($texto, $cor = "White", $alerta = $false, $prioridade = "Alta")
    if ($alerta -and $prioridade -eq "Baixa") {
        Write-Host $texto -ForegroundColor DarkYellow
        Add-Content -Path $logfile -Value "[BAIXA PRIORIDADE] $texto"
        $script:alertasBaixos++
    } elseif ($alerta) {
        Write-Host $texto -ForegroundColor Red
        Add-Content -Path $logfile -Value "[ALERTA] $texto"
        $script:alertas++
    } else {
        Write-Host $texto -ForegroundColor $cor
        Add-Content -Path $logfile -Value $texto
    }
}

function AssinaturaInfo($caminhoArquivo) {
    try {
        if (-not (Test-Path -LiteralPath $caminhoArquivo)) { return @{ Existe = $false; Assinado = $false; Editora = $null } }
        $assinatura = Get-AuthenticodeSignature -LiteralPath $caminhoArquivo -ErrorAction Stop
        if ($assinatura.Status -eq "Valid" -and $assinatura.SignerCertificate) {
            $editora = $assinatura.SignerCertificate.Subject
            if ($editora -match 'CN=([^,]+)') { $editora = $matches[1] }
            return @{ Existe = $true; Assinado = $true; Editora = $editora }
        } else {
            return @{ Existe = $true; Assinado = $false; Editora = $null }
        }
    } catch {
        return @{ Existe = $true; Assinado = $false; Editora = $null }
    }
}

function Titulo($n, $total, $texto) {
    Write-Host ""
    Write-Host "====================================================================" -ForegroundColor Cyan
    Write-Host "  ETAPA $n de $total - $texto" -ForegroundColor Cyan
    Write-Host "====================================================================" -ForegroundColor Cyan
    Add-Content -Path $logfile -Value ""
    Add-Content -Path $logfile -Value "==================== ETAPA $n de $total - $texto ===================="
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host ""
Write-Host "############################################################" -ForegroundColor Yellow
Write-Host "#                                                          #" -ForegroundColor Yellow
Write-Host "#          SCANNER ANTI-MINERADOR v4                       #" -ForegroundColor Yellow
Write-Host "#          Verificacao de seguranca do computador          #" -ForegroundColor Yellow
Write-Host "#                                                          #" -ForegroundColor Yellow
Write-Host "############################################################" -ForegroundColor Yellow
Write-Host ""
Write-Host "Este programa APENAS verifica e informa. Ele NAO apaga nada" -ForegroundColor Gray
Write-Host "sozinho. No final, se algo suspeito for encontrado, voce" -ForegroundColor Gray
Write-Host "escolhe o que remover." -ForegroundColor Gray
Write-Host ""
Write-Host "Cores: VERMELHO = alta prioridade, revise agora. AMARELO (com aviso)" -ForegroundColor Gray
Write-Host "= baixa prioridade, geralmente arquivo assinado digitalmente ou orfao" -ForegroundColor Gray
Write-Host "de instalador antigo - comum e raramente perigoso." -ForegroundColor Gray
if (-not $isAdmin) {
    Write-Host ""
    Write-Host "Rodando SEM privilegios de administrador." -ForegroundColor DarkYellow
    Write-Host "Tarefas agendadas maliciosas so podem ser removidas rodando" -ForegroundColor DarkYellow
    Write-Host "este arquivo como Administrador (botao direito > Executar como administrador)." -ForegroundColor DarkYellow
}
Write-Host ""
Start-Sleep -Milliseconds 800

$TOTAL_ETAPAS = 34

# ===================== ETAPA 1 - PROCESSOS =====================
Titulo 1 $TOTAL_ETAPAS "PROCESSOS SUSPEITOS EM EXECUCAO"
$nomesSuspeitos = @("xmrig","minerd","ccminer","cpuminer","ethminer","nheqminer","t-rex","phoenixminer","nbminer","teamredminer","srbminer","nanominer","wildrig","gminer","lolminer","xmr-stak","cryptonight")
$processos = Get-Process
$achouProcesso = $false
foreach ($p in $processos) {
    foreach ($n in $nomesSuspeitos) {
        if ($p.ProcessName -like "*$n*") {
            $achouProcesso = $true
            W "Processo suspeito: $($p.ProcessName) (PID $($p.Id))" "Red" $true
            [void]$acoes.Add(@{ Tipo = "Processo"; Alvo = $p.Id; Descricao = "Encerrar processo: $($p.ProcessName) (PID $($p.Id))" })
        }
    }
}
if (-not $achouProcesso) { W "Nenhum processo com nome de minerador conhecido foi encontrado." "Green" }

# ===================== ETAPA 2 - CPU =====================
Titulo 2 $TOTAL_ETAPAS "TOP 10 PROCESSOS POR USO DE CPU"
Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 | ForEach-Object {
    W ("{0,-25} PID {1,-8} CPU: {2}" -f $_.ProcessName, $_.Id, [math]::Round($_.CPU,1)) "White"
}

# ===================== ETAPA 3 - GPU =====================
Titulo 3 $TOTAL_ETAPAS "USO DE GPU"
try {
    $gpu = (Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop).CounterSamples | Where-Object { $_.CookedValue -gt 5 } | Sort-Object CookedValue -Descending | Select-Object -First 10
    if ($gpu) {
        foreach ($g in $gpu) { W ("{0} - {1}%" -f $g.InstanceName, [math]::Round($g.CookedValue,1)) "White" }
    } else {
        W "Nenhum processo usando GPU de forma relevante no momento." "Green"
    }
} catch {
    W "Nao foi possivel ler o uso de GPU nesta maquina." "DarkGray"
}

# ===================== ETAPA 4 - REDE =====================
Titulo 4 $TOTAL_ETAPAS "CONEXOES DE REDE EM PORTAS DE MINERACAO"
$portasMineracao = @(3333,4444,5555,7777,8080,9999,14444,45560,14433)
$conexoes = Get-NetTCPConnection -ErrorAction SilentlyContinue
$achouRede = $false
foreach ($c in $conexoes) {
    if ($portasMineracao -contains $c.RemotePort) {
        $achouRede = $true
        $procNome = (Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        W "Conexao suspeita: $procNome (PID $($c.OwningProcess)) -> $($c.RemoteAddress):$($c.RemotePort)" "Red" $true
    }
}
if (-not $achouRede) { W "Nenhuma conexao em portas tipicas de mineracao foi encontrada." "Green" }

# ===================== ETAPA 5 - INICIALIZACAO =====================
Titulo 5 $TOTAL_ETAPAS "ITENS DE INICIALIZACAO (STARTUP)"
$pastasStartup = @(
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
)
$shell = New-Object -ComObject WScript.Shell
$achouStartup = $false
$totalStartupItems = 0
foreach ($pasta in $pastasStartup) {
    if (Test-Path $pasta) {
        Get-ChildItem -Path $pasta -File -ErrorAction SilentlyContinue | ForEach-Object {
            $totalStartupItems++
            $alvo = $_.FullName
            $destino = $_.FullName
            if ($_.Extension -eq ".lnk") {
                try { $destino = $shell.CreateShortcut($_.FullName).TargetPath } catch {}
            }
            if ($_.Name -match '\.vbs$|\.js$|\.ps1$' -or $destino -match '\\Temp\\|\\AppData\\') {
                $achouStartup = $true
                W "Item suspeito na Inicializacao: $($_.Name) -> $destino" "Red" $true
                [void]$acoes.Add(@{ Tipo = "Arquivo"; Alvo = $alvo; Descricao = "Apagar item de inicializacao: $alvo" })
            } else {
                W "Item na Inicializacao: $($_.Name) -> $destino" "White"
            }
        }
    }
}
if (-not $achouStartup) { W "Nenhum item suspeito encontrado na pasta de Inicializacao." "Green" }
W "Total de itens na pasta de Inicializacao: $totalStartupItems" "White"
if ($totalStartupItems -gt 8) {
    W "Dica: muitos itens abrindo junto com o Windows deixam o boot mais lento. Voce pode desativar alguns em Configuracoes > Aplicativos > Inicializar." "DarkYellow"
}

# ===================== ETAPA 6 - REGISTRO =====================
Titulo 6 $TOTAL_ETAPAS "CHAVES DE REGISTRO (RUN / RUNONCE)"
$chavesRegistro = @(
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce",
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run",
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
)
$achouRegistro = $false
foreach ($chave in $chavesRegistro) {
    if (Test-Path $chave) {
        $props = Get-ItemProperty -Path $chave -ErrorAction SilentlyContinue
        if ($props) {
            $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                $valor = $_.Value
                if ($valor -match '\\Temp\\|\.vbs$|\.js$|\\AppData\\Roaming\\[^\\]+\\[^\\]+\.exe$') {
                    $achouRegistro = $true
                    W "Entrada suspeita no registro: $($_.Name) = $valor  ($chave)" "Red" $true
                    [void]$acoes.Add(@{ Tipo = "RegistroValor"; Alvo = @{ Path = $chave; Name = $_.Name }; Descricao = "Remover entrada de registro: $($_.Name) em $chave" })
                } else {
                    W "Entrada no registro: $($_.Name) = $valor  ($chave)" "White"
                }
            }
        }
    }
}
if (-not $achouRegistro) { W "Nenhuma entrada suspeita encontrada nas chaves Run/RunOnce." "Green" }

# ===================== ETAPA 7 - APPDATA/TEMP =====================
Titulo 7 $TOTAL_ETAPAS "PASTAS RECENTES NO APPDATA E TEMP (5 mais recentes de cada)"
$pastasVerificar = @("$env:APPDATA","$env:LOCALAPPDATA","$env:TEMP")
foreach ($pasta in $pastasVerificar) {
    if (Test-Path $pasta) {
        Get-ChildItem -Path $pasta -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 5 | ForEach-Object {
            $dias = [math]::Round(((Get-Date) - $_.LastWriteTime).TotalDays)
            if ($_.Name -match '^(xmrig|minerd|ccminer|cpuminer)') {
                W "$($_.FullName) (modificado ha $dias dia(s))" "Red" $true
                [void]$acoes.Add(@{ Tipo = "Pasta"; Alvo = $_.FullName; Descricao = "Revisar/apagar manualmente a pasta: $($_.FullName)" })
            } else {
                W "$($_.FullName) (modificado ha $dias dia(s))" "White"
            }
        }
    }
}

# ===================== ETAPA 8 - RAIZ DO C: =====================
Titulo 8 $TOTAL_ETAPAS "PASTAS NA RAIZ DO DISCO C (mais recentes primeiro)"
Get-ChildItem -Path "C:\" -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 15 | ForEach-Object {
    $dias = [math]::Round(((Get-Date) - $_.LastWriteTime).TotalDays)
    W "$($_.Name) (modificado ha $dias dia(s))" "White"
}
W "(Lista completa pode ser vista com o comando: dir C:\)" "DarkGray"

# ===================== ETAPA 9 - DRIVERS =====================
Titulo 9 $TOTAL_ETAPAS "ARQUIVOS DE DRIVER SUSPEITOS"
W "Busca limitada as pastas de usuario e temporarias, para nao travar o computador." "DarkGray"
$driversSuspeitos = @("WinRing0x64.sys","WinRing0.sys","Winlo64.sys")
$pastasBuscaDriver = @(
    "$env:USERPROFILE\Desktop",
    "$env:USERPROFILE\Downloads",
    "$env:USERPROFILE\Documents",
    "$env:APPDATA",
    "$env:LOCALAPPDATA",
    "$env:TEMP",
    "$env:PUBLIC",
    "C:\ProgramData"
)
$achouDriver = $false
foreach ($pasta in $pastasBuscaDriver) {
    if (Test-Path $pasta) {
        foreach ($d in $driversSuspeitos) {
            $achados = Get-ChildItem -Path $pasta -Filter $d -Recurse -Depth 6 -File -ErrorAction SilentlyContinue -Force
            foreach ($a in $achados) {
                $achouDriver = $true
                W "Driver suspeito encontrado: $($a.FullName)" "Red" $true
            }
        }
    }
}
if (-not $achouDriver) { W "Nenhum driver suspeito encontrado nas pastas verificadas." "Green" }

# ===================== ETAPA 10 - TAREFAS AGENDADAS =====================
Titulo 10 $TOTAL_ETAPAS "TAREFAS AGENDADAS SUSPEITAS"
$tarefas = Get-ScheduledTask -ErrorAction SilentlyContinue
$achouTarefa = $false
foreach ($t in $tarefas) {
    if ($t.TaskName -eq "ScannerAntiMineradorAuto") { continue }
    $acaoTexto = ($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join " "
    $suspeita = ($acaoTexto -match 'xmrig|miner|\\Sound\\') -or ($acaoTexto -match '\.vbs' -and $acaoTexto -match '\\Temp\\|\\AppData\\Roaming\\|system\.vbs|update\.vbs|audio\.vbs|mouse\.vbs|unistall\.vbs')
    if ($suspeita) {
        $achouTarefa = $true
        W "Tarefa suspeita: $($t.TaskName) -> $acaoTexto" "Red" $true
        [void]$acoes.Add(@{ Tipo = "Tarefa"; Alvo = @{ Nome = $t.TaskName; Path = $t.TaskPath }; Descricao = "Remover tarefa agendada: $($t.TaskName)" })
    }
}
if (-not $achouTarefa) { W "Nenhuma tarefa agendada suspeita encontrada." "Green" }

# ===================== ETAPA 11 - DEFENDER =====================
Titulo 11 $TOTAL_ETAPAS "STATUS DO WINDOWS DEFENDER"
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    W "Protecao em tempo real: $($mp.RealTimeProtectionEnabled)" "White"
    W "Ultima verificacao rapida: $($mp.QuickScanEndTime)" "White"
    W "Assinaturas de virus atualizadas em: $($mp.AntivirusSignatureLastUpdated)" "White"
} catch {
    W "Nao foi possivel ler o status do Windows Defender." "DarkGray"
}

# ===================== ETAPA 12 - EXCLUSOES DO DEFENDER =====================
Titulo 12 $TOTAL_ETAPAS "EXCLUSOES DO WINDOWS DEFENDER"
if (-not $isAdmin) {
    W "Rode como Administrador para verificar as exclusoes do Windows Defender." "DarkGray"
} else {
    try {
        $mpPrefs = Get-MpPreference -ErrorAction Stop
        $exclusoesDefender = New-Object System.Collections.ArrayList
        if ($mpPrefs.ExclusionPath) { foreach ($e in $mpPrefs.ExclusionPath) { if ($e -and $e -notmatch 'administrator|^N/A') { [void]$exclusoesDefender.Add(@{ Tipo = "Caminho"; Valor = $e }) } } }
        if ($mpPrefs.ExclusionProcess) { foreach ($e in $mpPrefs.ExclusionProcess) { if ($e -and $e -notmatch 'administrator|^N/A') { [void]$exclusoesDefender.Add(@{ Tipo = "Processo"; Valor = $e }) } } }
        if ($mpPrefs.ExclusionExtension) { foreach ($e in $mpPrefs.ExclusionExtension) { if ($e -and $e -notmatch 'administrator|^N/A') { [void]$exclusoesDefender.Add(@{ Tipo = "Extensao"; Valor = $e }) } } }
        if ($exclusoesDefender.Count -gt 0) {
            foreach ($ex in $exclusoesDefender) {
                W "Exclusao no Defender ($($ex.Tipo)): $($ex.Valor)" "Red" $true
                [void]$acoes.Add(@{ Tipo = "DefenderExclusao"; Alvo = @{ TipoExclusao = $ex.Tipo; Valor = $ex.Valor }; Descricao = "Remover exclusao do Defender ($($ex.Tipo)): $($ex.Valor)" })
            }
            W "IMPORTANTE: malware as vezes se adiciona nas exclusoes do Defender para nao ser detectado. Revise se voce reconhece cada item acima." "DarkYellow"
        } else {
            W "Nenhuma exclusao configurada no Windows Defender." "Green"
        }
    } catch {
        W "Nao foi possivel ler as exclusoes do Windows Defender." "DarkGray"
    }

    # Exclusoes/politicas FORCADAS via Group Policy no registro (nao removidas por Remove-MpPreference)
    $chavesPoliticaExclusao = @(
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Exclusions\Paths"; Rotulo = "Caminho (POLITICA)" },
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Exclusions\Processes"; Rotulo = "Processo (POLITICA)" },
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Exclusions\Extensions"; Rotulo = "Extensao (POLITICA)" }
    )
    $achouPolitica = $false
    foreach ($cp in $chavesPoliticaExclusao) {
        if (Test-Path $cp.Path) {
            $propsPol = Get-ItemProperty -Path $cp.Path -ErrorAction SilentlyContinue
            if ($propsPol) {
                $propsPol.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                    $achouPolitica = $true
                    W "Exclusao FORCADA POR POLITICA DE GRUPO no Defender - $($cp.Rotulo): $($_.Name)" "Red" $true
                    [void]$acoes.Add(@{ Tipo = "DefenderPolicyValor"; Alvo = @{ Path = $cp.Path; Name = $_.Name }; Descricao = "Remover exclusao FORCADA POR POLITICA do Defender ($($cp.Rotulo)): $($_.Name)" })
                }
            }
        }
    }
    if ($achouPolitica) {
        W "IMPORTANTE: estas exclusoes sao aplicadas via Politica de Grupo/registro e voltam sozinhas apos reiniciar se apenas removidas pelo metodo normal. Remova aqui para apagar a politica de verdade." "DarkYellow"
    }

    $defenderPolicyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
    if (Test-Path $defenderPolicyKey) {
        $pol = Get-ItemProperty -Path $defenderPolicyKey -ErrorAction SilentlyContinue
        if ($pol -and $pol.DisableAntiSpyware -eq 1) {
            W "ALERTA CRITICO: Politica de grupo esta CONFIGURADA PARA DESATIVAR o Windows Defender por completo (DisableAntiSpyware=1)!" "Red" $true
            [void]$acoes.Add(@{ Tipo = "DefenderPolicyValor"; Alvo = @{ Path = $defenderPolicyKey; Name = "DisableAntiSpyware" }; Descricao = "Remover politica que desativa o Windows Defender por completo" })
        }
    }
    $rtpPolicyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection"
    if (Test-Path $rtpPolicyKey) {
        $rtp = Get-ItemProperty -Path $rtpPolicyKey -ErrorAction SilentlyContinue
        if ($rtp -and $rtp.DisableRealtimeMonitoring -eq 1) {
            W "ALERTA CRITICO: Politica de grupo esta DESATIVANDO a protecao em tempo real do Defender!" "Red" $true
            [void]$acoes.Add(@{ Tipo = "DefenderPolicyValor"; Alvo = @{ Path = $rtpPolicyKey; Name = "DisableRealtimeMonitoring" }; Descricao = "Remover politica que desativa a protecao em tempo real do Defender" })
        }
    }
}

# ===================== ETAPA 13 - HOSTS E WMI =====================
Titulo 13 $TOTAL_ETAPAS "ARQUIVO HOSTS E PERSISTENCIA VIA WMI"
$hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$achouHosts = $false
if (Test-Path $hostsPath) {
    $linhasHosts = Get-Content $hostsPath -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -ne "" -and $_.Trim() -notmatch '^#' }
    foreach ($linha in $linhasHosts) {
        if ($linha -notmatch '^\s*(127\.0\.0\.1|::1)\s+localhost') {
            $achouHosts = $true
            W "Linha suspeita no arquivo hosts: $($linha.Trim())" "Red" $true
        }
    }
}
if (-not $achouHosts) {
    W "Nenhuma linha suspeita encontrada no arquivo hosts." "Green"
} else {
    [void]$acoes.Add(@{ Tipo = "HostsRestaurar"; Alvo = $hostsPath; Descricao = "Restaurar arquivo hosts (remove todas as linhas suspeitas encontradas acima)" })
}

$achouWmi = $false
try {
    $filtrosWmi = @(Get-WmiObject -Namespace root\subscription -Class __EventFilter -ErrorAction SilentlyContinue)
    $consumidoresWmi = @(Get-WmiObject -Namespace root\subscription -Class __EventConsumer -ErrorAction SilentlyContinue)
    if ($filtrosWmi.Count -gt 0 -or $consumidoresWmi.Count -gt 0) {
        $achouWmi = $true
        W "Persistencia via WMI detectada: $($filtrosWmi.Count) filtro(s) de evento, $($consumidoresWmi.Count) consumidor(es) de evento." "Red" $true
        W "Esta e uma tecnica avancada usada por alguns malwares para rodar automaticamente. Poucos programas legitimos usam isso." "DarkYellow"
        [void]$acoes.Add(@{ Tipo = "WmiPersistencia"; Alvo = $null; Descricao = "Remover persistencia via WMI (todos os filtros/consumidores/vinculos encontrados)" })
    }
} catch {}
if (-not $achouWmi) { W "Nenhuma persistencia via WMI (Event Filter/Consumer) encontrada." "Green" }

# ===================== ETAPA 14 - COMANDOS SUSPEITOS =====================
Titulo 14 $TOTAL_ETAPAS "COMANDOS SUSPEITOS EM EXECUCAO (POWERSHELL/CSCRIPT)"
$achouComando = $false
try {
    $procsComando = Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $_.Name -match 'powershell|pwsh|cscript|wscript' -and
        $_.CommandLine -match '-enc|-EncodedCommand|DownloadString|IEX |Invoke-Expression|FromBase64String'
    }
    foreach ($p in $procsComando) {
        $achouComando = $true
        W "Processo com comando ofuscado/suspeito: $($p.Name) (PID $($p.ProcessId)) -> $($p.CommandLine)" "Red" $true
    }
} catch {
    W "Nao foi possivel verificar linhas de comando dos processos (pode precisar de administrador)." "DarkGray"
}
if (-not $achouComando) { W "Nenhum comando ofuscado ou suspeito encontrado em processos ativos." "Green" }

# ===================== ETAPA 15 - WINDOWS UPDATE =====================
Titulo 15 $TOTAL_ETAPAS "ATUALIZACOES DO WINDOWS PENDENTES"
W "Isso pode demorar um pouco..." "DarkGray"
try {
    $updateSession = New-Object -ComObject Microsoft.Update.Session
    $updateSearcher = $updateSession.CreateUpdateSearcher()
    $resultadoUpdate = $updateSearcher.Search("IsInstalled=0 and IsHidden=0")
    if ($resultadoUpdate.Updates.Count -gt 0) {
        W "Ha $($resultadoUpdate.Updates.Count) atualizacao(oes) do Windows pendente(s). Atualizacoes pendentes podem deixar o PC lento e vulneravel." "DarkYellow"
    } else {
        W "Nenhuma atualizacao do Windows pendente. Sistema em dia." "Green"
    }
} catch {
    W "Nao foi possivel verificar atualizacoes do Windows nesta maquina." "DarkGray"
}

# ===================== ETAPA 16 - SERVICOS DO WINDOWS =====================
Titulo 16 $TOTAL_ETAPAS "SERVICOS DO WINDOWS COM CAMINHO SUSPEITO"
$achouServico = $false
try {
    $servicosSuspeitos = Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object {
        $_.PathName -and $_.PathName -match '\\Temp\\|\\AppData\\Roaming\\|\\AppData\\Local\\Temp\\'
    }
    foreach ($s in $servicosSuspeitos) {
        $achouServico = $true
        W "Servico suspeito: $($s.Name) ($($s.DisplayName)) -> $($s.PathName)  [Estado: $($s.State), Inicio: $($s.StartMode)]" "Red" $true
        [void]$acoes.Add(@{ Tipo = "Servico"; Alvo = $s.Name; Descricao = "Parar e desabilitar servico suspeito: $($s.Name) ($($s.DisplayName))" })
    }
} catch {
    W "Nao foi possivel listar os servicos do Windows." "DarkGray"
}
if (-not $achouServico) { W "Nenhum servico com caminho de executavel suspeito (Temp/AppData) encontrado." "Green" }

# ===================== ETAPA 17 - IFEO / APPINIT_DLLS / WINLOGON =====================
Titulo 17 $TOTAL_ETAPAS "HIJACK DE IFEO / APPINIT_DLLS / WINLOGON"
$achouHijack = $false
try {
    $ifeoBase = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options"
    if (Test-Path $ifeoBase) {
        Get-ChildItem -Path $ifeoBase -ErrorAction SilentlyContinue | ForEach-Object {
            $deb = Get-ItemProperty -Path $_.PSPath -Name "Debugger" -ErrorAction SilentlyContinue
            if ($deb -and $deb.Debugger) {
                $achouHijack = $true
                W "Hijack IFEO: '$($_.PSChildName)' e sequestrado para abrir '$($deb.Debugger)' no lugar" "Red" $true
                [void]$acoes.Add(@{ Tipo = "IfeoDebugger"; Alvo = $_.PSPath; Descricao = "Remover hijack de IFEO em '$($_.PSChildName)' (Debugger = $($deb.Debugger))" })
            }
        }
    }
} catch {}
try {
    $winKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows"
    $winProps = Get-ItemProperty -Path $winKey -ErrorAction SilentlyContinue
    if ($winProps -and $winProps.AppInit_DLLs -and $winProps.AppInit_DLLs.Trim() -ne "") {
        $achouHijack = $true
        W "AppInit_DLLs configurado (injeta DLL em todo processo que usa User32.dll): $($winProps.AppInit_DLLs)" "Red" $true
        [void]$acoes.Add(@{ Tipo = "AppInitDlls"; Alvo = $winKey; Descricao = "Limpar AppInit_DLLs (valor atual: $($winProps.AppInit_DLLs))" })
    }
} catch {}
try {
    $winlogonKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    $wl = Get-ItemProperty -Path $winlogonKey -ErrorAction SilentlyContinue
    if ($wl) {
        if ($wl.Shell -and $wl.Shell -ne "explorer.exe") {
            $achouHijack = $true
            W "Winlogon Shell alterado (deveria ser 'explorer.exe'): $($wl.Shell)" "Red" $true
        }
        if ($wl.Userinit -and $wl.Userinit -ne "C:\Windows\system32\userinit.exe,") {
            $achouHijack = $true
            W "Winlogon Userinit alterado (deveria ser 'C:\Windows\system32\userinit.exe,'): $($wl.Userinit)" "Red" $true
        }
    }
} catch {}
if (-not $achouHijack) { W "Nenhum hijack de IFEO, AppInit_DLLs ou Winlogon encontrado." "Green" }
W "(Alteracoes no Winlogon Shell/Userinit nao sao removidas automaticamente por seguranca - avise se aparecer algo aqui.)" "DarkGray"

# ===================== ETAPA 18 - CONTAS DE USUARIO =====================
Titulo 18 $TOTAL_ETAPAS "CONTAS DE USUARIO OCULTAS OU FORA DO PADRAO"
$achouConta = $false
try {
    $contasConhecidas = @("Administrator","Administrador","Guest","Convidado","DefaultAccount","WDAGUtilityAccount",$env:USERNAME)
    Get-LocalUser -ErrorAction Stop | Where-Object { $_.Enabled -eq $true -and ($contasConhecidas -notcontains $_.Name) } | ForEach-Object {
        $achouConta = $true
        W "Conta de usuario habilitada fora do padrao: $($_.Name)" "Red" $true
    }
} catch {
    W "Nao foi possivel listar contas de usuario locais." "DarkGray"
}
try {
    $userListKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList"
    if (Test-Path $userListKey) {
        $propsUL = Get-ItemProperty -Path $userListKey -ErrorAction SilentlyContinue
        if ($propsUL) {
            $propsUL.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' -and $_.Value -eq 0 } | ForEach-Object {
                $achouConta = $true
                W "Conta OCULTA na tela de login: $($_.Name) (nao aparece para o usuario ao ligar o PC)" "Red" $true
            }
        }
    }
} catch {}
if (-not $achouConta) { W "Nenhuma conta fora do padrao ou oculta na tela de login foi encontrada." "Green" }
W "(Contas nao sao removidas automaticamente. Revise em Configuracoes > Contas se aparecer algo suspeito.)" "DarkGray"

# ===================== ETAPA 19 - CERTIFICADOS RAIZ =====================
Titulo 19 $TOTAL_ETAPAS "CERTIFICADOS RAIZ SUSPEITOS"
$achouCert = $false
try {
    Get-ChildItem -Path "Cert:\LocalMachine\Root" -ErrorAction Stop | Where-Object {
        $_.Subject -eq $_.Issuer -and $_.NotBefore -gt (Get-Date).AddDays(-365)
    } | ForEach-Object {
        $achouCert = $true
        W "Certificado raiz autoassinado instalado recentemente: $($_.Subject) (instalado em: $($_.NotBefore.ToString('dd/MM/yyyy')))" "Red" $true
    }
} catch {
    W "Nao foi possivel verificar os certificados raiz instalados." "DarkGray"
}
if (-not $achouCert) { W "Nenhum certificado raiz autoassinado recente encontrado." "Green" }
W "Certificados raiz falsos podem ser usados para interceptar seu trafego HTTPS (inclusive para esconder mineracao/roubo de dados). Nao sao removidos automaticamente." "DarkGray"

# ===================== ETAPA 20 - FIREWALL =====================
Titulo 20 $TOTAL_ETAPAS "REGRAS DE FIREWALL SUSPEITAS"
$achouFirewall = $false
if (-not $isAdmin) {
    W "Rode como Administrador para verificar regras de firewall." "DarkGray"
} else {
    try {
        $regrasFirewall = Get-NetFirewallRule -Enabled True -Direction Inbound -Action Allow -ErrorAction Stop
        foreach ($r in $regrasFirewall) {
            try {
                $appFilter = Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $r -ErrorAction SilentlyContinue
                if ($appFilter -and $appFilter.Program -and $appFilter.Program -match '\\Temp\\|\\AppData\\Roaming\\[^\\]+\\[^\\]+\.exe$') {
                    $achouFirewall = $true
                    $infoAssinaturaFw = AssinaturaInfo $appFilter.Program
                    if (-not $infoAssinaturaFw.Existe) {
                        W "Regra de firewall ORFA (o programa ja foi apagado - resto de instalador antigo, seguro limpar): '$($r.DisplayName)' -> '$($appFilter.Program)'" "DarkYellow" $true "Baixa"
                    } elseif ($infoAssinaturaFw.Assinado) {
                        W "Regra de firewall para programa ASSINADO digitalmente (baixo risco): '$($r.DisplayName)' -> '$($appFilter.Program)' [Editora: $($infoAssinaturaFw.Editora)]" "DarkYellow" $true "Baixa"
                    } else {
                        W "Regra de firewall suspeita (programa NAO assinado digitalmente): '$($r.DisplayName)' libera entrada para '$($appFilter.Program)'" "Red" $true
                    }
                    [void]$acoes.Add(@{ Tipo = "FirewallRegra"; Alvo = $r.Name; Descricao = "Remover regra de firewall: $($r.DisplayName) ($($appFilter.Program))" })
                }
            } catch {}
        }
    } catch {
        W "Nao foi possivel verificar as regras de firewall." "DarkGray"
    }
    if (-not $achouFirewall) { W "Nenhuma regra de firewall suspeita (liberando programa em Temp/AppData) foi encontrada." "Green" }
    if ($achouFirewall) {
        W "Isso e comum em instaladores/atualizadores legitimos que rodam de pastas temporarias (ex: apps baseados em Electron, como Hydra, Discord, VS Code). So se preocupe se nao reconhecer o nome do programa." "DarkGray"
    }
}

# ===================== ETAPA 21 - EXTENSOES DE NAVEGADOR =====================
Titulo 21 $TOTAL_ETAPAS "EXTENSOES INSTALADAS NO NAVEGADOR"
$pastasExtensoes = @(
    @{ Nome = "Chrome"; Base = "$env:LOCALAPPDATA\Google\Chrome\User Data" },
    @{ Nome = "Edge"; Base = "$env:LOCALAPPDATA\Microsoft\Edge\User Data" }
)
$achouExtensaoAltoRisco = $false
$totalExtensoes = 0
$extensoesConhecidasSeguras = @{
    "gighmmpiobklfepjocnamgkkbiglidom" = "AdBlock (bloqueador de anuncios)"
    "fheoggkfdfchfphceeifdbepaooicaho" = "McAfee WebAdvisor (antivirus)"
}
foreach ($nav in $pastasExtensoes) {
    if (Test-Path $nav.Base) {
        Get-ChildItem -Path $nav.Base -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "Default" -or $_.Name -like "Profile*" } | ForEach-Object {
            $extBase = Join-Path $_.FullName "Extensions"
            if (Test-Path $extBase) {
                Get-ChildItem -Path $extBase -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                    $idExt = $_.Name
                    Get-ChildItem -Path $_.FullName -Directory -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object {
                        $manifestPath = Join-Path $_.FullName "manifest.json"
                        if (Test-Path $manifestPath) {
                            $totalExtensoes++
                            try {
                                $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
                                $nomeExt = $manifest.name
                                if ($nomeExt -match '^__MSG_') { $nomeExt = $idExt }
                                $perms = @()
                                if ($manifest.permissions) { $perms += $manifest.permissions }
                                if ($manifest.host_permissions) { $perms += $manifest.host_permissions }
                                $permsTexto = ($perms -join ", ")
                                $temAcessoTotal = ($permsTexto -match '<all_urls>') -or ($permsTexto -match 'http://\*/\*' -and $permsTexto -match 'https://\*/\*')
                                $altoRisco = ($permsTexto -match 'proxy') -or ($temAcessoTotal -and $permsTexto -match 'webRequest')
                                if ($altoRisco -and $extensoesConhecidasSeguras.ContainsKey($idExt)) {
                                    W "[$($nav.Nome)] Extensao com permissoes amplas, mas reconhecida como segura: $($extensoesConhecidasSeguras[$idExt]) ($idExt) -> $permsTexto" "DarkYellow" $true "Baixa"
                                } elseif ($altoRisco) {
                                    $achouExtensaoAltoRisco = $true
                                    W "[$($nav.Nome)] Extensao com permissoes de alto risco: $nomeExt ($idExt) -> $permsTexto" "Red" $true
                                } else {
                                    W "[$($nav.Nome)] Extensao instalada: $nomeExt ($idExt)" "White"
                                }
                            } catch {
                                W "[$($nav.Nome)] Extensao instalada: $idExt (nao foi possivel ler o manifest)" "White"
                            }
                        }
                    }
                }
            }
        }
    }
}
if ($totalExtensoes -eq 0) {
    W "Nenhuma extensao encontrada (ou Chrome/Edge nao instalados/fechados)." "DarkGray"
} elseif (-not $achouExtensaoAltoRisco) {
    W "Nenhuma extensao com permissoes de alto risco encontrada entre as $totalExtensoes extensao(oes) listada(s) acima." "Green"
} else {
    W "IMPORTANTE: revise as extensoes marcadas acima. Permissao 'proxy' e a mais perigosa (redireciona TODO o seu trafego de internet). Acesso total a sites + interceptacao de requisicoes tambem merece atencao, mas pode ser legitimo (bloqueadores de anuncios, gerenciadores de senha, extensoes de produtividade). Remova manualmente pelo navegador se nao reconhecer." "DarkYellow"
}

# ===================== ETAPA 22 - DNS E PROXY =====================
Titulo 22 $TOTAL_ETAPAS "DNS E PROXY DO SISTEMA/NAVEGADOR"
$achouProxyDns = $false
try {
    $proxyKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    $proxyProps = Get-ItemProperty -Path $proxyKey -ErrorAction SilentlyContinue
    if ($proxyProps) {
        if ($proxyProps.ProxyEnable -eq 1 -and $proxyProps.ProxyServer) {
            $achouProxyDns = $true
            W "Proxy manual ATIVADO no Windows: $($proxyProps.ProxyServer)" "Red" $true
            [void]$acoes.Add(@{ Tipo = "ProxyManual"; Alvo = $proxyKey; Descricao = "Desativar proxy manual do Windows ($($proxyProps.ProxyServer))" })
        }
        if ($proxyProps.AutoConfigURL) {
            $achouProxyDns = $true
            W "Script de configuracao automatica de proxy (PAC) configurado: $($proxyProps.AutoConfigURL)" "Red" $true
            [void]$acoes.Add(@{ Tipo = "ProxyAutoConfig"; Alvo = $proxyKey; Descricao = "Remover script de proxy automatico (PAC): $($proxyProps.AutoConfigURL)" })
        }
    }
} catch {}
if (-not $achouProxyDns) { W "Nenhum proxy manual ou script de proxy automatico configurado no Windows." "Green" }
try {
    Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.ServerAddresses.Count -gt 0 } | ForEach-Object {
        W "Adaptador '$($_.InterfaceAlias)' usando DNS: $($_.ServerAddresses -join ', ')" "White"
    }
    W "Revise se os DNS acima sao os do seu roteador/provedor ou servicos conhecidos (8.8.8.8, 1.1.1.1). DNS desconhecido pode redirecionar sites." "DarkGray"
} catch {
    W "Nao foi possivel verificar os servidores DNS configurados." "DarkGray"
}

# ===================== ETAPA 23 - PROGRAMAS INSTALADOS RECENTEMENTE =====================
Titulo 23 $TOTAL_ETAPAS "PROGRAMAS INSTALADOS RECENTEMENTE (TOP 15)"
try {
    $chavesDesinstalar = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $programas = Get-ItemProperty -Path $chavesDesinstalar -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.InstallDate } |
        Sort-Object InstallDate -Descending |
        Select-Object -First 15 DisplayName, InstallDate -Unique
    if ($programas) {
        foreach ($prog in $programas) {
            $dataFormatada = $prog.InstallDate
            if ($dataFormatada -match '^\d{8}$') {
                try { $dataFormatada = [datetime]::ParseExact($prog.InstallDate, "yyyyMMdd", $null).ToString("dd/MM/yyyy") } catch {}
            }
            W "$($prog.DisplayName) - instalado em $dataFormatada" "White"
        }
    } else {
        W "Nao foi possivel obter datas de instalacao dos programas." "DarkGray"
    }
} catch {
    W "Nao foi possivel listar os programas instalados." "DarkGray"
}
W "Revise se reconhece todos os programas instalados recentemente." "DarkGray"

# ===================== ETAPA 24 - ATALHOS DE NAVEGADOR =====================
Titulo 24 $TOTAL_ETAPAS "ATALHOS DO NAVEGADOR (SEQUESTRO DE ARGUMENTOS)"
$achouAtalho = $false
$navegadoresExe = @("chrome.exe","msedge.exe","firefox.exe","iexplore.exe")
$pastasAtalhos = @(
    "$env:USERPROFILE\Desktop",
    "$env:PUBLIC\Desktop",
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
    "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
)
$shellAtalho = New-Object -ComObject WScript.Shell
foreach ($pastaAtalho in $pastasAtalhos) {
    if (Test-Path $pastaAtalho) {
        Get-ChildItem -Path $pastaAtalho -Filter "*.lnk" -Recurse -Depth 2 -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $lnk = $shellAtalho.CreateShortcut($_.FullName)
                $alvoExe = [System.IO.Path]::GetFileName($lnk.TargetPath)
                if ($navegadoresExe -contains $alvoExe) {
                    $argsAtalho = $lnk.Arguments
                    if ($argsAtalho -and $argsAtalho -match 'http://|https://|--load-extension=|--proxy-server=|\.dll') {
                        $achouAtalho = $true
                        W "Atalho de navegador com argumentos suspeitos: $($_.FullName) -> $alvoExe $argsAtalho" "Red" $true
                        [void]$acoes.Add(@{ Tipo = "AtalhoLimpar"; Alvo = @{ Path = $_.FullName }; Descricao = "Limpar argumentos suspeitos do atalho: $($_.Name)" })
                    }
                }
            } catch {}
        }
    }
}
if (-not $achouAtalho) { W "Nenhum atalho de navegador com argumentos suspeitos encontrado." "Green" }

# ===================== ETAPA 25 - HOMEPAGE E MOTOR DE BUSCA =====================
Titulo 25 $TOTAL_ETAPAS "PAGINA INICIAL E MOTOR DE BUSCA DO NAVEGADOR"
$dominiosConhecidos = @("google.com","bing.com","duckduckgo.com","yahoo.com","ecosia.org","yandex.com")
$achouHomepage = $false
$pastasNavegadoresPref = @(
    @{ Nome = "Chrome"; Base = "$env:LOCALAPPDATA\Google\Chrome\User Data" },
    @{ Nome = "Edge"; Base = "$env:LOCALAPPDATA\Microsoft\Edge\User Data" }
)
foreach ($nav in $pastasNavegadoresPref) {
    if (Test-Path $nav.Base) {
        Get-ChildItem -Path $nav.Base -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "Default" -or $_.Name -like "Profile*" } | ForEach-Object {
            $prefPath = Join-Path $_.FullName "Preferences"
            if (Test-Path $prefPath) {
                try {
                    $pref = Get-Content -LiteralPath $prefPath -Raw -ErrorAction Stop | ConvertFrom-Json
                    $homepage = $pref.homepage
                    if ($homepage -and $homepage -match '^https?://' -and $homepage -notmatch ($dominiosConhecidos -join '|')) {
                        $achouHomepage = $true
                        W "[$($nav.Nome)] Pagina inicial configurada para dominio incomum: $homepage" "Red" $true
                    }
                    $urlsInicio = $pref.session.startup_urls
                    if ($urlsInicio) {
                        foreach ($u in $urlsInicio) {
                            if ($u -notmatch ($dominiosConhecidos -join '|')) {
                                $achouHomepage = $true
                                W "[$($nav.Nome)] URL de inicio configurada para dominio incomum: $u" "Red" $true
                            }
                        }
                    }
                    $searchUrl = $pref.default_search_provider_data.template_url_data.url
                    if ($searchUrl -and $searchUrl -notmatch ($dominiosConhecidos -join '|')) {
                        $achouHomepage = $true
                        W "[$($nav.Nome)] Motor de busca padrao aponta para dominio incomum: $searchUrl" "Red" $true
                    }
                } catch {}
            }
        }
    }
}
if (-not $achouHomepage) { W "Nenhuma pagina inicial ou motor de busca incomum encontrado (Chrome/Edge)." "Green" }
W "(Nao removido automaticamente - revise manualmente pelas configuracoes do navegador se algo suspeito aparecer aqui.)" "DarkGray"

# ===================== ETAPA 26 - ARQUIVOS OCULTOS COM ATRIBUTO DE SISTEMA =====================
Titulo 26 $TOTAL_ETAPAS "ARQUIVOS EXECUTAVEIS OCULTOS COM ATRIBUTO DE SISTEMA (TECNICA DE OCULTACAO)"
W "Nota: o Windows marca MUITAS pastas normais (Minhas Imagens, cofre de credenciais, cache do IE, etc.) como oculto+sistema - isso e normal. Por isso so verificamos ARQUIVOS EXECUTAVEIS com essa combinacao, que e realmente incomum." "DarkGray"
$achouOculto = $false
$extensoesExecutaveisOcultos = @(".exe",".dll",".scr",".com",".bat",".cmd",".ps1",".vbs",".js")
$pastasOcultarBusca = @(
    "$env:USERPROFILE\Desktop",
    "$env:USERPROFILE\Downloads",
    "$env:USERPROFILE\Documents",
    "$env:APPDATA",
    "$env:LOCALAPPDATA",
    "$env:TEMP",
    "$env:PUBLIC"
)
foreach ($pastaOculta in $pastasOcultarBusca) {
    if (Test-Path $pastaOculta) {
        Get-ChildItem -Path $pastaOculta -Recurse -Depth 3 -Force -File -ErrorAction SilentlyContinue |
            Where-Object {
                ($_.Attributes -band [System.IO.FileAttributes]::Hidden) -and
                ($_.Attributes -band [System.IO.FileAttributes]::System) -and
                ($extensoesExecutaveisOcultos -contains $_.Extension.ToLower())
            } | ForEach-Object {
                $achouOculto = $true
                W "Arquivo executavel OCULTO com atributo de SISTEMA (tecnica de ocultacao usada por malware): $($_.FullName)" "Red" $true
            }
    }
}
if (-not $achouOculto) { W "Nenhum arquivo executavel oculto com atributo de sistema foi encontrado." "Green" }
W "(Nao removido automaticamente - revise manualmente cada caminho marcado acima.)" "DarkGray"

# ===================== ETAPA 27 - VARIAVEIS DE AMBIENTE PATH =====================
Titulo 27 $TOTAL_ETAPAS "VARIAVEIS DE AMBIENTE PATH SUSPEITAS"
$achouPath = $false
$pathsParaChecar = @(
    @{ Nome = "PATH do Sistema"; Valor = [Environment]::GetEnvironmentVariable("Path","Machine") },
    @{ Nome = "PATH do Usuario"; Valor = [Environment]::GetEnvironmentVariable("Path","User") }
)
foreach ($pv in $pathsParaChecar) {
    if ($pv.Valor) {
        $partes = $pv.Valor -split ";" | Where-Object { $_ -and $_.Trim() -ne "" }
        foreach ($parte in $partes) {
            if ($parte -match '\\Temp\\?$|\\AppData\\Roaming\\?$|\\AppData\\Local\\Temp\\?$|\\Desktop\\?$|\\Downloads\\?$') {
                $achouPath = $true
                W "$($pv.Nome) contem uma pasta gravavel/temporaria: $parte" "Red" $true
            }
        }
    }
}
if (-not $achouPath) { W "Nenhuma pasta gravavel ou temporaria suspeita encontrada nas variaveis PATH." "Green" }
W "(Isso pode ser usado para fazer o Windows executar um programa malicioso no lugar de um legitimo com o mesmo nome. Nao removido automaticamente - revise em Configuracoes > Variaveis de Ambiente.)" "DarkGray"

# ===================== ETAPA 28 - PAYLOAD BINARIO NO REGISTRO =====================
Titulo 28 $TOTAL_ETAPAS "PAYLOAD BINARIO ESCONDIDO NO REGISTRO (TECNICA FILELESS)"
$achouPayloadRegistro = $false
if (-not $isAdmin) {
    W "Rode como Administrador para verificar valores binarios em HKLM:\SOFTWARE." "DarkGray"
} else {
    $chavesPayload = @("HKLM:\SOFTWARE","HKCU:\SOFTWARE")
    foreach ($chaveP in $chavesPayload) {
        if (Test-Path $chaveP) {
            try {
                $itemP = Get-Item -Path $chaveP -ErrorAction Stop
                foreach ($nomeValor in $itemP.GetValueNames()) {
                    try {
                        $tipoValor = $itemP.GetValueKind($nomeValor)
                        if ($tipoValor -eq "Binary") {
                            $bytesValor = $itemP.GetValue($nomeValor)
                            if ($bytesValor -and $bytesValor.Length -gt 51200) {
                                $achouPayloadRegistro = $true
                                W "Valor binario suspeito diretamente em $chaveP : '$nomeValor' com $([math]::Round($bytesValor.Length/1KB,1)) KB. Malware fileless as vezes guarda o executavel inteiro dentro do registro para nao deixar arquivo no disco." "Red" $true
                                [void]$acoes.Add(@{ Tipo = "RegistroPayload"; Alvo = @{ Path = $chaveP; Name = $nomeValor }; Descricao = "Remover payload binario suspeito do registro: '$nomeValor' em $chaveP ($([math]::Round($bytesValor.Length/1KB,1)) KB)" })
                            }
                        }
                    } catch {}
                }
            } catch {}
        }
    }
    if (-not $achouPayloadRegistro) { W "Nenhum valor binario grande e suspeito encontrado diretamente em HKLM/HKCU\SOFTWARE." "Green" }
}

# ===================== ETAPA 29 - SERVICOS EM CONTROLSETS ANTIGOS =====================
Titulo 29 $TOTAL_ETAPAS "SERVICOS OCULTOS EM CONTROLSETS ANTIGOS DO REGISTRO"
$achouServicoRegistro = $false
if (-not $isAdmin) {
    W "Rode como Administrador para verificar servicos em todos os ControlSets." "DarkGray"
} else {
    $controlSets = @("ControlSet001","ControlSet002","CurrentControlSet")
    foreach ($cs in $controlSets) {
        $servicesKey = "HKLM:\SYSTEM\$cs\Services"
        if (Test-Path $servicesKey) {
            Get-ChildItem -Path $servicesKey -ErrorAction SilentlyContinue | ForEach-Object {
                $nomeServicoReg = $_.PSChildName
                $propsServ = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
                if ($propsServ) {
                    $imgPath = $propsServ.ImagePath
                    $suspeitoNome = ($nomeServicoReg -match '^\$')
                    $suspeitoImagem = ($imgPath -and $imgPath -match 'cmd\.exe /c|powershell(\.exe)? -enc|powershell(\.exe)? -EncodedCommand|\\Temp\\|\\AppData\\Roaming\\')
                    if ($suspeitoNome -or $suspeitoImagem) {
                        $achouServicoRegistro = $true
                        W "Servico suspeito no registro ($cs): '$nomeServicoReg' -> ImagePath: $imgPath" "Red" $true
                        if ($cs -ne "CurrentControlSet") {
                            [void]$acoes.Add(@{ Tipo = "ServicoRegistro"; Alvo = @{ Path = $_.PSPath; Nome = $nomeServicoReg }; Descricao = "Remover copia oculta do servico suspeito no registro: '$nomeServicoReg' ($cs)" })
                        }
                    }
                }
            }
        }
    }
    if ($achouServicoRegistro) {
        W "Se o servico suspeito tambem aparecer no CurrentControlSet, use a opcao de remover Servico na ETAPA 16 acima (para parar e desabilitar corretamente)." "DarkYellow"
    } else {
        W "Nenhum servico com nome ou ImagePath suspeito encontrado em nenhum ControlSet." "Green"
    }
}

# ===================== ETAPA 30 - EXECUTAVEIS SOLTOS EM PROGRAMDATA =====================
Titulo 30 $TOTAL_ETAPAS "EXECUTAVEIS SOLTOS EM C:\PROGRAMDATA"
$achouExeProgramData = $false
if (Test-Path "C:\ProgramData") {
    Get-ChildItem -Path "C:\ProgramData" -Filter "*.exe" -File -ErrorAction SilentlyContinue | ForEach-Object {
        $achouExeProgramData = $true
        $infoAssinaturaPd = AssinaturaInfo $_.FullName
        if ($infoAssinaturaPd.Assinado) {
            W "Executavel solto em C:\ProgramData, mas ASSINADO digitalmente (baixo risco): $($_.FullName) [Editora: $($infoAssinaturaPd.Editora)]" "DarkYellow" $true "Baixa"
        } else {
            W "Executavel solto direto em C:\ProgramData e NAO assinado digitalmente (local incomum para programas legitimos): $($_.FullName)" "Red" $true
        }
        [void]$acoes.Add(@{ Tipo = "Arquivo"; Alvo = $_.FullName; Descricao = "Apagar executavel suspeito: $($_.FullName)" })
    }
}
if (-not $achouExeProgramData) { W "Nenhum executavel solto encontrado diretamente em C:\ProgramData." "Green" }
W "(Programas legitimos normalmente criam uma subpasta com o nome do fabricante em C:\ProgramData, nao deixam .exe soltos na raiz.)" "DarkGray"

# ===================== ETAPA 31 - ARQUIVOS COM EXTENSAO DISFARCADA =====================
Titulo 31 $TOTAL_ETAPAS "ARQUIVOS COM EXTENSAO DISFARCADA EM PROGRAMDATA"
$achouDisfarce = $false
$assinaturas = @{
    ".png"  = @(0x89,0x50,0x4E,0x47)
    ".jpg"  = @(0xFF,0xD8,0xFF)
    ".jpeg" = @(0xFF,0xD8,0xFF)
    ".gif"  = @(0x47,0x49,0x46)
}
if (Test-Path "C:\ProgramData") {
    Get-ChildItem -Path "C:\ProgramData" -Recurse -Depth 3 -File -ErrorAction SilentlyContinue |
        Where-Object { $assinaturas.ContainsKey($_.Extension.ToLower()) -and $_.Length -gt 102400 } |
        ForEach-Object {
            try {
                $assinaturaEsperada = $assinaturas[$_.Extension.ToLower()]
                $streamArquivo = [System.IO.File]::OpenRead($_.FullName)
                $bufferBytes = New-Object byte[] $assinaturaEsperada.Count
                [void]$streamArquivo.Read($bufferBytes, 0, $assinaturaEsperada.Count)
                $streamArquivo.Close()
                $coincide = $true
                for ($i = 0; $i -lt $assinaturaEsperada.Count; $i++) {
                    if ($bufferBytes[$i] -ne $assinaturaEsperada[$i]) { $coincide = $false; break }
                }
                if (-not $coincide) {
                    $achouDisfarce = $true
                    W "Arquivo '$($_.Extension)' com conteudo que NAO condiz com uma imagem de verdade (pode ser payload disfarcado): $($_.FullName)" "Red" $true
                }
            } catch {}
        }
}
if (-not $achouDisfarce) { W "Nenhum arquivo de imagem disfarcado encontrado em C:\ProgramData." "Green" }
W "(Nao removido automaticamente - revise manualmente cada arquivo marcado acima antes de apagar.)" "DarkGray"

# ===================== ETAPA 32 - COM HIJACKING VIA CLSID =====================
Titulo 32 $TOTAL_ETAPAS "COM HIJACKING (CLSID SEQUESTRADO VIA HKCU)"
W "Isso pode demorar um pouco (verificando componentes COM registrados)..." "DarkGray"
$achouComHijack = $false
try {
    $hkcuClsidBase = "HKCU:\Software\Classes\CLSID"
    if (Test-Path $hkcuClsidBase) {
        Get-ChildItem -Path $hkcuClsidBase -ErrorAction SilentlyContinue | ForEach-Object {
            $clsid = $_.PSChildName
            $hklmPath = "HKLM:\SOFTWARE\Classes\CLSID\$clsid"
            if (Test-Path $hklmPath) {
                foreach ($sub in @("InprocServer32","LocalServer32")) {
                    $hkcuSub = Join-Path $_.PSPath $sub
                    $hklmSub = Join-Path $hklmPath $sub
                    if ((Test-Path $hkcuSub) -and (Test-Path $hklmSub)) {
                        $valHkcu = (Get-ItemProperty -Path $hkcuSub -ErrorAction SilentlyContinue).'(default)'
                        $valHklm = (Get-ItemProperty -Path $hklmSub -ErrorAction SilentlyContinue).'(default)'
                        if ($valHkcu -and $valHklm -and ($valHkcu -ne $valHklm) -and ($valHkcu -match '\\Temp\\|\\AppData\\Local\\Temp\\|\\AppData\\Roaming\\[^\\]+\\[^\\]+\.dll$')) {
                            $achouComHijack = $true
                            W "COM Hijacking: CLSID $clsid tem versao DIFERENTE em HKCU (sequestra o componente oficial do HKLM, sem precisar de administrador). HKCU aponta para: $valHkcu | HKLM original: $valHklm" "Red" $true
                            [void]$acoes.Add(@{ Tipo = "ComHijack"; Alvo = $hkcuSub; Descricao = "Remover override de CLSID $clsid em HKCU (sequestro COM): $valHkcu" })
                        }
                    }
                }
            }
        }
    }
} catch {
    W "Nao foi possivel verificar sequestro de CLSID (COM Hijacking)." "DarkGray"
}
if (-not $achouComHijack) { W "Nenhum sequestro de CLSID (COM Hijacking) via HKCU encontrado." "Green" }
W "(Tecnica: malware registra uma copia de um componente do Windows em HKCU (que tem prioridade sobre HKLM) para sequestrar a execucao sem precisar de administrador. Pouco monitorada por antivirus comuns.)" "DarkGray"

# ===================== ETAPA 33 - EXTENSOES FORCADAS POR POLITICA =====================
Titulo 33 $TOTAL_ETAPAS "EXTENSOES FORCADAS POR POLITICA NO NAVEGADOR (NAO REMOVIVEIS PELA INTERFACE)"
$achouForceInstall = $false
$chavesForceInstall = @(
    @{ Nome = "Chrome"; Path = "HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist" },
    @{ Nome = "Chrome (Wow6432Node)"; Path = "HKLM:\SOFTWARE\WOW6432Node\Policies\Google\Chrome\ExtensionInstallForcelist" },
    @{ Nome = "Edge"; Path = "HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist" },
    @{ Nome = "Edge (Wow6432Node)"; Path = "HKLM:\SOFTWARE\WOW6432Node\Policies\Microsoft\Edge\ExtensionInstallForcelist" }
)
foreach ($cf in $chavesForceInstall) {
    if (Test-Path $cf.Path) {
        $propsForce = Get-ItemProperty -Path $cf.Path -ErrorAction SilentlyContinue
        if ($propsForce) {
            $propsForce.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                $achouForceInstall = $true
                W "[$($cf.Nome)] Extensao FORCADA por politica (o usuario NAO consegue remover pela interface normal do navegador): $($_.Value)" "Red" $true
                [void]$acoes.Add(@{ Tipo = "RegistroValor"; Alvo = @{ Path = $cf.Path; Name = $_.Name }; Descricao = "Remover extensao forcada por politica: $($_.Value)" })
            }
        }
    }
}
if (-not $achouForceInstall) { W "Nenhuma extensao forcada por politica de grupo encontrada." "Green" }
W "(Se aparecer algo aqui e voce - ou uma empresa - nao configurou isso de proposito, e forte indicio de sequestro do navegador. Costuma vir junto com o aviso 'seu navegador e gerenciado pela sua organizacao'.)" "DarkGray"

# ===================== ETAPA 34 - PACOTES DE AUTENTICACAO LSA =====================
Titulo 34 $TOTAL_ETAPAS "PACOTES DE AUTENTICACAO LSA (PERSISTENCIA AVANCADA)"
$achouLsa = $false
if (-not $isAdmin) {
    W "Rode como Administrador para verificar os pacotes de autenticacao LSA." "DarkGray"
} else {
    try {
        $lsaKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
        $pacotesPadrao = @("msv1_0","kerberos","wdigest","tspkg","pku2u","negotiate","schannel","cloudap","pku2u.dll","scecli","rassfm","kdc","efslsaext")
        $proprLsa = Get-ItemProperty -Path $lsaKey -ErrorAction SilentlyContinue
        if ($proprLsa) {
            foreach ($campo in @("Authentication Packages","Notification Packages","Security Packages")) {
                $valoresCampo = $proprLsa.$campo
                if ($valoresCampo) {
                    foreach ($v in $valoresCampo) {
                        $vLimpo = if ($v) { $v.Trim() } else { "" }
                        if ($vLimpo -match '^[A-Za-z0-9_\.\-]+$' -and ($pacotesPadrao -notcontains $vLimpo.ToLower())) {
                            $achouLsa = $true
                            W "$campo contem entrada fora do padrao: '$vLimpo' (pode ser uma DLL maliciosa carregada dentro do processo LSASS, com acesso a credenciais do Windows)" "Red" $true
                        }
                    }
                }
            }
        }
    } catch {
        W "Nao foi possivel verificar os pacotes de autenticacao LSA." "DarkGray"
    }
}
if (-not $achouLsa) { W "Nenhum pacote de autenticacao LSA fora do padrao encontrado." "Green" }
W "(Nao removido automaticamente - mexer errado aqui pode impedir o login no Windows. Se aparecer algo, pesquise o nome exato antes de tomar qualquer acao, ou peca ajuda.)" "DarkGray"

# ===================== RESUMO FINAL =====================
Write-Host ""
Write-Host "====================================================================" -ForegroundColor Cyan
Write-Host "  RESUMO EXECUTIVO" -ForegroundColor Cyan
Write-Host "====================================================================" -ForegroundColor Cyan
if ($alertas -gt 0) {
    Write-Host ""
    Write-Host "  ALTA PRIORIDADE: $alertas SINAL(IS) - REVISE AGORA  " -ForegroundColor White -BackgroundColor Red
}
if ($alertasBaixos -gt 0) {
    Write-Host ""
    Write-Host "  BAIXA PRIORIDADE: $alertasBaixos ITEM(NS) - comum em instaladores legitimos ou arquivos assinados/orfaos, baixo risco  " -ForegroundColor Black -BackgroundColor DarkYellow
}
if ($alertas -eq 0 -and $alertasBaixos -eq 0) {
    Write-Host ""
    Write-Host "  NENHUM SINAL SUSPEITO ENCONTRADO  " -ForegroundColor White -BackgroundColor DarkGreen
}
Write-Host ""
Write-Host "Relatorio completo salvo em:" -ForegroundColor Gray
Write-Host $logfile -ForegroundColor Gray
Write-Host ""

# ===================== REMOCAO INTERATIVA =====================
if ($acoes.Count -gt 0) {
    $removiveis = @($acoes | Where-Object { $_.Tipo -in @("Processo","Arquivo","RegistroValor","Tarefa","DefenderExclusao","DefenderPolicyValor","HostsRestaurar","WmiPersistencia","Servico","IfeoDebugger","AppInitDlls","FirewallRegra","ProxyManual","ProxyAutoConfig","AtalhoLimpar","RegistroPayload","ServicoRegistro","ComHijack") })
    if ($removiveis.Count -gt 0) {
        Write-Host "====================================================================" -ForegroundColor Yellow
        Write-Host "  ITENS QUE PODEM SER REMOVIDOS AGORA" -ForegroundColor Yellow
        Write-Host "====================================================================" -ForegroundColor Yellow
        for ($i = 0; $i -lt $removiveis.Count; $i++) {
            $extra = ""
            if ($removiveis[$i].Tipo -in @("Tarefa","DefenderExclusao","DefenderPolicyValor","HostsRestaurar","WmiPersistencia","Servico","IfeoDebugger","AppInitDlls","FirewallRegra","RegistroPayload","ServicoRegistro") -and -not $isAdmin) { $extra = "  (precisa rodar como administrador)" }
            Write-Host "[$($i+1)] $($removiveis[$i].Descricao)$extra" -ForegroundColor White
        }
        Write-Host ""
        Write-Host "Digite os numeros dos itens que deseja remover, separados por virgula" -ForegroundColor Yellow
        Write-Host "(exemplo: 1,3). Ou apenas pressione ENTER para nao remover nada." -ForegroundColor Yellow
        $resp = Read-Host "Sua escolha"
        if ($resp -and $resp.Trim() -ne "") {
            if ($isAdmin) {
                Write-Host ""
                Write-Host "Criando ponto de restauracao do Windows antes de remover..." -ForegroundColor Cyan
                try {
                    Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
                    Checkpoint-Computer -Description "Scanner Anti-Minerador - antes da remocao" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
                    Write-Host "[OK] Ponto de restauracao criado." -ForegroundColor Green
                } catch {
                    Write-Host "[AVISO] Nao foi possivel criar ponto de restauracao (o Windows limita a 1 a cada 24h, ou pode estar desativado). Continuando mesmo assim." -ForegroundColor DarkYellow
                }
            } else {
                Write-Host ""
                Write-Host "[AVISO] Sem administrador, nao foi possivel criar ponto de restauracao antes de remover." -ForegroundColor DarkYellow
            }
            $numeros = $resp -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
            foreach ($num in $numeros) {
                $idx = $num - 1
                if ($idx -ge 0 -and $idx -lt $removiveis.Count) {
                    $item = $removiveis[$idx]
                    try {
                        switch ($item.Tipo) {
                            "Processo" {
                                Stop-Process -Id $item.Alvo -Force -ErrorAction Stop
                                Write-Host "[OK] Processo encerrado (PID $($item.Alvo))." -ForegroundColor Green
                            }
                            "Arquivo" {
                                Remove-Item -LiteralPath $item.Alvo -Force -ErrorAction Stop
                                Write-Host "[OK] Arquivo removido: $($item.Alvo)" -ForegroundColor Green
                            }
                            "RegistroValor" {
                                Remove-ItemProperty -Path $item.Alvo.Path -Name $item.Alvo.Name -Force -ErrorAction Stop
                                Write-Host "[OK] Entrada de registro removida: $($item.Alvo.Name)" -ForegroundColor Green
                            }
                            "Tarefa" {
                                if (-not $isAdmin) {
                                    Write-Host "[PULADO] Precisa de administrador: $($item.Alvo.Nome)" -ForegroundColor DarkYellow
                                } else {
                                    Unregister-ScheduledTask -TaskName $item.Alvo.Nome -TaskPath $item.Alvo.Path -Confirm:$false -ErrorAction Stop
                                    try {
                                        $xmlTarefaPath = (Join-Path "$env:SystemRoot\System32\Tasks" ($item.Alvo.Path.Trim('\') + '\' + $item.Alvo.Nome)) -replace '\\{2,}','\'
                                        if (Test-Path -LiteralPath $xmlTarefaPath) {
                                            Remove-Item -LiteralPath $xmlTarefaPath -Force -ErrorAction Stop
                                            Write-Host "[OK] Tarefa agendada removida (registro + arquivo XML): $($item.Alvo.Nome)" -ForegroundColor Green
                                        } else {
                                            Write-Host "[OK] Tarefa agendada removida: $($item.Alvo.Nome)" -ForegroundColor Green
                                        }
                                    } catch {
                                        Write-Host "[AVISO] Tarefa removida do agendador, mas nao foi possivel apagar o arquivo XML residual (pode reaparecer no proximo boot): $($item.Alvo.Nome)" -ForegroundColor DarkYellow
                                    }
                                }
                            }
                            "DefenderExclusao" {
                                if (-not $isAdmin) {
                                    Write-Host "[PULADO] Precisa de administrador: exclusao do Defender $($item.Alvo.Valor)" -ForegroundColor DarkYellow
                                } else {
                                    switch ($item.Alvo.TipoExclusao) {
                                        "Caminho"   { Remove-MpPreference -ExclusionPath $item.Alvo.Valor -ErrorAction Stop }
                                        "Processo"  { Remove-MpPreference -ExclusionProcess $item.Alvo.Valor -ErrorAction Stop }
                                        "Extensao"  { Remove-MpPreference -ExclusionExtension $item.Alvo.Valor -ErrorAction Stop }
                                    }
                                    Write-Host "[OK] Exclusao removida do Defender: $($item.Alvo.Valor)" -ForegroundColor Green
                                }
                            }
                            "DefenderPolicyValor" {
                                if (-not $isAdmin) {
                                    Write-Host "[PULADO] Precisa de administrador: politica do Defender $($item.Alvo.Name)" -ForegroundColor DarkYellow
                                } else {
                                    Remove-ItemProperty -Path $item.Alvo.Path -Name $item.Alvo.Name -Force -ErrorAction Stop
                                    Write-Host "[OK] Politica de Defender removida: $($item.Alvo.Name)" -ForegroundColor Green
                                }
                            }
                            "HostsRestaurar" {
                                if (-not $isAdmin) {
                                    Write-Host "[PULADO] Precisa de administrador: restaurar arquivo hosts" -ForegroundColor DarkYellow
                                } else {
                                    Copy-Item -LiteralPath $item.Alvo -Destination "$($item.Alvo).bak_scanner" -Force -ErrorAction SilentlyContinue
                                    $linhasAtuais = Get-Content -LiteralPath $item.Alvo -ErrorAction Stop
                                    $linhasLimpas = $linhasAtuais | Where-Object { $_.Trim() -eq "" -or $_.Trim() -match '^#' -or $_ -match '^\s*(127\.0\.0\.1|::1)\s+localhost' }
                                    Set-Content -LiteralPath $item.Alvo -Value $linhasLimpas -Force -ErrorAction Stop
                                    Write-Host "[OK] Arquivo hosts restaurado (backup salvo como hosts.bak_scanner)." -ForegroundColor Green
                                }
                            }
                            "WmiPersistencia" {
                                if (-not $isAdmin) {
                                    Write-Host "[PULADO] Precisa de administrador: remover persistencia via WMI" -ForegroundColor DarkYellow
                                } else {
                                    Get-WmiObject -Namespace root\subscription -Class __FilterToConsumerBinding -ErrorAction SilentlyContinue | ForEach-Object { $_.Delete() }
                                    Get-WmiObject -Namespace root\subscription -Class __EventConsumer -ErrorAction SilentlyContinue | ForEach-Object { $_.Delete() }
                                    Get-WmiObject -Namespace root\subscription -Class __EventFilter -ErrorAction SilentlyContinue | ForEach-Object { $_.Delete() }
                                    Write-Host "[OK] Persistencia via WMI removida." -ForegroundColor Green
                                }
                            }
                            "Servico" {
                                if (-not $isAdmin) {
                                    Write-Host "[PULADO] Precisa de administrador: servico $($item.Alvo)" -ForegroundColor DarkYellow
                                } else {
                                    Stop-Service -Name $item.Alvo -Force -ErrorAction Stop
                                    Set-Service -Name $item.Alvo -StartupType Disabled -ErrorAction Stop
                                    Write-Host "[OK] Servico parado e desabilitado: $($item.Alvo)" -ForegroundColor Green
                                }
                            }
                            "IfeoDebugger" {
                                if (-not $isAdmin) {
                                    Write-Host "[PULADO] Precisa de administrador: hijack IFEO" -ForegroundColor DarkYellow
                                } else {
                                    Remove-ItemProperty -Path $item.Alvo -Name "Debugger" -Force -ErrorAction Stop
                                    Write-Host "[OK] Hijack de IFEO removido." -ForegroundColor Green
                                }
                            }
                            "AppInitDlls" {
                                if (-not $isAdmin) {
                                    Write-Host "[PULADO] Precisa de administrador: AppInit_DLLs" -ForegroundColor DarkYellow
                                } else {
                                    Set-ItemProperty -Path $item.Alvo -Name "AppInit_DLLs" -Value "" -Force -ErrorAction Stop
                                    Write-Host "[OK] AppInit_DLLs limpo." -ForegroundColor Green
                                }
                            }
                            "FirewallRegra" {
                                if (-not $isAdmin) {
                                    Write-Host "[PULADO] Precisa de administrador: regra de firewall" -ForegroundColor DarkYellow
                                } else {
                                    Remove-NetFirewallRule -Name $item.Alvo -ErrorAction Stop
                                    Write-Host "[OK] Regra de firewall removida." -ForegroundColor Green
                                }
                            }
                            "ProxyManual" {
                                Set-ItemProperty -Path $item.Alvo -Name "ProxyEnable" -Value 0 -Force -ErrorAction Stop
                                Write-Host "[OK] Proxy manual desativado." -ForegroundColor Green
                            }
                            "ProxyAutoConfig" {
                                Remove-ItemProperty -Path $item.Alvo -Name "AutoConfigURL" -Force -ErrorAction Stop
                                Write-Host "[OK] Script de proxy automatico removido." -ForegroundColor Green
                            }
                            "AtalhoLimpar" {
                                $shellFix = New-Object -ComObject WScript.Shell
                                $atalhoFix = $shellFix.CreateShortcut($item.Alvo.Path)
                                $atalhoFix.Arguments = ""
                                $atalhoFix.Save()
                                Write-Host "[OK] Argumentos suspeitos removidos do atalho: $($item.Alvo.Path)" -ForegroundColor Green
                            }
                            "RegistroPayload" {
                                if (-not $isAdmin) {
                                    Write-Host "[PULADO] Precisa de administrador: payload no registro $($item.Alvo.Name)" -ForegroundColor DarkYellow
                                } else {
                                    Remove-ItemProperty -Path $item.Alvo.Path -Name $item.Alvo.Name -Force -ErrorAction Stop
                                    Write-Host "[OK] Payload binario removido do registro: $($item.Alvo.Name)" -ForegroundColor Green
                                }
                            }
                            "ServicoRegistro" {
                                if (-not $isAdmin) {
                                    Write-Host "[PULADO] Precisa de administrador: servico no registro $($item.Alvo.Nome)" -ForegroundColor DarkYellow
                                } else {
                                    Remove-Item -Path $item.Alvo.Path -Recurse -Force -ErrorAction Stop
                                    Write-Host "[OK] Copia oculta do servico removida do registro: $($item.Alvo.Nome)" -ForegroundColor Green
                                }
                            }
                            "ComHijack" {
                                Remove-Item -Path $item.Alvo -Recurse -Force -ErrorAction Stop
                                Write-Host "[OK] Override de COM Hijacking removido do registro (HKCU)." -ForegroundColor Green
                            }
                        }
                    } catch {
                        Write-Host "[ERRO] Nao foi possivel remover item $num : $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
            }
        } else {
            Write-Host "Nenhum item foi removido." -ForegroundColor Gray
        }
    }
    $pastasEDrivers = @($acoes | Where-Object { $_.Tipo -in @("Pasta") })
    if ($pastasEDrivers.Count -gt 0) {
        Write-Host ""
        Write-Host "Pastas e drivers suspeitos NAO sao removidos automaticamente" -ForegroundColor DarkYellow
        Write-Host "(podem conter dados legitimos misturados). Revise manualmente" -ForegroundColor DarkYellow
        Write-Host "os caminhos marcados como [ALERTA] no relatorio." -ForegroundColor DarkYellow
    }
}

Add-Content -Path $logfile -Value "SCANNER_CONCLUIDO"
Write-Host ""
Read-Host "Pressione ENTER para fechar"
