# Testes automatizados do WinHealth (PowerShell puro, sem dependencias).
# Uso:  powershell -NoProfile -File Recursos\tests\Testes.ps1
# O script e carregado com -CarregarSomente (define as funcoes sem abrir o menu) e o Windows
# e simulado com dados falsos: nada aqui le ou altera a maquina real.

# Este arquivo mora em Recursos\tests\ - a raiz do projeto (onde fica o WinHealth.ps1) fica DOIS
# niveis acima (Recursos\tests\Testes.ps1 -> Recursos\tests -> Recursos -> raiz).
$raiz = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$tmp = Join-Path $env:TEMP ("winhealth_teste_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
. (Join-Path $raiz "WinHealth.ps1") -PastaKit $tmp -CarregarSomente

# O log de diagnostico (caixa-preta) por padrao vai pra %LOCALAPPDATA%\WinHealth - redireciona pra
# dentro da pasta temporaria do teste, senao excecoes de proposito ("falhou de proposito" etc.)
# sujariam o log de diagnostico REAL desta maquina.
$script:pastaLogDiagnostico = Join-Path $tmp 'LogDiagnostico'
$script:arquivoLogDiagnostico = Join-Path $script:pastaLogDiagnostico 'winhealth_debug.log'

$script:total = 0
$script:falhas = @()

function Teste {
    param([string]$Nome, [scriptblock]$Corpo)
    $script:total++
    try { $null = & $Corpo; Write-Host "  [OK]    $Nome" -ForegroundColor Green }
    catch {
        $script:falhas += "$Nome :: $($_.Exception.Message)"
        Write-Host "  [FALHA] $Nome" -ForegroundColor Red
        Write-Host "          $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}
function Igual { param($Obtido, $Esperado, [string]$Msg = "") if ($Obtido -ne $Esperado) { throw "esperado '$Esperado', obtido '$Obtido' $Msg" } }
function Verdade { param($Cond, [string]$Msg) if (-not $Cond) { throw $Msg } }
function SeveridadesDe { param($Res, [string]$Categoria = $null) @($Res | Where-Object { -not $Categoria -or $_.Categoria -like $Categoria } | ForEach-Object { $_.Severidade }) }

# ---- simulacao do Windows (funcoes com o mesmo nome do cmdlet tem precedencia) ----
$script:mockVolumes = @()
$script:mockPentes = @()
$script:mockRamBytes = 16GB
function Get-CimInstance {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$ClassName, [string]$Filter, [string]$Namespace)
    switch ($ClassName) {
        'Win32_LogicalDisk' { $script:mockVolumes }
        'Win32_PhysicalMemory' { $script:mockPentes }
        'Win32_PhysicalMemoryArray' { [pscustomobject]@{ MemoryDevices = 2 } }
        'Win32_ComputerSystem' { [pscustomobject]@{ TotalPhysicalMemory = $script:mockRamBytes } }
        'Win32_OperatingSystem' { [pscustomobject]@{ Caption = 'Windows de Teste' } }
    }
}
function NovoVolume { param([string]$Letra, [double]$TotalGB, [double]$LivreGB) [pscustomobject]@{ DeviceID = $Letra; Size = [int64]($TotalGB * 1GB); FreeSpace = [int64]($LivreGB * 1GB) } }
function NovoEstadoUSB {
    param([hashtable]$Sobrescrever = @{})
    $e = @{ Dispositivos = @(); TemHid = $true; DiscosUsb = @(); UsbstorStart = 3; WriteProtect = $null; GpoExiste = $false; GpoRegras = @(); DeviceInstallRegras = @(); ServicosDlp = @() }
    foreach ($k in $Sobrescrever.Keys) { $e[$k] = $Sobrescrever[$k] }
    [pscustomobject]$e
}
$pendriveVisivel = [pscustomobject]@{ Modelo = 'Kingston DataTraveler'; TamanhoGB = 14.4; VID = '0951'; PID = '1666'; Serie = 'ABC123' }

Write-Host ""
Write-Host "== Modelo de resultados ==" -ForegroundColor Cyan
Teste "Res devolve objeto com os 5 campos" {
    $r = Res 'Cat' 'Ok' 'Titulo' 'Det' 'Rec'
    Igual $r.Categoria 'Cat'; Igual $r.Severidade 'Ok'; Igual $r.Titulo 'Titulo'; Igual $r.Detalhe 'Det'; Igual $r.Recomendacao 'Rec'
}

Write-Host ""
Write-Host "== Espaco em disco ==" -ForegroundColor Cyan
Teste "5% livre e Problema" { $script:mockVolumes = @(NovoVolume 'C:' 200 10); Igual (Testar-EspacoDisco).Severidade 'Problema' }
Teste "15% livre e Atencao" { $script:mockVolumes = @(NovoVolume 'C:' 200 30); Igual (Testar-EspacoDisco).Severidade 'Atencao' }
Teste "50% livre e Ok" { $script:mockVolumes = @(NovoVolume 'C:' 200 100); Igual (Testar-EspacoDisco).Severidade 'Ok' }
Teste "limite: exatamente 10% livre nao e Problema" { $script:mockVolumes = @(NovoVolume 'C:' 200 20); Igual (Testar-EspacoDisco).Severidade 'Atencao' }
Teste "sem unidades legiveis e Indisponivel (nao Ok)" { $script:mockVolumes = @(); Igual (Testar-EspacoDisco).Severidade 'Indisponivel' }
Teste "cada unidade vira um resultado" { $script:mockVolumes = @((NovoVolume 'C:' 200 5), (NovoVolume 'D:' 400 300)); $r = @(Testar-EspacoDisco); Igual $r.Count 2; Igual $r[0].Severidade 'Problema'; Igual $r[1].Severidade 'Ok' }

Write-Host ""
Write-Host "== Memoria RAM ==" -ForegroundColor Cyan
$pente = [pscustomobject]@{ Capacity = 8GB; SMBIOSMemoryType = 26; Speed = 2667; Manufacturer = 'Samsung'; DeviceLocator = 'DIMM 1' }
function SeveridadeRam { param([int64]$Bytes) $script:mockRamBytes = $Bytes; $script:mockPentes = @($pente); $r = @(Testar-Memoria); ($r | Where-Object { $_.Severidade -ne 'Info' } | Select-Object -First 1).Severidade }
Teste "4 GB e Problema" { Igual (SeveridadeRam 4GB) 'Problema' }
Teste "8 GB e Atencao" { Igual (SeveridadeRam 8GB) 'Atencao' }
Teste "16 GB e Ok" { Igual (SeveridadeRam 16GB) 'Ok' }
Teste "tipo LPDDR4 (30) e reconhecido" {
    $script:mockPentes = @([pscustomobject]@{ Capacity = 8GB; SMBIOSMemoryType = 30; Speed = 4267; Manufacturer = 'Unknown'; DeviceLocator = '' })
    $r = @(Testar-Memoria)
    Verdade ($r | Where-Object { $_.Detalhe -like '*LPDDR4*' }) "LPDDR4 nao apareceu"
    Verdade (-not ($r | Where-Object { $_.Detalhe -like '*Unknown*' })) "fabricante 'Unknown' nao deveria aparecer"
}

Write-Host ""
Write-Host "== Temperatura e bateria (regressoes de um teste real como admin) ==" -ForegroundColor Cyan
Teste "leitura impossivel (2,1 C) e Indisponivel, nunca 'Normal' (regressao)" {
    $r = Interpretar-Temperatura @(2.1)
    Igual $r.Severidade 'Indisponivel'; Verdade ($r.Detalhe -like '*2,1*' -or $r.Detalhe -like '*2.1*') "deveria mostrar o valor recebido"
}
Teste "temperatura: 45 = Ok, 75 = Atencao, 90 = Problema, sem leitura = Indisponivel" {
    Igual (Interpretar-Temperatura @(45)).Severidade 'Ok'
    Igual (Interpretar-Temperatura @(75)).Severidade 'Atencao'
    Igual (Interpretar-Temperatura @(90)).Severidade 'Problema'
    Igual (Interpretar-Temperatura @()).Severidade 'Indisponivel'
}
Teste "temperatura: mistura de leitura lixo e valida usa so a valida" {
    $r = @(Interpretar-Temperatura @(2.1, 48))
    Igual $r.Count 1; Igual $r[0].Severidade 'Ok'
}
Teste "temperatura Ok avisa que a leitura ACPI pode nao ser a da CPU" { Verdade ((Interpretar-Temperatura @(40)).Detalhe -like '*ACPI*') "sem a ressalva" }
Teste "Ler-BateriaXml le capacidade de projeto, atual e ciclos" {
    $f = Join-Path $tmp 'bat.xml'
    [IO.File]::WriteAllText($f, '<?xml version="1.0"?><BatteryReport><Batteries><Battery><Id>X</Id><DesignCapacity>43092</DesignCapacity><FullChargeCapacity>36526</FullChargeCapacity><CycleCount>233</CycleCount></Battery></Batteries></BatteryReport>', [Text.Encoding]::UTF8)
    $b = Ler-BateriaXml $f
    Igual $b.Design 43092; Igual $b.Cheia 36526; Igual $b.Ciclos 233
}
Teste "Ler-BateriaXml: sem bateria, XML quebrado ou capacidade zero = nulo" {
    $f1 = Join-Path $tmp 'b1.xml'; [IO.File]::WriteAllText($f1, '<BatteryReport><Batteries></Batteries></BatteryReport>')
    $f2 = Join-Path $tmp 'b2.xml'; [IO.File]::WriteAllText($f2, '<quebrado')
    $f3 = Join-Path $tmp 'b3.xml'; [IO.File]::WriteAllText($f3, '<BatteryReport><Batteries><Battery><DesignCapacity>0</DesignCapacity><FullChargeCapacity>0</FullChargeCapacity></Battery></Batteries></BatteryReport>')
    Verdade ($null -eq (Ler-BateriaXml $f1)) "sem bateria deveria ser nulo"
    Verdade ($null -eq (Ler-BateriaXml $f2)) "xml quebrado deveria ser nulo"
    Verdade ($null -eq (Ler-BateriaXml $f3)) "capacidade zero deveria ser nulo"
    Verdade ($null -eq (Ler-BateriaXml (Join-Path $tmp 'nao_existe.xml'))) "arquivo inexistente deveria ser nulo"
}
function SaudeBateria { param($Cap)
    $script:capMock = $Cap
    function Get-CimInstance { [CmdletBinding()] param([Parameter(Position = 0)][string]$ClassName, [string]$Filter, [string]$Namespace) if ($ClassName -eq 'Win32_Battery') { [pscustomobject]@{ Name = 'Bat'; EstimatedChargeRemaining = 90; BatteryStatus = 2 } } }
    function Obter-CapacidadeBateria { $script:capMock }
    try { @(Testar-Bateria) } finally { Remove-Item Function:\Obter-CapacidadeBateria }
}
Teste "Testar-Bateria: 85% = Ok com ciclos (o caso real desta maquina)" {
    $r = SaudeBateria ([pscustomobject]@{ Design = 43092; Cheia = 36526; Ciclos = 233 })
    $s = $r | Where-Object { $_.Titulo -like 'Saúde da bateria*' }
    Igual $s.Severidade 'Ok'; Verdade ($s.Titulo -like '*85%*') "esperava 85%"
    Verdade ($r | Where-Object { $_.Titulo -eq 'Ciclos de carga' -and $_.Detalhe -eq '233' }) "faltou ciclos"
}
Teste "Testar-Bateria: 70% = Atencao, 55% = Problema, sem capacidade = Indisponivel" {
    Igual (SaudeBateria ([pscustomobject]@{ Design = 100; Cheia = 70; Ciclos = $null }) | Where-Object { $_.Titulo -like 'Saúde*' }).Severidade 'Atencao'
    Igual (SaudeBateria ([pscustomobject]@{ Design = 100; Cheia = 55; Ciclos = $null }) | Where-Object { $_.Titulo -like 'Saúde*' }).Severidade 'Problema'
    Igual (SaudeBateria $null | Where-Object { $_.Titulo -like 'Saúde*' }).Severidade 'Indisponivel'
}

Write-Host ""
Write-Host "== Atualizacoes de driver ==" -ForegroundColor Cyan
Teste "Interpretar-AtualizacoesDriver: coleta falhou (excecao no COM) vira Indisponivel" {
    $r = Interpretar-AtualizacoesDriver ([pscustomobject]@{ Ok = $false; Titulos = @() })
    Igual $r.Severidade 'Indisponivel'
}
Teste "Interpretar-AtualizacoesDriver: nenhum titulo pendente vira Ok" {
    $r = Interpretar-AtualizacoesDriver ([pscustomobject]@{ Ok = $true; Titulos = @() })
    Igual $r.Severidade 'Ok'
}
Teste "Interpretar-AtualizacoesDriver: um Res 'Atencao' por titulo pendente, com o nome do driver e a recomendacao certa" {
    $r = @(Interpretar-AtualizacoesDriver ([pscustomobject]@{ Ok = $true; Titulos = @('Intel(R) UHD Graphics', 'Realtek Audio') }))
    Igual $r.Count 2
    Igual $r[0].Severidade 'Atencao'
    Verdade ($r[0].Titulo -like '*Intel*UHD Graphics*') "titulo nao contem o nome do driver: $($r[0].Titulo)"
    Verdade ($r[0].Recomendacao -like '*Atualizações opcionais*') "recomendacao nao aponta pro Windows Update: $($r[0].Recomendacao)"
    Verdade ($r[1].Titulo -like '*Realtek*') "segundo item nao veio"
}

Write-Host ""
Write-Host "== Diagnostico de USB (interpretacao) ==" -ForegroundColor Cyan
Teste "GPO Deny_Read + pendrive invisivel: conclusao Atencao" {
    $e = NovoEstadoUSB @{ GpoExiste = $true; GpoRegras = @('Deny_Read em {53f5630d}') }
    $r = @(Avaliar-EstadoUSB $e $true)
    Igual ($r | Where-Object { $_.Categoria -eq 'Conclusão' }).Severidade 'Atencao'
    Verdade ($r | Where-Object { $_.Categoria -like 'Configura*' -and $_.Severidade -eq 'Problema' -and $_.Titulo -like '*Deny_Read*' }) "GPO nao virou Problema"
}
Teste "USBSTOR desabilitado (Start=4) e Problema" {
    $r = @(Avaliar-EstadoUSB (NovoEstadoUSB @{ UsbstorStart = 4 }) $true)
    Verdade ($r | Where-Object { $_.Titulo -like '*USBSTOR desabilitado*' -and $_.Severidade -eq 'Problema' }) "USBSTOR=4 nao foi detectado"
}
Teste "USBSTOR ilegivel e Indisponivel, nunca Ok" {
    $r = @(Avaliar-EstadoUSB (NovoEstadoUSB @{ UsbstorStart = $null }) $true)
    Igual ($r | Where-Object { $_.Titulo -eq 'Driver USBSTOR' }).Severidade 'Indisponivel'
}
Teste "WriteProtect=1 e Problema" {
    $r = @(Avaliar-EstadoUSB (NovoEstadoUSB @{ WriteProtect = 1 }) $true)
    Verdade ($r | Where-Object { $_.Titulo -like '*gravação*' -and $_.Severidade -eq 'Problema' }) "WriteProtect nao detectado"
}
Teste "restricao de instalacao de dispositivos e Problema" {
    $r = @(Avaliar-EstadoUSB (NovoEstadoUSB @{ DeviceInstallRegras = @('restrição por classe/ID de dispositivo ativa') }) $true)
    Verdade ($r | Where-Object { $_.Titulo -like '*instalação de dispositivos*' -and $_.Severidade -eq 'Problema' }) "DeviceInstall nao detectado"
}
Teste "sem pendrive conectado: inconclusivo, sem alarme falso (regressao)" {
    $r = @(Avaliar-EstadoUSB (NovoEstadoUSB @{ TemHid = $true }) $false)
    Igual ($r | Where-Object { $_.Categoria -eq 'Conclusão' }).Severidade 'Indisponivel'
    Igual (@($r | Where-Object { $_.Severidade -eq 'Problema' }).Count) 0
}
Teste "pendrive conectado + HID ok + nada visivel + sem config: suspeita de DLP (Atencao)" {
    $r = @(Avaliar-EstadoUSB (NovoEstadoUSB @{ TemHid = $true }) $true)
    Igual ($r | Where-Object { $_.Categoria -eq 'Conclusão' }).Severidade 'Atencao'
    Verdade ($r | Where-Object { $_.Categoria -like 'Pendrives*' -and $_.Severidade -eq 'Problema' }) "invisivel com HID deveria ser Problema"
}
Teste "pendrive conectado sem HID e nada visivel: nao acusa bloqueio" {
    $r = @(Avaliar-EstadoUSB (NovoEstadoUSB @{ TemHid = $false }) $true)
    Igual (@($r | Where-Object { $_.Severidade -eq 'Problema' }).Count) 0
}
Teste "pendrive conectado sem HID e nada visivel: conclusao orienta o proximo passo, nao diz 'nenhum pendrive analisado' (regressao print USB)" {
    $r = @(Avaliar-EstadoUSB (NovoEstadoUSB @{ TemHid = $false }) $true)
    $c = $r | Where-Object { $_.Categoria -eq 'Conclusão' }
    Igual $c.Severidade 'Atencao'
    Verdade ($c.Recomendacao -like '*outra máquina*') "sem orientacao de proximo passo"
    Verdade ($c.Titulo -notlike '*inconclusivo*') "ainda diz inconclusivo"
}
Teste "pendrive visivel e sem restricoes: conclusao Ok + Hardware ID" {
    $r = @(Avaliar-EstadoUSB (NovoEstadoUSB @{ DiscosUsb = @($pendriveVisivel) }) $true)
    Igual ($r | Where-Object { $_.Categoria -eq 'Conclusão' }).Severidade 'Ok'
    Verdade ($r | Where-Object { $_.Titulo -eq 'Hardware ID' -and $_.Detalhe -like '*VID_0951&PID_1666*' }) "Hardware ID ausente"
}
Teste "pendrive visivel mas VID/PID ilegivel: avisa como Indisponivel" {
    $sem = [pscustomobject]@{ Modelo = 'Generico'; TamanhoGB = 8; VID = $null; PID = $null; Serie = $null }
    $r = @(Avaliar-EstadoUSB (NovoEstadoUSB @{ DiscosUsb = @($sem) }) $true)
    Verdade ($r | Where-Object { $_.Titulo -like 'Hardware ID de*' -and $_.Severidade -eq 'Indisponivel' }) "VID/PID ilegivel deveria ser Indisponivel"
}
Teste "servico de DLP aparece so como indicio (Info)" {
    $r = @(Avaliar-EstadoUSB (NovoEstadoUSB @{ ServicosDlp = @('McAfee DLP [mfedlp] - Running') }) $true)
    Verdade ($r | Where-Object { $_.Categoria -like 'Software*' -and $_.Titulo -eq 'Serviço' -and $_.Severidade -eq 'Info' }) "servico nao listado como Info"
    Igual (@($r | Where-Object { $_.Categoria -like 'Software*' -and $_.Severidade -eq 'Problema' }).Count) 0
}
Teste "dispositivo USB com erro vira Atencao" {
    $dev = [pscustomobject]@{ Classe = 'USB'; Nome = 'Dispositivo desconhecido'; Status = 'Error'; Problema = 'CM_PROB_FAILED_INSTALL'; Id = 'USB\VID_1234&PID_5678\1' }
    $r = @(Avaliar-EstadoUSB (NovoEstadoUSB @{ Dispositivos = @($dev) }) $true)
    Verdade ($r | Where-Object { $_.Categoria -like 'USB em uso*' -and $_.Severidade -eq 'Atencao' }) "erro de dispositivo nao virou Atencao"
}

Write-Host ""
Write-Host "== Texto do chamado ==" -ForegroundColor Cyan
Teste "inclui Hardware ID, serie e maquina" {
    $t = (Novo-TextoChamado @($pendriveVisivel) 'PC-01' 'DOM\gabriel' '27/09/2026 10:00') -join "`n"
    Verdade ($t -like '*USB\VID_0951&PID_1666*') "sem Hardware ID"
    Verdade ($t -like '*ABC123*') "sem serie"
    Verdade ($t -like '*PC-01*') "sem maquina"
}
Teste "sem VID/PID nao gera texto (nada de chamado vazio)" {
    $sem = [pscustomobject]@{ Modelo = 'X'; TamanhoGB = 1; VID = $null; PID = $null; Serie = $null }
    Igual @(Novo-TextoChamado @($sem) 'PC' 'u' 'd').Count 0
}

Write-Host ""
Write-Host "== Reparo: leitura da saida dos comandos ==" -ForegroundColor Cyan
function GravarBytes { param([byte[]]$Bytes) $f = Join-Path $tmp ([guid]::NewGuid().ToString('N') + '.bin'); [IO.File]::WriteAllBytes($f, $Bytes); $f }
Teste "UTF-16 com BOM (como o SFC grava) e decodificado sem NULs" {
    $b = [byte[]](0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes("Verificação 45% concluída.")
    Igual (Ler-SaidaComando (GravarBytes $b)) "Verificação 45% concluída."
}
Teste "UTF-16 sem BOM tambem e decodificado" {
    Igual (Ler-SaidaComando (GravarBytes ([Text.Encoding]::Unicode.GetBytes("did not find any integrity violations")))) "did not find any integrity violations"
}
Teste "texto simples (OEM) passa sem alteracao" { Igual (Ler-SaidaComando (GravarBytes ([Text.Encoding]::ASCII.GetBytes("ok 100%")))) "ok 100%" }
Teste "bytes OEM (CP850, como DISM/CHKDSK gravam) nao viram '?' (regressao)" {
    $oem = [Text.Encoding]::GetEncoding(850)
    Igual (Ler-SaidaComando (GravarBytes ($oem.GetBytes("privilégios elevados")))) "privilégios elevados"
}
Teste "bytes ANSI (como o CHKDSK grava) sao lidos com Codificacao Ansi (regressao)" {
    $ansi = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
    Igual (Ler-SaidaComando (GravarBytes ($ansi.GetBytes("o disco está desbloqueado"))) 'Ansi') "o disco está desbloqueado"
}
Teste "UTF-8 valido tambem e decodificado" {
    Igual (Ler-SaidaComando (GravarBytes ([Text.Encoding]::UTF8.GetBytes("não encontrou")))) "não encontrou"
}
Teste "arquivo inexistente ou vazio da string vazia" {
    Igual (Ler-SaidaComando (Join-Path $tmp 'nao_existe.txt')) ""
    Igual (Ler-SaidaComando (GravarBytes ([byte[]]@()))) ""
}
Teste "ultima linha util pega o ultimo progresso mesmo com \r e linhas em branco" {
    Igual (Ultima-LinhaUtil "inicio`r`n[==   20% ]`r[====  40% ]`r`n`r`n") "[====  40% ]"
    Igual (Ultima-LinhaUtil "") ""
}

Write-Host ""
Write-Host "== Reparo: execucao de comandos (wrapper) ==" -ForegroundColor Cyan
Teste "captura codigo de saida diferente de zero" { Igual (Invoke-Comando 'cmd.exe' @('/c', 'exit 3')).Codigo 3 }
Teste "captura saida e codigo 0" { $r = Invoke-Comando 'cmd.exe' @('/c', 'echo oi-teste'); Igual $r.Codigo 0; Verdade ($r.Saida -like '*oi-teste*') "sem saida" }
Teste "programa inexistente: Codigo nulo e ErroInicio preenchido (nao lanca excecao)" {
    $r = Invoke-Comando 'programa_que_nao_existe_xyz.exe' @()
    Verdade ($null -eq $r.Codigo) "Codigo deveria ser nulo"
    Verdade ($r.ErroInicio) "ErroInicio vazio"
}
Teste "callback de progresso e chamado enquanto o comando roda" {
    $script:chamadas = 0
    $null = Invoke-Comando 'powershell.exe' @('-NoProfile', '-Command', 'Start-Sleep 4') { param($t, $l) $script:chamadas++ }
    Verdade ($script:chamadas -ge 1) "callback nunca chamado"
}
Teste "arquivos temporarios do wrapper sao removidos" {
    $antes = @(Get-ChildItem $env:TEMP -Filter 'winhealth_cmd_*' -ErrorAction SilentlyContinue).Count
    $null = Invoke-Comando 'cmd.exe' @('/c', 'echo x')
    Igual @(Get-ChildItem $env:TEMP -Filter 'winhealth_cmd_*' -ErrorAction SilentlyContinue).Count $antes
}

Write-Host ""
Write-Host "== Reparo: ponto de restauracao (data real, nao so a regra generica de 24h) ==" -ForegroundColor Cyan
Teste "Obter-UltimoPontoRestauracao: sem nenhum ponto, devolve null" {
    function Get-ComputerRestorePoint { param($ErrorAction) @() }
    Igual (Obter-UltimoPontoRestauracao) $null
}
Teste "Obter-UltimoPontoRestauracao: erro na consulta devolve null, sem lancar excecao" {
    function Get-ComputerRestorePoint { param($ErrorAction) throw 'sem acesso' }
    Igual (Obter-UltimoPontoRestauracao) $null
}
Teste "Obter-UltimoPontoRestauracao: pega o de maior SequenceNumber (mais recente) e converte a data WMI certa" {
    function Get-ComputerRestorePoint {
        param($ErrorAction)
        @(
            [pscustomobject]@{ SequenceNumber = 10; CreationTime = '20260101120000.000000-180' }
            [pscustomobject]@{ SequenceNumber = 12; CreationTime = '20260927153000.000000-180' }
            [pscustomobject]@{ SequenceNumber = 11; CreationTime = '20260615090000.000000-180' }
        )
    }
    $r = Obter-UltimoPontoRestauracao
    Igual $r.Year 2026; Igual $r.Month 9; Igual $r.Day 27; Igual $r.Hour 15; Igual $r.Minute 30
}

Write-Host ""
Write-Host "== Reparo: interpretacao (DISM / SFC / CHKDSK) ==" -ForegroundColor Cyan
Teste "DISM 0 = Ok" { Igual (Interpretar-Dism 0 "").Severidade 'Ok' }
Teste "DISM 3010 = Ok (reinicio)" { $r = Interpretar-Dism 3010 ""; Igual $r.Severidade 'Ok'; Verdade ($r.Titulo -like '*reinício*') "sem aviso de reinicio" }
Teste "DISM 0x800F081F = Problema com codigo em hex (independe do idioma)" {
    $r = Interpretar-Dism -2146498529 "texto em qualquer idioma"
    Igual $r.Severidade 'Problema'; Verdade ($r.Titulo -like '*0x800F081F*') "hex ausente"
}
Teste "DISM 0x800F0906 = Problema (download)" { Verdade ((Interpretar-Dism -2146498298 "").Titulo -like '*baixar*') "esperava aviso de download" }
Teste "DISM erro desconhecido = Problema" { Igual (Interpretar-Dism 5 "").Severidade 'Problema' }
Teste "DISM sem codigo (nao executou) = Problema, nunca Ok" { Igual (Interpretar-Dism $null "").Severidade 'Problema' }
Teste "SFC PT-BR: sem violacao = Ok" { Igual (Interpretar-Sfc 0 "A Proteção de Recursos do Windows não encontrou nenhuma violação de integridade.").Severidade 'Ok' }
Teste "SFC EN: reparou = Ok" { Igual (Interpretar-Sfc 0 "Windows Resource Protection found corrupt files and successfully repaired them.").Severidade 'Ok' }
Teste "SFC PT-BR: nao conseguiu corrigir = Problema (mesmo com codigo 0)" { Igual (Interpretar-Sfc 0 "A Proteção de Recursos do Windows encontrou arquivos corrompidos, mas não foi possível corrigir alguns deles.").Severidade 'Problema' }
Teste "SFC EN: unable to fix = Problema" { Igual (Interpretar-Sfc 1 "found corrupt files but was unable to fix some of them").Severidade 'Problema' }
Teste "SFC reparo pendente = Atencao" { Igual (Interpretar-Sfc 1 "There is a system repair pending which requires reboot to complete.").Severidade 'Atencao' }
Teste "SFC idioma desconhecido: codigo 0 = Ok; codigo != 0 = Atencao (nunca passa como certo)" {
    Igual (Interpretar-Sfc 0 "Texto em outro idioma").Severidade 'Ok'
    Igual (Interpretar-Sfc 2 "Texto em outro idioma").Severidade 'Atencao'
}
Teste "SFC com saida UTF-16 (via Ler-SaidaComando) e interpretado" {
    $b = [byte[]](0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes("did not find any integrity violations")
    Igual (Interpretar-Sfc 0 (Ler-SaidaComando (GravarBytes $b))).Titulo 'SFC: nenhum arquivo de sistema corrompido'
}
Teste "CHKDSK 0 = Ok" { Igual (Interpretar-Chkdsk 0 "").Severidade 'Ok' }
Teste "CHKDSK codigo != 0 sem texto de sucesso = Atencao, sem acusar 'problemas no disco' (regressao)" {
    $r = Interpretar-Chkdsk 3 "Acesso negado, privilégios insuficientes."
    Igual $r.Severidade 'Atencao'
    Verdade ($r.Titulo -notlike '*reportou problemas*') "titulo acusa problema no disco sem base"
    Verdade ($r.Detalhe -like '*Acesso negado*') "faltou a ultima mensagem real do programa"
}
Teste "erro generico do DISM mostra a ultima mensagem real" { Verdade ((Interpretar-Dism 87 "linha1`nParametro invalido.").Detalhe -like '*Parametro invalido*') "sem ultima mensagem" }
Teste "CHKDSK texto 'nao encontrou problemas' vence codigo" { Igual (Interpretar-Chkdsk 3 "O Windows examinou o sistema de arquivos e não encontrou problemas.").Severidade 'Ok' }
Teste "CHKDSK sem codigo = Indisponivel" { Igual (Interpretar-Chkdsk $null "").Severidade 'Indisponivel' }

Write-Host ""
Write-Host "== Preparar formatacao: protecao de dados sensiveis ==" -ForegroundColor Cyan
$segredo = "Rede: CasaDoJoao | Senha: s3nh4-Secr3ta-ção"
Teste "protege e desprotege (ida e volta, com acentos)" {
    $enc = Proteger-Texto $segredo "senha-forte-123"
    Igual (Desproteger-Texto $enc "senha-forte-123") $segredo
}
Teste "o arquivo protegido nao contem o texto original nem a senha em claro" {
    $enc = Proteger-Texto $segredo "senha-forte-123"
    $lat = [Text.Encoding]::GetEncoding(28591).GetString($enc)
    Verdade (-not $lat.Contains('CasaDoJoao')) "vazou o nome da rede"
    Verdade (-not $lat.Contains('s3nh4')) "vazou a senha do wifi"
    Verdade (-not $lat.Contains('senha-forte-123')) "vazou a senha de protecao"
}
Teste "senha errada e recusada" {
    $enc = Proteger-Texto $segredo "senha-forte-123"
    $erro = $null; try { $null = Desproteger-Texto $enc "outra-senha" } catch { $erro = $_.Exception.Message }
    Verdade ($erro -like '*Senha incorreta*') "esperava recusa, obteve: $erro"
}
Teste "arquivo adulterado (1 byte) e detectado" {
    $enc = Proteger-Texto $segredo "senha-forte-123"
    $enc[$enc.Length - 40] = $enc[$enc.Length - 40] -bxor 1
    $erro = $null; try { $null = Desproteger-Texto $enc "senha-forte-123" } catch { $erro = $_.Exception.Message }
    Verdade ($erro) "adulteracao passou despercebida"
}
Teste "arquivo truncado ou de outro programa e recusado" {
    $e1 = $null; try { $null = Desproteger-Texto ([byte[]](1, 2, 3)) "x" } catch { $e1 = $_.Exception.Message }
    Verdade ($e1 -like '*inválido*') "truncado nao recusado"
    $e2 = $null; try { $null = Desproteger-Texto ([byte[]](, 65 * 120)) "x" } catch { $e2 = $_.Exception.Message }
    Verdade ($e2 -like '*não foi criado*') "arquivo estranho nao recusado: $e2"
}
Teste "duas protecoes do mesmo texto diferem (sal/IV aleatorios)" {
    $a = [Convert]::ToBase64String((Proteger-Texto $segredo "senha-forte-123"))
    $b = [Convert]::ToBase64String((Proteger-Texto $segredo "senha-forte-123"))
    Verdade ($a -ne $b) "saidas identicas"
}
Teste "senha vazia e rejeitada" { $e = $null; try { $null = Proteger-Texto "x" "" } catch { $e = $_ }; Verdade $e "aceitou senha vazia" }

Write-Host ""
Write-Host "== Preparar formatacao: coleta e interpretacao ==" -ForegroundColor Cyan
Teste "Ler-PerfisWifiXml: rede com senha, aberta e corporativa" {
    $d = Join-Path $tmp 'wifi'; New-Item -ItemType Directory $d | Out-Null
    $modelo = '<?xml version="1.0"?><WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1"><name>{0}</name><MSM><security><authEncryption><authentication>{1}</authentication></authEncryption>{2}</security></MSM></WLANProfile>'
    [IO.File]::WriteAllText("$d\a.xml", ($modelo -f 'Casa Joao', 'WPA2PSK', '<sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>abc12345</keyMaterial></sharedKey>'), [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText("$d\b.xml", ($modelo -f 'Cafe', 'open', ''), [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText("$d\c.xml", ($modelo -f 'Empresa', 'WPA2', ''), [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText("$d\quebrado.xml", '<nao fecha', [Text.Encoding]::UTF8)
    $r = @(Ler-PerfisWifiXml $d)
    Igual $r.Count 3 "(o XML quebrado deve ser ignorado)"
    Igual ($r | Where-Object { $_.Nome -eq 'Casa Joao' }).Senha 'abc12345'
    Verdade (-not ($r | Where-Object { $_.Nome -eq 'Cafe' }).Senha) "rede aberta nao deveria ter senha"
}
Teste "Interpretar-ExportDrivers: 0 com drivers = Ok" { Igual (Interpretar-ExportDrivers 0 12 'C:\x').Severidade 'Ok' }
Teste "Interpretar-ExportDrivers: 0 sem drivers = Atencao (nao Ok)" { Igual (Interpretar-ExportDrivers 0 0 'C:\x').Severidade 'Atencao' }
Teste "Interpretar-ExportDrivers: codigo != 0 = Problema" { Igual (Interpretar-ExportDrivers 5 3 'C:\x').Severidade 'Problema' }
Teste "Interpretar-ExportDrivers: sem codigo = Problema" { Igual (Interpretar-ExportDrivers $null 0 'C:\x').Severidade 'Problema' }
Teste "Medir-Pasta soma tamanho e conta arquivos (recursivo)" {
    $d = Join-Path $tmp 'medir'; New-Item -ItemType Directory "$d\sub" | Out-Null
    [IO.File]::WriteAllBytes("$d\a.bin", (New-Object byte[] 1048576))
    [IO.File]::WriteAllBytes("$d\sub\b.bin", (New-Object byte[] 1048576))
    $m = Medir-Pasta $d
    Igual $m.Arquivos 2; Igual $m.GB 0
    Verdade ((Medir-Pasta (Join-Path $tmp 'nao_existe')).Arquivos -eq 0) "pasta inexistente deveria dar 0"
}
Teste "Esta-NoOneDrive reconhece caminhos dentro do OneDrive" {
    Verdade (Esta-NoOneDrive 'C:\Users\a\OneDrive\Desktop' @('C:\Users\a\OneDrive')) "esperava true"
    Verdade (-not (Esta-NoOneDrive 'C:\Users\a\OneDriveFake\Desktop' @('C:\Users\a\OneDrive'))) "prefixo parcial nao pode casar"
    Verdade (-not (Esta-NoOneDrive 'C:\Users\a\Desktop' @($null, ''))) "raizes vazias nao podem casar"
}
Teste "Novo-TextoSensivel inclui chave e so redes COM senha" {
    $t = Novo-TextoSensivel 'PC-01' '27/09/2026' 'AAAAA-BBBBB' @([pscustomobject]@{ Nome = 'Casa'; Senha = 'xyz98765' }, [pscustomobject]@{ Nome = 'Cafe'; Senha = '' })
    Verdade ($t -like '*AAAAA-BBBBB*') "sem chave"
    Verdade ($t -like '*Casa*xyz98765*') "sem rede com senha"
    Verdade ($t -notlike '*Cafe*') "rede aberta nao deveria constar"
}

Write-Host ""
Write-Host "== Preparar formatacao: privacidade (regressao) ==" -ForegroundColor Cyan
$chaveFalsa = 'ZZZZZ-YYYYY-XXXXX-WWWWW-VVVVV'
function TextoDe { param($Res) (@($Res) | ForEach-Object { "$($_.Categoria)|$($_.Titulo)|$($_.Detalhe)|$($_.Recomendacao)" }) -join "`n" }
function Obter-ChaveOem { $chaveFalsa }
Teste "a chave do Windows NUNCA aparece nos resultados exibidos/logados (guardando ou nao)" {
    $script:sensivel = @{ Chave = $null; Wifi = @() }
    Verdade ((TextoDe (Preparar-ChaveWindows $true)) -notlike "*$chaveFalsa*") "chave vazou (guardar=sim)"
    Verdade ((TextoDe (Preparar-ChaveWindows $false)) -notlike "*$chaveFalsa*") "chave vazou (guardar=nao)"
}
Teste "so guarda a chave em memoria; o texto sensivel e a unica saida em claro" {
    $script:sensivel = @{ Chave = $null; Wifi = @() }
    $null = Preparar-ChaveWindows $true
    Igual $script:sensivel.Chave $chaveFalsa
}
function Exportar-PerfisWifi { param([bool]$ComSenha) @([pscustomobject]@{ Nome = 'Casa'; Autenticacao = 'WPA2PSK'; Senha = 'senhaSecreta777' }, [pscustomobject]@{ Nome = 'Empresa'; Autenticacao = 'WPA2'; Senha = '' }) }
Teste "senhas de Wi-Fi NUNCA aparecem nos resultados (com opt-in)" {
    $script:sensivel = @{ Chave = $null; Wifi = @() }; $script:isAdmin = $true
    $r = @(Preparar-Wifi $true)
    Verdade ((TextoDe $r) -notlike '*senhaSecreta777*') "senha vazou nos resultados"
    Igual @($script:sensivel.Wifi).Count 1
}
Teste "sem opt-in: nenhuma senha e guardada e nenhuma aparece" {
    $script:sensivel = @{ Chave = $null; Wifi = @() }; $script:isAdmin = $true
    $r = @(Preparar-Wifi $false)
    Verdade ((TextoDe $r) -notlike '*senhaSecreta777*') "senha vazou"
    Igual @($script:sensivel.Wifi).Count 0
    Verdade ((TextoDe $r) -like '*Casa*') "deveria listar os nomes das redes"
}
Teste "com opt-in mas sem admin e senhas ilegiveis: Indisponivel (nao Ok)" {
    function Exportar-PerfisWifi { param([bool]$ComSenha) @([pscustomobject]@{ Nome = 'Casa'; Autenticacao = 'WPA2PSK'; Senha = '' }) }
    $script:sensivel = @{ Chave = $null; Wifi = @() }; $script:isAdmin = $false
    $r = @(Preparar-Wifi $true)
    Verdade ($r | Where-Object { $_.Severidade -eq 'Indisponivel' }) "esperava Indisponivel"
}
Remove-Item Function:\Obter-ChaveOem, Function:\Exportar-PerfisWifi
$script:isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host ""
Write-Host "== Limpeza: travas de seguranca ==" -ForegroundColor Cyan
Teste "recusa raiz de unidade, perfil, Windows, System32, Users e caminho vazio" {
    foreach ($c in @('C:\', 'C:', $env:USERPROFILE, $env:SystemRoot, "$env:SystemRoot\System32", "$env:SystemDrive\Users", $env:LOCALAPPDATA, '', '   ', $null)) {
        Verdade (-not (Testar-CaminhoLimpeza $c)) "deveria recusar: '$c'"
    }
}
Teste "aceita os alvos reais da limpeza" {
    foreach ($a in $script:AlvosLimpeza) { Verdade (Testar-CaminhoLimpeza (& $a.Caminho)) "deveria aceitar: $($a.Id) = $(& $a.Caminho)" }
}
Teste "Limpar-Pasta lanca excecao para caminho proibido (nao apaga nada)" {
    $e = $null; try { $null = Limpar-Pasta $env:USERPROFILE } catch { $e = $_.Exception.Message }
    Verdade ($e -like '*não permitido*') "nao recusou o perfil do usuario: $e"
}

Write-Host ""
Write-Host "== Limpeza: medir e limpar ==" -ForegroundColor Cyan
function NovaPastaTeste { $d = Join-Path $tmp ("limpa_" + [guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory "$d\sub\fundo" | Out-Null; $d }
Teste "Medir-Alvo soma bytes e arquivos recursivamente" {
    $d = NovaPastaTeste
    [IO.File]::WriteAllBytes("$d\a.tmp", (New-Object byte[] 1000)); [IO.File]::WriteAllBytes("$d\sub\fundo\b.tmp", (New-Object byte[] 2000))
    $m = Medir-Alvo $d
    Igual $m.Bytes 3000; Igual $m.Arquivos 2; Verdade $m.Existe "Existe deveria ser true"
}
Teste "Medir-Alvo de pasta inexistente: Existe=false, sem erro" { $m = Medir-Alvo (Join-Path $tmp 'nao_existe_xyz'); Verdade (-not $m.Existe) "Existe deveria ser false"; Igual $m.Bytes 0 }
Teste "Limpar-Pasta remove arquivos e subpastas e informa o tamanho liberado" {
    $d = NovaPastaTeste
    [IO.File]::WriteAllBytes("$d\a.tmp", (New-Object byte[] 5000)); [IO.File]::WriteAllBytes("$d\sub\fundo\b.tmp", (New-Object byte[] 5000))
    $r = Limpar-Pasta $d
    Igual $r.BytesLiberados 10000; Igual $r.ArquivosRemovidos 2; Igual $r.Restantes 0
    Igual @(Get-ChildItem $d -Force).Count 0
    Verdade (Test-Path $d) "a pasta em si deve permanecer"
}
Teste "Limpar-Pasta PRESERVA os arquivos do proprio WinHealth (winhealth_*) (regressao)" {
    $d = NovaPastaTeste
    [IO.File]::WriteAllText("$d\winhealth_123.ps1", "script em uso"); [IO.File]::WriteAllText("$d\winhealth_cmd_ab.txt", "x"); [IO.File]::WriteAllText("$d\lixo.tmp", "y")
    $r = Limpar-Pasta $d @('winhealth_*')
    Verdade (Test-Path "$d\winhealth_123.ps1") "apagou o script do WinHealth"
    Verdade (Test-Path "$d\winhealth_cmd_ab.txt") "apagou temporario do wrapper"
    Verdade (-not (Test-Path "$d\lixo.tmp")) "deveria ter apagado o lixo"
    Igual $r.Restantes 0 "(itens excluidos nao contam como 'em uso')"
}
Teste "arquivo em uso (bloqueado) e mantido e reportado, sem excecao" {
    $d = NovaPastaTeste
    [IO.File]::WriteAllText("$d\livre.tmp", "x"); [IO.File]::WriteAllText("$d\preso.tmp", "y")
    $fs = [IO.File]::Open("$d\preso.tmp", 'Open', 'ReadWrite', 'None')
    try { $r = Limpar-Pasta $d } finally { $fs.Dispose() }
    Verdade (Test-Path "$d\preso.tmp") "arquivo bloqueado sumiu?"
    Verdade (-not (Test-Path "$d\livre.tmp")) "arquivo livre deveria ter sido removido"
    Igual $r.Restantes 1
}
Teste "contagem por item: removidos entram na conta mesmo com arquivo grande preso e arquivos vazios (regressao print Limpeza)" {
    $d = NovaPastaTeste
    [IO.File]::WriteAllBytes("$d\preso.tmp", (New-Object byte[] 4000)); [IO.File]::WriteAllBytes("$d\sub\vazio1.tmp", (New-Object byte[] 0)); [IO.File]::WriteAllBytes("$d\vazio2.tmp", (New-Object byte[] 0))
    $fs = [IO.File]::Open("$d\preso.tmp", 'Open', 'ReadWrite', 'None')
    try { $r = Limpar-Pasta $d } finally { $fs.Dispose() }
    Igual $r.ArquivosRemovidos 2; Igual $r.Restantes 1; Igual $r.BytesLiberados 0
    Igual (Interpretar-Limpeza 'X' $r).Severidade 'Ok'
}
Teste "NAO segue junction: o conteudo do destino do link e preservado (regressao)" {
    $d = NovaPastaTeste; $alvoFora = Join-Path $tmp ("fora_" + [guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory $alvoFora | Out-Null
    [IO.File]::WriteAllText("$alvoFora\precioso.txt", "nao apague")
    $null = cmd /c mklink /J "$d\sub\atalho" "$alvoFora" 2>&1
    $r = Limpar-Pasta $d
    Verdade (Test-Path "$alvoFora\precioso.txt") "APAGOU o conteudo do destino da junction!"
    Verdade ($r.Ignorados -ge 1) "a pasta com junction deveria ser ignorada e contada"
}
Teste "Formatar-Tamanho" {
    Verdade ((Formatar-Tamanho 512) -like '512 B') "bytes"
    Verdade ((Formatar-Tamanho 5MB) -like '5 MB') "MB"
    Verdade ((Formatar-Tamanho 3GB) -like '3?00 GB') "GB: $(Formatar-Tamanho 3GB)"
}

Write-Host ""
Write-Host "== Limpeza: interpretacao ==" -ForegroundColor Cyan
Teste "liberou espaco = Ok; ja limpo = Info; tudo em uso = Atencao; nulo = Indisponivel" {
    Igual (Interpretar-Limpeza 'X' ([pscustomobject]@{ BytesLiberados = 5MB; ArquivosRemovidos = 3; Restantes = 0; Ignorados = 0 })).Severidade 'Ok'
    Igual (Interpretar-Limpeza 'X' ([pscustomobject]@{ BytesLiberados = 0; ArquivosRemovidos = 0; Restantes = 0; Ignorados = 0 })).Severidade 'Info'
    Igual (Interpretar-Limpeza 'X' ([pscustomobject]@{ BytesLiberados = 0; ArquivosRemovidos = 0; Restantes = 4; Ignorados = 0 })).Severidade 'Atencao'
    Igual (Interpretar-Limpeza 'X' $null).Severidade 'Indisponivel'
}
Teste "liberou espaco mas deixou arquivos em uso: Ok com aviso no detalhe" {
    $r = Interpretar-Limpeza 'X' ([pscustomobject]@{ BytesLiberados = 1MB; ArquivosRemovidos = 1; Restantes = 2; Ignorados = 0 })
    Igual $r.Severidade 'Ok'; Verdade ($r.Detalhe -like '*em uso*') "sem aviso"
}
Teste "Inicializacao: mais de 8 = Atencao; ate 8 = sem alerta" {
    $muitos = 1..9 | ForEach-Object { [pscustomobject]@{ Nome = "app$_"; Origem = 'Run' } }
    Verdade (@(Interpretar-Inicializacao $muitos | Where-Object { $_.Severidade -eq 'Atencao' }).Count -eq 1) "9 itens deveriam gerar Atencao"
    Igual @(Interpretar-Inicializacao @($muitos | Select-Object -First 8) | Where-Object { $_.Severidade -eq 'Atencao' }).Count 0
}
Teste "a limpeza do Windows Update nao roda em cima de instalacao (regra na tabela)" {
    $wu = $script:AlvosLimpeza | Where-Object { $_.Id -eq 'WinUpdate' }
    Verdade ($wu.Admin) "WU deveria exigir admin"
    Verdade (@($wu.Servicos) -contains 'wuauserv') "deveria parar/restaurar wuauserv"
}

Write-Host ""
Write-Host "== Relatorio completo ==" -ForegroundColor Cyan
Teste "Res tem o campo Arquivo (opcional) sem quebrar os demais" {
    $r = Res 'C' 'Ok' 'T' 'D' 'R' 'a.html'; Igual $r.Arquivo 'a.html'
    Igual (Res 'C' 'Ok' 'T').Arquivo ''
}
Teste "arquivo gerado = Ok com link; ausente = Indisponivel com a ultima mensagem real" {
    $ok = Interpretar-ArquivoGerado 'C' 'Bateria' 0 $true 'bateria.html' ''
    Igual $ok.Severidade 'Ok'; Igual $ok.Arquivo 'bateria.html'
    $no = Interpretar-ArquivoGerado 'C' 'Wi-Fi' 1 $false 'wifi.html' "linha1`nO serviço WLAN não está em execução." 'Não foi possível gerar.' 'Tente como admin.'
    Igual $no.Severidade 'Indisponivel'; Verdade ($no.Detalhe -like '*WLAN*') "sem a mensagem real"; Igual $no.Recomendacao 'Tente como admin.'
}
Teste "Novo-HtmlDrivers: escapa HTML, ordena por classe e marca driver com mais de 3 anos" {
    $drv = @(
        [pscustomobject]@{ DeviceName = '<img src=x onerror=alert(1)>'; DeviceClass = 'ZZ'; Manufacturer = 'Fab'; DriverVersion = '1.0'; DriverDate = (Get-Date).AddYears(-6) },
        [pscustomobject]@{ DeviceName = 'Placa de video'; DeviceClass = 'AA'; Manufacturer = 'NVIDIA'; DriverVersion = '31.0'; DriverDate = (Get-Date).AddMonths(-2) })
    $h = Novo-HtmlDrivers $drv 'PC-01'
    Verdade (-not $h.Contains('<img src=x')) "HTML cru do nome do dispositivo"
    Verdade ($h.Contains('&lt;img src=x')) "nao escapou"
    Verdade ($h.IndexOf('Placa de video') -lt $h.IndexOf('&lt;img')) "ordem por classe (AA antes de ZZ)"
    Verdade ($h -like '*mais de 3 anos*') "faltou marcar driver antigo"
    Verdade (([regex]::Matches($h, 'mais de 3 anos')).Count -eq 1) "so o driver de 6 anos deveria ser marcado"
}
Teste "Novo-HtmlDrivers nao marca como antigo o driver nativo da Microsoft (regressao)" {
    $h = Novo-HtmlDrivers @([pscustomobject]@{ DeviceName = 'Microsoft AC Adapter'; DeviceClass = 'BATTERY'; Manufacturer = 'Microsoft'; DriverVersion = '10.0'; DriverDate = (Get-Date).AddYears(-20) }) 'PC'
    Verdade ($h -notlike '*mais de 3 anos*') "driver nativo foi marcado como antigo"
}
Teste "Novo-HtmlDrivers tolera driver sem data" {
    $h = Novo-HtmlDrivers @([pscustomobject]@{ DeviceName = 'X'; DeviceClass = 'C'; Manufacturer = ''; DriverVersion = ''; DriverDate = $null }) 'PC'
    Verdade ($h -like '*<td>X</td>*') "linha ausente"
}
Teste "indice: links relativos e escapados, contagem e item nao gerado com 'O que fazer'" {
    $arq = Join-Path $tmp 'idx.html'
    $itens = @(
        (Res 'C' 'Ok' 'Diagnóstico' 'Resultado: 0 problema(s).' '' 'diagnostico.html'),
        (Res 'C' 'Indisponivel' 'Energia' 'Exige administrador.' 'Reabra como administrador.'),
        (Res 'C' 'Info' 'Bateria' 'Sem bateria.'),
        (Res 'C' 'Ok' '<b>x</b>' '' '' 'a"b.html'))
    Exportar-IndiceRelatorio $itens ([ordered]@{ 'Computador' = 'PC-<01>' }) $arq
    $h = [IO.File]::ReadAllText($arq)
    Verdade ($h -like '*href="diagnostico.html"*') "link relativo ausente"
    Verdade (-not $h.Contains('a"b.html')) "aspas do nome de arquivo nao escapadas (quebra o atributo href)"
    Verdade (-not $h.Contains('<b>x</b>')) "titulo nao escapado"
    Verdade (-not $h.Contains('PC-<01>')) "nome da maquina nao escapado"
    Verdade ($h -like '*2 de 4 relatório(s) gerado(s)*') "contagem errada"
    Verdade ($h -like '*O que fazer:</strong> Reabra*') "faltou recomendacao do item nao gerado"
    Verdade ($h -like '*hero attn*') "com item nao gerado o cabecalho deveria ser attn"
}
Teste "indice sem falhas usa cabecalho ok" {
    $arq = Join-Path $tmp 'idx2.html'
    Exportar-IndiceRelatorio @((Res 'C' 'Ok' 'A' '' '' 'a.html')) ([ordered]@{}) $arq
    Verdade ([IO.File]::ReadAllText($arq) -like '*hero ok*') "esperava hero ok"
}
Teste "Coletar-Diagnostico devolve os resultados dos checks na ordem e define infoMaquina" {
    $backup = $script:ChecksDiagnostico
    function TesteA { Res 'Cat A' 'Ok' 'a1'; Res 'Cat A' 'Info' 'a2' }
    function TesteB { Res 'Cat B' 'Problema' 'b1'; 'lixo-no-pipeline' }
    $script:ChecksDiagnostico = @(@{ Rotulo = 'a'; Funcao = 'TesteA' }, @{ Rotulo = 'b'; Funcao = 'TesteB' })
    try {
        $r = @(Coletar-Diagnostico)
        Igual $r.Count 3 "(texto solto no pipeline deve ser descartado)"
        Igual $r[0].Titulo 'a1'; Igual $r[2].Titulo 'b1'
    } finally { $script:ChecksDiagnostico = $backup; Remove-Item Function:\TesteA, Function:\TesteB }
}
Teste "Coletar-Diagnostico: -OnProgresso avisa de CADA check, em ordem, com indice/total corretos (base da barra de progresso real)" {
    $backup = $script:ChecksDiagnostico
    function TesteA { Res 'Cat A' 'Ok' 'a1' }
    function TesteB { Res 'Cat B' 'Ok' 'b1' }
    $script:ChecksDiagnostico = @(@{ Rotulo = 'primeiro'; Funcao = 'TesteA' }, @{ Rotulo = 'segundo'; Funcao = 'TesteB' })
    $avisos = New-Object System.Collections.Generic.List[object]
    try {
        $null = Coletar-Diagnostico -OnProgresso { param($Rotulo, $I, $N) $avisos.Add(@{ Rotulo = $Rotulo; I = $I; N = $N }) }
        Igual $avisos.Count 2
        Igual $avisos[0].Rotulo 'primeiro'; Igual $avisos[0].I 1; Igual $avisos[0].N 2
        Igual $avisos[1].Rotulo 'segundo'; Igual $avisos[1].I 2; Igual $avisos[1].N 2
    } finally { $script:ChecksDiagnostico = $backup; Remove-Item Function:\TesteA, Function:\TesteB }
}

Write-Host ""
Write-Host "== Scanner anti-minerador (launcher autoextraivel) ==" -ForegroundColor Cyan
$arqScanner = Join-Path $raiz 'Recursos\Ferramentas\SCANNER ANTI-MINERADOR v4.bat'
Teste "o numero do '-Skip N' bate com a linha do marcador PSSTART_MARKER (acoplamento fragil)" {
    $l = @(Get-Content -LiteralPath $arqScanner -Encoding UTF8)
    $idx = [Array]::FindIndex([string[]]$l, [Predicate[string]]{ param($x) $x -match '^rem PSSTART_MARKER' })
    Verdade ($idx -ge 0) "marcador ausente"
    $m = [regex]::Match(($l -join "`n"), 'Select-Object -Skip (\d+)')
    Verdade $m.Success "sem Skip no launcher"
    Igual ([int]$m.Groups[1].Value) ($idx + 1) "(o Skip deve ser a linha do marcador; se voce adicionou linhas no cabecalho, ajuste)"
}
Teste "Modulo-Scanner (console): so usa -Verb RunAs quando NAO esta admin (regressao: -Verb RunAs com -ArgumentList falha silenciosamente se quem chama ja esta elevado, achado ao vivo em 28/09/2026)" {
    $src = [IO.File]::ReadAllText((Join-Path $raiz 'WinHealth.ps1'))
    $m = [regex]::Match($src, '(?s)function Modulo-Scanner \{.*?\n\}')
    Verdade $m.Success "Modulo-Scanner nao encontrada"
    Verdade ($m.Value -match '\bif \(\$isAdmin\)') "nao pula -Verb RunAs quando ja admin"
}
Teste "o scanner aceita -PastaSaida e o launcher repassa o argumento" {
    $t = Get-Content -LiteralPath $arqScanner -Raw -Encoding UTF8
    Verdade ($t -match 'param\(\[string\]\$PastaSaida') "param PastaSaida ausente"
    Verdade ($t -match '-File "%TMPPS%" -PastaSaida "%~1"') "launcher nao repassa a pasta"
    Verdade ($t -match 'resultado_scanner_antiminerador\.txt') "fallback para o Desktop removido (uso avulso quebraria)"
}
Teste "o script do scanner tem sintaxe valida (trecho depois do marcador)" {
    $l = @(Get-Content -LiteralPath $arqScanner -Encoding UTF8)
    $idx = [Array]::FindIndex([string[]]$l, [Predicate[string]]{ param($x) $x -match '^rem PSSTART_MARKER' })
    $errs = $null
    [void][Management.Automation.Language.Parser]::ParseInput((($l | Select-Object -Skip ($idx + 1)) -join "`n"), [ref]$null, [ref]$errs)
    Igual @($errs).Count 0 "$(@($errs | ForEach-Object { $_.Message }) -join ' | ')"
}
Teste "o scanner grava o marcador SCANNER_CONCLUIDO no log como ultima acao (a GUI depende dele pra saber que terminou, ver Rodar-ScannerGui)" {
    $t = Get-Content -LiteralPath $arqScanner -Raw -Encoding UTF8
    Verdade ($t -match 'Add-Content -Path \$logfile -Value "SCANNER_CONCLUIDO"') "marcador de conclusao ausente no scanner"
    Verdade ($t.IndexOf('SCANNER_CONCLUIDO') -gt $t.LastIndexOf('Read-Host "Sua escolha"')) "marcador deveria vir DEPOIS da remocao interativa, nao antes"
}

Write-Host ""
Write-Host "== Log de diagnostico (caixa-preta) ==" -ForegroundColor Cyan
Teste "Obter-ConteudoLogDiagnostico: sem arquivo nenhum, devolve mensagem amigavel (nao erro/vazio)" {
    Remove-Item -Path $script:pastaLogDiagnostico -Recurse -Force -ErrorAction SilentlyContinue
    Verdade ((Obter-ConteudoLogDiagnostico) -like '*Nenhum evento*') "nao avisou que nao ha log ainda"
}
Teste "Escrever-LogDiagnostico: grava linha real no arquivo com nivel, timestamp e mensagem (contra o disco de verdade, nao mockado)" {
    Remove-Item -Path $script:pastaLogDiagnostico -Recurse -Force -ErrorAction SilentlyContinue
    Escrever-LogDiagnostico -Nivel 'ERRO' -Mensagem 'algo deu errado de propósito'
    Verdade (Test-Path $script:arquivoLogDiagnostico) "arquivo de log nao foi criado"
    $conteudo = Get-Content -LiteralPath $script:arquivoLogDiagnostico -Raw
    Verdade ($conteudo -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} - ERRO - algo deu errado de propósito') "formato da linha nao bate: $conteudo"
    Verdade ((Obter-ConteudoLogDiagnostico) -eq $conteudo) "Obter-ConteudoLogDiagnostico nao leu o mesmo conteudo gravado"
}
Teste "Escrever-LogDiagnostico: nao derruba o resto do programa se a pasta nao puder ser criada (engole erro, so nao grava)" {
    $antigo = $script:pastaLogDiagnostico
    try {
        $script:pastaLogDiagnostico = 'Z:\caminho\que\nao\existe\de\jeito\nenhum'
        $script:arquivoLogDiagnostico = Join-Path $script:pastaLogDiagnostico 'x.log'
        Escrever-LogDiagnostico -Nivel 'INFO' -Mensagem 'nao deveria lancar excecao'
    } finally {
        $script:pastaLogDiagnostico = $antigo
        $script:arquivoLogDiagnostico = Join-Path $antigo 'winhealth_debug.log'
    }
}
Teste "Escrever-LogDiagnostico: quando passa do tamanho maximo, mantem so as linhas mais recentes (nao cresce sem limite)" {
    Remove-Item -Path $script:pastaLogDiagnostico -Recurse -Force -ErrorAction SilentlyContinue
    $tamanhoAntigo = $script:tamanhoMaximoLogDiagnostico
    $linhasAntigo = $script:linhasManterLogDiagnostico
    try {
        $script:tamanhoMaximoLogDiagnostico = 200
        $script:linhasManterLogDiagnostico = 5
        1..30 | ForEach-Object { Escrever-LogDiagnostico -Nivel 'DEBUG' -Mensagem "linha de enchimento numero $_ soh pra passar do limite" }
        $linhas = @(Get-Content -LiteralPath $script:arquivoLogDiagnostico)
        Verdade ($linhas.Count -lt 30) "nao truncou (ainda tem todas as 30 linhas): $($linhas.Count)"
        Verdade ($linhas[-1] -like '*linha de enchimento numero 30*') "a linha mais RECENTE deveria ter sobrevivido ao corte"
    } finally {
        $script:tamanhoMaximoLogDiagnostico = $tamanhoAntigo
        $script:linhasManterLogDiagnostico = $linhasAntigo
    }
}

Write-Host ""
Write-Host "== Acesso / administrador ==" -ForegroundColor Cyan
Teste "elevado = Admin" { Igual (Obter-EstadoAcesso $true $true) 'Admin' }
Teste "conta admin sem elevacao = LimitadoElevavel" { Igual (Obter-EstadoAcesso $false $true) 'LimitadoElevavel' }
Teste "conta comum = LimitadoPadrao" { Igual (Obter-EstadoAcesso $false $false) 'LimitadoPadrao' }
function whoami { $script:whoamiSaida }
Teste "grupo Administradores 'usado apenas para negar' (UAC) conta como conta admin (regressao)" {
    $script:whoamiSaida = @('BUILTIN\Administradores   Alias   S-1-5-32-544   Grupo usado apenas para negar', 'Everyone   Grupo bem conhecido   S-1-1-0   Grupo obrigatorio')
    Igual (Test-ContaNoGrupoAdmin) $true
}
Teste "conta sem o grupo Administradores nao e conta admin" {
    $script:whoamiSaida = @('Everyone   Grupo bem conhecido   S-1-1-0   Grupo obrigatorio', 'BUILTIN\Users   Alias   S-1-5-32-545   Grupo obrigatorio')
    Igual (Test-ContaNoGrupoAdmin) $false
}
Remove-Item Function:\whoami
Teste "todo item do menu aponta para uma funcao existente" {
    foreach ($i in $script:Menu) { Verdade (Get-Command $i.Acao -CommandType Function -ErrorAction SilentlyContinue) "funcao ausente: $($i.Acao)" }
}
Teste "chaves do menu sao unicas e Admin so usa valores validos" {
    Igual (@($script:Menu | ForEach-Object { $_.Chave } | Select-Object -Unique).Count) $script:Menu.Count
    foreach ($i in $script:Menu) { Verdade (@('Nao', 'Parcial', 'Sim') -contains $i.Admin) "Admin invalido em $($i.Chave)" }
}

Write-Host ""
Write-Host "== Relatorio HTML ==" -ForegroundColor Cyan
Teste "escapa HTML vindo de dispositivo/maquina (anti-XSS)" {
    $arq = Join-Path $tmp 'xss.html'
    $malicioso = '<script>alert(1)</script>'
    $rs = @((Res 'Cat' 'Problema' $malicioso $malicioso $malicioso))
    Exportar-RelatorioHtml $rs ([ordered]@{ 'Computador' = $malicioso }) $arq
    $html = [IO.File]::ReadAllText($arq)
    Verdade (-not $html.Contains('<script>alert')) "script cru no HTML"
    Verdade ($html.Contains('&lt;script&gt;alert(1)&lt;/script&gt;')) "texto nao foi escapado"
}
Teste "veredito reflete a pior severidade" {
    $arq = Join-Path $tmp 'v.html'
    Exportar-RelatorioHtml @((Res 'C' 'Ok' 'a'), (Res 'C' 'Atencao' 'b')) ([ordered]@{}) $arq
    Verdade ([IO.File]::ReadAllText($arq) -like '*hero attn*') "esperava hero attn"
    Exportar-RelatorioHtml @((Res 'C' 'Ok' 'a'), (Res 'C' 'Problema' 'b')) ([ordered]@{}) $arq
    Verdade ([IO.File]::ReadAllText($arq) -like '*hero prob*') "esperava hero prob"
    Exportar-RelatorioHtml @((Res 'C' 'Ok' 'a')) ([ordered]@{}) $arq
    Verdade ([IO.File]::ReadAllText($arq) -like '*hero ok*') "esperava hero ok"
}
Teste "categorias saem na ordem de execucao (nao alfabetica)" {
    $arq = Join-Path $tmp 'o.html'
    Exportar-RelatorioHtml @((Res 'Zebra' 'Ok' 'z'), (Res 'Abelha' 'Ok' 'a')) ([ordered]@{}) $arq
    $h = [IO.File]::ReadAllText($arq)
    Verdade ($h.IndexOf('Zebra') -lt $h.IndexOf('Abelha')) "ordem alfabetica indevida"
}
Teste "item nao verificado e contado e nunca vira 'Tudo certo'" {
    $arq = Join-Path $tmp 'n.html'
    Exportar-RelatorioHtml @((Res 'C' 'Indisponivel' 'sem admin')) ([ordered]@{}) $arq
    $h = [IO.File]::ReadAllText($arq)
    Verdade ($h -like '*Não verificado*') "faltou rotulo"
    Verdade ($h -notlike '*Tudo certo*') "indisponivel virou 'Tudo certo'"
}

Write-Host ""
Write-Host "== Janela (GUI) e launcher ==" -ForegroundColor Cyan
$sta = ([Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA')
if (-not $sta) { Write-Host "  [PULADO] testes de janela: o PowerShell nao esta em modo STA" -ForegroundColor DarkYellow }
Teste "toda aba do menu tem nome curto e icone hexadecimal valido" {
    foreach ($m in $script:Menu) {
        Verdade ($m.Aba -and $m.Aba.Length -le 14) "aba curta ausente/longa em $($m.Chave)"
        Verdade ($m.Icone -match '^[0-9A-Fa-f]{4}$') "icone invalido em $($m.Chave): $($m.Icone)"
    }
}
Teste "Obter-JanelasConsoleGui: so pega janela do Windows Terminal com o titulo exato 'WinHealth (console)' (regressao das 'duas guias')" {
    function Get-Process {
        param($Name, $ErrorAction)
        if ($Name -eq 'WindowsTerminal') {
            @(
                [pscustomobject]@{ MainWindowTitle = 'WinHealth (console)'; MainWindowHandle = [IntPtr]123 }
                [pscustomobject]@{ MainWindowTitle = 'WinHealth'; MainWindowHandle = [IntPtr]456 }
                [pscustomobject]@{ MainWindowTitle = 'outro programa qualquer'; MainWindowHandle = [IntPtr]789 }
            )
        }
    }
    $h = @(Obter-JanelasConsoleGui)
    Verdade ($h -contains [IntPtr]123) "nao pegou a janela do Windows Terminal com o titulo certo"
    Verdade (-not ($h -contains [IntPtr]456)) "pegou a janela WPF (titulo 'WinHealth', sem ' (console)') por engano"
    Verdade (-not ($h -contains [IntPtr]789)) "pegou uma janela de outro programa por engano"
}
Teste "launcher: modo -gui usa um titulo de console diferente do titulo da janela WPF (regressao das 'duas guias')" {
    $bat = [IO.File]::ReadAllText((Join-Path $raiz 'WinHealth.bat'))
    Verdade ($bat -like '*title WinHealth (console)*') "faltou o titulo distinto do console em modo gui"
}
Teste "launcher nunca redireciona para /dev/null (cmd nao entende; o del temporario nao rodava) (regressao)" {
    $bat = [IO.File]::ReadAllText((Join-Path $raiz 'WinHealth.bat'))
    Verdade ($bat -notlike '*/dev/*') "sintaxe de Linux no .bat"
    Verdade ($bat -like '*del "%TMPPS%" >nul 2>&1*') "faltou o del do temporario com redirecionamento do Windows"
}
Teste "launcher: argumento gui liga o modo janela e nao pausa no fim" {
    $bat = [IO.File]::ReadAllText((Join-Path $raiz 'WinHealth.bat'))
    Verdade ($bat -like '*"%~1"=="gui"*-Gui*') "gui nao repassa -Gui"
    Verdade ($bat -like '*if defined WHGUI exit /b*') "modo janela nao encerra sem pausa"
    $atalho = [IO.File]::ReadAllText((Join-Path $raiz 'WinHealth Janela.bat'))
    Verdade ($atalho -like '*WinHealth.bat" gui*') "atalho nao chama o launcher com gui"
}
Teste "reabrir como administrador preserva o modo janela e o modulo unico" {
    $src = [IO.File]::ReadAllText((Join-Path $raiz 'WinHealth.ps1'))
    Verdade ($src -like '*if ($Gui) { $argumentos += " -Gui" }*') "perde -Gui ao elevar"
    Verdade ($src -like '*if ($SairAoFinal) { $argumentos += " -SairAoFinal" }*') "perde -SairAoFinal ao elevar"
}
if ($sta) {
    Teste "janela: abre com Painel + uma aba por modulo, sem exibir" {
        $w = Novo-JanelaGui -EstadoAcesso 'Admin'
        Igual $script:GuiNav.Items.Count ($script:Menu.Count + 1)
        Igual $script:GuiNav.Items[0].Tag 'painel'
        Verdade ($null -ne $script:GuiConteudo.Content) "painel nao foi montado"
        Igual $w.FindName('TxtMaquina').Text $nomeMaquina
    }
    Teste "janela: aviso de acesso reflete os 3 estados e so mostra botao quando limitado" {
        $w = Novo-JanelaGui -EstadoAcesso 'Admin'
        Igual $w.FindName('TxtAcesso').Text 'Administrador'; Igual "$($w.FindName('BtnAdmin').Visibility)" 'Collapsed'
        $w = Novo-JanelaGui -EstadoAcesso 'LimitadoElevavel'
        Igual $w.FindName('TxtAcesso').Text 'Modo limitado'; Igual "$($w.FindName('BtnAdmin').Visibility)" 'Visible'
        Igual $w.FindName('BtnAdmin').Content 'Reabrir como administrador'
        $w = Novo-JanelaGui -EstadoAcesso 'LimitadoPadrao'
        Verdade ($w.FindName('TxtAcesso').Text -like 'Conta comum*') "texto da conta comum"
        Igual $w.FindName('BtnAdmin').Content 'Usar conta administradora'
    }
    Teste "janela: tem o botao 'Terminal de Diagnostico' na barra do topo (nao clicado aqui - abre janela modal de verdade, travaria o teste)" {
        $w = Novo-JanelaGui -EstadoAcesso 'Admin'
        $btn = $w.FindName('BtnDiagnostico')
        Verdade ($null -ne $btn) "botao do Terminal de Diagnostico nao existe na janela"
        Igual $btn.Content 'Terminal de Diagnóstico'
    }
    Teste "Novo-JanelaDiagnosticoGui: mostra o conteudo REAL do log (nao mockado) e fecha sem erro ao clicar 'Fechar'" {
        Remove-Item -Path $script:pastaLogDiagnostico -Recurse -Force -ErrorAction SilentlyContinue
        Escrever-LogDiagnostico -Nivel 'INFO' -Mensagem 'evento de teste pro terminal de diagnostico'
        $w = Novo-JanelaDiagnosticoGui
        Verdade ($script:GuiDiagnostico.Log.Text -like '*evento de teste pro terminal de diagnostico*') "janela nao carregou o conteudo real do log"
        $w.FindName('BtnFechar').RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    }
    Teste "Novo-JanelaDiagnosticoGui: sem nenhum log ainda, mostra a mensagem amigavel (nao em branco)" {
        Remove-Item -Path $script:pastaLogDiagnostico -Recurse -Force -ErrorAction SilentlyContinue
        $null = Novo-JanelaDiagnosticoGui
        Verdade ($script:GuiDiagnostico.Log.Text -like '*Nenhum evento*') "nao mostrou a mensagem de log vazio"
    }
    Teste "janela: selecionar uma aba mostra o titulo do modulo" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '3'
        Igual $script:GuiNav.SelectedItem.Tag '3'
        $titulo = $script:GuiConteudo.Content.Children[0].Text
        Igual $titulo (($script:Menu | Where-Object { $_.Chave -eq '3' }).Titulo)
    }
    Teste "janela: clicar num cartao de modulo do Painel abre a aba (handlers enxergam as funcoes)" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui 'painel'
        $modulos = $script:GuiConteudo.Content.Children | Where-Object { $_ -is [System.Windows.Controls.WrapPanel] } | Select-Object -Last 1
        Igual $modulos.Children.Count $script:Menu.Count
        $cartao = $modulos.Children[3]
        $ev = New-Object System.Windows.Input.MouseButtonEventArgs([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
        $ev.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonUpEvent
        $cartao.RaiseEvent($ev)
        Igual $script:GuiNav.SelectedItem.Tag $script:Menu[3].Chave
    }
    Teste "janela: 'Abrir modulo' inicia o console com -IniciarEm N -SairAoFinal e guarda o processo" {
        function Start-Process { param($FilePath, $ArgumentList, [switch]$PassThru, $Verb, [switch]$Wait, $ErrorAction) $script:mockSP = @{ Arq = $FilePath; Args = "$ArgumentList" }; [pscustomobject]@{ HasExited = $false } }
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '8'
        $botao = $script:GuiConteudo.Content.Children[3].Child.Children | Where-Object { $_ -is [System.Windows.Controls.Button] } | Select-Object -First 1
        $botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Verdade ($script:mockSP.Args -like '*-IniciarEm 8 -SairAoFinal*') "argumentos: $($script:mockSP.Args)"
        Igual $script:GuiFilhos.Count 1
    }

    Write-Host ""
    Write-Host "== Aba de Diagnostico (GUI) ==" -ForegroundColor Cyan
    # Le o texto de todo TextBlock/Run dentro de um elemento WPF, recursivamente - pra testar o
    # CONTEUDO renderizado sem depender de indice exato de filho (fragil a mudanca de layout).
    function Textos-Gui {
        param($El)
        $out = New-Object System.Collections.Generic.List[string]
        function Rec($e) {
            if ($null -eq $e) { return }
            if ($e -is [System.Windows.Controls.TextBlock]) {
                if ($e.Text) { $out.Add($e.Text) }
                foreach ($i in $e.Inlines) { if ($i -is [System.Windows.Documents.Run] -and $i.Text) { $out.Add($i.Text) } }
            }
            if ($e.PSObject.Properties['Children']) { foreach ($c in @($e.Children)) { Rec $c } }
            if ($e.PSObject.Properties['Child'] -and $e.Child) { Rec $e.Child }
            if ($e.PSObject.Properties['Content'] -and $e.Content) {
                if ($e.Content -is [string]) { $out.Add($e.Content) } else { Rec $e.Content }
            }
        }
        Rec $El
        , $out
    }

    $resProblema = Res 'Disco' 'Problema' 'C: quase cheio' 'Faltam 5 GB.' 'Rode a limpeza.'
    $resOk = Res 'Disco' 'Ok' 'Saúde SMART normal'
    $resInfo = Res 'Disco' 'Info' 'Modelo' 'SSD X'
    $resIdInfo = Res 'Identificação da máquina' 'Info' 'Computador' 'PC-TESTE'

    Teste "Novo-CartaoResultadoGui: rotulo por severidade + titulo + detalhe + recomendacao" {
        $t = Textos-Gui (Novo-CartaoResultadoGui $resProblema)
        Verdade ($t -contains 'Problema') "faltou rotulo Problema"
        Verdade ($t -contains 'C: quase cheio') "faltou titulo"
        Verdade ($t -contains 'Faltam 5 GB.') "faltou detalhe"
        Verdade (($t -join ' ') -like '*Rode a limpeza.*') "faltou recomendacao"
    }
    Teste "Novo-CartaoResultadoGui: item Ok sem detalhe/recomendacao nao quebra" {
        $t = Textos-Gui (Novo-CartaoResultadoGui $resOk)
        Verdade ($t -contains 'Tudo certo') "faltou rotulo Ok"
        Verdade ($t -contains 'Saúde SMART normal') "faltou titulo"
    }
    Teste "Novo-SecaoDiagnosticoGui: cartoes saem ordenados por severidade (Problema antes de Ok), Info vira linha rotulo/valor" {
        $sec = Novo-SecaoDiagnosticoGui 'Disco' @($resOk, $resProblema, $resInfo)
        $t = Textos-Gui $sec
        Verdade ($t.IndexOf('C: quase cheio') -lt $t.IndexOf('Saúde SMART normal')) "problema deveria vir antes do Ok"
        Verdade ($t -contains 'Modelo') "item Info nao virou linha rotulo/valor"
    }
    Teste "Novo-SecaoDiagnosticoGui: 'Identificação da máquina' nao repete os Infos (ja aparecem no card do topo) (regressao)" {
        Igual (Novo-SecaoDiagnosticoGui 'Identificação da máquina' @($resIdInfo)) $null
    }
    Teste "Novo-SecaoDiagnosticoGui: categoria sem nada pra mostrar volta null" {
        Igual (Novo-SecaoDiagnosticoGui 'Vazia' @()) $null
    }
    Teste "Novo-ResumoDiagnosticoGui: veredito muda com Problema/Atencao/Ok" {
        Verdade ((Textos-Gui (Novo-ResumoDiagnosticoGui @($resProblema))) -contains 'Requer atenção') "veredito de problema"
        Verdade ((Textos-Gui (Novo-ResumoDiagnosticoGui @((Res 'X' 'Atencao' 'a')))) -contains 'Em bom estado, com pontos de melhoria') "veredito de atencao"
        Verdade ((Textos-Gui (Novo-ResumoDiagnosticoGui @((Res 'X' 'Ok' 'a')))) -contains 'Máquina saudável') "veredito ok"
    }

    function Aguardar-TarefaGui {
        param([int]$TimeoutSegundos = 15)
        $frame = New-Object Windows.Threading.DispatcherFrame
        $poll = New-Object Windows.Threading.DispatcherTimer -Property @{ Interval = [TimeSpan]::FromMilliseconds(50) }
        $limite = (Get-Date).AddSeconds($TimeoutSegundos)
        $poll.Add_Tick({ if ($script:tgResultado -or (Get-Date) -gt $limite) { $frame.Continue = $false } }.GetNewClosure())
        $poll.Start()
        [Windows.Threading.Dispatcher]::PushFrame($frame)
        $poll.Stop()
    }
    Teste "Iniciar-TarefaGui: roda em segundo plano (nao trava) e devolve o resultado na thread da UI" {
        $script:tgResultado = $null
        $null = Iniciar-TarefaGui -Script { 21 * 2 } -OnConcluir { param($Saida, $Erro) $script:tgResultado = @{ Saida = $Saida; Erro = $Erro } }
        Aguardar-TarefaGui
        Verdade ($null -ne $script:tgResultado) "OnConcluir nunca foi chamado (timeout)"
        Igual $script:tgResultado.Saida[0] 42
        Igual $script:tgResultado.Erro $null
    }
    Teste "Iniciar-TarefaGui: excecao no script vira Erro, sem travar a fila de eventos" {
        $script:tgResultado = $null
        $null = Iniciar-TarefaGui -Script { throw 'falhou de proposito' } -OnConcluir { param($Saida, $Erro) $script:tgResultado = @{ Erro = $Erro } }
        Aguardar-TarefaGui
        Verdade ($null -ne $script:tgResultado) "OnConcluir nunca foi chamado (timeout)"
        Verdade ("$($script:tgResultado.Erro)" -like '*falhou de proposito*') "mensagem de erro perdida: $($script:tgResultado.Erro)"
    }
    Teste "Iniciar-TarefaGui: quando a tarefa de fundo falha, o erro fica registrado no log de diagnostico (caixa-preta) - contra o disco de verdade" {
        Remove-Item -Path $script:pastaLogDiagnostico -Recurse -Force -ErrorAction SilentlyContinue
        $script:tgResultado = $null
        $null = Iniciar-TarefaGui -Script { throw 'falha registrada no log' } -OnConcluir { param($Saida, $Erro) $script:tgResultado = @{ Erro = $Erro } }
        Aguardar-TarefaGui
        Verdade ($null -ne $script:tgResultado) "OnConcluir nunca foi chamado (timeout)"
        Verdade (Test-Path $script:arquivoLogDiagnostico) "a falha nao gerou nenhuma entrada no log de diagnostico"
        $conteudo = Get-Content -LiteralPath $script:arquivoLogDiagnostico -Raw
        Verdade ($conteudo -like '*ERRO*falha registrada no log*') "log nao contem a mensagem real do erro: $conteudo"
    }
    Teste "Iniciar-TarefaGui: -OnTick recebe segundos DECORRIDOS reais (nao uma estimativa), enquanto a tarefa ainda roda" {
        $script:tgTicks = New-Object System.Collections.Generic.List[int]
        $script:tgResultado = $null
        $null = Iniciar-TarefaGui -Script { Start-Sleep -Milliseconds 700; 1 } -OnConcluir { param($Saida, $Erro) $script:tgResultado = @{ Saida = $Saida } } -OnTick { param($Seg) $script:tgTicks.Add($Seg) }
        Aguardar-TarefaGui
        Verdade ($null -ne $script:tgResultado) "OnConcluir nunca foi chamado (timeout)"
        Verdade ($script:tgTicks.Count -gt 0) "OnTick nunca disparou enquanto a tarefa rodava"
        Verdade (($script:tgTicks | Where-Object { $_ -lt 0 }).Count -eq 0) "segundos negativos (nao pode - e tempo decorrido real)"
    }

    # A partir daqui, Iniciar-TarefaGui e substituida por um mock que so CAPTURA o script e o
    # OnConcluir (sem rodar de verdade - Coletar-Diagnostico real bate no hardware, o que tornaria
    # o teste lento e dependente da maquina). O OnConcluir capturado e chamado manualmente com dados
    # falsos, exatamente como o Iniciar-TarefaGui real faria ao terminar.
    function Iniciar-TarefaGui { param($Script, $OnConcluir, $OnProgresso, $Fila, $OnTick) $script:tgCapturado = @{ Script = $Script.ToString(); OnConcluir = $OnConcluir; OnProgresso = $OnProgresso; Fila = $Fila; OnTick = $OnTick } }

    Teste "aba de Diagnostico: 'Rodar diagnostico' chama Iniciar-TarefaGui com um script que roda Coletar-Diagnostico" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '1'
        $botao = $script:GuiConteudo.Content.Children[3].Children[0]
        Igual $botao.Content 'Rodar diagnóstico'
        $botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Verdade ($script:tgCapturado.Script -like '*-CarregarSomente*') "nao dot-source com -CarregarSomente: $($script:tgCapturado.Script)"
        Verdade ($script:tgCapturado.Script -like '*Coletar-Diagnostico*') "nao chama Coletar-Diagnostico"
        Igual $botao.IsEnabled $false
        Verdade ($script:GuiDiag.Status.Text -like '*Coletando*') "status nao mudou ao clicar: $($script:GuiDiag.Status.Text)"
    }
    Teste "aba de Diagnostico: progresso REAL - barra e log so avancam quando o OnProgresso chega, nunca sozinhos (regressao contra progresso simulado)" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '1'
        $botao = $script:GuiConteudo.Content.Children[3].Children[0]
        $botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Igual "$($script:GuiDiag.Progresso.Visibility)" 'Visible'
        Igual $script:GuiDiag.Barra.Maximum ([double]@($script:ChecksDiagnostico).Count)
        Igual $script:GuiDiag.Barra.Value 0.0
        Igual $script:GuiDiag.Log.Children.Count 0
        Verdade ($null -ne $script:tgCapturado.OnProgresso) "Iniciar-TarefaGui nao recebeu -OnProgresso"
        Verdade ($null -ne $script:tgCapturado.Fila) "Iniciar-TarefaGui nao recebeu -Fila"

        & $script:tgCapturado.OnProgresso ([pscustomobject]@{ I = 3; N = 10; Rotulo = 'saúde do disco' })
        Igual $script:GuiDiag.Barra.Value 3.0
        Verdade ($script:GuiDiag.Status.Text -like '*3/10*sa*disco*') "status nao mostrou o passo real: $($script:GuiDiag.Status.Text)"
        Igual $script:GuiDiag.Log.Children.Count 1

        & $script:tgCapturado.OnProgresso ([pscustomobject]@{ I = 4; N = 10; Rotulo = 'espaço em disco' })
        Igual $script:GuiDiag.Barra.Value 4.0
        Igual $script:GuiDiag.Log.Children.Count 2

        $pacote = [pscustomobject]@{ Itens = @((Res 'Disco' 'Ok' 'tudo bem')); Info = [ordered]@{} }
        & $script:tgCapturado.OnConcluir @($pacote) $null
        Igual "$($script:GuiDiag.Progresso.Visibility)" 'Collapsed'
    }
    Teste "aba de Diagnostico: -OnTick mostra 'rodando ha Xs' com tempo real, sem inventar tempo restante (pedido do Gabriel apos achar o status repetitivo)" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '1'
        $botao = $script:GuiConteudo.Content.Children[3].Children[0]
        $botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Verdade ($null -ne $script:tgCapturado.OnTick) "Iniciar-TarefaGui nao recebeu -OnTick"

        & $script:tgCapturado.OnTick 0
        Verdade ($script:GuiDiag.Status.Text -like '*Coletando informações da máquina*rodando há 0s*') "status sem o tempo decorrido antes do 1o passo: $($script:GuiDiag.Status.Text)"

        & $script:tgCapturado.OnProgresso ([pscustomobject]@{ I = 3; N = 10; Rotulo = 'saúde do disco' })
        & $script:tgCapturado.OnTick 7
        Verdade ($script:GuiDiag.Status.Text -like '*3/10*sa*disco*rodando há 7s*') "status nao combinou o passo atual com o tempo decorrido: $($script:GuiDiag.Status.Text)"
    }
    Teste "aba de Diagnostico: ao concluir, preenche o MESMO painel visivel na aba (regressao do bug de closure sobre escopo de funcao)" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '1'
        $abaRoot = $script:GuiConteudo.Content
        $botao = $abaRoot.Children[3].Children[0]
        $botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $pacote = [pscustomobject]@{ Itens = @((Res 'Disco' 'Ok' 'tudo bem')); Info = [ordered]@{ Computador = 'PC-TESTE' } }
        & $script:tgCapturado.OnConcluir @($pacote) $null
        Igual $botao.IsEnabled $true
        Verdade ($script:GuiDiag.Status.Text -like 'Última execução:*') "status nao virou 'ultima execucao': $($script:GuiDiag.Status.Text)"
        Igual $script:GuiUltimoDiagnostico.Itens.Count 1
        Verdade ($script:GuiDiag.Resultado.Children.Count -gt 0) "painel de resultado ficou vazio (bug de closure)"
        Verdade (@($abaRoot.Children) | Where-Object { [object]::ReferenceEquals($_, $script:GuiDiag.Resultado) }) "GuiDiag.Resultado nao e um painel que esta na tela"
    }
    Teste "aba de Diagnostico: erro na coleta mostra a mensagem, reabilita o botao e nao apaga o ultimo resultado bom" {
        $script:GuiUltimoDiagnostico = $null
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '1'
        $botao = $script:GuiConteudo.Content.Children[3].Children[0]
        $botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        & $script:tgCapturado.OnConcluir $null ([pscustomobject]@{ Exception = [pscustomobject]@{ Message = 'falha simulada' } })
        Igual $botao.IsEnabled $true
        Verdade ($script:GuiDiag.Status.Text -like '*falha simulada*') "mensagem de erro nao chegou na tela: $($script:GuiDiag.Status.Text)"
        Igual $script:GuiUltimoDiagnostico $null
    }
    Teste "aba de Diagnostico: botao 'Abrir Windows Update' so aparece quando ha driver desatualizado (Atencao) nos resultados" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '1'
        Preencher-ResultadoDiagnosticoGui $script:GuiDiag.Resultado @((Res 'Disco' 'Ok' 'tudo bem')) ([ordered]@{})
        Verdade (-not ((Textos-Gui $script:GuiDiag.Resultado) -contains 'Abrir Windows Update (Atualizações opcionais)')) "botao apareceu sem nenhum driver desatualizado"

        Preencher-ResultadoDiagnosticoGui $script:GuiDiag.Resultado @((Res 'Atualizações de driver' 'Atencao' 'Driver desatualizado: X')) ([ordered]@{})
        Verdade ((Textos-Gui $script:GuiDiag.Resultado) -contains 'Abrir Windows Update (Atualizações opcionais)') "botao nao apareceu com driver desatualizado"
    }
    Teste "Mostrar-AbaGui: chave 1=Diagnostico, 2=Scanner, 3=Reparo, 4=Limpeza, 7=USB, as outras continuam com 'Abrir modulo'" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Mostrar-AbaGui '1'
        Verdade ((Textos-Gui $script:GuiConteudo.Content) -contains 'Rodar diagnóstico') "aba 1 nao virou a de Diagnostico"
        Mostrar-AbaGui '2'
        Verdade ((Textos-Gui $script:GuiConteudo.Content) -contains 'Rodar Scanner') "aba 2 nao virou a de Scanner"
        Mostrar-AbaGui '3'
        Verdade ((Textos-Gui $script:GuiConteudo.Content) -contains 'Rodar reparo do Windows') "aba 3 nao virou a de Reparo"
        Mostrar-AbaGui '4'
        Verdade ((Textos-Gui $script:GuiConteudo.Content) -contains 'Calcular o que pode ser liberado') "aba 4 nao virou a de Limpeza"
        Mostrar-AbaGui '7'
        Verdade ((Textos-Gui $script:GuiConteudo.Content) -contains 'Verificar USB') "aba 7 nao virou a de USB"
        Mostrar-AbaGui '5'
        Verdade ((Textos-Gui $script:GuiConteudo.Content) -contains 'Abrir módulo') "aba 5 deveria continuar generica"
    }

    Write-Host ""
    Write-Host "== Aba de Limpeza (GUI) ==" -ForegroundColor Cyan
    Teste "Novo-LinhaAlvoLimpezaGui: mostra tamanho quando Ok, e o motivo quando nao" {
        Verdade ((Textos-Gui (Novo-LinhaAlvoLimpezaGui ([pscustomobject]@{ Rotulo = 'Temp'; Estado = 'Ok'; Bytes = 5MB; Arquivos = 3 }))) -join ' ') -like '*5 MB (3 arquivos)*'
        Verdade ((Textos-Gui (Novo-LinhaAlvoLimpezaGui ([pscustomobject]@{ Rotulo = 'X'; Estado = 'RequerAdmin'; Bytes = 0; Arquivos = 0 }))) -contains 'Requer administrador')
        Verdade ((Textos-Gui (Novo-LinhaAlvoLimpezaGui ([pscustomobject]@{ Rotulo = 'X'; Estado = 'NaoExiste'; Bytes = 0; Arquivos = 0 }))) -contains 'Não existe nesta máquina')
    }
    Teste "regressao PS 5.1: scripts de fundo da GUI NAO usam List[object] (@() perde os itens silenciosamente nessa versao)" {
        $src = [IO.File]::ReadAllText((Join-Path $raiz 'WinHealth.ps1'))
        Verdade (-not $src.Contains('List[object]')) "achou List[object] no codigo - @() em cima disso perde os itens no PowerShell 5.1 (bug real, ja nos mordeu)"
    }
    function Iniciar-TarefaGui { param($Script, $OnConcluir, $OnProgresso, $Fila, $OnTick) $script:tgCapturado = @{ Script = $Script.ToString(); OnConcluir = $OnConcluir; OnProgresso = $OnProgresso; Fila = $Fila; OnTick = $OnTick } }
    function Clear-RecycleBin { param([switch]$Force, $ErrorAction) $script:mockRecycleBinChamado = $true; if ($script:mockRecycleBinFalha) { throw 'falha simulada ao esvaziar' } }
    function Obter-ProgramasInicializacao { @() }

    Teste "aba de Limpeza: 'Calcular' chama Iniciar-TarefaGui com script que mede os alvos (Medir-Alvo), com progresso real" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '4'
        $botaoCalcular = $script:GuiLimpeza.BotaoCalcular
        $botaoCalcular.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Verdade ($script:tgCapturado.Script -like '*-CarregarSomente*') "nao dot-source com -CarregarSomente"
        Verdade ($script:tgCapturado.Script -like '*Medir-Alvo*') "nao mede os alvos"
        Igual $botaoCalcular.IsEnabled $false
        Igual "$($script:GuiLimpeza.Progresso.Visibility)" 'Visible'
        Igual $script:GuiLimpeza.Barra.Maximum ([double]@($script:AlvosLimpeza).Count)
        Verdade ($null -ne $script:tgCapturado.OnProgresso) "Iniciar-TarefaGui nao recebeu -OnProgresso"

        & $script:tgCapturado.OnProgresso ([pscustomobject]@{ I = 2; N = 4; Rotulo = 'temporários do Windows' })
        Igual $script:GuiLimpeza.Barra.Value 2.0
        Verdade ($script:GuiLimpeza.Status.Text -like '*2/4*') "status nao mostrou o passo real"
        Igual $script:GuiLimpeza.Log.Children.Count 1
    }
    Teste "aba de Limpeza: previa mostra os alvos, o total e habilita 'Limpar agora'" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '4'
        $script:GuiLimpeza.BotaoCalcular.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $linhas = @(
            [pscustomobject]@{ Rotulo = 'Temporários do usuário'; Estado = 'Ok'; Bytes = 5MB; Arquivos = 10 }
            [pscustomobject]@{ Rotulo = 'Temporários do Windows'; Estado = 'RequerAdmin'; Bytes = 0; Arquivos = 0 }
        )
        & $script:tgCapturado.OnConcluir @([pscustomobject]@{ Linhas = $linhas }) $null
        Igual "$($script:GuiLimpeza.Progresso.Visibility)" 'Collapsed'
        Igual $script:GuiLimpeza.BotaoCalcular.IsEnabled $true
        $t = Textos-Gui $script:GuiLimpeza.Previa
        Verdade ($t -contains 'Temporários do usuário') "faltou o alvo na previa"
        Verdade (($t -join ' ') -like '*Total estimado: 5 MB*') "total nao bateu: $($t -join ' ')"
        Verdade ($t -contains 'Limpar agora') "botao Limpar agora nao apareceu"
    }
    Teste "aba de Limpeza: 'Limpar agora' chama Iniciar-TarefaGui de novo com script que limpa de verdade (Limpar-Alvo/Limpar-CacheDns)" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '4'
        $script:GuiLimpeza.BotaoCalcular.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        & $script:tgCapturado.OnConcluir @([pscustomobject]@{ Linhas = @([pscustomobject]@{ Rotulo = 'X'; Estado = 'Ok'; Bytes = 1MB; Arquivos = 1 }) }) $null
        $botaoLimpar = $script:GuiLimpeza.Previa.Children[$script:GuiLimpeza.Previa.Children.Count - 1]
        Igual $botaoLimpar.Content 'Limpar agora'
        $botaoLimpar.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Verdade ($script:tgCapturado.Script -like '*Limpar-Alvo*') "nao chama Limpar-Alvo"
        Verdade ($script:tgCapturado.Script -like '*Limpar-CacheDns*') "nao chama Limpar-CacheDns"
        Igual "$($script:GuiLimpeza.Progresso.Visibility)" 'Visible'
    }
    Teste "aba de Limpeza: sem itens na Lixeira, vai direto pro resumo final (inicializacao + total)" {
        $script:mockRecycleBinChamado = $false
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '4'
        $script:GuiLimpeza.BotaoCalcular.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        & $script:tgCapturado.OnConcluir @([pscustomobject]@{ Linhas = @() }) $null
        $script:GuiLimpeza.Previa.Children[$script:GuiLimpeza.Previa.Children.Count - 1].RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $pacote = [pscustomobject]@{ Resultados = @((Res 'Arquivos temporários e caches' 'Ok' 'Temp: 3 MB liberados')); BytesLiberados = [int64]3MB; LixeiraBytes = [int64]0; LixeiraItens = 0 }
        & $script:tgCapturado.OnConcluir @($pacote) $null
        Igual "$($script:GuiLimpeza.Progresso.Visibility)" 'Collapsed'
        Verdade (-not $script:mockRecycleBinChamado) "Clear-RecycleBin foi chamado sem ter item na lixeira"
        $t = Textos-Gui $script:GuiLimpeza.Resultado
        Verdade (($t -join ' ') -like '*Limpeza concluída - 3 MB liberados*') "resumo final errado: $($t -join ' ')"
        Verdade (-not ($t -contains 'Esvaziar Lixeira')) "mostrou prompt de lixeira sem ter item"
    }
    Teste "aba de Limpeza: com itens na Lixeira, pede a escolha e so soma ao total se 'Esvaziar' for clicado" {
        $script:mockRecycleBinChamado = $false; $script:mockRecycleBinFalha = $false
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '4'
        $script:GuiLimpeza.BotaoCalcular.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        & $script:tgCapturado.OnConcluir @([pscustomobject]@{ Linhas = @() }) $null
        $script:GuiLimpeza.Previa.Children[$script:GuiLimpeza.Previa.Children.Count - 1].RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $pacote = [pscustomobject]@{ Resultados = @((Res 'Arquivos temporários e caches' 'Ok' 'Temp: 2 MB liberados')); BytesLiberados = [int64]2MB; LixeiraBytes = [int64]10MB; LixeiraItens = 5 }
        & $script:tgCapturado.OnConcluir @($pacote) $null
        $t1 = Textos-Gui $script:GuiLimpeza.Resultado
        Verdade ($t1 -contains 'Esvaziar Lixeira') "nao pediu a escolha da lixeira"
        Verdade (-not (($t1 -join ' ') -like '*Limpeza concluída*')) "mostrou o resumo final antes da escolha da lixeira"

        $botaoEsvaziar = $script:GuiLimpeza.Resultado.Children | Where-Object { $_ -is [System.Windows.Controls.Border] } | Select-Object -Last 1 | ForEach-Object { $_.Child.Children[2].Children[0] }
        Igual $botaoEsvaziar.Content 'Esvaziar Lixeira'
        $botaoEsvaziar.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Verdade $script:mockRecycleBinChamado "nao chamou Clear-RecycleBin ao clicar Esvaziar"
        $t2 = Textos-Gui $script:GuiLimpeza.Resultado
        Verdade (($t2 -join ' ') -like '*Limpeza concluída - 12 MB liberados*') "total nao somou a lixeira: $($t2 -join ' ')"
    }
    Teste "aba de Limpeza: 'Manter Lixeira' nao chama Clear-RecycleBin e nao soma ao total" {
        $script:mockRecycleBinChamado = $false
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '4'
        $script:GuiLimpeza.BotaoCalcular.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        & $script:tgCapturado.OnConcluir @([pscustomobject]@{ Linhas = @() }) $null
        $script:GuiLimpeza.Previa.Children[$script:GuiLimpeza.Previa.Children.Count - 1].RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $pacote = [pscustomobject]@{ Resultados = @((Res 'Arquivos temporários e caches' 'Ok' 'Temp: 1 MB liberados')); BytesLiberados = [int64]1MB; LixeiraBytes = [int64]9MB; LixeiraItens = 2 }
        & $script:tgCapturado.OnConcluir @($pacote) $null
        $botaoManter = $script:GuiLimpeza.Resultado.Children | Where-Object { $_ -is [System.Windows.Controls.Border] } | Select-Object -Last 1 | ForEach-Object { $_.Child.Children[2].Children[1] }
        Igual $botaoManter.Content 'Manter Lixeira'
        $botaoManter.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Verdade (-not $script:mockRecycleBinChamado) "Manter Lixeira chamou Clear-RecycleBin"
        $t = Textos-Gui $script:GuiLimpeza.Resultado
        Verdade (($t -join ' ') -like '*Limpeza concluída - 1 MB liberados*') "total nao devia incluir a lixeira mantida: $($t -join ' ')"
    }

    Write-Host ""
    Write-Host "== Inicializacao: Ativar/Desativar (Gerenciador de Tarefas por baixo) ==" -ForegroundColor Cyan
    Teste "Alternar-ItemInicializacao: item sem ChaveAprovado (pasta de todos os usuarios) nunca grava, devolve false" {
        $item = [pscustomobject]@{ Nome = 'X'; ChaveAprovado = $null; NomeValor = 'X' }
        Igual (Alternar-ItemInicializacao $item $false) $false
    }
    Teste "Alternar-ItemInicializacao: desabilitar sem valor previo grava 12 bytes com o bit 0 ligado" {
        function Test-Path { param($Path) $true }
        function Get-ItemProperty { param($Path, $Name, $ErrorAction) $null }
        $script:mockNovoValor = $null
        function New-ItemProperty { param($Path, $Name, $Value, $PropertyType, [switch]$Force, $ErrorAction) $script:mockNovoValor = $Value }
        $item = [pscustomobject]@{ Nome = 'X'; ChaveAprovado = 'HKCU:\fake'; NomeValor = 'X' }
        Igual (Alternar-ItemInicializacao $item $false) $true
        Igual $script:mockNovoValor.Length 12
        Igual ($script:mockNovoValor[0] -band 1) 1 "bit 0 deveria estar ligado (desabilitado)"
    }
    Teste "Alternar-ItemInicializacao: habilitar preserva os outros bytes existentes, so desliga o bit 0" {
        function Test-Path { param($Path) $true }
        function Get-ItemProperty { param($Path, $Name, $ErrorAction) [pscustomobject]@{ X = [byte[]](3, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9) } }
        $script:mockNovoValor = $null
        function New-ItemProperty { param($Path, $Name, $Value, $PropertyType, [switch]$Force, $ErrorAction) $script:mockNovoValor = $Value }
        $item = [pscustomobject]@{ Nome = 'X'; ChaveAprovado = 'HKCU:\fake'; NomeValor = 'X' }
        Igual (Alternar-ItemInicializacao $item $true) $true
        Igual ($script:mockNovoValor[0] -band 1) 0 "bit 0 deveria estar desligado (habilitado)"
        Igual $script:mockNovoValor[1] 9 "nao deveria mexer nos outros bytes"
    }
    # Teste de ponta a ponta contra o REGISTRO DE VERDADE (nao mockado), numa chave temporaria
    # isolada. Achado real em 28/09/2026 (Gabriel testou e "clicar em Desativar nao fazia nada"):
    # o mock acima usa um [pscustomobject] simples, cujo acesso a propriedade preserva o tipo
    # Byte[] certinho - mas o Get-ItemProperty DE VERDADE devolve um objeto cujo acesso DINAMICO
    # (".($Nome)") dentro de um "$v = if (...) {...} else {...}" o PowerShell DESMEMBRA em
    # Object[] (perde o tipo Byte[]), e so isso faz "$v -is [byte[]]" dar falso sempre - Habilitado
    # sempre saia 'true', entao o clique gravava certo no registro mas a tela nunca mudava. So um
    # teste against o registro real pega esse tipo de bug; mock nenhum reproduz.
    Teste "Alternar-ItemInicializacao + leitura: ciclo completo contra o registro de verdade (regressao do bug 'clicar nao fazia nada')" {
        $chaveBase = 'HKCU:\Software\WinHealthTesteTemp'
        $chaveRun = "$chaveBase\Run"
        $chaveAprovado = "$chaveBase\StartupApproved\Run"
        try {
            New-Item -Path $chaveRun -Force | Out-Null
            New-ItemProperty -Path $chaveRun -Name 'AppTeste' -Value 'C:\fake.exe' -PropertyType String -Force | Out-Null
            New-Item -Path $chaveAprovado -Force | Out-Null
            New-ItemProperty -Path $chaveAprovado -Name 'AppTeste' -Value ([byte[]](2,0,0,0,1,2,3,4,5,6,7,8)) -PropertyType Binary -Force | Out-Null

            # Le do jeito que Obter-ProgramasInicializacao le (mesma forma, byte0 par = habilitado)
            $aprov = Get-ItemProperty -Path $chaveAprovado -ErrorAction SilentlyContinue
            $v = $null
            if ($aprov) { $v = $aprov.('AppTeste') }
            $habilitadoAntes = -not ($v -is [byte[]] -and $v.Length -gt 0 -and ($v[0] -band 1) -eq 1)
            Igual $habilitadoAntes $true "estado inicial deveria ser habilitado (byte0 par)"

            $item = [pscustomobject]@{ Nome = 'AppTeste'; ChaveAprovado = $chaveAprovado; NomeValor = 'AppTeste' }
            Igual (Alternar-ItemInicializacao $item $false) $true "Alternar-ItemInicializacao deveria devolver true"

            $aprov2 = Get-ItemProperty -Path $chaveAprovado -ErrorAction SilentlyContinue
            $v2 = $null
            if ($aprov2) { $v2 = $aprov2.('AppTeste') }
            $habilitadoDepois = -not ($v2 -is [byte[]] -and $v2.Length -gt 0 -and ($v2[0] -band 1) -eq 1)
            Igual $habilitadoDepois $false "depois de desativar, a releitura deveria mostrar desabilitado (regressao do bug real)"
        } finally {
            Remove-Item -Path $chaveBase -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    function Obter-ProgramasInicializacao { @($script:mockItensInicializacao) }
    function Alternar-ItemInicializacao { param($Item, [bool]$Habilitar) $script:mockAlternarChamado = @{ Item = $Item; Habilitar = $Habilitar }; $true }
    function Start-Process { param($FilePath) $script:mockStartProcess = $FilePath }

    Teste "Preencher-InicializacaoGui: mostra Ativar/Desativar por item, e 'Não desativável aqui' pra quem nao pode" {
        $script:mockItensInicializacao = @(
            [pscustomobject]@{ Nome = 'OneDrive'; Origem = 'Usuário (Run)'; Habilitado = $true; ChaveAprovado = 'HKCU:\a'; NomeValor = 'OneDrive' }
            [pscustomobject]@{ Nome = 'Hydra'; Origem = 'Usuário (Run)'; Habilitado = $false; ChaveAprovado = 'HKCU:\a'; NomeValor = 'Hydra' }
            [pscustomobject]@{ Nome = 'Antigo.lnk'; Origem = 'Pasta Inicializar (todos)'; Habilitado = $true; ChaveAprovado = $null; NomeValor = 'Antigo.lnk' }
        )
        $c = New-Object System.Windows.Controls.StackPanel
        Preencher-InicializacaoGui $c
        $t = Textos-Gui $c
        Verdade ($t -contains 'OneDrive') "faltou o item habilitado"
        Verdade ($t -contains 'Desativar') "item habilitado deveria oferecer Desativar"
        Verdade ($t -contains 'Ativar') "item desabilitado deveria oferecer Ativar"
        Verdade (($t -join ' ') -like '*Hydra*desativado*') "nao marcou o item desabilitado como tal"
        Verdade ($t -contains 'Não desativável aqui') "item sem ChaveAprovado deveria avisar que nao da pra desativar"
        Verdade ($t -contains 'Desinstalar...') "faltou o atalho de desinstalar"
    }
    Teste "Novo-LinhaInicializacaoGui: cada linha tem uma borda embaixo (divisoria entre itens - pedido do Gabriel, ficava tudo grudado)" {
        $script:mockItensInicializacao = @([pscustomobject]@{ Nome = 'OneDrive'; Origem = 'Usuário (Run)'; Habilitado = $true; ChaveAprovado = 'HKCU:\a'; NomeValor = 'OneDrive' })
        $c = New-Object System.Windows.Controls.StackPanel
        Preencher-InicializacaoGui $c
        $borda = $c.Children[1].Child.Children[0]
        Verdade ($borda -is [System.Windows.Controls.Border]) "linha nao esta envolvida num Border"
        Verdade ($borda.BorderThickness.Bottom -gt 0) "borda de baixo ausente (sem divisoria visivel)"
    }
    Teste "Preencher-InicializacaoGui: mais de 8 HABILITADOS mostra Atencao; desabilitados nao contam pro total" {
        $script:mockItensInicializacao = @(1..9 | ForEach-Object { [pscustomobject]@{ Nome = "App$_"; Origem = 'Usuário (Run)'; Habilitado = $true; ChaveAprovado = 'HKCU:\a'; NomeValor = "App$_" } })
        $script:mockItensInicializacao += [pscustomobject]@{ Nome = 'Desativado'; Origem = 'Usuário (Run)'; Habilitado = $false; ChaveAprovado = 'HKCU:\a'; NomeValor = 'Desativado' }
        $c = New-Object System.Windows.Controls.StackPanel
        Preencher-InicializacaoGui $c
        $t = Textos-Gui $c
        Verdade (($t -join ' ') -like '*9 programas abrem junto com o Windows*') "nao contou certo (9 habilitados, 1 desabilitado nao deveria contar): $($t -join ' ')"
    }
    Teste "Preencher-InicializacaoGui: clicar 'Desativar' chama Alternar-ItemInicializacao com o item certo e Habilitar=false, e redesenha" {
        $script:mockItensInicializacao = @([pscustomobject]@{ Nome = 'OneDrive'; Origem = 'Usuário (Run)'; Habilitado = $true; ChaveAprovado = 'HKCU:\a'; NomeValor = 'OneDrive' })
        $script:mockAlternarChamado = $null
        $c = New-Object System.Windows.Controls.StackPanel
        Preencher-InicializacaoGui $c
        $linha = $c.Children[1].Child.Children[0].Child
        $botaoToggle = $linha.Children[1]
        Igual $botaoToggle.Content 'Desativar'
        $botaoToggle.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Igual $script:mockAlternarChamado.Item.Nome 'OneDrive'
        Igual $script:mockAlternarChamado.Habilitar $false
    }
    Teste "Preencher-InicializacaoGui: clicar 'Desinstalar...' abre Configuracoes > Apps" {
        $script:mockItensInicializacao = @([pscustomobject]@{ Nome = 'OneDrive'; Origem = 'Usuário (Run)'; Habilitado = $true; ChaveAprovado = 'HKCU:\a'; NomeValor = 'OneDrive' })
        $script:mockStartProcess = $null
        $c = New-Object System.Windows.Controls.StackPanel
        Preencher-InicializacaoGui $c
        $linha = $c.Children[1].Child.Children[0].Child
        $botaoDesinstalar = $linha.Children[2]
        Igual $botaoDesinstalar.Content 'Desinstalar...'
        $botaoDesinstalar.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Igual $script:mockStartProcess 'ms-settings:appsfeatures'
    }
    Teste "console (Modulo-Limpeza): Interpretar-Inicializacao so recebe os HABILITADOS, igual sempre foi (regressao de comportamento)" {
        $script:mockItensInicializacao = @(
            [pscustomobject]@{ Nome = 'A'; Origem = 'x'; Habilitado = $true; ChaveAprovado = $null; NomeValor = 'A' }
            [pscustomobject]@{ Nome = 'B'; Origem = 'x'; Habilitado = $false; ChaveAprovado = $null; NomeValor = 'B' }
        )
        $res = @(Interpretar-Inicializacao @(Obter-ProgramasInicializacao | Where-Object Habilitado))
        Igual (($res | Where-Object { $_.Titulo -eq 'Total de programas abrindo com o Windows' }).Detalhe) '1'
    }

    Write-Host ""
    Write-Host "== Aba de Scanner (GUI) ==" -ForegroundColor Cyan
    function Start-Process { param($FilePath, $ArgumentList, [switch]$PassThru, $Verb, [switch]$Wait, $ErrorAction) $script:mockSP = @{ Arq = $FilePath }; [pscustomobject]@{ HasExited = $false } }

    Teste "aba de Scanner: 'Rodar Scanner' chama Iniciar-TarefaGui com script que lanca o processo elevado e acompanha o log (ETAPA N de 34), progresso real" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '2'
        $botao = $script:GuiScanner.Botao
        $botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Verdade ($script:tgCapturado.Script -like '*-CarregarSomente*') "nao dot-source com -CarregarSomente"
        Verdade ($script:tgCapturado.Script -like '*-Verb RunAs*') "nao lanca o scanner elevado"
        Verdade ($script:tgCapturado.Script -like '*if ($isAdmin)*') "nao pula o -Verb RunAs quando ja esta admin (regressao: Start-Process -Verb RunAs -ArgumentList falha silenciosamente - ExitCode=1, o .bat nunca chega a rodar - quando quem chama ja esta elevado; achado testando ao vivo nesta maquina, era o motivo real do Scanner nunca funcionar pro Gabriel, que sempre roda como Administrador)"
        Verdade ($script:tgCapturado.Script -like '*ETAPA*') "nao acompanha as etapas do log"
        Verdade ($script:tgCapturado.Script -like '*SCANNER_CONCLUIDO*') "nao detecta o fim pelo marcador do log (regressao: o handle de `$p.HasExited nao e confiavel atraves da fronteira de elevacao - foi a causa real do bug 'encerrou sem gerar relatorio')"
        Verdade ($script:tgCapturado.Script -like '*AddSeconds(90)*') "timeout de espera do arquivo nao e mais generoso (90s) - regressao: 25s podia nao dar tempo do antivirus escanear o .ps1 recem-extraido"
        Verdade ($script:tgCapturado.Script -like '*if ($achado.FullName -ne $arquivo)*') "nao reavalia o arquivo mais recente a cada volta (regressao: se um 2o scanner for lancado perto o bastante, o loop ficava preso pra sempre no arquivo antigo - achado ao vivo, ficava parado em ETAPA 27/34 sem o marcador enquanto a janela real mostrava as 34 etapas completas)"
        Verdade ($script:tgCapturado.Script -like '*conteudo.Length -lt $posicao*') "nao reinicia a posicao quando o conteudo encolhe (arquivo apagado/recriado no mesmo caminho)"
        Igual $botao.IsEnabled $false
        Igual "$($script:GuiScanner.Progresso.Visibility)" 'Visible'
        Igual $script:GuiScanner.Barra.Maximum 34.0
        Verdade ($null -ne $script:tgCapturado.OnProgresso) "Iniciar-TarefaGui nao recebeu -OnProgresso"

        & $script:tgCapturado.OnProgresso ([pscustomobject]@{ I = 6; N = 34; Rotulo = 'DRIVERS' })
        Igual $script:GuiScanner.Barra.Value 6.0
        Verdade ($script:GuiScanner.Status.Text -like '*6/34*') "status nao mostrou a etapa real"
        Igual $script:GuiScanner.Log.Children.Count 1
    }
    Teste "aba de Scanner: -OnTick mostra 'rodando ha Xs' so ANTES da 1a etapa chegar (depois disso o status real manda)" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '2'
        $script:GuiScanner.Botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Verdade ($null -ne $script:tgCapturado.OnTick) "Iniciar-TarefaGui nao recebeu -OnTick"

        & $script:tgCapturado.OnTick 12
        Verdade ($script:GuiScanner.Status.Text -like '*rodando há 12s*') "nao mostrou o tempo decorrido esperando o scanner comecar: $($script:GuiScanner.Status.Text)"

        & $script:tgCapturado.OnProgresso ([pscustomobject]@{ I = 1; N = 34; Rotulo = 'PROCESSOS SUSPEITOS' })
        & $script:tgCapturado.OnTick 13
        Verdade ($script:GuiScanner.Status.Text -like '*1/34*') "depois da 1a etapa, o OnTick nao deveria sobrescrever com o texto de espera: $($script:GuiScanner.Status.Text)"
    }
    Teste "aba de Scanner: nao encontrado mostra aviso pra colocar o .bat na pasta Ferramentas" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '2'
        $script:GuiScanner.Botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        & $script:tgCapturado.OnConcluir @([pscustomobject]@{ Erro = 'NaoEncontrado' }) $null
        Igual "$($script:GuiScanner.Progresso.Visibility)" 'Collapsed'
        Igual $script:GuiScanner.Botao.IsEnabled $true
        $t = Textos-Gui $script:GuiScanner.Resultado
        Verdade ($t -contains 'Scanner não encontrado') "nao avisou que o scanner nao foi encontrado"
    }
    Teste "aba de Scanner: sem relatorio (nunca escreveu nada em 90s) mostra aviso especifico (nao trava, permite tentar de novo)" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '2'
        $script:GuiScanner.Botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        & $script:tgCapturado.OnConcluir @([pscustomobject]@{ Erro = 'SemRelatorio' }) $null
        Igual $script:GuiScanner.Botao.IsEnabled $true
        $t = Textos-Gui $script:GuiScanner.Resultado
        Verdade ($t -contains 'O scanner não começou a gerar o relatório em 90s') "nao avisou que o relatorio nunca comecou"
        Verdade (($t -join ' ') -like '*antivírus*') "nao mencionou o antivirus como possivel causa (risco ja documentado do Scanner)"
    }
    Teste "aba de Scanner: UAC recusado mostra aviso especifico (nao trava, permite tentar de novo)" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '2'
        $script:GuiScanner.Botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        & $script:tgCapturado.OnConcluir @([pscustomobject]@{ Erro = 'Uac' }) $null
        $t = Textos-Gui $script:GuiScanner.Resultado
        Verdade ($t -contains 'Permissão de administrador não concedida') "nao avisou da recusa do UAC"
    }
    Teste "aba de Scanner: nenhum sinal suspeito mostra cartao Ok" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '2'
        $script:GuiScanner.Botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        & $script:tgCapturado.OnConcluir @([pscustomobject]@{ LogPath = 'C:\rel.txt'; Alertas = 0; AlertasBaixos = 0 }) $null
        $t = Textos-Gui $script:GuiScanner.Resultado
        Verdade ($t -contains 'Nenhum sinal suspeito encontrado') "nao mostrou o cartao Ok"
    }
    Teste "aba de Scanner: alertas e itens de baixa prioridade viram cartoes com a contagem certa, botao abre o relatorio real" {
        $script:mockSP = $null
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '2'
        $script:GuiScanner.Botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        & $script:tgCapturado.OnConcluir @([pscustomobject]@{ LogPath = 'C:\rel_scanner.txt'; Alertas = 2; AlertasBaixos = 5 }) $null
        $t = Textos-Gui $script:GuiScanner.Resultado
        Verdade (($t -join ' ') -like '*2 sinal(is) de alta prioridade*') "nao contou os alertas de alta prioridade: $($t -join ' ')"
        Verdade (($t -join ' ') -like '*5 item(ns) de baixa prioridade*') "nao contou os itens de baixa prioridade: $($t -join ' ')"
        $botaoAbrir = $script:GuiScanner.Resultado.Children[$script:GuiScanner.Resultado.Children.Count - 1]
        Igual $botaoAbrir.Content 'Abrir relatório completo'
        $botaoAbrir.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Igual $script:mockSP.Arq 'C:\rel_scanner.txt'
    }

    Write-Host ""
    Write-Host "== Aba de Reparo (GUI) ==" -ForegroundColor Cyan
    function Enable-ComputerRestore { param($Drive, $ErrorAction) }
    function Checkpoint-Computer { param($Description, $RestorePointType, $ErrorAction) if ($script:mockCheckpointFalha) { throw 'falha simulada ao criar ponto de restauracao' } }
    function Confirmar-ContinuarSemPontoGui { $script:mockConfirmarChamado = $true; $script:mockConfirmarResposta }

    Teste "aba de Reparo: sem administrador, o botao fica desabilitado com aviso e Rodar-ReparoGui nao faz nada (guarda redundante)" {
        $script:tgCapturado = $null
        $null = Novo-JanelaGui -EstadoAcesso 'LimitadoElevavel'
        Ir-AbaGui '3'
        Igual $script:GuiReparo.Botao.IsEnabled $false
        Verdade ($script:GuiReparo.Status.Text -like '*Requer administrador*') "nao avisou que precisa de administrador"
        Rodar-ReparoGui
        Igual $script:tgCapturado $null "nao deveria iniciar nada sem ser administrador, mesmo chamando a funcao direto"
    }
    Teste "aba de Reparo: avisa de forma visivel que o ponto de restauracao e criado automaticamente antes de comecar (pedido do Gabriel - ele nao via onde isso acontecia)" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '3'
        $t = Textos-Gui $script:GuiConteudo.Content
        Verdade (($t -join ' ') -like '*Ponto de restauração:*antes de começar*criar um ponto de restauração*') "aviso do ponto de restauracao nao esta visivel na aba: $($t -join ' ')"
    }
    Teste "aba de Reparo: com administrador e ponto de restauracao OK, chama Iniciar-TarefaGui com DISM->SFC->CHKDSK na ordem certa" {
        $script:mockCheckpointFalha = $false; $script:mockConfirmarChamado = $false
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '3'
        Igual $script:GuiReparo.Botao.IsEnabled $true
        $script:GuiReparo.Botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Verdade (-not $script:mockConfirmarChamado) "pediu confirmacao mesmo com o ponto de restauracao OK"
        Verdade ($script:tgCapturado.Script -like '*-CarregarSomente*') "nao dot-source com -CarregarSomente"
        Verdade ($script:tgCapturado.Script -like '*DISM.exe*') "nao roda o DISM"
        Verdade ($script:tgCapturado.Script -like '*sfc.exe*') "nao roda o SFC"
        Verdade ($script:tgCapturado.Script -like '*chkdsk.exe*') "nao roda o CHKDSK"
        $ordemDism = $script:tgCapturado.Script.IndexOf('DISM.exe')
        $ordemSfc = $script:tgCapturado.Script.IndexOf('sfc.exe')
        $ordemChkdsk = $script:tgCapturado.Script.IndexOf('chkdsk.exe')
        Verdade ($ordemDism -lt $ordemSfc -and $ordemSfc -lt $ordemChkdsk) "ordem errada: DISM deve vir antes do SFC, que deve vir antes do CHKDSK"
        Igual $script:GuiReparo.Botao.IsEnabled $false
        Igual "$($script:GuiReparo.Progresso.Visibility)" 'Visible'
        Igual $script:GuiReparo.Barra.Maximum 3.0
    }
    Teste "aba de Reparo: progresso real por etapa (Inicio/Tick/Fim) avanca a barra so quando a etapa de verdade termina, e nao duplica a mesma linha no log" {
        $script:mockCheckpointFalha = $false
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '3'
        $script:GuiReparo.Botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))

        & $script:tgCapturado.OnProgresso ([pscustomobject]@{ Tipo = 'Inicio'; Etapa = 1; Nome = 'DISM'; Decorrido = '00:00:00'; Linha = '' })
        Igual $script:GuiReparo.Barra.Value 0.0
        Verdade ($script:GuiReparo.Status.Text -like '*Etapa 1 de 3*DISM*iniciando*') "status nao mostrou o inicio real"

        & $script:tgCapturado.OnProgresso ([pscustomobject]@{ Tipo = 'Tick'; Etapa = 1; Nome = 'DISM'; Decorrido = '00:00:20'; Linha = '20.0%' })
        & $script:tgCapturado.OnProgresso ([pscustomobject]@{ Tipo = 'Tick'; Etapa = 1; Nome = 'DISM'; Decorrido = '00:00:22'; Linha = '20.0%' })
        Verdade ($script:GuiReparo.Status.Text -like '*rodando há 00:00:22*') "status nao avancou com o tick real"
        Igual $script:GuiReparo.Log.Children.Count 2 "linha repetida nao deveria duplicar no log (Inicio + 1 tick, o 2o tick e igual ao 1o)"

        & $script:tgCapturado.OnProgresso ([pscustomobject]@{ Tipo = 'Fim'; Etapa = 1; Nome = 'DISM'; Decorrido = '00:00:25'; Linha = '' })
        Igual $script:GuiReparo.Barra.Value 1.0
        Verdade ($script:GuiReparo.Status.Text -like '*concluída em 00:00:25*') "status nao confirmou a etapa concluida"
    }
    Teste "aba de Reparo: resultado final mostra as 3 etapas + ponto de restauracao, e o banner reflete a pior severidade" {
        $script:mockCheckpointFalha = $false
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '3'
        $script:GuiReparo.Botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $pacote = [pscustomobject]@{
            ResDism   = (Res 'Etapa 1 de 3 - DISM (imagem do Windows)' 'Ok' 'DISM concluído: a imagem do Windows está íntegra')
            ResSfc    = (Res 'Etapa 2 de 3 - SFC (arquivos do sistema)' 'Problema' 'O SFC encontrou corrupção que NÃO conseguiu reparar')
            ResChkdsk = (Res 'Etapa 3 de 3 - CHKDSK (disco)' 'Ok' 'CHKDSK: nenhum problema no sistema de arquivos')
        }
        & $script:tgCapturado.OnConcluir @($pacote) $null
        Igual "$($script:GuiReparo.Progresso.Visibility)" 'Collapsed'
        Igual $script:GuiReparo.Botao.IsEnabled $true
        $t = Textos-Gui $script:GuiReparo.Resultado
        Verdade ($t -contains 'Ponto de restauração criado antes do reparo') "nao confirmou o ponto de restauracao"
        Verdade ($t -contains 'DISM concluído: a imagem do Windows está íntegra') "faltou o resultado do DISM"
        Verdade ($t -contains 'O SFC encontrou corrupção que NÃO conseguiu reparar') "faltou o resultado do SFC"
        Verdade (($t -join ' ') -like '*Reparo concluído com problema(s)*') "banner deveria refletir o Problema do SFC (pior severidade): $($t -join ' ')"
    }
    Teste "aba de Reparo: ponto de restauracao falha e usuario NAO confirma - aborta sem chamar Iniciar-TarefaGui" {
        $script:mockCheckpointFalha = $true; $script:mockConfirmarResposta = $false; $script:mockConfirmarChamado = $false
        $script:tgCapturado = $null
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '3'
        $script:GuiReparo.Botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Verdade $script:mockConfirmarChamado "deveria ter pedido confirmacao quando o ponto de restauracao falha"
        Igual $script:tgCapturado $null "nao deveria ter iniciado o reparo sem a confirmacao"
        Igual $script:GuiReparo.Botao.IsEnabled $true "botao nao deveria ficar desabilitado se o reparo nem comecou"
    }
    Teste "aba de Reparo: ponto de restauracao falha mas usuario confirma continuar - reparo roda e o card final avisa" {
        $script:mockCheckpointFalha = $true; $script:mockConfirmarResposta = $true; $script:mockConfirmarChamado = $false
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '3'
        $script:GuiReparo.Botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Verdade $script:mockConfirmarChamado "deveria ter pedido confirmacao"
        Verdade ($null -ne $script:tgCapturado -and $null -ne $script:tgCapturado.Script) "deveria ter iniciado o reparo apos a confirmacao"
        $pacote = [pscustomobject]@{
            ResDism   = (Res 'x' 'Ok' 'ok dism')
            ResSfc    = (Res 'x' 'Ok' 'ok sfc')
            ResChkdsk = (Res 'x' 'Ok' 'ok chkdsk')
        }
        & $script:tgCapturado.OnConcluir @($pacote) $null
        $t = Textos-Gui $script:GuiReparo.Resultado
        Verdade ($t -contains 'Não foi possível criar o ponto de restauração') "nao avisou que o ponto de restauracao falhou"
        Verdade (($t -join ' ') -like '*Reparo concluído sem problemas*') "banner deveria ser Ok (as 3 etapas OK): $($t -join ' ')"
    }

    Write-Host ""
    Write-Host "== Aba de USB (GUI) ==" -ForegroundColor Cyan

    Teste "aba de USB: 'Verificar USB' chama Iniciar-TarefaGui com script que coleta o estado (sem barra de progresso - checagem rapida)" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '7'
        $botao = $script:GuiUSB.Botao
        $botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Verdade ($script:tgCapturado.Script -like '*-CarregarSomente*') "nao dot-source com -CarregarSomente"
        Verdade ($script:tgCapturado.Script -like '*Coletar-EstadoUSB*') "nao coleta o estado do USB"
        Igual $botao.IsEnabled $false
        Igual $script:GuiUSB.Status.Text 'Verificando...'
    }
    Teste "aba de USB: sem nenhum disco USB visivel, pergunta se ha pendrive conectado (substitui o Read-Host do console)" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '7'
        $script:GuiUSB.Botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $estado = [pscustomobject]@{ Dispositivos = @(); TemHid = $true; DiscosUsb = @(); UsbstorStart = 3; WriteProtect = 0; GpoExiste = $false; GpoRegras = @(); DeviceInstallRegras = @(); ServicosDlp = @() }
        & $script:tgCapturado.OnConcluir @([pscustomobject]@{ Estado = $estado }) $null
        Igual $script:GuiUSB.Botao.IsEnabled $true
        $t = Textos-Gui $script:GuiUSB.Resultado
        Verdade ($t -contains 'Nenhum pendrive/disco USB visível ao Windows agora') "nao mostrou a pergunta"
        Verdade ($t -contains 'Sim, tem um pendrive conectado') "faltou o botao Sim"
        Verdade ($t -contains 'Não') "faltou o botao Não"
    }
    Teste "aba de USB: com disco USB visivel, pula a pergunta e mostra o resultado direto (Avaliar-EstadoUSB reaproveitada)" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '7'
        $script:GuiUSB.Botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $estado = [pscustomobject]@{ Dispositivos = @(); TemHid = $true; DiscosUsb = @([pscustomobject]@{ Modelo = 'Pendrive Teste'; TamanhoGB = 8.0; VID = $null; PID = $null; Serie = $null }); UsbstorStart = 3; WriteProtect = 0; GpoExiste = $false; GpoRegras = @(); DeviceInstallRegras = @(); ServicosDlp = @() }
        & $script:tgCapturado.OnConcluir @([pscustomobject]@{ Estado = $estado }) $null
        $t = Textos-Gui $script:GuiUSB.Resultado
        Verdade (-not ($t -contains 'Sim, tem um pendrive conectado')) "nao deveria perguntar quando ja ha disco visivel"
        Verdade ($t -contains 'Não há sinais de bloqueio de USB nesta máquina') "nao mostrou a conclusao Ok"
    }
    Teste "aba de USB: clicar 'Sim'/'Não' na pergunta chama Avaliar-EstadoUSB com o Conectado certo (Estado levado no .Tag, sem depender de closure)" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '7'
        $script:GuiUSB.Botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $estado = [pscustomobject]@{ Dispositivos = @(); TemHid = $true; DiscosUsb = @(); UsbstorStart = 3; WriteProtect = 0; GpoExiste = $false; GpoRegras = @(); DeviceInstallRegras = @(); ServicosDlp = @() }
        & $script:tgCapturado.OnConcluir @([pscustomobject]@{ Estado = $estado }) $null
        $caixaPergunta = $script:GuiUSB.Resultado.Children[0]
        $botaoSim = $caixaPergunta.Child.Children[2].Children[0]
        $botaoSim.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $t = Textos-Gui $script:GuiUSB.Resultado
        Verdade ($t -contains 'Pendrive conectado, mas o Windows não o enxerga') "clicar Sim deveria acusar o padrao de bloqueio (HID presente + pendrive conectado + nada visivel)"
        Igual $script:GuiUltimoUSB.Conectado $true
    }
    Teste "aba de USB: gera e salva o texto do chamado quando ha Hardware ID (VID/PID), com botao Copiar" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '7'
        $script:GuiUSB.Botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $estado = [pscustomobject]@{ Dispositivos = @(); TemHid = $true; DiscosUsb = @([pscustomobject]@{ Modelo = 'Multilaser 16GB'; TamanhoGB = 14.9; VID = '0930'; PID = '6544'; Serie = 'XYZ' }); UsbstorStart = 3; WriteProtect = 0; GpoExiste = $false; GpoRegras = @(); DeviceInstallRegras = @(); ServicosDlp = @() }
        & $script:tgCapturado.OnConcluir @([pscustomobject]@{ Estado = $estado }) $null
        $t = Textos-Gui $script:GuiUSB.Resultado
        Verdade ($t -contains 'Hardware ID') "faltou o rotulo Hardware ID"
        Verdade (($t -join ' ') -like '*USB\VID_0930&PID_6544*') "faltou o valor do Hardware ID no texto do chamado: $($t -join ' ')"
        Verdade ($t -contains 'Copiar texto') "faltou o botao de copiar"
        $arq = Get-ChildItem (Join-Path $tmp 'Recursos\Relatorios') -Filter '*_PedidoLiberacaoUSB_*.txt' -ErrorAction SilentlyContinue
        Verdade ($null -ne $arq) "nao salvou o arquivo do chamado em Relatorios"
        if ($arq) { Remove-Item $arq.FullName -Force }
    }
    Teste "aba de USB: sem Hardware ID nenhum (nenhum disco com VID), nao mostra o card do chamado" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '7'
        $script:GuiUSB.Botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $estado = [pscustomobject]@{ Dispositivos = @(); TemHid = $true; DiscosUsb = @(); UsbstorStart = 3; WriteProtect = 0; GpoExiste = $false; GpoRegras = @(); DeviceInstallRegras = @(); ServicosDlp = @() }
        & $script:tgCapturado.OnConcluir @([pscustomobject]@{ Estado = $estado }) $null
        $script:GuiUSB.Resultado.Children[0].Child.Children[2].Children[1].RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $t = Textos-Gui $script:GuiUSB.Resultado
        Verdade (-not ($t -contains 'Texto para o chamado')) "nao deveria gerar chamado sem nenhum Hardware ID"
    }
    Teste "aba de USB: reabrir a aba depois de responder a pergunta mostra o MESMO resultado (nao pergunta de novo)" {
        $null = Novo-JanelaGui -EstadoAcesso 'Admin'
        Ir-AbaGui '7'
        $script:GuiUSB.Botao.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $estado = [pscustomobject]@{ Dispositivos = @(); TemHid = $false; DiscosUsb = @(); UsbstorStart = 3; WriteProtect = 0; GpoExiste = $false; GpoRegras = @(); DeviceInstallRegras = @(); ServicosDlp = @() }
        & $script:tgCapturado.OnConcluir @([pscustomobject]@{ Estado = $estado }) $null
        $script:GuiUSB.Resultado.Children[0].Child.Children[2].Children[1].RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Ir-AbaGui 'painel'
        Ir-AbaGui '7'
        $t = Textos-Gui $script:GuiUSB.Resultado
        Verdade (-not ($t -contains 'Sim, tem um pendrive conectado')) "voltou a perguntar de novo em vez de lembrar a resposta"
        Verdade ($t -contains 'Diagnóstico inconclusivo') "nao preservou o resultado (Nao + sem HID = inconclusivo)"
    }
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
if ($script:falhas.Count -eq 0) {
    Write-Host "  $($script:total) testes, todos passaram." -ForegroundColor Green
    exit 0
} else {
    Write-Host "  $($script:falhas.Count) de $($script:total) testes FALHARAM." -ForegroundColor Red
    exit 1
}
