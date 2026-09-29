param([string]$PastaKit = "", [string]$IniciarEm = "", [switch]$CarregarSomente, [switch]$Gui, [switch]$SairAoFinal)

$ErrorActionPreference = 'SilentlyContinue'

# ===================== CONFIGURACAO =====================
if (-not $PastaKit -or -not (Test-Path $PastaKit)) { $PastaKit = "$env:USERPROFILE\Desktop" }
$PastaKit = [IO.Path]::GetFullPath($PastaKit).TrimEnd('\')

# Rodando de compartilhamento de rede (modo sem pendrive)? Relatorios contem dados sensiveis
# (senhas de Wi-Fi, chave do Windows) e NUNCA devem ir para o compartilhamento.
$modoRede = $PastaKit.StartsWith('\\')
if ($modoRede) {
    $pastaRelatorios = Join-Path $env:USERPROFILE "Desktop\Relatorios-WinHealth"
} else {
    $pastaRelatorios = Join-Path $PastaKit "Recursos\Relatorios"
}
if (-not (Test-Path $pastaRelatorios)) {
    try { New-Item -Path $pastaRelatorios -ItemType Directory -Force -ErrorAction Stop | Out-Null } catch { $pastaRelatorios = "$env:USERPROFILE\Desktop" }
}
$pastaFerramentas = Join-Path $PastaKit "Recursos\Ferramentas"

$nomeMaquina = $env:COMPUTERNAME
$carimbo = Get-Date -Format "yyyy-MM-dd_HHmm"
$logfile = Join-Path $pastaRelatorios "$nomeMaquina`_$carimbo.txt"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
# Conta que PERTENCE ao grupo Administradores mas esta sem elevacao (UAC): basta confirmar. Conta comum: precisa de credencial de outra conta.
# whoami /groups e usado porque o .Groups do .NET OMITE grupos "usado apenas para negar", que e como o UAC deixa o grupo Administradores.
function Test-ContaNoGrupoAdmin {
    try { return [bool](& whoami /groups 2>$null | Select-String 'S-1-5-32-544' -Quiet) } catch { return $false }
}
$temContaAdmin = Test-ContaNoGrupoAdmin

$script:achados = 0
$script:achadosBaixos = 0

# ===================== LOG DE DIAGNOSTICO (caixa-preta) =====================
# Log tecnico PERSISTENTE (sobrevive entre execucoes, ao contrario do $logfile acima, que e um
# relatorio novo por sessao dentro de Relatorios). Ideia trazida pelo Gabriel do proprio projeto
# OmniCursorPro dele (logging.basicConfig + sys.excepthook + um "Terminal de Diagnostico" que le o
# arquivo) - aqui adaptado ao que ja existe: como $ErrorActionPreference e SilentlyContinue no
# script inteiro, varios bugs desta sessao (closure perdendo variavel, array virando Object[], tail
# do Scanner desincronizando) so foram achados com testes isolados manuais, porque nada ficava
# registrado em lugar nenhum quando algo dava errado. Fica em %LOCALAPPDATA%, nunca dentro do
# projeto/pendrive (e so um log tecnico local desta maquina, nao um relatorio do cliente).
$script:pastaLogDiagnostico = Join-Path $env:LOCALAPPDATA 'WinHealth'
$script:arquivoLogDiagnostico = Join-Path $script:pastaLogDiagnostico 'winhealth_debug.log'
$script:tamanhoMaximoLogDiagnostico = 5MB
$script:linhasManterLogDiagnostico = 5000
function Escrever-LogDiagnostico {
    param([ValidateSet('DEBUG', 'INFO', 'AVISO', 'ERRO')][string]$Nivel = 'INFO', [Parameter(Mandatory)][string]$Mensagem)
    try {
        if (-not (Test-Path $script:pastaLogDiagnostico)) { New-Item -Path $script:pastaLogDiagnostico -ItemType Directory -Force -ErrorAction Stop | Out-Null }
        # Evita crescer sem limite numa ferramenta usada dia apos dia: se passar do limite, mantem so as linhas mais recentes.
        if ((Test-Path $script:arquivoLogDiagnostico) -and (Get-Item $script:arquivoLogDiagnostico).Length -gt $script:tamanhoMaximoLogDiagnostico) {
            $recentes = @(Get-Content -LiteralPath $script:arquivoLogDiagnostico -Tail $script:linhasManterLogDiagnostico)
            Set-Content -LiteralPath $script:arquivoLogDiagnostico -Value $recentes -Encoding UTF8
        }
        Add-Content -LiteralPath $script:arquivoLogDiagnostico -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') - $Nivel - $Mensagem" -Encoding UTF8
    } catch { }
}

# ===================== FUNCOES BASE =====================
function W {
    param($texto, $cor = "White", $alerta = $false, $prioridade = "Alta")
    if ($alerta -and $prioridade -eq "Baixa") {
        Write-Host $texto -ForegroundColor DarkYellow
        Add-Content -Path $logfile -Value "[ATENCAO] $texto"
        $script:achadosBaixos++
    } elseif ($alerta) {
        Write-Host $texto -ForegroundColor Red
        Add-Content -Path $logfile -Value "[PROBLEMA] $texto"
        $script:achados++
    } else {
        Write-Host $texto -ForegroundColor $cor
        Add-Content -Path $logfile -Value $texto
    }
}

function Secao($texto) {
    Write-Host ""
    Write-Host "====================================================================" -ForegroundColor Cyan
    Write-Host "  $texto" -ForegroundColor Cyan
    Write-Host "====================================================================" -ForegroundColor Cyan
    Add-Content -Path $logfile -Value ""
    Add-Content -Path $logfile -Value "==================== $texto ===================="
}

function Pausa {
    Write-Host ""
    Write-Host "Pressione ENTER para $(if ($SairAoFinal) { 'fechar' } else { 'voltar ao menu' })..." -ForegroundColor DarkGray
    [void](Read-Host)
}

function Obter-EstadoAcesso {
    param([bool]$Elevado, [bool]$TemContaAdmin)
    if ($Elevado) { return 'Admin' }
    if ($TemContaAdmin) { return 'LimitadoElevavel' }
    return 'LimitadoPadrao'
}

# Reabre o WinHealth elevado numa nova janela e ESPERA ela fechar (o launcher .bat so apaga o
# script temporario depois que esta instancia termina). Retorna $true se a sessao elevada rodou.
function Reabrir-ComoAdmin {
    param([string]$IniciarEmModulo = "")
    if ($isAdmin) { return $false }
    Write-Host ""
    if ((Obter-EstadoAcesso $isAdmin $temContaAdmin) -eq 'LimitadoPadrao') {
        Write-Host "  Sua conta NÃO é administradora: o Windows vai pedir usuário e senha de uma conta administradora." -ForegroundColor DarkYellow
        Write-Host "  Se você não tem essa credencial, peça a quem administra a máquina (não tente contornar)." -ForegroundColor DarkYellow
        Write-Host "  Atenção: usando outra conta, os relatórios vão para a área DESSA conta." -ForegroundColor DarkYellow
    }
    $argumentos = "-NoProfile -ExecutionPolicy RemoteSigned -File `"$PSCommandPath`" -PastaKit `"$PastaKit`""
    if ($IniciarEmModulo) { $argumentos += " -IniciarEm $IniciarEmModulo" }
    if ($Gui) { $argumentos += " -Gui" }
    if ($SairAoFinal) { $argumentos += " -SairAoFinal" }
    try {
        Write-Host "  Abrindo nova janela como administrador... (esta janela aguarda até você fechar a outra)" -ForegroundColor Cyan
        Start-Process -FilePath "powershell.exe" -ArgumentList $argumentos -Verb RunAs -Wait -ErrorAction Stop
        return $true
    } catch {
        Write-Host "  Não foi possível abrir como administrador (cancelado ou sem permissão)." -ForegroundColor Red
        Write-Host "  Seguindo em modo limitado. Detalhe: $($_.Exception.Message)" -ForegroundColor DarkGray
        return $false
    }
}

function ExigirAdmin {
    if ($isAdmin) { return $true }
    Write-Host ""
    Write-Host "  ESTA OPÇÃO PRECISA DE ADMINISTRADOR  " -ForegroundColor White -BackgroundColor Red
    $r = Read-Host "Reabrir o WinHealth como administrador agora? (S/N)"
    if ($r -match '^[Ss]') {
        if (Reabrir-ComoAdmin $script:moduloAtual) { $script:encerrar = $true; return $false }
    }
    Pausa
    return $false
}

function CriarPontoRestauracao($descricao) {
    Write-Host ""
    Write-Host "Criando ponto de restauracao antes de mexer no sistema..." -ForegroundColor Cyan
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description $descricao -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
        Write-Host "[OK] Ponto de restauracao criado." -ForegroundColor Green
        return $true
    } catch {
        Write-Host "[AVISO] Nao foi possivel criar ponto de restauracao." -ForegroundColor DarkYellow
        Write-Host "(O Windows limita a 1 a cada 24h, ou a Protecao do Sistema pode estar desligada.)" -ForegroundColor DarkGray
        $ultimo = Obter-UltimoPontoRestauracao
        if ($ultimo) { Write-Host "O ponto mais recente que ja existe e de $($ultimo.ToString('dd/MM/yyyy HH:mm')) - continua valendo pra voltar atras." -ForegroundColor DarkGray }
        $resp = Read-Host "Continuar mesmo assim? (S/N)"
        return ($resp -match '^[Ss]')
    }
}

# Data/hora real do ponto de restauracao mais recente (ou $null se nao houver nenhum/erro na consulta).
# Usado pra trocar "o Windows limita a 1 a cada 24h" (uma regra generica) por um fato concreto - se ja
# existe um ponto recente, ele continua servindo pra voltar atras mesmo sem criar um novo agora.
function Obter-UltimoPontoRestauracao {
    try {
        $p = Get-ComputerRestorePoint -ErrorAction Stop | Sort-Object SequenceNumber -Descending | Select-Object -First 1
        if (-not $p) { return $null }
        [Management.ManagementDateTimeConverter]::ToDateTime($p.CreationTime)
    } catch { $null }
}

# ===================== MODULO 1 - DIAGNOSTICO COMPLETO =====================
# Arquitetura: cada checagem (Testar-*) so COLETA e devolve objetos "Resultado".
# O console (Mostrar-Resultados) e o relatorio HTML (Exportar-RelatorioHtml) sao
# apenas renderizadores desses mesmos objetos - a futura GUI sera mais um.
# Severidade: Ok | Info | Atencao | Problema | Indisponivel (nao foi possivel verificar)

function Res {
    param([string]$Categoria, [string]$Severidade, [string]$Titulo, [string]$Detalhe = "", [string]$Recomendacao = "", [string]$Arquivo = "")
    [pscustomobject]@{ Categoria = $Categoria; Severidade = $Severidade; Titulo = $Titulo; Detalhe = $Detalhe; Recomendacao = $Recomendacao; Arquivo = $Arquivo }
}

function Testar-Identificacao {
    $c = "Identificação da máquina"
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    } catch {
        Res $c 'Indisponivel' 'Dados básicos da máquina' 'Não foi possível ler nome, modelo e sistema.'
        return
    }
    $ramTxt = "$([math]::Round($cs.TotalPhysicalMemory/1GB,1)) GB"
    $info = [ordered]@{
        'Computador' = $cs.Name
        'Fabricante / modelo' = "$($cs.Manufacturer) $($cs.Model)"
    }
    if ($bios) { $info['Número de série'] = $bios.SerialNumber }
    if ($cpu) { $info['Processador'] = "$($cpu.Name.Trim()) ($($cpu.NumberOfCores) núcleos)" }
    $info['Memória RAM'] = $ramTxt
    if ($os) { $info['Sistema'] = "$($os.Caption) (build $($os.BuildNumber))" }
    foreach ($k in $info.Keys) { Res $c 'Info' $k $info[$k] }

    if ($os -and $os.LastBootUpTime) {
        $dias = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
        $info['Tempo ligado'] = "$dias dia(s) sem reiniciar"
        if ($dias -gt 7) {
            Res $c 'Atencao' "Máquina ligada há $dias dias sem reiniciar" "" "Isso acumula lentidão (memória não liberada). Reiniciar costuma resolver bastante coisa."
        } else {
            Res $c 'Info' 'Tempo ligado' "$dias dia(s) sem reiniciar"
        }
    }
    $script:infoMaquina = $info
}

function Testar-Memoria {
    $c = "Memória RAM"
    try {
        $pentes = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
        $arr = Get-CimInstance Win32_PhysicalMemoryArray -ErrorAction SilentlyContinue | Select-Object -First 1
        $totalSlots = if ($arr) { [int]$arr.MemoryDevices } else { 0 }
        $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory/1GB, 0)
    } catch {
        Res $c 'Indisponivel' 'Pentes de memória' 'Não foi possível ler os pentes de memória.'
        return
    }
    $slotsTxt = if ($totalSlots -gt 0) { "$($pentes.Count) de $totalSlots slot(s)" } else { "$($pentes.Count) pente(s)" }
    Res $c 'Info' 'Pentes instalados' $slotsTxt
    $n = 0
    foreach ($p in $pentes) {
        $n++
        $tipo = switch ($p.SMBIOSMemoryType) { 24 {"DDR3"} 26 {"DDR4"} 27 {"LPDDR"} 28 {"LPDDR2"} 29 {"LPDDR3"} 30 {"LPDDR4"} 34 {"DDR5"} 35 {"LPDDR5"} default {"tipo $($p.SMBIOSMemoryType)"} }
        $local = if ($p.DeviceLocator) { $p.DeviceLocator } else { "$n" }
        $fab = if ($p.Manufacturer -and $p.Manufacturer.Trim() -notmatch '^(Unknown|0+)$') { " - $($p.Manufacturer.Trim())" } else { "" }
        Res $c 'Info' "Pente (slot $local)" "$([math]::Round($p.Capacity/1GB,0)) GB $tipo $($p.Speed) MHz$fab"
    }
    $livres = $totalSlots - $pentes.Count
    if ($totalSlots -gt 0 -and $livres -gt 0) {
        Res $c 'Info' 'Slots livres' "$livres - dá para expandir a RAM sem trocar o pente atual."
    }
    if ($ramGB -le 4) {
        Res $c 'Problema' "Apenas $ramGB GB de RAM" "" "Isso é muito pouco para o Windows 11 - travamentos são esperados. Upgrade de memória é a melhor solução."
    } elseif ($ramGB -le 8) {
        Res $c 'Atencao' "$ramGB GB de RAM" "" "Suficiente para uso básico, mas trava com muitas abas/programas abertos ao mesmo tempo."
    } else {
        Res $c 'Ok' "$ramGB GB de RAM" "Quantidade adequada para uso profissional."
    }
}

function Testar-Disco {
    $c = "Saúde do disco (SMART)"
    try { $discos = @(Get-PhysicalDisk -ErrorAction Stop) } catch {
        Res $c 'Indisponivel' 'Saúde dos discos' 'Não foi possível ler o status SMART.' 'Execute o WinHealth como administrador.'
        return
    }
    $semContadores = $false
    foreach ($d in $discos) {
        $tipo = if ($d.MediaType -and $d.MediaType -ne 'Unspecified') { $d.MediaType } else { "tipo não identificado" }
        $desc = "$($d.FriendlyName) ($tipo, $([math]::Round($d.Size/1GB,0)) GB)"
        if ($d.HealthStatus -eq 'Healthy') {
            Res $c 'Ok' "Disco $desc" "Status de saúde informado pelo próprio disco: saudável."
        } else {
            Res $c 'Problema' "Disco $desc reporta falha" "Status informado pelo disco: $($d.HealthStatus)" "O PRÓPRIO DISCO ESTÁ REPORTANDO FALHA. Faça backup dos dados agora e planeje a troca."
        }
        try {
            $rel = $d | Get-StorageReliabilityCounter -ErrorAction Stop
        } catch {
            $semContadores = $true
            continue
        }
        if ($rel) {
            if ($rel.PowerOnHours) {
                Res $c 'Info' "Horas ligado ($($d.FriendlyName))" "$($rel.PowerOnHours) h (cerca de $([math]::Round($rel.PowerOnHours/8760,1)) ano(s) de uso real)"
            }
            if ($null -ne $rel.Wear -and $rel.Wear -gt 0) {
                if ($rel.Wear -gt 80) {
                    Res $c 'Problema' "SSD com desgaste alto: $($rel.Wear)% ($($d.FriendlyName))" "" "Comece a planejar a troca do SSD."
                } else {
                    Res $c 'Info' "Desgaste do SSD ($($d.FriendlyName))" "$($rel.Wear)%"
                }
            }
            if ($rel.ReadErrorsTotal -gt 0 -or $rel.WriteErrorsTotal -gt 0) {
                Res $c 'Problema' "Erros de leitura/escrita no disco $($d.FriendlyName)" "Leitura: $($rel.ReadErrorsTotal) | Escrita: $($rel.WriteErrorsTotal)" "Erros de leitura/escrita indicam disco em degradação. Faça backup e avalie a troca."
            }
        }
    }
    if ($semContadores) {
        Res $c 'Indisponivel' 'Contadores SMART detalhados' 'Não foi possível ler horas de uso, desgaste do SSD e erros de leitura/escrita.' 'Execute o WinHealth como administrador.'
    }
}

function Testar-EspacoDisco {
    $c = "Espaço em disco"
    $vols = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue)
    if ($vols.Count -eq 0) {
        Res $c 'Indisponivel' 'Espaço em disco' 'Não foi possível ler as unidades.'
        return
    }
    foreach ($v in $vols) {
        if ($v.Size -le 0) { continue }
        $livreGB = [math]::Round($v.FreeSpace/1GB, 1)
        $totalGB = [math]::Round($v.Size/1GB, 1)
        $pct = [math]::Round(($v.FreeSpace/$v.Size)*100, 0)
        $txt = "Unidade $($v.DeviceID) - $livreGB GB livres de $totalGB GB ($pct% livre)"
        if ($pct -lt 10) {
            Res $c 'Problema' $txt "" "Disco quase cheio. Abaixo de 10% livre o Windows fica MUITO lento e pode até travar."
        } elseif ($pct -lt 20) {
            Res $c 'Atencao' $txt "" "Pouco espaço livre - já começa a impactar o desempenho."
        } else {
            Res $c 'Ok' $txt
        }
    }
}

function Testar-Travamentos {
    $c = "Travamentos e telas azuis"
    $dumps = @(Get-ChildItem "$env:SystemRoot\Minidump\*.dmp" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($dumps.Count -gt 0) {
        $recentes = ($dumps | Select-Object -First 5 | ForEach-Object { "$($_.Name) - $($_.LastWriteTime.ToString('dd/MM/yyyy HH:mm'))" }) -join "`n"
        Res $c 'Problema' "$($dumps.Count) registro(s) de tela azul (minidump)" "Mais recentes:`n$recentes" "Abra os arquivos de $env:SystemRoot\Minidump com o BlueScreenView (ou WinDbg) para ver qual driver causou."
    } else {
        Res $c 'Ok' 'Nenhuma tela azul registrada' "Sem arquivos em $env:SystemRoot\Minidump."
    }

    if (-not $isAdmin) {
        Res $c 'Indisponivel' 'Histórico de eventos críticos do sistema' 'Requer administrador.' 'Execute o WinHealth como administrador para ver desligamentos inesperados e erros de hardware.'
        return
    }
    try {
        $limite = (Get-Date).AddDays(-30)
        $achou = $false
        $kp = @(Get-WinEvent -FilterHashtable @{LogName='System'; Id=41; StartTime=$limite} -ErrorAction SilentlyContinue)
        if ($kp.Count -gt 0) {
            $achou = $true
            $ultimos = ($kp | Select-Object -First 3 | ForEach-Object { $_.TimeCreated.ToString('dd/MM/yyyy HH:mm') }) -join ", "
            Res $c 'Problema' "$($kp.Count) desligamento(s) inesperado(s) nos últimos 30 dias" "Evento Kernel-Power 41. Mais recentes: $ultimos" "A máquina desligou/reiniciou sem avisar o Windows. Causas comuns: fonte fraca, superaquecimento, RAM com defeito ou driver ruim."
        }
        $whea = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$limite} -ErrorAction SilentlyContinue)
        if ($whea.Count -gt 0) {
            $achou = $true
            Res $c 'Problema' "$($whea.Count) erro(s) de HARDWARE registrados (WHEA) nos últimos 30 dias" "" "WHEA significa que o próprio processador/chipset reportou erro físico. Suspeite de RAM, CPU, superaquecimento ou fonte - raramente é problema de software."
        }
        $crit = @(Get-WinEvent -FilterHashtable @{LogName='System'; Level=1; StartTime=$limite} -ErrorAction SilentlyContinue)
        if ($crit.Count -gt 0) {
            $achou = $true
            Res $c 'Atencao' "$($crit.Count) evento(s) CRÍTICO(S) no log do sistema nos últimos 30 dias"
        }
        if (-not $achou) {
            Res $c 'Ok' 'Nenhum desligamento inesperado nem erro de hardware nos últimos 30 dias'
        }
    } catch {
        Res $c 'Indisponivel' 'Histórico de eventos críticos do sistema' "Falha ao ler o log de eventos: $($_.Exception.Message)"
    }
}

function Testar-Drivers {
    $c = "Drivers"
    try { $comErro = @(Get-PnpDevice -ErrorAction Stop | Where-Object { $_.Status -eq 'Error' -or $_.Status -eq 'Degraded' }) } catch {
        Res $c 'Indisponivel' 'Drivers com problema' 'Não foi possível verificar os drivers.'
        return
    }
    if ($comErro.Count -eq 0) {
        Res $c 'Ok' 'Nenhum dispositivo com erro no Gerenciador de Dispositivos'
        return
    }
    foreach ($dev in $comErro) {
        Res $c 'Problema' "Dispositivo com problema: $($dev.FriendlyName)" "Classe: $($dev.Class) | Status: $($dev.Status)" "Abra o Gerenciador de Dispositivos e reinstale o driver deste item."
    }
}

function Interpretar-Temperatura {
    param([double[]]$Leituras)
    $c = "Temperatura"
    # Leituras fora de 15..130 C sao lixo do firmware (ex.: uma zona ACPI que devolve 2 C num PC ligado).
    $validas = @($Leituras | Where-Object { $_ -ge 15 -and $_ -lt 130 })
    if ($validas.Count -eq 0) {
        $bruto = if (@($Leituras).Count -gt 0) { "Leitura recebida: $((@($Leituras) | ForEach-Object { [math]::Round($_, 1) }) -join ', ') °C, que não é plausível para um processador ligado." } else { 'Esta máquina não expõe a temperatura via Windows (ou requer administrador).' }
        return (Res $c 'Indisponivel' 'Temperatura do processador' $bruto 'Use HWMonitor ou Core Temp para medir a temperatura real.')
    }
    foreach ($celsius in $validas) {
        $nota = "Leitura da zona térmica ACPI do Windows; em alguns equipamentos ela não representa a temperatura do processador."
        if ($celsius -gt 85) {
            Res $c 'Problema' "Temperatura: $celsius °C" $nota "MUITO QUENTE. Provável poeira no cooler ou pasta térmica ressecada. Superaquecimento causa travamento e desligamento sozinho."
        } elseif ($celsius -gt 70) {
            Res $c 'Atencao' "Temperatura: $celsius °C" $nota "Está alta - vale limpar o cooler."
        } else {
            Res $c 'Ok' "Temperatura: $celsius °C" "Normal. $nota"
        }
    }
}

function Testar-Temperatura {
    try {
        $temp = @(Get-CimInstance -Namespace "root/wmi" -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop)
        Interpretar-Temperatura @($temp | ForEach-Object { [math]::Round(($_.CurrentTemperature / 10) - 273.15, 1) })
    } catch {
        Interpretar-Temperatura @()
    }
}

function Ler-BateriaXml {
    param([string]$Caminho)
    try {
        $x = New-Object Xml.XmlDocument
        $x.Load($Caminho)
        $b = @($x.BatteryReport.Batteries.Battery)[0]
        if (-not $b) { return $null }
        $d = [int64]$b.DesignCapacity; $f = [int64]$b.FullChargeCapacity
        if ($d -le 0 -or $f -le 0) { return $null }
        [pscustomobject]@{ Design = $d; Cheia = $f; Ciclos = $(if ($b.CycleCount) { [int]$b.CycleCount } else { $null }) }
    } catch { $null }
}

function Obter-CapacidadeBateria {
    $design = $null; $cheia = $null
    try { $design = (Get-CimInstance -Namespace "root/wmi" -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity } catch {}
    try { $cheia = (Get-CimInstance -Namespace "root/wmi" -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity } catch {}
    $ciclos = $null
    # Varios notebooks nao implementam BatteryStaticData: o relatorio do powercfg (XML) traz os mesmos numeros.
    $xmlPath = Join-Path $env:TEMP ("winhealth_bat_" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".xml")
    try {
        $null = Invoke-Comando 'powercfg.exe' @('/batteryreport', '/xml', '/output', "`"$xmlPath`"")
        $b = Ler-BateriaXml $xmlPath
        if ($b) { if (-not $design -or -not $cheia) { $design = $b.Design; $cheia = $b.Cheia }; $ciclos = $b.Ciclos }
    } finally { Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue }
    if ($design -gt 0 -and $cheia -gt 0) { [pscustomobject]@{ Design = [int64]$design; Cheia = [int64]$cheia; Ciclos = $ciclos } } else { $null }
}

function Testar-Bateria {
    $c = "Bateria (notebook)"
    $bat = $null
    try { $bat = Get-CimInstance Win32_Battery -ErrorAction Stop | Select-Object -First 1 } catch {}
    if (-not $bat) {
        Res $c 'Info' 'Bateria' 'Nenhuma bateria detectada (provavelmente um desktop).'
        return
    }
    Res $c 'Info' 'Bateria detectada' "$($bat.Name)"
    Res $c 'Info' 'Carga atual' "$($bat.EstimatedChargeRemaining)%"
    $estados = @{1 = "Descarregando"; 2 = "Na tomada"; 3 = "Carregada"; 4 = "Baixa"; 5 = "Crítica"; 6 = "Carregando"; 7 = "Carregando (baixa)"; 8 = "Carregando (alta)" }
    if ($estados.ContainsKey([int]$bat.BatteryStatus)) { Res $c 'Info' 'Estado' $estados[[int]$bat.BatteryStatus] }
    $cap = Obter-CapacidadeBateria
    if (-not $cap) {
        Res $c 'Indisponivel' 'Saúde da bateria (capacidade atual x original)' 'Não foi possível ler a capacidade da bateria.' 'Execute como administrador ou gere o relatório de bateria pela opção [5].'
        return
    }
    if ($cap.Ciclos) { Res $c 'Info' 'Ciclos de carga' "$($cap.Ciclos)" }
    $saude = [math]::Round(($cap.Cheia / $cap.Design) * 100, 0)
    $det = "Capacidade atual $($cap.Cheia) mWh de $($cap.Design) mWh de projeto."
    $txt = "Saúde da bateria: $saude% da capacidade original"
    if ($saude -lt 60) { Res $c 'Problema' $txt $det "Bateria bem gasta, considere trocar." }
    elseif ($saude -lt 80) { Res $c 'Atencao' $txt $det "Desgaste já perceptível." }
    else { Res $c 'Ok' $txt $det }
}

function Testar-Protecao {
    $c = "Proteção e atualizações"
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        if ($mp.RealTimeProtectionEnabled) {
            Res $c 'Ok' 'Windows Defender: proteção em tempo real ligada'
        } else {
            $outros = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue | Where-Object { $_.displayName -notmatch 'Defender' } | ForEach-Object { $_.displayName })
            if ($outros.Count -gt 0) {
                Res $c 'Info' 'Defender em tempo real desligado' "antivírus de terceiros detectado ($($outros -join ', ')). Confirme que ele está ativo e atualizado."
            } else {
                Res $c 'Problema' 'Windows Defender: proteção em tempo real DESLIGADA' "Nenhum outro antivírus detectado." "A máquina está desprotegida. Ligue a proteção ou instale um antivírus."
            }
        }
        Res $c 'Info' 'Assinaturas de vírus atualizadas em' "$($mp.AntivirusSignatureLastUpdated.ToString('dd/MM/yyyy HH:mm'))"
    } catch {
        Res $c 'Indisponivel' 'Status do Windows Defender' 'Não foi possível ler o status do Defender (pode haver outro antivírus gerenciando a máquina).'
    }
    try {
        $sessao = New-Object -ComObject Microsoft.Update.Session
        $busca = $sessao.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0")
        if ($busca.Updates.Count -gt 0) {
            Res $c 'Atencao' "$($busca.Updates.Count) atualização(ões) do Windows pendente(s)" "" "Instale as atualizações pelo Windows Update (correções de segurança e estabilidade)."
        } else {
            Res $c 'Ok' 'Windows em dia' 'Nenhuma atualização pendente.'
        }
    } catch {
        Res $c 'Indisponivel' 'Atualizações do Windows' 'Não foi possível verificar as atualizações pendentes.'
    }
}

function Testar-Processos {
    $c = "Programas que mais usam memória agora"
    $top = Get-Process -ErrorAction SilentlyContinue | Group-Object ProcessName | ForEach-Object {
        [pscustomobject]@{ Nome = $_.Name; MB = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum/1MB, 0) }
    } | Sort-Object MB -Descending | Select-Object -First 5
    foreach ($p in $top) { Res $c 'Info' $p.Nome "$($p.MB) MB" }
}

# So a coleta (I/O real, o COM do Windows Update). Devolve os titulos crus; quem decide severidade/
# texto e a Interpretar-AtualizacoesDriver (pura), separada pra dar pra testar sem bater no Windows.
function Coletar-AtualizacoesDriver {
    try {
        $sessao = New-Object -ComObject Microsoft.Update.Session
        $busca = $sessao.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Driver'")
        [pscustomobject]@{ Ok = $true; Titulos = @($busca.Updates | ForEach-Object { $_.Title }) }
    } catch {
        [pscustomobject]@{ Ok = $false; Titulos = @() }
    }
}

function Interpretar-AtualizacoesDriver {
    param($Coletado)
    $c = "Atualizações de driver"
    if (-not $Coletado.Ok) {
        Res $c 'Indisponivel' 'Atualizações de driver' 'Não foi possível consultar o Windows Update para drivers.'
        return
    }
    $titulos = @($Coletado.Titulos)
    if ($titulos.Count -eq 0) {
        Res $c 'Ok' 'Nenhuma atualização de driver pendente no Windows Update'
        return
    }
    foreach ($t in $titulos) {
        Res $c 'Atencao' "Driver desatualizado: $t" '' 'Abra Configurações > Windows Update > Atualizações opcionais para instalar.'
    }
}

function Testar-AtualizacoesDriver { Interpretar-AtualizacoesDriver (Coletar-AtualizacoesDriver) }

$script:ChecksDiagnostico = @(
    @{ Rotulo = "identificação da máquina"; Funcao = "Testar-Identificacao" },
    @{ Rotulo = "memória RAM";              Funcao = "Testar-Memoria" },
    @{ Rotulo = "saúde do disco";           Funcao = "Testar-Disco" },
    @{ Rotulo = "espaço em disco";          Funcao = "Testar-EspacoDisco" },
    @{ Rotulo = "telas azuis e desligamentos"; Funcao = "Testar-Travamentos" },
    @{ Rotulo = "drivers";                  Funcao = "Testar-Drivers" },
    @{ Rotulo = "temperatura";              Funcao = "Testar-Temperatura" },
    @{ Rotulo = "bateria";                  Funcao = "Testar-Bateria" },
    @{ Rotulo = "proteção e atualizações (pode demorar)"; Funcao = "Testar-Protecao" },
    @{ Rotulo = "atualizações de driver (pode demorar)"; Funcao = "Testar-AtualizacoesDriver" },
    @{ Rotulo = "consumo de memória";       Funcao = "Testar-Processos" }
)

function Mostrar-Resultados {
    param($resultados, [switch]$SemCabecalho)
    $rotulos = @{ Ok = "[OK]       "; Info = "           "; Atencao = "[ATENCAO]  "; Problema = "[PROBLEMA] "; Indisponivel = "[?]        " }
    $cores = @{ Ok = "Green"; Info = "White"; Atencao = "DarkYellow"; Problema = "Red"; Indisponivel = "DarkGray" }
    $ultima = $null
    foreach ($x in $resultados) {
        if ($x.Categoria -ne $ultima) { if (-not $SemCabecalho) { Secao $x.Categoria }; $ultima = $x.Categoria }
        $pre = $rotulos[$x.Severidade]
        $linha = if ($x.Severidade -eq 'Info' -and $x.Detalhe) { "$($x.Titulo): $($x.Detalhe)" } else { $x.Titulo }
        Write-Host ($pre + $linha) -ForegroundColor $cores[$x.Severidade]
        Add-Content -Path $logfile -Value ($pre + $linha)
        if ($x.Severidade -ne 'Info') {
            if ($x.Detalhe) {
                foreach ($l in ($x.Detalhe -split "`n")) {
                    Write-Host ("           " + $l) -ForegroundColor DarkGray
                    Add-Content -Path $logfile -Value ("           " + $l)
                }
            }
            if ($x.Recomendacao) {
                Write-Host ("           -> " + $x.Recomendacao) -ForegroundColor DarkYellow
                Add-Content -Path $logfile -Value ("           -> " + $x.Recomendacao)
            }
        }
        switch ($x.Severidade) {
            'Problema' { $script:achados++ }
            'Atencao' { $script:achadosBaixos++ }
            'Indisponivel' { $script:indisponiveis++ }
        }
    }
}

$script:CssRelatorio = @'
:root{--bg:#f4f5f7;--surface:#fff;--text:#1a1d23;--muted:#5b6470;--border:#e2e5ea;--accent:#175cd3;
--prob:#b42318;--prob-bg:#fef3f2;--att:#93370d;--att-bg:#fffaeb;--ok:#067647;--ok-bg:#ecfdf3;--info:#175cd3;--na:#5b6470;--na-bg:#f2f4f7}
@media (prefers-color-scheme:dark){:root{--bg:#0f1216;--surface:#171b21;--text:#e8eaed;--muted:#9aa4b2;--border:#2a303a;--accent:#84adff;
--prob:#f97066;--prob-bg:#2a1615;--att:#fdb022;--att-bg:#2a2110;--ok:#47cd89;--ok-bg:#10251b;--info:#84adff;--na:#9aa4b2;--na-bg:#1e232b}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.55 system-ui,"Segoe UI",Roboto,Arial,sans-serif}
.wrap{max-width:860px;margin:0 auto;padding:0 16px 48px}
.top{display:flex;flex-wrap:wrap;gap:2px 16px;justify-content:space-between;align-items:baseline;padding:20px 0 12px;border-bottom:1px solid var(--border);margin-bottom:20px}
.brand{font-weight:700;font-size:18px;letter-spacing:.2px}.brand b{color:var(--accent)}
.top span{color:var(--muted);font-size:13px}
.hero{border-radius:14px;padding:22px 22px 18px;border:1px solid var(--border);background:var(--surface);border-left:6px solid var(--ok)}
.hero.attn{border-left-color:var(--att)}.hero.prob{border-left-color:var(--prob)}
.hero h1{margin:0 0 4px;font-size:24px;line-height:1.25}
.hero p{margin:0;color:var(--muted)}
.stats{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-top:18px}
.stat{border:1px solid var(--border);border-radius:10px;padding:10px 12px;background:var(--bg)}
.stat b{display:block;font-size:26px;line-height:1.1}.stat span{font-size:12.5px;color:var(--muted)}
.stat.prob b{color:var(--prob)}.stat.att b{color:var(--att)}.stat.ok b{color:var(--ok)}.stat.na b{color:var(--na)}
h2{font-size:15px;text-transform:uppercase;letter-spacing:.6px;color:var(--muted);margin:30px 0 10px}
.machine{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:6px 16px;margin-top:18px}
dl.kv{margin:0;display:grid;grid-template-columns:minmax(150px,32%) 1fr}
dl.kv dt,dl.kv dd{margin:0;padding:8px 0;border-bottom:1px solid var(--border)}
dl.kv dt{color:var(--muted)}dl.kv dd{overflow-wrap:anywhere}
dl.kv dt:last-of-type,dl.kv dd:last-of-type{border-bottom:0}
.item{display:flex;gap:12px;background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:12px 14px;margin-bottom:8px;break-inside:avoid}
.chip{flex:none;align-self:flex-start;font-size:12px;font-weight:700;padding:3px 9px;border-radius:999px;white-space:nowrap}
.item h3{margin:0;font-size:15px;line-height:1.4}
.item p{margin:4px 0 0;color:var(--muted);font-size:14px}
.item p.rec{color:var(--text)}
.sev-problema{border-left:5px solid var(--prob)}.sev-problema .chip{background:var(--prob-bg);color:var(--prob)}
.sev-atencao{border-left:5px solid var(--att)}.sev-atencao .chip{background:var(--att-bg);color:var(--att)}
.sev-ok{border-left:5px solid var(--ok)}.sev-ok .chip{background:var(--ok-bg);color:var(--ok)}
.sev-indisponivel{border-left:5px solid var(--na)}.sev-indisponivel .chip{background:var(--na-bg);color:var(--na)}
footer{margin-top:34px;padding-top:14px;border-top:1px solid var(--border);color:var(--muted);font-size:12.5px}
footer p{margin:4px 0}
@media (max-width:620px){.stats{grid-template-columns:repeat(2,1fr)}dl.kv{grid-template-columns:1fr}dl.kv dt{border-bottom:0;padding-bottom:0}.hero h1{font-size:21px}}
@media print{body{background:#fff}.hero,.item,.machine,.stat{box-shadow:none}.top span{color:#444}}
'@

function Exportar-RelatorioHtml {
    param($resultados, $info, [string]$caminho)
    $ErrorActionPreference = 'Stop'
    $h = { param($s) ([System.Net.WebUtility]::HtmlEncode([string]$s)) -replace "`r?`n", "<br>" }
    $sev = @{
        Problema     = @{ Rot = 'Problema';       Simb = '&#10005;'; Ordem = 0; Cls = 'problema' }
        Atencao      = @{ Rot = 'Atenção';        Simb = '!';        Ordem = 1; Cls = 'atencao' }
        Indisponivel = @{ Rot = 'Não verificado'; Simb = '?';        Ordem = 2; Cls = 'indisponivel' }
        Ok           = @{ Rot = 'Tudo certo';     Simb = '&#10003;'; Ordem = 3; Cls = 'ok' }
    }
    $nP = @($resultados | Where-Object { $_.Severidade -eq 'Problema' }).Count
    $nA = @($resultados | Where-Object { $_.Severidade -eq 'Atencao' }).Count
    $nOk = @($resultados | Where-Object { $_.Severidade -eq 'Ok' }).Count
    $nNa = @($resultados | Where-Object { $_.Severidade -eq 'Indisponivel' }).Count

    if ($nP -gt 0) {
        $cls = 'prob'; $veredito = 'Requer atenção'
        $sub = "$nP problema(s) encontrado(s)" + $(if ($nA -gt 0) { " e $nA ponto(s) de melhoria." } else { "." })
    } elseif ($nA -gt 0) {
        $cls = 'attn'; $veredito = 'Em bom estado, com pontos de melhoria'
        $sub = "$nA ponto(s) de baixo risco encontrado(s)."
    } else {
        $cls = 'ok'; $veredito = 'Máquina saudável'
        $sub = "Nenhum problema encontrado nas verificações realizadas."
    }
    if ($nNa -gt 0) { $sub += " $nNa verificação(ões) não puderam ser feitas (veja os itens 'Não verificado')." }

    $nome = & $h $(if ($info -and $info['Computador']) { $info['Computador'] } else { $env:COMPUTERNAME })
    $data = Get-Date -Format "dd/MM/yyyy HH:mm"
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html><html lang="pt-BR"><head><meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width,initial-scale=1">')
    [void]$sb.AppendLine("<title>WinHealth - Diagnóstico - $nome</title><style>$($script:CssRelatorio)</style></head><body><div class=""wrap"">")
    [void]$sb.AppendLine("<div class=""top""><div class=""brand"">Win<b>Health</b></div><span>Relatório de diagnóstico &middot; $data</span></div>")
    [void]$sb.AppendLine("<section class=""hero $cls""><h1>$(& $h $veredito)</h1><p>$(& $h $sub)</p>")
    [void]$sb.AppendLine("<div class=""stats""><div class=""stat prob""><b>$nP</b><span>Problemas</span></div><div class=""stat att""><b>$nA</b><span>Pontos de atenção</span></div><div class=""stat ok""><b>$nOk</b><span>Verificações OK</span></div><div class=""stat na""><b>$nNa</b><span>Não verificados</span></div></div></section>")

    if ($info -and $info.Count -gt 0) {
        [void]$sb.AppendLine('<div class="machine"><dl class="kv">')
        foreach ($k in $info.Keys) { [void]$sb.AppendLine("<dt>$(& $h $k)</dt><dd>$(& $h $info[$k])</dd>") }
        [void]$sb.AppendLine('</dl></div>')
    }

    $categorias = @()
    foreach ($x in $resultados) { if ($categorias -notcontains $x.Categoria) { $categorias += $x.Categoria } }
    foreach ($cat in $categorias) {
        $g = [pscustomobject]@{ Name = $cat; Group = @($resultados | Where-Object { $_.Categoria -eq $cat }) }
        $i = 0
        $cards = @($g.Group | Where-Object { $_.Severidade -ne 'Info' } | ForEach-Object { [pscustomobject]@{ I = $i++; X = $_ } } |
            Sort-Object @{ Expression = { $sev[$_.X.Severidade].Ordem } }, I | ForEach-Object { $_.X })
        $infos = @()
        if ($g.Name -ne 'Identificação da máquina') { $infos = @($g.Group | Where-Object { $_.Severidade -eq 'Info' }) }
        if ($cards.Count -eq 0 -and $infos.Count -eq 0) { continue }
        [void]$sb.AppendLine("<h2>$(& $h $g.Name)</h2>")
        foreach ($x in $cards) {
            $m = $sev[$x.Severidade]
            [void]$sb.Append("<article class=""item sev-$($m.Cls)""><span class=""chip"">$($m.Simb) $($m.Rot)</span><div><h3>$(& $h $x.Titulo)</h3>")
            if ($x.Detalhe) { [void]$sb.Append("<p>$(& $h $x.Detalhe)</p>") }
            if ($x.Recomendacao) { [void]$sb.Append("<p class=""rec""><strong>O que fazer:</strong> $(& $h $x.Recomendacao)</p>") }
            [void]$sb.AppendLine("</div></article>")
        }
        if ($infos.Count -gt 0) {
            [void]$sb.AppendLine('<div class="machine"><dl class="kv">')
            foreach ($x in $infos) { [void]$sb.AppendLine("<dt>$(& $h $x.Titulo)</dt><dd>$(& $h $x.Detalhe)</dd>") }
            [void]$sb.AppendLine('</dl></div>')
        }
    }

    $aviso = if (-not $isAdmin) { "<p>Executado sem privilégios de administrador: algumas verificações não puderam ser feitas (marcadas como &quot;Não verificado&quot;).</p>" } else { "" }
    [void]$sb.AppendLine("<footer><p>Relatório gerado automaticamente pelo WinHealth em $data. Reflete o estado da máquina no momento da verificação.</p>$aviso<p>Nenhum software detecta com certeza todas as falhas físicas de hardware; este relatório é um apoio ao diagnóstico técnico.</p></footer></div></body></html>")
    [IO.File]::WriteAllText($caminho, $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
}

function Coletar-Diagnostico {
    param([switch]$Mostrar, [scriptblock]$OnProgresso)
    $script:infoMaquina = [ordered]@{}
    $todos = @()
    $total = @($script:ChecksDiagnostico).Count
    $i = 0
    foreach ($check in $script:ChecksDiagnostico) {
        $i++
        if ($Mostrar) { Write-Host "  Verificando: $($check.Rotulo)..." -ForegroundColor DarkGray }
        if ($OnProgresso) { & $OnProgresso $check.Rotulo $i $total }
        $res = @(& $check.Funcao | Where-Object { $_ -and $_.PSObject.Properties['Severidade'] })
        if ($Mostrar) { Mostrar-Resultados $res }
        $todos += $res
    }
    $todos
}

function Modulo-Diagnostico {
    Clear-Host
    $script:achados = 0
    $script:achadosBaixos = 0
    $script:indisponiveis = 0
    $todos = @(Coletar-Diagnostico -Mostrar)

    Write-Host ""
    Write-Host "====================================================================" -ForegroundColor Cyan
    Write-Host "  RESUMO DO DIAGNOSTICO" -ForegroundColor Cyan
    Write-Host "====================================================================" -ForegroundColor Cyan
    Add-Content -Path $logfile -Value ""
    Add-Content -Path $logfile -Value "==================== RESUMO ===================="
    if ($script:achados -gt 0) {
        Write-Host ""
        Write-Host "  $($script:achados) PROBLEMA(S) QUE PRECISAM DE ATENCAO  " -ForegroundColor White -BackgroundColor Red
        Add-Content -Path $logfile -Value "$($script:achados) problema(s) que precisam de atencao."
    }
    if ($script:achadosBaixos -gt 0) {
        Write-Host ""
        Write-Host "  $($script:achadosBaixos) PONTO(S) DE MELHORIA - baixo risco  " -ForegroundColor Black -BackgroundColor DarkYellow
        Add-Content -Path $logfile -Value "$($script:achadosBaixos) ponto(s) de melhoria."
    }
    if ($script:achados -eq 0 -and $script:achadosBaixos -eq 0) {
        Write-Host ""
        Write-Host "  NENHUM PROBLEMA ENCONTRADO - MAQUINA SAUDAVEL  " -ForegroundColor White -BackgroundColor DarkGreen
        Add-Content -Path $logfile -Value "Nenhum problema encontrado."
    }
    if ($script:indisponiveis -gt 0) {
        Write-Host ""
        Write-Host "  $($script:indisponiveis) verificacao(oes) NAO puderam ser feitas (itens marcados com [?])." -ForegroundColor DarkGray
        Add-Content -Path $logfile -Value "$($script:indisponiveis) verificacao(oes) nao puderam ser feitas."
    }
    Write-Host ""
    Write-Host "Relatorio de texto salvo em:" -ForegroundColor Gray
    Write-Host $logfile -ForegroundColor Gray

    $arqHtml = Join-Path $pastaRelatorios "$nomeMaquina`_Diagnostico_$carimbo.html"
    try {
        Exportar-RelatorioHtml $todos $script:infoMaquina $arqHtml
        Write-Host ""
        Write-Host "Relatorio para o cliente (HTML) salvo em:" -ForegroundColor Green
        Write-Host $arqHtml -ForegroundColor Green
        $ab = Read-Host "Abrir o relatorio no navegador agora? (S/N)"
        if ($ab -match '^[Ss]') { Start-Process $arqHtml }
    } catch {
        Write-Host "Nao foi possivel gerar o relatorio HTML: $($_.Exception.Message)" -ForegroundColor Red
    }
    if (-not $isAdmin -and $script:indisponiveis -gt 0) {
        Write-Host ""
        Write-Host "Várias verificações ficaram '[?]' porque o WinHealth não está como administrador." -ForegroundColor Yellow
        $r = Read-Host "Reabrir como administrador e rodar o diagnóstico completo agora? (S/N)"
        if ($r -match '^[Ss]') {
            if (Reabrir-ComoAdmin '1') { $script:encerrar = $true; return }
        }
    }
    Pausa
}

# ===================== MODULO 2 - SCANNER DE VIRUS =====================
function Modulo-Scanner {
    Clear-Host
    Secao "SCANNER ANTI-MALWARE"
    $caminhoScanner = Join-Path $pastaFerramentas "SCANNER ANTI-MINERADOR v4.bat"
    if (Test-Path $caminhoScanner) {
        Write-Host "Abrindo o Scanner Anti-Minerador v4 (34 etapas)..." -ForegroundColor Cyan
        Write-Host "Ele abre em uma janela propria. Volte aqui quando terminar." -ForegroundColor DarkGray
        if ($modoRede) {
            $copiaLocal = Join-Path $env:TEMP "SCANNER_ANTI-MINERADOR_v4.bat"
            Copy-Item -LiteralPath $caminhoScanner -Destination $copiaLocal -Force
            $caminhoScanner = $copiaLocal
        }
        # o scanner grava o relatorio na pasta de relatorios do WinHealth (e nao solto no Desktop do cliente)
        # -Verb RunAs com -ArgumentList falha silenciosamente se JA estamos admin (achado 28/09/2026,
        # ver comentario grande em Rodar-ScannerGui) - so usar o verbo quando for preciso elevar de verdade.
        if ($isAdmin) { Start-Process -FilePath $caminhoScanner -ArgumentList "`"$pastaRelatorios`"" }
        else { Start-Process -FilePath $caminhoScanner -ArgumentList "`"$pastaRelatorios`"" -Verb RunAs }
    } else {
        Write-Host "Scanner nao encontrado." -ForegroundColor Red
        Write-Host ""
        Write-Host "Coloque o arquivo 'SCANNER ANTI-MINERADOR v4.bat' dentro da pasta:" -ForegroundColor DarkYellow
        Write-Host "  $pastaFerramentas" -ForegroundColor White
        Write-Host ""
        Write-Host "(Se a pasta nao existir, crie ela junto do WinHealth.bat)" -ForegroundColor DarkGray
    }
    Pausa
}

# ===================== MODULO 3 - REPARO DO WINDOWS =====================
# Invoke-Comando roda um programa externo e devolve codigo de saida + texto (com progresso ao vivo).
# Interpretar-* sao funcoes PURAS (codigo + texto -> objetos Res), testaveis sem rodar DISM/SFC/CHKDSK.
# O codigo de saida e a base da decisao (nao depende do idioma do Windows); o texto so refina.

function Ler-SaidaComando {
    param([string]$Caminho, [ValidateSet('Oem', 'Ansi')][string]$Codificacao = 'Oem')
    if (-not (Test-Path -LiteralPath $Caminho)) { return "" }
    try {
        $fs = New-Object IO.FileStream($Caminho, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { $ms = New-Object IO.MemoryStream; $fs.CopyTo($ms); $bytes = $ms.ToArray() } finally { $fs.Dispose() }
    } catch { return "" }
    if ($bytes.Length -eq 0) { return "" }
    # SFC grava UTF-16 (com NULs) quando redirecionado; DISM/CHKDSK gravam na pagina de codigo OEM do console.
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $txt = [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    } elseif ([Array]::IndexOf($bytes, [byte]0) -ge 0) {
        $txt = [Text.Encoding]::Unicode.GetString($bytes)
    } else {
        # DISM grava em OEM (CP850); CHKDSK grava em ANSI (CP1252): a ferramenta diz qual usar.
        try { $txt = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes) }
        catch {
            $enc = [Text.Encoding]::Default
            $ti = [Globalization.CultureInfo]::CurrentCulture.TextInfo
            try { $enc = [Text.Encoding]::GetEncoding($(if ($Codificacao -eq 'Oem') { $ti.OEMCodePage } else { $ti.ANSICodePage })) } catch {}
            $txt = $enc.GetString($bytes)
        }
    }
    $txt -replace "`0", ""
}

function Ultima-Mensagem {
    param([string]$Saida)
    $u = Ultima-LinhaUtil $Saida
    if ($u) { "Última mensagem do programa: $u" } else { "" }
}

function Ultima-LinhaUtil {
    param([string]$Texto)
    $linhas = @($Texto -split "[\r\n]+" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($linhas.Count -eq 0) { return "" }
    $linhas[-1]
}

function Invoke-Comando {
    param([string]$Exe, [string[]]$Argumentos = @(), [scriptblock]$AoProgredir = $null, [ValidateSet('Oem', 'Ansi')][string]$Codificacao = 'Oem')
    $arq = Join-Path $env:TEMP ("winhealth_cmd_" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".txt")
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = [pscustomobject]@{ Exe = $Exe; Argumentos = ($Argumentos -join ' '); Codigo = $null; Saida = ""; Duracao = [timespan]::Zero; ErroInicio = $null }
    try {
        $sp = @{ FilePath = $Exe; NoNewWindow = $true; PassThru = $true; RedirectStandardOutput = $arq; RedirectStandardError = "$arq.err"; ErrorAction = 'Stop' }
        if ($Argumentos.Count -gt 0) { $sp.ArgumentList = $Argumentos }
        $p = Start-Process @sp
        $null = $p.Handle
        while (-not $p.WaitForExit(2000)) {
            if ($AoProgredir) { & $AoProgredir $sw.Elapsed.ToString('hh\:mm\:ss') (Ultima-LinhaUtil (Ler-SaidaComando $arq $Codificacao)) }
        }
        $p.WaitForExit()
        $r.Codigo = $p.ExitCode
    } catch { $r.ErroInicio = $_.Exception.Message }
    $r.Saida = (Ler-SaidaComando $arq $Codificacao) + (Ler-SaidaComando "$arq.err" $Codificacao)
    Remove-Item -LiteralPath $arq, "$arq.err" -Force -ErrorAction SilentlyContinue
    $r.Duracao = $sw.Elapsed
    $r
}

function Interpretar-Dism {
    param($Codigo, [string]$Saida)
    $c = "Etapa 1 de 3 - DISM (imagem do Windows)"
    if ($null -eq $Codigo) { return (Res $c 'Problema' 'Não foi possível executar o DISM' '' 'Confirme que o WinHealth está como administrador e que o DISM.exe existe nesta máquina.') }
    $cod = [int]$Codigo
    $hex = '0x{0:X8}' -f $cod
    if ($cod -eq 0) { return (Res $c 'Ok' 'DISM concluído: a imagem do Windows está íntegra' 'A imagem do componente foi verificada/reparada sem erros.') }
    if ($cod -eq 3010) { return (Res $c 'Ok' 'DISM concluído (requer reinício)' 'O reparo terminou, mas o Windows precisa reiniciar para finalizar.') }
    if ($cod -eq -2146498529) { return (Res $c 'Problema' "DISM não encontrou os arquivos de origem ($hex)" '' 'Verifique a conexão com a internet (o DISM baixa os arquivos da Microsoft) ou use uma ISO do Windows: DISM /Online /Cleanup-Image /RestoreHealth /Source:wim:X:\sources\install.wim:1 /LimitAccess') }
    if ($cod -eq -2146498298) { return (Res $c 'Problema' "DISM não conseguiu baixar os arquivos de origem ($hex)" '' 'Verifique internet, proxy ou o servidor de atualizações (WSUS) da rede.') }
    Res $c 'Problema' "DISM terminou com erro ($hex)" ("Código de saída: $cod`n" + (Ultima-Mensagem $Saida)).Trim() 'Veja os detalhes em C:\Windows\Logs\DISM\dism.log e no relatório desta sessão.'
}

function Interpretar-Sfc {
    param($Codigo, [string]$Saida)
    $c = "Etapa 2 de 3 - SFC (arquivos do sistema)"
    if ($null -eq $Codigo) { return (Res $c 'Problema' 'Não foi possível executar o SFC' '' 'Confirme que o WinHealth está como administrador.') }
    if ($Saida -match 'não foi possível corrigir|não foi possível reparar|was unable to fix') {
        return (Res $c 'Problema' 'O SFC encontrou corrupção que NÃO conseguiu reparar' '' 'Guarde o relatório e o log C:\Windows\Logs\CBS\CBS.log. Se o DISM da etapa anterior falhou, resolva ele primeiro; pode ser necessário reinstalar o Windows.')
    }
    if ($Saida -match 'reparo do sistema pendente|repair pending') {
        return (Res $c 'Atencao' 'Há um reparo do sistema pendente' 'O SFC não pôde rodar antes de um reinício.' 'Reinicie a máquina e rode o reparo de novo.')
    }
    if ($Saida -match 'reparou com êxito|successfully repaired') { return (Res $c 'Ok' 'O SFC encontrou arquivos corrompidos e os REPAROU') }
    if ($Saida -match 'não encontrou nenhuma violação|did not find any integrity violations') { return (Res $c 'Ok' 'SFC: nenhum arquivo de sistema corrompido') }
    if ([int]$Codigo -eq 0) { return (Res $c 'Ok' 'SFC concluído sem erros' 'O programa terminou com sucesso (o texto de saída está no idioma da máquina; veja o relatório).') }
    Res $c 'Atencao' "O SFC terminou com código $([int]$Codigo)" ("Resultado não confirmado.`n" + (Ultima-Mensagem $Saida)).Trim() 'Reinicie e rode de novo; detalhes em C:\Windows\Logs\CBS\CBS.log.'
}

function Interpretar-Chkdsk {
    param($Codigo, [string]$Saida)
    $c = "Etapa 3 de 3 - CHKDSK (disco)"
    if ($null -eq $Codigo) { return (Res $c 'Indisponivel' 'Não foi possível executar o CHKDSK') }
    if ($Saida -match 'não encontrou problemas|found no problems' -or [int]$Codigo -eq 0) {
        return (Res $c 'Ok' 'CHKDSK: nenhum problema no sistema de arquivos')
    }
    Res $c 'Atencao' "O CHKDSK não concluiu sem erros (código $([int]$Codigo))" ("Pode indicar erros no disco OU que a verificação não pôde rodar.`n" + (Ultima-Mensagem $Saida)).Trim() "Leia a mensagem acima. Se forem erros no disco, faça backup e rode 'chkdsk $env:SystemDrive /f /r' e reinicie (demora horas)."
}

function Mostrar-Progresso {
    param($Decorrido, $Linha)
    $largura = 100
    try { $largura = $Host.UI.RawUI.WindowSize.Width - 2 } catch {}
    $txt = "  [$Decorrido] $Linha"
    if ($txt.Length -gt $largura) { $txt = $txt.Substring(0, $largura) }
    Write-Host ("`r" + $txt.PadRight($largura)) -NoNewline -ForegroundColor DarkGray
}

function Executar-EtapaReparo {
    param([string]$Cabecalho, [string]$Exe, [string[]]$Argumentos, [string]$Interpretador, [string]$Aviso = "", [string]$Codificacao = 'Oem')
    Secao $Cabecalho
    if ($Aviso) { Write-Host $Aviso -ForegroundColor DarkYellow }
    $cmd = Invoke-Comando $Exe $Argumentos { param($d, $l) Mostrar-Progresso $d $l } $Codificacao
    Write-Host ""
    Write-Host ("  Concluído em {0} (código de saída: {1})" -f $cmd.Duracao.ToString('hh\:mm\:ss'), $(if ($null -eq $cmd.Codigo) { 'n/d' } else { $cmd.Codigo })) -ForegroundColor DarkGray
    if ($cmd.ErroInicio) { Write-Host "  Erro ao iniciar: $($cmd.ErroInicio)" -ForegroundColor Red }
    Add-Content -Path $logfile -Value "----- $Exe $($cmd.Argumentos) | código $($cmd.Codigo) | duração $($cmd.Duracao.ToString('hh\:mm\:ss')) -----"
    Add-Content -Path $logfile -Value $cmd.Saida
    $res = @(& $Interpretador $cmd.Codigo $cmd.Saida)
    Mostrar-Resultados $res -SemCabecalho
    $res
}

function Modulo-Reparo {
    Clear-Host
    $script:achados = 0
    $script:achadosBaixos = 0
    $script:indisponiveis = 0
    Secao "REPARO DO WINDOWS"
    if (-not (ExigirAdmin)) { return }

    Write-Host "Este reparo executa, NESTA ORDEM (que é a ordem correta):" -ForegroundColor White
    Write-Host ""
    Write-Host "  1. DISM   - conserta a IMAGEM base do Windows (baixa arquivos da Microsoft)" -ForegroundColor Gray
    Write-Host "  2. SFC    - conserta os ARQUIVOS do sistema usando a imagem já corrigida" -ForegroundColor Gray
    Write-Host "  3. CHKDSK - verifica erros no sistema de arquivos do disco" -ForegroundColor Gray
    Write-Host ""
    Write-Host "A ordem importa: rodar SFC antes do DISM é o erro mais comum, porque o" -ForegroundColor DarkYellow
    Write-Host "SFC repara usando uma imagem que pode estar corrompida também." -ForegroundColor DarkYellow
    Write-Host ""
    Write-Host "Tempo estimado: 15 a 40 minutos. Precisa de internet para o DISM." -ForegroundColor DarkYellow
    Write-Host ""
    $ok = Read-Host "Deseja continuar? (S/N)"
    if ($ok -notmatch '^[Ss]') { return }

    if (-not (CriarPontoRestauracao "WinHealth - antes do reparo do Windows")) { return }

    $null = Executar-EtapaReparo "ETAPA 1 de 3 - DISM (reparando a imagem do Windows)" "DISM.exe" @('/Online', '/Cleanup-Image', '/RestoreHealth') 'Interpretar-Dism' "Pode demorar bastante e ficar parado em 20%. É normal; o cronômetro abaixo mostra que continua rodando."
    $null = Executar-EtapaReparo "ETAPA 2 de 3 - SFC (reparando arquivos do sistema)" "sfc.exe" @('/scannow') 'Interpretar-Sfc'
    $null = Executar-EtapaReparo "ETAPA 3 de 3 - CHKDSK (verificando o disco)" "chkdsk.exe" @($env:SystemDrive, '/scan') 'Interpretar-Chkdsk' "Modo verificação (/scan): não corrige nada, só verifica." 'Ansi'

    Write-Host ""
    if ($script:achados -gt 0) {
        Write-Host "  REPARO CONCLUÍDO COM $($script:achados) PROBLEMA(S) - VEJA OS ITENS ACIMA  " -ForegroundColor White -BackgroundColor DarkRed
    } elseif ($script:achadosBaixos -gt 0) {
        Write-Host "  REPARO CONCLUÍDO COM $($script:achadosBaixos) PONTO(S) DE ATENÇÃO  " -ForegroundColor Black -BackgroundColor DarkYellow
    } else {
        Write-Host "  REPARO CONCLUÍDO SEM PROBLEMAS  " -ForegroundColor White -BackgroundColor DarkGreen
    }
    Write-Host ""
    Write-Host "Reinicie a máquina para finalizar qualquer reparo aplicado." -ForegroundColor Gray
    Write-Host "Relatório salvo em: $logfile" -ForegroundColor Gray
    Pausa
}

# ===================== LIMPEZA E OTIMIZACAO (menu 4) =====================
# Os alvos ficam numa TABELA (dado, nao logica). Mostra o que sera apagado ANTES de apagar.
# Regras de seguranca: nunca toca em raiz de unidade/perfil/pasta do Windows, nunca segue junctions,
# preserva os arquivos temporarios do proprio WinHealth e so esvazia a Lixeira com pergunta separada.

$script:AlvosLimpeza = @(
    @{ Id = 'TempUsuario'; Rotulo = 'Temporários do usuário'; Caminho = { $env:TEMP }; Admin = $false; Excluir = @('winhealth_*'); Servicos = @() },
    @{ Id = 'TempWindows'; Rotulo = 'Temporários do Windows'; Caminho = { "$env:SystemRoot\Temp" }; Admin = $true; Excluir = @(); Servicos = @() },
    @{ Id = 'INetCache'; Rotulo = 'Cache da internet (Windows)'; Caminho = { "$env:LOCALAPPDATA\Microsoft\Windows\INetCache" }; Admin = $false; Excluir = @(); Servicos = @() },
    @{ Id = 'WinUpdate'; Rotulo = 'Cache do Windows Update'; Caminho = { "$env:SystemRoot\SoftwareDistribution\Download" }; Admin = $true; Excluir = @(); Servicos = @('wuauserv', 'bits') }
)

function Formatar-Tamanho {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    "$([int64]$Bytes) B"
}

function Testar-CaminhoLimpeza {
    param([string]$Caminho)
    if ([string]::IsNullOrWhiteSpace($Caminho)) { return $false }
    if ($Caminho -notmatch '^([A-Za-z]:\\|\\\\)') { return $false }
    try { $c = [IO.Path]::GetFullPath($Caminho).TrimEnd('\') } catch { return $false }
    if ($c.Length -le 3) { return $false }
    $proibidos = @($env:USERPROFILE, $env:SystemRoot, "$env:SystemRoot\System32", $env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:SystemDrive\Users", $env:ProgramData, $env:LOCALAPPDATA, $env:APPDATA) |
        Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
    foreach ($p in $proibidos) { if ($c -ieq $p) { return $false } }
    $true
}

function Deve-Excluir {
    param([string]$Nome, [string[]]$Padroes)
    foreach ($p in @($Padroes)) { if ($p -and $Nome -like $p) { return $true } }
    $false
}

function Medir-Alvo {
    param([string]$Caminho, [string[]]$Excluir = @())
    $r = [pscustomobject]@{ Existe = $false; Bytes = [int64]0; Arquivos = 0 }
    if (-not $Caminho -or -not (Test-Path -LiteralPath $Caminho)) { return $r }
    $r.Existe = $true
    foreach ($item in @(Get-ChildItem -LiteralPath $Caminho -Force -ErrorAction SilentlyContinue)) {
        if (Deve-Excluir $item.Name $Excluir) { continue }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($item.PSIsContainer) {
            $m = Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
            $r.Bytes += [int64]$m.Sum; $r.Arquivos += [int]$m.Count
        } else {
            $r.Bytes += [int64]$item.Length; $r.Arquivos++
        }
    }
    $r
}

function Medir-Item {
    param([System.IO.FileSystemInfo]$Item)
    if (-not (Test-Path -LiteralPath $Item.FullName)) { return [pscustomobject]@{ Bytes = [int64]0; Arquivos = 0 } }
    if ($Item.PSIsContainer) {
        $m = Get-ChildItem -LiteralPath $Item.FullName -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
        return [pscustomobject]@{ Bytes = [int64]$m.Sum; Arquivos = [int]$m.Count }
    }
    [pscustomobject]@{ Bytes = [int64]$Item.Length; Arquivos = 1 }
}

function Limpar-Pasta {
    param([string]$Caminho, [string[]]$Excluir = @())
    if (-not (Testar-CaminhoLimpeza $Caminho)) { throw "Caminho não permitido para limpeza: '$Caminho'" }
    $ignorados = 0; $bytes = [int64]0; $removidos = 0; $restantes = 0
    foreach ($item in @(Get-ChildItem -LiteralPath $Caminho -Force -ErrorAction SilentlyContinue)) {
        if (Deve-Excluir $item.Name $Excluir) { continue }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $ignorados++; continue }
        $antes = Medir-Item $item
        $pular = $false
        if ($item.PSIsContainer) {
            $pular = @(Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -gt 0
            if ($pular) { $ignorados++ }
        }
        if (-not $pular) { Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        $depois = Medir-Item $item
        $bytes += [math]::Max([int64]0, $antes.Bytes - $depois.Bytes)
        $removidos += [math]::Max(0, $antes.Arquivos - $depois.Arquivos)
        $restantes += $depois.Arquivos
    }
    [pscustomobject]@{
        Caminho = $Caminho
        BytesLiberados = [int64]$bytes
        ArquivosRemovidos = [int]$removidos
        Restantes = [int]$restantes
        Ignorados = $ignorados
    }
}

function Interpretar-Limpeza {
    param([string]$Rotulo, $Resultado, [string]$Categoria = "Arquivos temporários e caches")
    if ($null -eq $Resultado) { return (Res $Categoria 'Indisponivel' $Rotulo 'Não foi possível limpar.') }
    $extra = @()
    if ($Resultado.Restantes -gt 0) { $extra += "$($Resultado.Restantes) arquivo(s) em uso foram mantidos." }
    if ($Resultado.Ignorados -gt 0) { $extra += "$($Resultado.Ignorados) item(ns) com atalhos de pasta (junction) foram ignorados por segurança." }
    if ($Resultado.BytesLiberados -gt 0 -or $Resultado.ArquivosRemovidos -gt 0) {
        return (Res $Categoria 'Ok' "$($Rotulo): $(Formatar-Tamanho $Resultado.BytesLiberados) liberados" (@("$($Resultado.ArquivosRemovidos) arquivo(s) removidos.") + $extra -join "`n"))
    }
    if ($Resultado.Restantes -gt 0) {
        return (Res $Categoria 'Atencao' "$($Rotulo): nada pôde ser removido" ($extra -join "`n") 'Feche os programas abertos e tente de novo, ou reinicie a máquina e rode a limpeza logo depois.')
    }
    Res $Categoria 'Info' $Rotulo 'já estava limpo.'
}

function Medir-Lixeira {
    try {
        $bin = (New-Object -ComObject Shell.Application).Namespace(0xA)
        $soma = [int64]0; $n = 0
        foreach ($i in $bin.Items()) { $soma += [int64]$i.Size; $n++ }
        [pscustomobject]@{ Bytes = $soma; Itens = $n }
    } catch { $null }
}

function Limpar-Alvo {
    param($Alvo)
    $cat = "Arquivos temporários e caches"
    $caminho = & $Alvo.Caminho
    if ($Alvo.Admin -and -not $isAdmin) { return (Res $cat 'Indisponivel' $Alvo.Rotulo 'Exige administrador.' 'Reabra como administrador (tecla A no menu) e rode de novo.') }
    if ($Alvo.Servicos.Count -gt 0) {
        if (Get-Process -Name TiWorker -ErrorAction SilentlyContinue) {
            return (Res $cat 'Atencao' "$($Alvo.Rotulo): pulado" 'O Windows está instalando atualizações agora.' 'Apagar esse cache no meio de uma instalação pode corromper a atualização. Rode a limpeza depois que terminar.')
        }
    }
    $estadoAntes = @{}
    foreach ($s in $Alvo.Servicos) {
        $estadoAntes[$s] = (Get-Service -Name $s -ErrorAction SilentlyContinue).Status
        if ($estadoAntes[$s] -eq 'Running') { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
    }
    try {
        $r = Limpar-Pasta $caminho $Alvo.Excluir
        $script:bytesLiberados += $r.BytesLiberados
        Interpretar-Limpeza $Alvo.Rotulo $r
    } catch {
        Res $cat 'Problema' $Alvo.Rotulo $_.Exception.Message
    } finally {
        foreach ($s in $Alvo.Servicos) { if ($estadoAntes[$s] -eq 'Running') { Start-Service -Name $s -ErrorAction SilentlyContinue } }
    }
}

function Limpar-CacheDns {
    $c = "Cache de DNS"
    $cmd = Invoke-Comando 'ipconfig.exe' @('/flushdns')
    if ($null -ne $cmd.Codigo -and [int]$cmd.Codigo -eq 0) { return (Res $c 'Ok' 'Cache de DNS limpo' 'Ajuda quando sites não abrem ou abrem errado.') }
    Res $c 'Indisponivel' 'Cache de DNS' ("Não foi possível limpar (código $($cmd.Codigo)).`n" + (Ultima-Mensagem $cmd.Saida)).Trim() 'Costuma exigir administrador (tecla A no menu).'
}

function Obter-ProgramasInicializacao {
    $runs = [ordered]@{
        'Usuário (Run)' = @{ Chave = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Aprovado = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
        'Todos os usuários (Run)' = @{ Chave = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; Aprovado = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
        'Todos os usuários 32 bits (Run)' = @{ Chave = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Aprovado = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
    }
    foreach ($origem in $runs.Keys) {
        $props = Get-ItemProperty -Path $runs[$origem].Chave -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        $aprov = Get-ItemProperty -Path $runs[$origem].Aprovado -ErrorAction SilentlyContinue
        foreach ($p in $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }) {
            # NAO usar "$v = if (...) {...} else {...}" aqui: essa forma (se/senao como EXPRESSAO)
            # faz o PowerShell desmembrar o array Byte[] em Object[] na saida do bloco, perdendo o
            # tipo - "$v -is [byte[]]" vira sempre falso e Habilitado sempre da certo (bug real,
            # achado 28/09/2026: o clique em Desativar gravava certo no registro, mas a tela nunca
            # refletia porque a RELEITURA sempre calculava Habilitado=true). Atribuir dentro de um
            # if-ESTATUTO comum preserva o tipo.
            $v = $null
            if ($aprov) { $v = $aprov.($p.Name) }
            $habilitado = -not ($v -is [byte[]] -and $v.Length -gt 0 -and ($v[0] -band 1) -eq 1)
            [pscustomobject]@{ Nome = $p.Name; Origem = $origem; Habilitado = $habilitado; ChaveAprovado = $runs[$origem].Aprovado; NomeValor = $p.Name }
        }
    }
    # A pasta de todos os usuarios nao tem uma chave StartupApproved propria e confiavel (o
    # Gerenciador de Tarefas as vezes reusa a mesma StartupFolder do usuario, as vezes nao) - por
    # seguranca, so a pasta do USUARIO fica alternavel; a de todos os usuarios fica so-leitura.
    $pastas = [ordered]@{
        'Pasta Inicializar (usuário)' = @{ Caminho = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"; Aprovado = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
        'Pasta Inicializar (todos)' = @{ Caminho = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"; Aprovado = $null }
    }
    foreach ($origem in $pastas.Keys) {
        $cfg = $pastas[$origem]
        $aprov = $null
        if ($cfg.Aprovado) { $aprov = Get-ItemProperty -Path $cfg.Aprovado -ErrorAction SilentlyContinue }
        Get-ChildItem -LiteralPath $cfg.Caminho -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object {
            $v = $null
            if ($aprov) { $v = $aprov.($_.Name) }
            $habilitado = -not ($v -is [byte[]] -and $v.Length -gt 0 -and ($v[0] -band 1) -eq 1)
            [pscustomobject]@{ Nome = $_.Name; Origem = $origem; Habilitado = $habilitado; ChaveAprovado = $cfg.Aprovado; NomeValor = $_.Name }
        }
    }
}

function Interpretar-Inicializacao {
    param($Itens)
    $c = "Programas que abrem com o Windows"
    $lista = @($Itens)
    foreach ($i in $lista) { Res $c 'Info' $i.Nome $i.Origem }
    if ($lista.Count -gt 8) {
        Res $c 'Atencao' "$($lista.Count) programas abrem junto com o Windows" 'Cada um consome memória desde o momento em que o PC liga.' 'Desative os desnecessários em: Configurações > Aplicativos > Inicialização. O WinHealth não desativa nada sozinho, porque alguns são importantes (antivírus, por exemplo).'
    } else {
        Res $c 'Info' 'Total de programas abrindo com o Windows' "$($lista.Count)"
    }
}

# Ativa/desativa um item de inicializacao (so na GUI - o console/relatorio continuam so leitura,
# igual sempre foram). Mesmo mecanismo que o Gerenciador de Tarefas usa: grava o bit de habilitado
# no StartupApproved correspondente (ver Obter-ProgramasInicializacao). NAO desinstala nem apaga
# nada - so controla se o Windows roda aquele item no login. Reversivel a qualquer momento.
function Alternar-ItemInicializacao {
    param($Item, [bool]$Habilitar)
    if (-not $Item.ChaveAprovado) { return $false }
    try {
        if (-not (Test-Path $Item.ChaveAprovado)) { New-Item -Path $Item.ChaveAprovado -Force -ErrorAction Stop | Out-Null }
        $atual = (Get-ItemProperty -Path $Item.ChaveAprovado -Name $Item.NomeValor -ErrorAction SilentlyContinue).($Item.NomeValor)
        $bytes = New-Object byte[] 12
        if ($atual -is [byte[]] -and $atual.Length -ge 1) { $bytes = [byte[]]$atual.Clone() }
        if ($Habilitar) { $bytes[0] = $bytes[0] -band 0xFE } else { $bytes[0] = $bytes[0] -bor 0x01 }
        New-ItemProperty -Path $Item.ChaveAprovado -Name $Item.NomeValor -Value $bytes -PropertyType Binary -Force -ErrorAction Stop | Out-Null
        $true
    } catch { $false }
}

function Modulo-Limpeza {
    Clear-Host
    $script:achados = 0
    $script:achadosBaixos = 0
    $script:indisponiveis = 0
    $script:bytesLiberados = [int64]0
    Secao "LIMPEZA E OTIMIZAÇÃO"
    Write-Host "Esta limpeza remove arquivos temporários e caches. Nenhum documento, foto ou programa" -ForegroundColor White
    Write-Host "é tocado. A Lixeira só é esvaziada se você pedir (pergunta separada, no final)." -ForegroundColor Green
    Write-Host ""
    Write-Host "Calculando o que pode ser liberado..." -ForegroundColor DarkGray
    Write-Host ""

    $previa = 0
    foreach ($alvo in $script:AlvosLimpeza) {
        if ($alvo.Admin -and -not $isAdmin) { Write-Host ("  {0,-34} requer administrador (será pulado)" -f $alvo.Rotulo) -ForegroundColor DarkGray; continue }
        $m = Medir-Alvo (& $alvo.Caminho) $alvo.Excluir
        if (-not $m.Existe) { Write-Host ("  {0,-34} não existe nesta máquina" -f $alvo.Rotulo) -ForegroundColor DarkGray; continue }
        $previa += $m.Bytes
        Write-Host ("  {0,-34} {1,10}  ({2} arquivos)" -f $alvo.Rotulo, (Formatar-Tamanho $m.Bytes), $m.Arquivos) -ForegroundColor White
    }
    Write-Host ""
    Write-Host "  Total estimado: $(Formatar-Tamanho $previa)" -ForegroundColor Cyan
    Write-Host ""
    $ok = Read-Host "Limpar agora? (S/N)"
    if ($ok -notmatch '^[Ss]') { return }

    Write-Host ""
    foreach ($alvo in $script:AlvosLimpeza) {
        Write-Host "  Limpando: $($alvo.Rotulo)..." -ForegroundColor DarkGray
        Mostrar-Resultados @(Limpar-Alvo $alvo)
    }

    Mostrar-Resultados @(Limpar-CacheDns)

    $lix = Medir-Lixeira
    if ($lix -and $lix.Itens -gt 0) {
        Secao "Lixeira"
        Write-Host "A Lixeira tem $($lix.Itens) item(ns), $(Formatar-Tamanho $lix.Bytes). São arquivos que o usuário jogou fora e" -ForegroundColor Yellow
        Write-Host "podem ser recuperados agora. Esvaziar NÃO tem volta." -ForegroundColor Yellow
        $r = Read-Host "Esvaziar a Lixeira? (S/N)"
        if ($r -match '^[Ss]') {
            try {
                Clear-RecycleBin -Force -ErrorAction Stop
                $script:bytesLiberados += $lix.Bytes
                Mostrar-Resultados @(Res "Lixeira" 'Ok' "Lixeira esvaziada: $(Formatar-Tamanho $lix.Bytes) liberados") -SemCabecalho
            } catch {
                Mostrar-Resultados @(Res "Lixeira" 'Indisponivel' 'Não foi possível esvaziar a Lixeira' $_.Exception.Message) -SemCabecalho
            }
        } else {
            Write-Host "  Lixeira mantida." -ForegroundColor DarkGray
        }
    }

    Mostrar-Resultados @(Interpretar-Inicializacao @(Obter-ProgramasInicializacao | Where-Object Habilitado))

    Write-Host ""
    Write-Host "  LIMPEZA CONCLUÍDA - $(Formatar-Tamanho $script:bytesLiberados) LIBERADOS  " -ForegroundColor White -BackgroundColor DarkGreen
    Pausa
}

# ===================== PREPARAR FORMATACAO (menu 6) =====================
# Dados SENSIVEIS (chave do Windows, senhas de Wi-Fi) so sao guardados se o tecnico optar e, nesse caso,
# ficam num arquivo CRIPTOGRAFADO com senha (AES-256 + HMAC-SHA256). Nunca vao para a tela nem para o
# relatorio de texto. O restante (drivers, lista de programas, mapa dos dados) nao e sensivel.

$script:CabecalhoProtegido = [Text.Encoding]::ASCII.GetBytes("WHENC1")

function Derivar-Chaves {
    param([string]$Senha, [byte[]]$Sal)
    $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($Senha, $Sal, 200000)
    $b = $kdf.GetBytes(64)
    @{ Enc = [byte[]]$b[0..31]; Mac = [byte[]]$b[32..63] }
}

function Proteger-Texto {
    param([string]$Texto, [string]$Senha)
    if ([string]::IsNullOrEmpty($Senha)) { throw "Senha vazia." }
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $sal = New-Object byte[] 16; $iv = New-Object byte[] 16
    $rng.GetBytes($sal); $rng.GetBytes($iv)
    $k = Derivar-Chaves $Senha $sal
    $aes = [Security.Cryptography.Aes]::Create()
    $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'; $aes.Key = $k.Enc; $aes.IV = $iv
    $plano = [Text.Encoding]::UTF8.GetBytes($Texto)
    $cif = $aes.CreateEncryptor().TransformFinalBlock($plano, 0, $plano.Length)
    $corpo = [byte[]]($script:CabecalhoProtegido + $sal + $iv + $cif)
    $tag = ([Security.Cryptography.HMACSHA256]::new($k.Mac)).ComputeHash($corpo)
    [byte[]]($corpo + $tag)
}

function Desproteger-Texto {
    param([byte[]]$Dados, [string]$Senha)
    $min = $script:CabecalhoProtegido.Length + 16 + 16 + 16 + 32
    if ($Dados.Length -lt $min) { throw "Arquivo inválido ou corrompido." }
    for ($i = 0; $i -lt $script:CabecalhoProtegido.Length; $i++) { if ($Dados[$i] -ne $script:CabecalhoProtegido[$i]) { throw "Este arquivo não foi criado pelo WinHealth." } }
    $o = $script:CabecalhoProtegido.Length
    $sal = [byte[]]$Dados[$o..($o + 15)]
    $iv = [byte[]]$Dados[($o + 16)..($o + 31)]
    $fimCorpo = $Dados.Length - 33
    $cif = [byte[]]$Dados[($o + 32)..$fimCorpo]
    $tag = [byte[]]$Dados[($Dados.Length - 32)..($Dados.Length - 1)]
    $k = Derivar-Chaves $Senha $sal
    $calc = ([Security.Cryptography.HMACSHA256]::new($k.Mac)).ComputeHash([byte[]]$Dados[0..$fimCorpo])
    $diff = 0
    for ($i = 0; $i -lt 32; $i++) { $diff = $diff -bor ($calc[$i] -bxor $tag[$i]) }
    if ($diff -ne 0) { throw "Senha incorreta ou arquivo alterado." }
    $aes = [Security.Cryptography.Aes]::Create()
    $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'; $aes.Key = $k.Enc; $aes.IV = $iv
    [Text.Encoding]::UTF8.GetString($aes.CreateDecryptor().TransformFinalBlock($cif, 0, $cif.Length))
}

function ConverterSecureString {
    param([securestring]$Segura)
    $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Segura)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
}

function Ler-SenhaProtecao {
    while ($true) {
        $a = ConverterSecureString (Read-Host "Defina uma senha para proteger os dados sensíveis (mín. 8 caracteres; ENTER vazio = não guardar)" -AsSecureString)
        if ($a.Length -eq 0) { return $null }
        if ($a.Length -lt 8) { Write-Host "  Senha curta demais (mínimo 8 caracteres)." -ForegroundColor Red; continue }
        $b = ConverterSecureString (Read-Host "Repita a senha" -AsSecureString)
        if ($a -ne $b) { Write-Host "  As senhas não conferem. Tente de novo." -ForegroundColor Red; continue }
        return $a
    }
}

function Obter-ChaveOem {
    try { (Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop).OA3xOriginalProductKey } catch { $null }
}

function Obter-EspacoLivreGB {
    param([string]$Caminho)
    try {
        $raiz = [IO.Path]::GetPathRoot($Caminho)
        if ($raiz.StartsWith('\\')) { return $null }
        $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($raiz.TrimEnd('\'))'" -ErrorAction Stop
        [math]::Round($d.FreeSpace / 1GB, 1)
    } catch { $null }
}

function Interpretar-ExportDrivers {
    param($Codigo, [int]$Quantidade, [string]$Pasta)
    $c = "2 de 5 - Backup dos drivers"
    if ($null -eq $Codigo) { return (Res $c 'Problema' 'Não foi possível executar o DISM para exportar os drivers') }
    if ([int]$Codigo -ne 0) { return (Res $c 'Problema' "A exportação de drivers falhou (código $([int]$Codigo))" '' 'Confirme que está como administrador e que há espaço livre no destino.') }
    if ($Quantidade -le 0) { return (Res $c 'Atencao' 'Nenhum driver foi exportado' 'O comando terminou sem erro, mas a pasta de destino está vazia.') }
    Res $c 'Ok' "$Quantidade driver(s) salvos" "Pasta: $Pasta`nDepois de formatar: Gerenciador de Dispositivos > botão direito no item sem driver > Atualizar driver > Procurar no meu computador > aponte para essa pasta."
}

function Obter-ProgramasInstalados {
    $chaves = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    @(Get-ItemProperty -Path $chaves -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } |
        Select-Object DisplayName, DisplayVersion, Publisher -Unique | Sort-Object DisplayName)
}

function Medir-Pasta {
    param([string]$Caminho)
    $m = Get-ChildItem -LiteralPath $Caminho -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
    [pscustomobject]@{ GB = [math]::Round(([double]$m.Sum) / 1GB, 2); Arquivos = [int]$m.Count }
}

function Esta-NoOneDrive {
    param([string]$Caminho, [string[]]$RaizesOneDrive)
    foreach ($r in @($RaizesOneDrive | Where-Object { $_ })) { if ($Caminho.StartsWith($r.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    $false
}

function Ler-PerfisWifiXml {
    param([string]$Pasta)
    foreach ($f in @(Get-ChildItem -LiteralPath $Pasta -Filter *.xml -ErrorAction SilentlyContinue)) {
        try {
            $x = New-Object Xml.XmlDocument
            $x.Load($f.FullName)
            $seg = $x.WLANProfile.MSM.security
            [pscustomobject]@{
                Nome = [string]$x.WLANProfile.name
                Autenticacao = [string]$seg.authEncryption.authentication
                Senha = [string]$seg.sharedKey.keyMaterial
            }
        } catch {}
    }
}

function Exportar-PerfisWifi {
    param([bool]$ComSenha)
    $tmp = Join-Path $env:TEMP ("winhealth_wifi_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $args = @('wlan', 'export', 'profile', "folder=`"$tmp`"")
        if ($ComSenha) { $args += 'key=clear' }
        $null = Invoke-Comando 'netsh.exe' $args
        @(Ler-PerfisWifiXml $tmp)
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Novo-TextoSensivel {
    param([string]$Maquina, [string]$Data, [string]$ChaveOem, $Wifi)
    $t = @("WinHealth - dados SENSÍVEIS de $Maquina ($Data)", "Apague este arquivo depois de reconfigurar a máquina.", "")
    if ($ChaveOem) { $t += "Chave OEM do Windows (gravada na BIOS): $ChaveOem"; $t += "" }
    $comSenha = @($Wifi | Where-Object { $_.Senha })
    if ($comSenha.Count -gt 0) {
        $t += "Redes Wi-Fi com senha:"
        foreach ($w in $comSenha) { $t += "  Rede: $($w.Nome) | Senha: $($w.Senha)" }
    }
    $t -join "`r`n"
}

function Preparar-ChaveWindows {
    param([bool]$Guardar)
    $c = "1 de 5 - Chave de ativação do Windows"
    $chave = Obter-ChaveOem
    if ($chave) {
        $script:sensivel.Chave = $chave
        if ($Guardar) { Res $c 'Ok' 'Chave OEM (gravada na BIOS) encontrada' 'Será guardada no arquivo protegido; o valor não é exibido nem gravado no relatório.' }
        else { Res $c 'Info' 'Chave OEM (gravada na BIOS) encontrada' 'não foi guardada (você optou por não salvar dados sensíveis); ela continua na BIOS e pode ser lida de novo depois.' }
    } else {
        Res $c 'Info' 'Sem chave OEM na BIOS' 'provavelmente a licença é digital, vinculada à conta Microsoft. Depois de formatar, basta entrar com a mesma conta Microsoft que o Windows reativa sozinho.'
    }
}

function Preparar-Drivers {
    param([string]$PastaBackup)
    $c = "2 de 5 - Backup dos drivers"
    if (-not $isAdmin) { return (Res $c 'Indisponivel' 'Backup dos drivers' 'Exige administrador.' 'Reabra como administrador (tecla A no menu) e rode de novo.') }
    $dest = Join-Path $PastaBackup "Drivers"
    New-Item -Path $dest -ItemType Directory -Force | Out-Null
    Write-Host "Exportando drivers... (pode demorar alguns minutos)" -ForegroundColor DarkYellow
    $cmd = Invoke-Comando 'DISM.exe' @('/Online', '/Export-Driver', "/Destination:`"$dest`"") { param($d, $l) Mostrar-Progresso $d $l }
    Write-Host ""
    $qtd = @(Get-ChildItem $dest -Directory -ErrorAction SilentlyContinue).Count
    Interpretar-ExportDrivers $cmd.Codigo $qtd $dest
}

function Preparar-Programas {
    param([string]$PastaBackup)
    $c = "3 de 5 - Programas instalados"
    $progs = @(Obter-ProgramasInstalados)
    if ($progs.Count -eq 0) { return (Res $c 'Indisponivel' 'Programas instalados' 'Não foi possível listar os programas.') }
    $arq = Join-Path $PastaBackup "programas_instalados.txt"
    [IO.File]::WriteAllText($arq, ($progs | Format-Table -AutoSize | Out-String -Width 200), (New-Object Text.UTF8Encoding($true)))
    Res $c 'Ok' "$($progs.Count) programa(s) listados" "Arquivo: programas_instalados.txt"
}

function Preparar-DadosUsuario {
    param([string]$PastaBackup)
    $c = "4 de 5 - Dados do usuário (o que precisa ser salvo)"
    $roots = @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer)
    $pastas = [ordered]@{
        'Desktop' = [Environment]::GetFolderPath('Desktop')
        'Documentos' = [Environment]::GetFolderPath('MyDocuments')
        'Downloads' = Join-Path $env:USERPROFILE 'Downloads'
        'Imagens' = [Environment]::GetFolderPath('MyPictures')
        'Vídeos' = [Environment]::GetFolderPath('MyVideos')
        'Música' = [Environment]::GetFolderPath('MyMusic')
    }
    $total = 0.0; $linhas = @()
    foreach ($nome in $pastas.Keys) {
        $cam = $pastas[$nome]
        if (-not $cam -or -not (Test-Path -LiteralPath $cam)) { continue }
        $m = Medir-Pasta $cam
        $total += $m.GB
        $nuvem = Esta-NoOneDrive $cam $roots
        $sufixo = if ($nuvem) { " [OneDrive: confirme se a sincronização está em dia]" } else { "" }
        Res $c 'Info' $nome "$($m.GB) GB ($($m.Arquivos) arquivos)$sufixo"
        $linhas += "$cam -> $($m.GB) GB ($($m.Arquivos) arquivos)$sufixo"
    }
    [IO.File]::WriteAllText((Join-Path $PastaBackup "dados_para_backup.txt"), ($linhas -join "`r`n"), (New-Object Text.UTF8Encoding($true)))
    $outros = @(Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users', $env:USERNAME) } | ForEach-Object { $_.Name })
    if ($outros.Count -gt 0) { Res $c 'Atencao' "Outros perfis de usuário nesta máquina NÃO foram mapeados: $($outros -join ', ')" '' 'Confira com o cliente se há dados nesses perfis, e em outros discos (D:, etc.).' }
    if ($total -gt 0) {
        Res $c 'Atencao' "Total do usuário atual: $([math]::Round($total, 2)) GB - será PERDIDO na formatação" 'Isso cobre só o usuário atual e as pastas padrão.' 'Copie para um HD externo ou nuvem ANTES de formatar. Não copie para o pendrive do Windows: ele será formatado também.'
    } else {
        Res $c 'Info' 'Total do usuário atual' 'nenhum dado encontrado nas pastas padrão.'
    }
}

function Preparar-Wifi {
    param([bool]$GuardarSenhas)
    $c = "5 de 5 - Redes Wi-Fi salvas"
    $perfis = @(Exportar-PerfisWifi $GuardarSenhas)
    if ($perfis.Count -eq 0) { return (Res $c 'Info' 'Redes Wi-Fi salvas' 'nenhuma encontrada.') }
    Res $c 'Info' "Redes Wi-Fi salvas ($($perfis.Count))" (($perfis | ForEach-Object { $_.Nome }) -join ', ')
    if (-not $GuardarSenhas) { return (Res $c 'Info' 'Senhas de Wi-Fi' 'não foram guardadas (você optou por não salvar dados sensíveis).') }
    $comSenha = @($perfis | Where-Object { $_.Senha })
    $script:sensivel.Wifi = $comSenha
    if ($comSenha.Count -gt 0) {
        Res $c 'Ok' "$($comSenha.Count) senha(s) de Wi-Fi guardadas" 'No arquivo protegido; não aparecem na tela nem no relatório. Redes corporativas (802.1X) não têm senha salva.'
    } elseif (-not $isAdmin) {
        Res $c 'Indisponivel' 'Senhas de Wi-Fi' 'Ler as senhas exige administrador.' 'Reabra como administrador (tecla A no menu) e rode de novo.'
    } else {
        Res $c 'Info' 'Senhas de Wi-Fi' 'nenhuma rede com senha salva (podem ser redes abertas ou corporativas 802.1X).'
    }
}

function Modulo-Formatar {
    Clear-Host
    $script:achados = 0
    $script:achadosBaixos = 0
    $script:indisponiveis = 0
    $script:sensivel = @{ Chave = $null; Wifi = @() }
    Secao "PREPARAÇÃO PARA FORMATAR"

    Write-Host "  LEIA ANTES DE CONTINUAR  " -ForegroundColor White -BackgroundColor DarkRed
    Write-Host ""
    Write-Host "Este módulo NÃO formata a máquina. É proposital, por dois motivos:" -ForegroundColor White
    Write-Host ""
    Write-Host " 1. Tecnicamente impossível: o Windows não consegue formatar o disco" -ForegroundColor Gray
    Write-Host "    em que ele mesmo está rodando. Formatar exige dar boot pelo" -ForegroundColor Gray
    Write-Host "    pendrive de instalação do Windows." -ForegroundColor Gray
    Write-Host ""
    Write-Host " 2. Segurança: um botão 'formatar agora' em um kit de técnico é a" -ForegroundColor Gray
    Write-Host "    forma mais fácil de apagar a máquina do cliente errado por engano." -ForegroundColor Gray
    Write-Host ""
    Write-Host "O que ele faz é o trabalho que REALMENTE importa antes de formatar:" -ForegroundColor Green
    Write-Host ""
    Write-Host "   [1] Localizar a chave de ativação do Windows" -ForegroundColor White
    Write-Host "   [2] Fazer BACKUP DOS DRIVERS da máquina (salva horas depois)" -ForegroundColor White
    Write-Host "   [3] Exportar a lista de programas instalados" -ForegroundColor White
    Write-Host "   [4] Mapear os dados do usuário e o tamanho de cada pasta" -ForegroundColor White
    Write-Host "   [5] Listar as redes Wi-Fi salvas" -ForegroundColor White
    Write-Host ""
    $ok = Read-Host "Deseja preparar a formatação agora? (S/N)"
    if ($ok -notmatch '^[Ss]') { return }

    Write-Host ""
    Write-Host "DADOS SENSÍVEIS: a chave do Windows e as SENHAS de Wi-Fi do cliente são confidenciais." -ForegroundColor Yellow
    Write-Host "Se você optar por guardá-las, ficam num arquivo CRIPTOGRAFADO com a senha que você definir" -ForegroundColor Yellow
    Write-Host "(nunca aparecem na tela nem no relatório). Se perder a senha, não há como recuperar." -ForegroundColor Yellow
    $senhaProtecao = $null
    $guardar = Read-Host "Guardar chave do Windows e senhas de Wi-Fi (protegidas por senha)? (S/N)"
    if ($guardar -match '^[Ss]') { $senhaProtecao = Ler-SenhaProtecao }
    $guardarSensivel = [bool]$senhaProtecao
    if (-not $guardarSensivel) { Write-Host "  OK: dados sensíveis NÃO serão guardados." -ForegroundColor DarkGray }

    $pastaBackup = Join-Path $pastaRelatorios "$nomeMaquina`_PreFormatacao_$carimbo"
    try { New-Item -Path $pastaBackup -ItemType Directory -Force -ErrorAction Stop | Out-Null } catch {
        Write-Host "Não foi possível criar a pasta de backup em $pastaBackup" -ForegroundColor Red
        Pausa
        return
    }
    $livre = Obter-EspacoLivreGB $pastaBackup
    if ($null -ne $livre -and $livre -lt 3) {
        Write-Host ""
        Write-Host "  ATENÇÃO: só há $livre GB livres no destino do backup. Os drivers costumam ocupar de 0,5 a 3 GB." -ForegroundColor Yellow
        $r = Read-Host "Continuar mesmo assim? (S/N)"
        if ($r -notmatch '^[Ss]') { return }
    }

    Mostrar-Resultados @(Preparar-ChaveWindows $guardarSensivel)
    Secao "2 de 5 - Backup dos drivers"
    Mostrar-Resultados @(Preparar-Drivers $pastaBackup) -SemCabecalho
    Mostrar-Resultados @(Preparar-Programas $pastaBackup)
    Mostrar-Resultados @(Preparar-DadosUsuario $pastaBackup)
    Mostrar-Resultados @(Preparar-Wifi $guardarSensivel)

    if ($guardarSensivel -and ($script:sensivel.Chave -or @($script:sensivel.Wifi).Count -gt 0)) {
        $arqSens = Join-Path $pastaBackup "dados_sensiveis.whenc"
        try {
            $texto = Novo-TextoSensivel $nomeMaquina (Get-Date -Format 'dd/MM/yyyy HH:mm') $script:sensivel.Chave $script:sensivel.Wifi
            [IO.File]::WriteAllBytes($arqSens, (Proteger-Texto $texto $senhaProtecao))
            Mostrar-Resultados @(Res "Dados sensíveis" 'Ok' 'Arquivo protegido criado: dados_sensiveis.whenc' 'Para ler: menu do WinHealth > opção 8 (precisa da senha que você definiu). Apague depois de reconfigurar a máquina.')
        } catch {
            Mostrar-Resultados @(Res "Dados sensíveis" 'Problema' 'Não foi possível criar o arquivo protegido' $_.Exception.Message)
        }
    }
    $senhaProtecao = $null
    $script:sensivel = @{ Chave = $null; Wifi = @() }

    Write-Host ""
    Write-Host "====================================================================" -ForegroundColor Green
    Write-Host "  PREPARAÇÃO CONCLUÍDA" -ForegroundColor Green
    Write-Host "====================================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Tudo salvo em:" -ForegroundColor White
    Write-Host "  $pastaBackup" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "PRÓXIMOS PASSOS PARA FORMATAR:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host " 1. Copie os dados do usuário para um HD externo (lista acima)" -ForegroundColor White
    Write-Host " 2. Confirme que a pasta de backup acima está em local SEGURO" -ForegroundColor White
    Write-Host "    (fora do disco que será formatado!)" -ForegroundColor DarkYellow
    Write-Host " 3. Crie o pendrive de instalação do Windows pelo site oficial da" -ForegroundColor White
    Write-Host "    Microsoft (Media Creation Tool)" -ForegroundColor White
    Write-Host " 4. Reinicie a máquina e aperte F2/F12/DEL para dar boot pelo pendrive" -ForegroundColor White
    Write-Host " 5. Depois de instalar, use a pasta Drivers do backup para reinstalar" -ForegroundColor White
    Write-Host "    tudo que o Windows não reconhecer sozinho" -ForegroundColor White
    Write-Host " 6. Depois de reconfigurar a máquina, APAGUE esta pasta de backup" -ForegroundColor White
    Write-Host "    (contém dados do cliente)" -ForegroundColor DarkYellow
    Write-Host ""
    Pausa
}

function Modulo-AbrirProtegido {
    Clear-Host
    Secao "ABRIR ARQUIVO PROTEGIDO"
    Write-Host "Mostra na tela o conteúdo de um arquivo .whenc criado pelo WinHealth." -ForegroundColor DarkGray
    Write-Host "O texto NÃO é salvo em disco. Feche esta janela quando terminar." -ForegroundColor DarkGray
    Write-Host ""
    $caminho = (Read-Host "Caminho do arquivo .whenc (ENTER vazio = cancelar)").Trim('"', ' ')
    if (-not $caminho) { return }
    if (-not (Test-Path -LiteralPath $caminho)) { Write-Host "Arquivo não encontrado." -ForegroundColor Red; Pausa; return }
    $senha = ConverterSecureString (Read-Host "Senha" -AsSecureString)
    try {
        $texto = Desproteger-Texto ([IO.File]::ReadAllBytes($caminho)) $senha
        Write-Host ""
        Write-Host "---------------------------------------------" -ForegroundColor Cyan
        Write-Host $texto -ForegroundColor White
        Write-Host "---------------------------------------------" -ForegroundColor Cyan
    } catch {
        Write-Host "Não foi possível abrir: $($_.Exception.Message)" -ForegroundColor Red
    }
    $senha = $null
    Pausa
}

# ===================== RELATORIO COMPLETO PARA O CLIENTE (menu 5) =====================
# Gera uma PASTA com: diagnostico.html (o mesmo da opcao 1), bateria.html, energia.html, wifi.html,
# drivers.html, sistema.txt e um index.html que junta tudo. Cada Gerar-* devolve um Res com o nome do
# arquivo; o indice e o console sao renderizadores desses Res.

$script:CssTabela = @'
table.tab{width:100%;border-collapse:collapse;background:var(--surface);border:1px solid var(--border);border-radius:12px;overflow:hidden;font-size:13.5px}
table.tab th,table.tab td{padding:8px 12px;text-align:left;border-bottom:1px solid var(--border);overflow-wrap:anywhere}
table.tab th{background:var(--bg);color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.5px}
table.tab tr:last-child td{border-bottom:0}
.sev-info{border-left:5px solid var(--info)}.sev-info .chip{background:var(--na-bg);color:var(--info)}
a.abrir{display:inline-block;margin-top:8px;padding:5px 12px;border-radius:8px;border:1px solid var(--accent);color:var(--accent);text-decoration:none;font-weight:600;font-size:13.5px}
.nota{color:var(--muted);font-size:13px;margin:6px 0 0}
'@

function ParaHtml { param($s) ([System.Net.WebUtility]::HtmlEncode([string]$s)) -replace "`r?`n", "<br>" }

function Interpretar-ArquivoGerado {
    param([string]$Categoria, [string]$Titulo, $Codigo, [bool]$ArquivoExiste, [string]$Arquivo, [string]$Saida, [string]$SemArquivo = "Não foi possível gerar.", [string]$Recomendacao = "")
    if ($ArquivoExiste) { return (Res $Categoria 'Ok' $Titulo "Arquivo: $Arquivo" '' $Arquivo) }
    Res $Categoria 'Indisponivel' $Titulo (("$SemArquivo`n" + (Ultima-Mensagem $Saida)).Trim()) $Recomendacao
}

function Novo-HtmlDrivers {
    param($Drivers, [string]$Maquina)
    $limite = (Get-Date).AddYears(-3)
    $linhas = New-Object System.Text.StringBuilder
    foreach ($d in @($Drivers | Sort-Object @{ Expression = { $_.DeviceClass } }, @{ Expression = { $_.DeviceName } })) {
        $data = ""; $antigo = ""
        if ($d.DriverDate) {
            $data = ([datetime]$d.DriverDate).ToString('dd/MM/yyyy')
            # drivers nativos do Windows costumam ter datas antigas e isso e normal: so sinaliza os de terceiros
            if ([datetime]$d.DriverDate -lt $limite -and [string]$d.Manufacturer -notmatch '^Microsoft') { $antigo = " (mais de 3 anos)" }
        }
        [void]$linhas.AppendLine("<tr><td>$(ParaHtml $d.DeviceClass)</td><td>$(ParaHtml $d.DeviceName)</td><td>$(ParaHtml $d.Manufacturer)</td><td>$(ParaHtml $d.DriverVersion)</td><td>$data$antigo</td></tr>")
    }
    $n = @($Drivers).Count
    @"
<!DOCTYPE html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>WinHealth - Drivers - $(ParaHtml $Maquina)</title><style>$($script:CssRelatorio)$($script:CssTabela)</style></head><body><div class="wrap">
<div class="top"><div class="brand">Win<b>Health</b></div><span>Drivers instalados &middot; $(ParaHtml $Maquina)</span></div>
<h2>$n driver(s) assinados</h2>
<p class="nota">Data antiga não significa problema: só indica que o fabricante não lançou versão mais nova. Drivers de vídeo, rede e chipset merecem atenção se a máquina apresenta falhas.</p>
<table class="tab"><thead><tr><th>Classe</th><th>Dispositivo</th><th>Fabricante</th><th>Versão</th><th>Data</th></tr></thead><tbody>
$($linhas.ToString())</tbody></table></div></body></html>
"@
}

function Exportar-IndiceRelatorio {
    param($Itens, $Info, [string]$Caminho)
    $ErrorActionPreference = 'Stop'
    $nOk = @($Itens | Where-Object { $_.Severidade -eq 'Ok' }).Count
    $nNao = @($Itens | Where-Object { $_.Severidade -eq 'Indisponivel' }).Count
    $total = @($Itens).Count
    $nome = ParaHtml $(if ($Info -and $Info['Computador']) { $Info['Computador'] } else { $env:COMPUTERNAME })
    $data = Get-Date -Format "dd/MM/yyyy HH:mm"
    $cls = if ($nNao -gt 0) { 'attn' } else { 'ok' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">')
    [void]$sb.AppendLine("<title>WinHealth - Relatório completo - $nome</title><style>$($script:CssRelatorio)$($script:CssTabela)</style></head><body><div class=""wrap"">")
    [void]$sb.AppendLine("<div class=""top""><div class=""brand"">Win<b>Health</b></div><span>Relatório completo &middot; $data</span></div>")
    [void]$sb.AppendLine("<section class=""hero $cls""><h1>Relatório completo de $nome</h1><p>$nOk de $total relatório(s) gerado(s)$(if ($nNao -gt 0) { "; $nNao não pôde(ram) ser gerado(s) (veja abaixo)." } else { "." })</p></section>")
    if ($Info -and $Info.Count -gt 0) {
        [void]$sb.AppendLine('<div class="machine"><dl class="kv">')
        foreach ($k in $Info.Keys) { [void]$sb.AppendLine("<dt>$(ParaHtml $k)</dt><dd>$(ParaHtml $Info[$k])</dd>") }
        [void]$sb.AppendLine('</dl></div>')
    }
    [void]$sb.AppendLine('<h2>Relatórios</h2>')
    foreach ($x in $Itens) {
        $cls2 = switch ($x.Severidade) { 'Ok' { 'ok' } 'Indisponivel' { 'indisponivel' } default { 'info' } }
        $rot = switch ($x.Severidade) { 'Ok' { '&#10003; Gerado' } 'Indisponivel' { '? Não gerado' } default { 'i Informação' } }
        [void]$sb.Append("<article class=""item sev-$cls2""><span class=""chip"">$rot</span><div><h3>$(ParaHtml $x.Titulo)</h3>")
        if ($x.Detalhe -and -not $x.Arquivo) { [void]$sb.Append("<p>$(ParaHtml $x.Detalhe)</p>") }
        if ($x.Recomendacao) { [void]$sb.Append("<p class=""rec""><strong>O que fazer:</strong> $(ParaHtml $x.Recomendacao)</p>") }
        if ($x.Arquivo) { [void]$sb.Append("<a class=""abrir"" href=""$([System.Net.WebUtility]::HtmlEncode($x.Arquivo))"">Abrir $(ParaHtml $x.Arquivo)</a>") }
        [void]$sb.AppendLine("</div></article>")
    }
    [void]$sb.AppendLine("<footer><p>Gerado automaticamente pelo WinHealth em $data.</p><p>Estes arquivos contêm informações desta máquina (modelo, número de série, nomes de redes Wi-Fi e programas), mas não contêm senhas. Compartilhe apenas com quem precisa.</p></footer></div></body></html>")
    [IO.File]::WriteAllText($Caminho, $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
}

function Gerar-RelDiagnostico {
    param([string]$Pasta)
    $c = "Relatórios gerados"
    $todos = @(Coletar-Diagnostico)
    Exportar-RelatorioHtml $todos $script:infoMaquina (Join-Path $Pasta 'diagnostico.html')
    $nP = @($todos | Where-Object { $_.Severidade -eq 'Problema' }).Count
    $nA = @($todos | Where-Object { $_.Severidade -eq 'Atencao' }).Count
    Res $c 'Ok' 'Diagnóstico da máquina (saúde, disco, memória, proteção...)' "Resultado: $nP problema(s), $nA ponto(s) de atenção." '' 'diagnostico.html'
}

function Gerar-RelBateria {
    param([string]$Pasta)
    $c = "Relatórios gerados"; $arq = Join-Path $Pasta 'bateria.html'
    $cmd = Invoke-Comando 'powercfg.exe' @('/batteryreport', '/output', "`"$arq`"")
    if (Test-Path -LiteralPath $arq) { return (Res $c 'Ok' 'Bateria (desgaste, ciclos, histórico de uso)' '' '' 'bateria.html') }
    Res $c 'Info' 'Bateria' 'Sem bateria nesta máquina (provavelmente um desktop).'
}

function Gerar-RelEnergia {
    param([string]$Pasta)
    $c = "Relatórios gerados"; $t = 'Energia e desempenho (análise de 60 segundos)'
    if (-not $isAdmin) { return (Res $c 'Indisponivel' $t 'Exige administrador.' 'Reabra como administrador (tecla A no menu) e gere de novo.') }
    $arq = Join-Path $Pasta 'energia.html'
    Write-Host "  Observando o comportamento do sistema por 60 segundos (não use o computador)..." -ForegroundColor DarkYellow
    $cmd = Invoke-Comando 'powercfg.exe' @('/energy', '/output', "`"$arq`"", '/duration', '60') { param($d, $l) Mostrar-Progresso $d $l }
    Write-Host ""
    Interpretar-ArquivoGerado $c $t $cmd.Codigo (Test-Path -LiteralPath $arq) 'energia.html' $cmd.Saida
}

function Gerar-RelWifi {
    param([string]$Pasta)
    $c = "Relatórios gerados"; $t = 'Rede Wi-Fi (histórico de conexões e falhas)'
    if (-not $isAdmin) { return (Res $c 'Indisponivel' $t 'Exige administrador.' 'Reabra como administrador (tecla A no menu) e gere de novo.') }
    $cmd = Invoke-Comando 'netsh.exe' @('wlan', 'show', 'wlanreport')
    $origem = Join-Path $env:ProgramData 'Microsoft\Windows\WlanReport\wlan-report-latest.html'
    $recente = (Test-Path -LiteralPath $origem) -and ((Get-Item -LiteralPath $origem).LastWriteTime -gt (Get-Date).AddMinutes(-10))
    if ($recente) { Copy-Item -LiteralPath $origem -Destination (Join-Path $Pasta 'wifi.html') -Force }
    Interpretar-ArquivoGerado $c $t $cmd.Codigo $recente 'wifi.html' $cmd.Saida 'Não foi possível gerar (a máquina pode não ter placa Wi-Fi ativa).'
}

function Gerar-RelDrivers {
    param([string]$Pasta)
    $c = "Relatórios gerados"; $t = 'Drivers instalados (com data e versão)'
    try {
        $drv = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | Where-Object { $_.DeviceName })
        if ($drv.Count -eq 0) { return (Res $c 'Indisponivel' $t 'Nenhum driver retornado pelo Windows.') }
        [IO.File]::WriteAllText((Join-Path $Pasta 'drivers.html'), (Novo-HtmlDrivers $drv $nomeMaquina), (New-Object Text.UTF8Encoding($true)))
        Res $c 'Ok' $t "$($drv.Count) driver(s)." '' 'drivers.html'
    } catch {
        Res $c 'Indisponivel' $t "Não foi possível listar os drivers: $($_.Exception.Message)"
    }
}

function Gerar-RelSistema {
    param([string]$Pasta)
    $c = "Relatórios gerados"; $t = 'Informações do sistema (systeminfo)'
    Write-Host "  Coletando informações do sistema (pode levar até 30 segundos)..." -ForegroundColor DarkGray
    $cmd = Invoke-Comando 'systeminfo.exe' @() { param($d, $l) Mostrar-Progresso $d $l } 'Oem'
    Write-Host ""
    if ($cmd.Saida.Trim().Length -gt 0 -and $null -ne $cmd.Codigo -and [int]$cmd.Codigo -eq 0) {
        [IO.File]::WriteAllText((Join-Path $Pasta 'sistema.txt'), $cmd.Saida, (New-Object Text.UTF8Encoding($true)))
        return (Res $c 'Ok' $t '' '' 'sistema.txt')
    }
    Res $c 'Indisponivel' $t (("Não foi possível coletar.`n" + (Ultima-Mensagem $cmd.Saida)).Trim())
}

function Modulo-RelatorioCompleto {
    Clear-Host
    $script:achados = 0
    $script:achadosBaixos = 0
    $script:indisponiveis = 0
    Secao "RELATÓRIO COMPLETO PARA O CLIENTE"
    Write-Host "Gera uma pasta com relatórios que abrem no navegador, prontos para mostrar ao cliente:" -ForegroundColor White
    Write-Host "  - Diagnóstico da máquina (o mesmo da opção 1)" -ForegroundColor Gray
    Write-Host "  - Bateria (desgaste, ciclos, histórico de uso)" -ForegroundColor Gray
    Write-Host "  - Energia e desempenho (análise de 60 segundos; exige administrador)" -ForegroundColor Gray
    Write-Host "  - Rede Wi-Fi (histórico de conexões e falhas; exige administrador)" -ForegroundColor Gray
    Write-Host "  - Drivers instalados, com data e versão" -ForegroundColor Gray
    Write-Host "  - Informações do sistema" -ForegroundColor Gray
    Write-Host "  - Um index.html que junta tudo" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Leva alguns minutos. Os arquivos NÃO contêm senhas, mas têm dados da máquina" -ForegroundColor DarkYellow
    Write-Host "(modelo, série, nomes de redes Wi-Fi e programas)." -ForegroundColor DarkYellow
    if (-not $isAdmin) { Write-Host "Sem administrador, energia e Wi-Fi serão pulados (aparecem como 'não gerado')." -ForegroundColor DarkYellow }
    Write-Host ""
    $ok = Read-Host "Gerar agora? (S/N)"
    if ($ok -notmatch '^[Ss]') { return }

    $pastaRel = Join-Path $pastaRelatorios "$nomeMaquina`_RelatorioCompleto_$carimbo"
    try { New-Item -Path $pastaRel -ItemType Directory -Force -ErrorAction Stop | Out-Null } catch {
        Write-Host "Não foi possível criar a pasta $pastaRel" -ForegroundColor Red
        Pausa
        return
    }

    Secao "Gerando relatórios"
    $itens = @()
    foreach ($etapa in @(
            @{ Rotulo = 'diagnóstico (pode demorar)'; Funcao = 'Gerar-RelDiagnostico' },
            @{ Rotulo = 'bateria'; Funcao = 'Gerar-RelBateria' },
            @{ Rotulo = 'energia'; Funcao = 'Gerar-RelEnergia' },
            @{ Rotulo = 'Wi-Fi'; Funcao = 'Gerar-RelWifi' },
            @{ Rotulo = 'drivers'; Funcao = 'Gerar-RelDrivers' },
            @{ Rotulo = 'sistema'; Funcao = 'Gerar-RelSistema' })) {
        Write-Host "  Gerando: $($etapa.Rotulo)..." -ForegroundColor DarkGray
        $r = @(& $etapa.Funcao $pastaRel | Where-Object { $_ -and $_.PSObject.Properties['Severidade'] })
        Mostrar-Resultados $r -SemCabecalho
        $itens += $r
    }

    $indice = Join-Path $pastaRel 'index.html'
    try {
        Exportar-IndiceRelatorio $itens $script:infoMaquina $indice
        Write-Host ""
        Write-Host "  RELATÓRIO COMPLETO GERADO  " -ForegroundColor White -BackgroundColor DarkGreen
        Write-Host ""
        Write-Host "Pasta: $pastaRel" -ForegroundColor Cyan
        Write-Host "Comece pelo index.html (abre no navegador)." -ForegroundColor Gray
        $ab = Read-Host "Abrir o index.html agora? (S/N)"
        if ($ab -match '^[Ss]') { Start-Process $indice }
    } catch {
        Write-Host "Os arquivos foram gerados em $pastaRel, mas o index.html falhou: $($_.Exception.Message)" -ForegroundColor Red
    }
    Pausa
}

# ===================== MODULO 7 - DIAGNOSTICO DE USB =====================
# Coletar-EstadoUSB junta os FATOS (leitura do sistema); Avaliar-EstadoUSB interpreta
# (funcao pura, testavel com dados simulados). Nada aqui altera a maquina.

function Coletar-EstadoUSB {
    $e = [ordered]@{
        Dispositivos = @(); TemHid = $false; DiscosUsb = @()
        UsbstorStart = $null; WriteProtect = $null
        GpoExiste = $false; GpoRegras = @()
        DeviceInstallRegras = @(); ServicosDlp = @()
    }
    try {
        $e.Dispositivos = @(Get-PnpDevice -PresentOnly -ErrorAction Stop |
            Where-Object { $_.InstanceId -like 'USB\VID_*' -and $_.InstanceId -notmatch '&MI_|LAMPARRAY' } |
            ForEach-Object { [pscustomobject]@{ Classe = $_.Class; Nome = $_.FriendlyName; Status = $_.Status; Problema = $_.Problem; Id = $_.InstanceId } })
    } catch {}
    $e.TemHid = @(Get-PnpDevice -PresentOnly -Class HIDClass -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'USB\*' }).Count -gt 0

    try {
        $discos = @(Get-CimInstance Win32_DiskDrive -ErrorAction Stop | Where-Object { $_.InterfaceType -eq 'USB' -or $_.MediaType -like 'Removable*' })
        foreach ($d in $discos) {
            $vid = $null; $pid_ = $null; $serie = $null; $pai = $null
            try { $pai = (Get-PnpDeviceProperty -InstanceId $d.PNPDeviceID -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop).Data } catch {}
            if ($pai -match 'USB\\VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})\\(.+)$') {
                $vid = $Matches[1].ToUpper(); $pid_ = $Matches[2].ToUpper(); $serie = $Matches[3]
            }
            $e.DiscosUsb += [pscustomobject]@{ Modelo = $d.Model; TamanhoGB = [math]::Round($d.Size/1GB, 1); VID = $vid; PID = $pid_; Serie = $serie }
        }
    } catch {}

    try { $e.UsbstorStart = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR" -ErrorAction Stop).Start } catch {}
    $e.WriteProtect = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\StorageDevicePolicies" -ErrorAction SilentlyContinue).WriteProtect

    $rsd = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices"
    if (Test-Path $rsd) {
        $e.GpoExiste = $true
        if ((Get-ItemProperty $rsd -ErrorAction SilentlyContinue).Deny_All -eq 1) { $e.GpoRegras += "Deny_All (todas as classes removíveis)" }
        Get-ChildItem $rsd -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            foreach ($n in 'Deny_All','Deny_Read','Deny_Write','Deny_Execute') {
                if ($p.$n -eq 1) { $e.GpoRegras += "$n em $($_.PSChildName)" }
            }
        }
    }
    $di = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions" -ErrorAction SilentlyContinue
    if ($di) {
        if ($di.DenyRemovableDevices -eq 1) { $e.DeviceInstallRegras += "bloqueia dispositivos removíveis (DenyRemovableDevices)" }
        if ($di.DenyUnspecified -eq 1 -or $di.DenyDeviceClasses -eq 1 -or $di.DenyDeviceIDs -eq 1) { $e.DeviceInstallRegras += "restrição por classe/ID de dispositivo ativa" }
    }

    $padrao = 'DLP|Device ?Control|Forcepoint|Digital ?Guardian|^Sense$|CSFalcon|Cylance|mfedlp|Endpoint Protector'
    $e.ServicosDlp = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $padrao -or $_.DisplayName -match $padrao } |
        ForEach-Object { "$($_.DisplayName) [$($_.Name)] - $($_.Status)" })
    [pscustomobject]$e
}

function Avaliar-EstadoUSB {
    param($Estado, [bool]$PendriveConectado)
    $c1 = "USB em uso agora (mouse/teclado x armazenamento)"
    $c2 = "Pendrives e discos USB conectados"
    $c3 = "Configuração do Windows para armazenamento USB"
    $c4 = "Software de controle de dispositivo (DLP/EDR) - indícios"
    $c5 = "Conclusão"

    if (@($Estado.Dispositivos).Count -eq 0) { Res $c1 'Info' 'Dispositivos USB' 'Nenhum dispositivo USB detectado agora.' }
    foreach ($u in @($Estado.Dispositivos)) {
        if ($u.Status -eq 'Error') { Res $c1 'Atencao' "[$($u.Classe)] $($u.Nome)" "Status: Error ($($u.Problema)) - $($u.Id)" }
        else { Res $c1 'Info' "[$($u.Classe)] $($u.Nome)" "$($u.Status) - $($u.Id)" }
    }

    $visiveis = @($Estado.DiscosUsb)
    if ($visiveis.Count -eq 0) {
        if ($PendriveConectado -and $Estado.TemHid) {
            Res $c2 'Problema' 'Pendrive conectado, mas o Windows não o enxerga' 'Mouse/teclado USB funcionam e nenhum armazenamento USB aparece.' 'Padrão TÍPICO de bloqueio da classe Mass Storage por política (DLP/GPO).'
        } elseif ($PendriveConectado) {
            Res $c2 'Atencao' 'Pendrive conectado e não aparece' '' 'Tente outra porta USB e outro pendrive antes de concluir que é bloqueio.'
        } else {
            Res $c2 'Indisponivel' 'Nenhum pendrive conectado' 'Sem pendrive não dá para concluir nada.' 'Conecte o pendrive e rode esta opção de novo.'
        }
    }
    foreach ($d in $visiveis) {
        Res $c2 'Info' 'Disco USB' "$($d.Modelo) - $($d.TamanhoGB) GB"
        if ($d.VID) { Res $c2 'Info' 'Hardware ID' "USB\VID_$($d.VID)&PID_$($d.PID) (série: $($d.Serie))" }
        else { Res $c2 'Indisponivel' "Hardware ID de $($d.Modelo)" 'Não foi possível ler o VID/PID deste dispositivo.' 'Veja no Gerenciador de Dispositivos > Detalhes > Id de Hardware.' }
    }

    $motivos = 0
    if ($null -eq $Estado.UsbstorStart) {
        Res $c3 'Indisponivel' 'Driver USBSTOR' 'Não foi possível ler o estado do driver de armazenamento USB.'
    } elseif ($Estado.UsbstorStart -eq 4) {
        $motivos++
        Res $c3 'Problema' 'Driver USBSTOR desabilitado (Start=4)' '' 'Nenhum pendrive funciona nesta máquina. É configuração da empresa - abra chamado.'
    } else {
        Res $c3 'Ok' 'Driver USBSTOR habilitado' "Start=$($Estado.UsbstorStart)"
    }
    if ($Estado.WriteProtect -eq 1) {
        $motivos++
        Res $c3 'Problema' 'Proteção contra gravação em USB ligada (WriteProtect=1)' 'O pendrive abre, mas não grava.' 'Os relatórios não poderão ser salvos no pendrive.'
    }
    if (@($Estado.GpoRegras).Count -gt 0) {
        foreach ($r in @($Estado.GpoRegras)) { $motivos++; Res $c3 'Problema' "Política de grupo (GPO) ativa: $r" }
    } elseif ($Estado.GpoExiste) {
        Res $c3 'Info' 'Política de armazenamento removível' 'existe, mas sem regras de bloqueio.'
    } else {
        Res $c3 'Ok' 'Nenhuma política de "Acesso a Armazenamento Removível" (GPO)'
    }
    if (@($Estado.DeviceInstallRegras).Count -gt 0) {
        foreach ($r in @($Estado.DeviceInstallRegras)) { $motivos++; Res $c3 'Problema' "Política de instalação de dispositivos: $r" '' 'Um pendrive novo pode ser barrado até ser liberado pelo VID/PID.' }
    } else {
        Res $c3 'Ok' 'Nenhuma restrição de instalação de dispositivos'
    }

    if (@($Estado.ServicosDlp).Count -gt 0) {
        foreach ($s in @($Estado.ServicosDlp)) { Res $c4 'Info' 'Serviço' $s }
        Res $c4 'Info' 'Observação' 'isso é só indício pelo nome do serviço; confirme com o time de segurança antes de citar em chamado.'
    } else {
        Res $c4 'Info' 'Serviços de DLP/controle de dispositivo' 'nenhum com nome típico encontrado.'
    }

    if ($motivos -gt 0) {
        Res $c5 'Atencao' "Encontrei $motivos configuração(ões) do próprio Windows restringindo USB" 'É política da empresa, não defeito do pendrive.' 'Abra chamado pedindo a liberação do pendrive de trabalho pelo Hardware ID (texto abaixo). Sem pendrive: rode o WinHealth pelo compartilhamento de rede ou link interno (veja o LEIA-ME).'
    } elseif ($visiveis.Count -eq 0 -and $PendriveConectado -and $Estado.TemHid) {
        Res $c5 'Atencao' 'Nenhuma configuração do Windows explica, mas o padrão aponta para software de segurança (DLP/EDR)' '' 'Anote o modelo do pendrive e pergunte ao time de segurança (o Hardware ID só aparece se o Windows enxergar o dispositivo: Gerenciador de Dispositivos > Detalhes > Id de Hardware).'
    } elseif ($visiveis.Count -eq 0 -and $PendriveConectado) {
        Res $c5 'Atencao' 'Nenhuma configuração do Windows explica, e o pendrive não aparece' 'Não há mouse/teclado USB para comparar, então não dá para separar bloqueio por software de problema físico.' 'Teste este pendrive em outra máquina e outro pendrive nesta. Se ambos funcionarem, plugue um mouse USB: se o mouse funcionar e o pendrive não, é o padrão de bloqueio por DLP/EDR - abra chamado.'
    } elseif ($visiveis.Count -eq 0) {
        Res $c5 'Indisponivel' 'Diagnóstico inconclusivo' 'Nenhum pendrive foi analisado.'
    } else {
        Res $c5 'Ok' 'Não há sinais de bloqueio de USB nesta máquina'
    }
}

function Novo-TextoChamado {
    param($DiscosUsb, [string]$Maquina, [string]$Usuario, [string]$Data)
    $comId = @($DiscosUsb | Where-Object { $_.VID })
    if ($comId.Count -eq 0) { return @() }
    $t = @()
    $t += "Solicitação de liberação de dispositivo USB (whitelist)"
    $t += "Máquina: $Maquina | Usuário: $Usuario | Data: $Data"
    foreach ($x in $comId) {
        $t += "Dispositivo: $($x.Modelo) ($($x.TamanhoGB) GB)"
        $t += "Hardware ID: USB\VID_$($x.VID)&PID_$($x.PID)"
        $t += "Número de série: $($x.Serie)"
    }
    $t += "Finalidade: kit de diagnóstico e suporte técnico (uso profissional)."
    $t
}

function Modulo-USB {
    Clear-Host
    $script:achados = 0
    $script:achadosBaixos = 0
    $script:indisponiveis = 0
    Write-Host "Só LEITURA: não altera nenhuma configuração da máquina." -ForegroundColor DarkGray
    $estado = Coletar-EstadoUSB
    $conectado = $true
    if (@($estado.DiscosUsb).Count -eq 0) {
        Write-Host "Nenhum pendrive/disco USB visível ao Windows agora." -ForegroundColor DarkYellow
        $resp = Read-Host "Há um pendrive conectado a esta máquina neste momento? (S/N)"
        $conectado = ($resp -match '^[Ss]')
    }
    Mostrar-Resultados @(Avaliar-EstadoUSB $estado $conectado)

    $texto = @(Novo-TextoChamado $estado.DiscosUsb $nomeMaquina "$env:USERDOMAIN\$env:USERNAME" (Get-Date -Format 'dd/MM/yyyy HH:mm'))
    if ($texto.Count -gt 0) {
        $arq = Join-Path $pastaRelatorios "$nomeMaquina`_PedidoLiberacaoUSB_$carimbo.txt"
        [IO.File]::WriteAllText($arq, ($texto -join "`r`n"), (New-Object Text.UTF8Encoding($true)))
        Write-Host ""
        Write-Host "---------- TEXTO PARA O CHAMADO ----------" -ForegroundColor Cyan
        $texto | ForEach-Object { Write-Host $_ -ForegroundColor White }
        Write-Host "------------------------------------------" -ForegroundColor Cyan
        Write-Host "Salvo também em: $arq" -ForegroundColor Gray
    }
    Pausa
}

# ===================== MENU PRINCIPAL =====================
# Admin: 'Nao' = funciona sem elevacao | 'Parcial' = roda, mas alguns itens exigem admin | 'Sim' = exige admin
$script:Menu = @(
    @{ Chave = '1'; Aba = 'Diagnóstico'; Icone = 'E9D9'; Titulo = 'Diagnóstico completo da máquina'; Descricao = 'Disco, RAM, temperatura, telas azuis, drivers, bateria + relatório HTML'; Admin = 'Parcial'; Acao = 'Modulo-Diagnostico' },
    @{ Chave = '2'; Aba = 'Scanner'; Icone = 'EA18'; Titulo = 'Escanear vírus e malware'; Descricao = 'Abre o Scanner Anti-Minerador (34 etapas); ele pede permissão de administrador'; Admin = 'Nao'; Acao = 'Modulo-Scanner' },
    @{ Chave = '3'; Aba = 'Reparo'; Icone = 'E90F'; Titulo = 'Reparar o Windows'; Descricao = 'DISM + SFC + CHKDSK na ordem correta'; Admin = 'Sim'; Acao = 'Modulo-Reparo' },
    @{ Chave = '4'; Aba = 'Limpeza'; Icone = 'E74D'; Titulo = 'Limpeza e otimização'; Descricao = 'Temporários, cache, DNS, lixeira, inicialização'; Admin = 'Parcial'; Acao = 'Modulo-Limpeza' },
    @{ Chave = '5'; Aba = 'Relatórios'; Icone = 'E9F9'; Titulo = 'Relatório completo para o cliente'; Descricao = 'Bateria, energia, Wi-Fi e drivers'; Admin = 'Parcial'; Acao = 'Modulo-RelatorioCompleto' },
    @{ Chave = '6'; Aba = 'Formatação'; Icone = 'E8B7'; Titulo = 'Preparar formatação'; Descricao = 'Drivers, programas, mapa dos dados, Wi-Fi e chave (sensíveis só com senha)'; Admin = 'Parcial'; Acao = 'Modulo-Formatar' },
    @{ Chave = '7'; Aba = 'USB'; Icone = 'E88E'; Titulo = 'Diagnóstico de USB bloqueado'; Descricao = 'Detecta bloqueio por política e gera texto para o chamado'; Admin = 'Nao'; Acao = 'Modulo-USB' },
    @{ Chave = '8'; Aba = 'Protegidos'; Icone = 'E72E'; Titulo = 'Abrir arquivo protegido (.whenc)'; Descricao = 'Lê os dados sensíveis guardados pela opção 6 (pede a senha)'; Admin = 'Nao'; Acao = 'Modulo-AbrirProtegido' }
)

function MostrarMenu {
    Clear-Host
    $estadoAcesso = Obter-EstadoAcesso $isAdmin $temContaAdmin
    Write-Host ""
    Write-Host "############################################################" -ForegroundColor Yellow
    Write-Host "#                                                          #" -ForegroundColor Yellow
    Write-Host "#                    W I N H E A L T H                     #" -ForegroundColor Yellow
    Write-Host "#              Diagnóstico e Reparo de Windows             #" -ForegroundColor Yellow
    Write-Host "#                                                          #" -ForegroundColor Yellow
    Write-Host "############################################################" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Máquina: $nomeMaquina" -ForegroundColor Gray
    if ($modoRede) {
        Write-Host "  Origem: REDE ($PastaKit) - relatórios salvos localmente em:" -ForegroundColor Cyan
        Write-Host "          $pastaRelatorios" -ForegroundColor Cyan
    }
    switch ($estadoAcesso) {
        'Admin' { Write-Host "  Modo: ADMINISTRADOR (todas as opções liberadas)" -ForegroundColor Green }
        'LimitadoElevavel' {
            Write-Host "  Modo: LIMITADO - sua conta pode virar administrador." -ForegroundColor Yellow
            Write-Host "  Digite A para reabrir como administrador (o Windows pede confirmação)." -ForegroundColor DarkYellow
        }
        default {
            Write-Host "  Modo: LIMITADO - conta comum, sem permissão de administrador." -ForegroundColor Yellow
            Write-Host "  Digite A e informe uma conta administradora, ou peça a quem administra a máquina." -ForegroundColor DarkYellow
        }
    }
    Write-Host ""
    Write-Host "  ------------------------------------------------------" -ForegroundColor DarkGray
    foreach ($item in $script:Menu) {
        Write-Host "   [$($item.Chave)]  $($item.Titulo)" -ForegroundColor White -NoNewline
        if (-not $isAdmin -and $item.Admin -eq 'Sim') { Write-Host "  [requer administrador]" -ForegroundColor Red -NoNewline }
        elseif (-not $isAdmin -and $item.Admin -eq 'Parcial') { Write-Host "  [mais completo como administrador]" -ForegroundColor DarkYellow -NoNewline }
        Write-Host ""
        Write-Host "        $($item.Descricao)" -ForegroundColor DarkGray
        Write-Host ""
    }
    Write-Host "  ------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
    if (-not $isAdmin) { Write-Host "   [A]  Reabrir como administrador" -ForegroundColor Yellow }
    Write-Host "   [0]  Sair" -ForegroundColor DarkYellow
    Write-Host ""
}

# ===================== JANELA (GUI WPF) - ESQUELETO + ABA DE DIAGNOSTICO =====================
# Janela escura com abas laterais, aviso do nivel de acesso e Painel. So apresentacao: a logica
# continua nas funcoes Coletar-*/Testar-*/Modulo-*. Cores = as do relatorio HTML (tema escuro).

$script:CoresGui = @{
    Fundo = '#0F1216'; Barra = '#12161B'; Superficie = '#171B21'; Borda = '#2A303A'
    Texto = '#E8EAED'; Muted = '#9AA4B2'; Acento = '#84ADFF'; AcentoFundo = '#1B2740'
    Ok = '#47CD89'; OkFundo = '#10251B'; Atencao = '#FDB022'; AtencaoFundo = '#2A2110'
    Problema = '#F97066'; ProblemaFundo = '#2A1615'; Info = '#84ADFF'; InfoFundo = '#1B2740'
    Indisponivel = '#9AA4B2'; IndisponivelFundo = '#232830'
}
# Rotulo em portugues + qual cor usar de $script:CoresGui, uma entrada por Severidade do modelo Res
# (mesmos rotulos do relatorio HTML, ver $sev dentro de Exportar-RelatorioHtml).
$script:SeveridadeGui = @{
    Problema     = @{ Rotulo = 'Problema';       Tom = 'Problema' }
    Atencao      = @{ Rotulo = 'Atenção';        Tom = 'Atencao' }
    Indisponivel = @{ Rotulo = 'Não verificado'; Tom = 'Indisponivel' }
    Ok           = @{ Rotulo = 'Tudo certo';     Tom = 'Ok' }
}
$script:OrdemSeveridadeGui = @{ Problema = 0; Atencao = 1; Indisponivel = 2; Ok = 3 }
$script:FonteIconesGui = 'Segoe Fluent Icons, Segoe MDL2 Assets'

$script:XamlJanela = @'
<Window @@NS@@ Title="WinHealth" Width="1060" Height="700" MinWidth="900" MinHeight="580"
        WindowStartupLocation="CenterScreen" Background="@@Fundo@@" Foreground="@@Texto@@"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <Style x:Key="BotaoPrimario" TargetType="Button">
      <Setter Property="Foreground" Value="@@Fundo@@"/>
      <Setter Property="Background" Value="@@Acento@@"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="18,9"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.88"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="BotaoSecundario" TargetType="Button">
      <Setter Property="Foreground" Value="@@Texto@@"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="@@Borda@@" BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="@@Superficie@@"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="ItemNav" TargetType="ListBoxItem">
      <Setter Property="Foreground" Value="@@Muted@@"/>
      <Setter Property="Margin" Value="10,1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ListBoxItem">
          <Border x:Name="b" Background="Transparent" CornerRadius="8" Padding="12,9">
            <Grid>
              <Rectangle x:Name="barra" Width="3" Height="16" RadiusX="1.5" RadiusY="1.5" Fill="@@Acento@@" HorizontalAlignment="Left" Margin="-9,0,0,0" Visibility="Collapsed"/>
              <ContentPresenter/>
            </Grid>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="@@Superficie@@"/><Setter Property="Foreground" Value="@@Texto@@"/></Trigger>
            <Trigger Property="IsSelected" Value="True"><Setter TargetName="b" Property="Background" Value="@@AcentoFundo@@"/><Setter TargetName="barra" Property="Visibility" Value="Visible"/><Setter Property="Foreground" Value="@@Acento@@"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Grid Background="Transparent">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="@@Borda@@" CornerRadius="4" Margin="2"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
            </Track>
          </Grid>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
  </Window.Resources>
  <Grid Background="@@Fundo@@">
    <Grid.RowDefinitions><RowDefinition Height="58"/><RowDefinition Height="*"/><RowDefinition Height="30"/></Grid.RowDefinitions>
    <Border Grid.Row="0" Background="@@Barra@@" BorderBrush="@@Borda@@" BorderThickness="0,0,0,1">
      <Grid Margin="22,0">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock FontSize="21" FontWeight="Bold"><Run Text="Win" Foreground="@@Texto@@"/><Run Text="Health" Foreground="@@Acento@@"/></TextBlock>
          <TextBlock x:Name="TxtMaquina" Margin="18,4,0,0" Foreground="@@Muted@@" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <Button x:Name="BtnDiagnostico" Content="Terminal de Diagnóstico" Style="{StaticResource BotaoSecundario}" Margin="0,0,12,0" ToolTip="Registro técnico local (erros/eventos internos) - útil pra investigar algo estranho"/>
          <Button x:Name="BtnAdmin" Style="{StaticResource BotaoSecundario}" Margin="0,0,12,0" Visibility="Collapsed"/>
          <Border x:Name="ChipAcesso" CornerRadius="12" Padding="12,4"><TextBlock x:Name="TxtAcesso" FontWeight="SemiBold" FontSize="12.5"/></Border>
        </StackPanel>
      </Grid>
    </Border>
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions><ColumnDefinition Width="220"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Border Grid.Column="0" Background="@@Barra@@" BorderBrush="@@Borda@@" BorderThickness="0,0,1,0" Padding="0,12,0,0">
        <ListBox x:Name="Nav" Background="Transparent" BorderThickness="0" ItemContainerStyle="{StaticResource ItemNav}" ScrollViewer.HorizontalScrollBarVisibility="Disabled" FocusVisualStyle="{x:Null}"/>
      </Border>
      <ScrollViewer x:Name="Rolagem" Grid.Column="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <ContentControl x:Name="Conteudo" Margin="32,26,24,24"/>
      </ScrollViewer>
    </Grid>
    <Border Grid.Row="2" Background="@@Barra@@" BorderBrush="@@Borda@@" BorderThickness="0,1,0,0">
      <TextBlock x:Name="TxtRodape" Margin="22,0" VerticalAlignment="Center" Foreground="@@Muted@@" FontSize="11.5" TextTrimming="CharacterEllipsis"/>
    </Border>
  </Grid>
</Window>
'@

function ConvertTo-XamlGui {
    param([string]$Xaml)
    $t = $Xaml.Replace('@@NS@@', 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"')
    foreach ($k in $script:CoresGui.Keys) { $t = $t.Replace("@@$k@@", $script:CoresGui[$k]) }
    [Windows.Markup.XamlReader]::Parse($t)
}

function Esc-Gui { param([string]$Texto) [System.Security.SecurityElement]::Escape($Texto) }

function Obter-BrushGui { param([string]$Cor) (New-Object Windows.Media.BrushConverter).ConvertFromString($script:CoresGui[$Cor]) }

function Novo-ChipGui {
    param([string]$Texto, [string]$Tom = 'Info')
    "<Border Background=`"$($script:CoresGui["$($Tom)Fundo"])`" CornerRadius=`"10`" Padding=`"9,2`" HorizontalAlignment=`"Left`" Margin=`"0,10,0,0`"><TextBlock Text=`"$(Esc-Gui $Texto)`" Foreground=`"$($script:CoresGui[$Tom])`" FontSize=`"11.5`" FontWeight=`"SemiBold`" TextWrapping=`"Wrap`"/></Border>"
}

function Obter-ChipAdminGui {
    param($Item, [bool]$Elevado)
    switch ($Item.Admin) {
        'Sim'     { Novo-ChipGui 'Requer administrador' $(if ($Elevado) { 'Ok' } else { 'Problema' }) }
        'Parcial' { Novo-ChipGui 'Melhor como administrador' $(if ($Elevado) { 'Ok' } else { 'Atencao' }) }
        default   { Novo-ChipGui 'Funciona sem administrador' 'Ok' }
    }
}

function Novo-CartaoGui {
    param([string]$Rotulo, [string]$Valor, [string]$Detalhe, [string]$Tom = 'Texto')
    ConvertTo-XamlGui @"
<Border @@NS@@ Width="236" Background="@@Superficie@@" BorderBrush="@@Borda@@" BorderThickness="1" CornerRadius="10" Padding="16,14" Margin="0,0,12,12">
  <StackPanel>
    <TextBlock Text="$(Esc-Gui $Rotulo)" FontSize="12" Foreground="@@Muted@@"/>
    <TextBlock Text="$(Esc-Gui $Valor)" FontSize="20" FontWeight="SemiBold" Foreground="@@$Tom@@" TextWrapping="Wrap" Margin="0,4,0,0"/>
    <TextBlock Text="$(Esc-Gui $Detalhe)" FontSize="12" Foreground="@@Muted@@" TextWrapping="Wrap" Margin="0,4,0,0"/>
  </StackPanel>
</Border>
"@
}

function Novo-CartaoModuloGui {
    param($Item, [bool]$Elevado)
    $glifo = [string][char][Convert]::ToInt32($Item.Icone, 16)
    $c = ConvertTo-XamlGui @"
<Border @@NS@@ Width="236" Background="@@Superficie@@" BorderBrush="@@Borda@@" BorderThickness="1" CornerRadius="10" Padding="16,14" Margin="0,0,12,12" Cursor="Hand">
  <StackPanel>
    <StackPanel Orientation="Horizontal">
      <Border Width="32" Height="32" CornerRadius="8" Background="@@AcentoFundo@@">
        <TextBlock FontFamily="$script:FonteIconesGui" FontSize="16" Text="$glifo" Foreground="@@Acento@@" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <TextBlock Text="$(Esc-Gui $Item.Aba)" FontSize="15" FontWeight="SemiBold" Margin="12,0,0,0" VerticalAlignment="Center"/>
    </StackPanel>
    <TextBlock Text="$(Esc-Gui $Item.Descricao)" FontSize="12" Foreground="@@Muted@@" TextWrapping="Wrap" Margin="0,10,0,0"/>
    $(Obter-ChipAdminGui $Item $Elevado)
  </StackPanel>
</Border>
"@
    $c.Tag = $Item.Chave
    $c.Add_MouseEnter({ $this.BorderBrush = Obter-BrushGui 'Acento' })
    $c.Add_MouseLeave({ $this.BorderBrush = Obter-BrushGui 'Borda' })
    $c.Add_MouseLeftButtonUp({ Ir-AbaGui $this.Tag })
    $c
}

function Novo-TituloGui {
    param([string]$Titulo, [string]$Subtitulo)
    "<TextBlock Text=`"$(Esc-Gui $Titulo)`" FontSize=`"24`" FontWeight=`"SemiBold`"/><TextBlock Text=`"$(Esc-Gui $Subtitulo)`" Foreground=`"$($script:CoresGui.Muted)`" TextWrapping=`"Wrap`" Margin=`"0,4,0,20`"/>"
}

function Novo-PainelGui {
    $elevado = ($script:GuiEstado -eq 'Admin')
    $so = try { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch { $null }
    if (-not $so) { $so = 'Windows' }
    $qtdRel = @(Get-ChildItem -LiteralPath $pastaRelatorios -Force -ErrorAction SilentlyContinue).Count

    $painel = ConvertTo-XamlGui "<StackPanel @@NS@@>$(Novo-TituloGui 'Painel' 'Resumo desta máquina e acesso rápido aos módulos.')</StackPanel>"

    $cartoes = New-Object System.Windows.Controls.WrapPanel
    [void]$cartoes.Children.Add((Novo-CartaoGui 'Máquina' $nomeMaquina $so))
    switch ($script:GuiEstado) {
        'Admin'            { [void]$cartoes.Children.Add((Novo-CartaoGui 'Acesso' 'Administrador' 'Todos os módulos liberados.' 'Ok')) }
        'LimitadoElevavel' { [void]$cartoes.Children.Add((Novo-CartaoGui 'Acesso' 'Limitado' 'Sua conta pode virar administrador (botão no topo).' 'Atencao')) }
        default            { [void]$cartoes.Children.Add((Novo-CartaoGui 'Acesso' 'Conta comum' 'Sem administrador: alguns módulos ficam restritos.' 'Atencao')) }
    }
    if ($modoRede) { [void]$cartoes.Children.Add((Novo-CartaoGui 'Origem' 'Rede' $PastaKit)) }
    else { [void]$cartoes.Children.Add((Novo-CartaoGui 'Origem' 'Pendrive / pasta local' $PastaKit)) }
    [void]$cartoes.Children.Add((Novo-CartaoGui 'Relatórios' "$qtdRel item(ns)" $pastaRelatorios))
    [void]$painel.Children.Add($cartoes)

    $botaoPasta = ConvertTo-XamlGui '<Button @@NS@@ Content="Abrir pasta de relatórios" Style="{DynamicResource BotaoSecundario}" HorizontalAlignment="Left" Margin="0,0,0,8"/>'
    $botaoPasta.Add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$pastaRelatorios`"" })
    [void]$painel.Children.Add($botaoPasta)

    [void]$painel.Children.Add((ConvertTo-XamlGui '<TextBlock @@NS@@ Text="Módulos" FontSize="16" FontWeight="SemiBold" Margin="0,22,0,12"/>'))
    $modulos = New-Object System.Windows.Controls.WrapPanel
    foreach ($item in $script:Menu) { [void]$modulos.Children.Add((Novo-CartaoModuloGui $item $elevado)) }
    [void]$painel.Children.Add($modulos)

    [void]$painel.Children.Add((ConvertTo-XamlGui "<Border @@NS@@ Background=`"@@InfoFundo@@`" CornerRadius=`"8`" Padding=`"14,10`" Margin=`"0,8,0,0`"><TextBlock Text=`"Nova interface em construção: por enquanto cada módulo abre em uma janela de console. As abas ganham conteúdo próprio nos próximos passos.`" Foreground=`"@@Info@@`" TextWrapping=`"Wrap`" FontSize=`"12.5`"/></Border>"))
    $painel
}

function Novo-AbaModuloGui {
    param($Item)
    $elevado = ($script:GuiEstado -eq 'Admin')
    $aba = ConvertTo-XamlGui "<StackPanel @@NS@@>$(Novo-TituloGui $Item.Titulo $Item.Descricao)$(Obter-ChipAdminGui $Item $elevado)</StackPanel>"
    $caixa = ConvertTo-XamlGui "<Border @@NS@@ Background=`"@@Superficie@@`" BorderBrush=`"@@Borda@@`" BorderThickness=`"1`" CornerRadius=`"10`" Padding=`"18,16`" Margin=`"0,22,0,0`"><StackPanel><TextBlock Text=`"Esta aba ainda não tem tela própria.`" FontSize=`"15`" FontWeight=`"SemiBold`"/><TextBlock Text=`"Por enquanto o módulo abre em uma janela de console e fecha sozinho ao terminar.`" Foreground=`"@@Muted@@`" TextWrapping=`"Wrap`" Margin=`"0,4,0,16`"/></StackPanel></Border>"
    $botao = ConvertTo-XamlGui '<Button @@NS@@ Content="Abrir módulo" Style="{DynamicResource BotaoPrimario}" HorizontalAlignment="Left"/>'
    $botao.Tag = $Item.Chave
    $botao.Add_Click({ Abrir-ModuloGui $this.Tag })
    [void]$caixa.Child.Children.Add($botao)
    [void]$aba.Children.Add($caixa)
    $aba
}

function Novo-CartaoResultadoGui {
    param($Res)
    $sev = $script:SeveridadeGui[$Res.Severidade]
    $detalhe = if ($Res.Detalhe) { "<TextBlock Text=`"$(Esc-Gui $Res.Detalhe)`" Foreground=`"@@Muted@@`" FontSize=`"12.5`" TextWrapping=`"Wrap`" Margin=`"0,4,0,0`"/>" } else { '' }
    $rec = if ($Res.Recomendacao) { "<TextBlock FontSize=`"12.5`" TextWrapping=`"Wrap`" Margin=`"0,6,0,0`"><Run Text=`"O que fazer: `" FontWeight=`"SemiBold`"/><Run Text=`"$(Esc-Gui $Res.Recomendacao)`"/></TextBlock>" } else { '' }
    ConvertTo-XamlGui @"
<Border @@NS@@ Background="@@Superficie@@" BorderBrush="@@Borda@@" BorderThickness="1" CornerRadius="8" Margin="0,0,0,8">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="4"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Rectangle Grid.Column="0" Fill="@@$($sev.Tom)@@"/>
    <StackPanel Grid.Column="1" Margin="14,10,14,10">
      <Border Background="@@$($sev.Tom)Fundo@@" CornerRadius="10" Padding="8,2" HorizontalAlignment="Left">
        <TextBlock Text="$(Esc-Gui $sev.Rotulo)" Foreground="@@$($sev.Tom)@@" FontSize="11" FontWeight="SemiBold"/>
      </Border>
      <TextBlock Text="$(Esc-Gui $Res.Titulo)" FontSize="14" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,6,0,0"/>
      $detalhe
      $rec
    </StackPanel>
  </Grid>
</Border>
"@
}

function Novo-LinhaInfoGui {
    param($Res)
    ConvertTo-XamlGui @"
<Grid @@NS@@ Margin="0,0,0,6">
  <Grid.ColumnDefinitions><ColumnDefinition Width="190"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
  <TextBlock Grid.Column="0" Text="$(Esc-Gui $Res.Titulo)" Foreground="@@Muted@@" FontSize="12.5" TextWrapping="Wrap"/>
  <TextBlock Grid.Column="1" Text="$(Esc-Gui $Res.Detalhe)" FontSize="12.5" TextWrapping="Wrap"/>
</Grid>
"@
}

# Uma secao por Categoria: itens normais viram cartoes (ordenados por severidade, igual ao HTML),
# itens Info viram uma caixa de pares rotulo/valor. Categoria "Identificação da máquina" nao repete
# os Infos aqui porque eles ja aparecem no card de maquina no topo da aba (Testar-Identificacao
# tambem preenche $script:infoMaquina com os mesmos dados).
function Novo-SecaoDiagnosticoGui {
    param([string]$Categoria, [object[]]$Itens)
    $cards = @($Itens | Where-Object { $_.Severidade -ne 'Info' } | Sort-Object @{ Expression = { $script:OrdemSeveridadeGui[$_.Severidade] } })
    $infos = @()
    if ($Categoria -ne 'Identificação da máquina') { $infos = @($Itens | Where-Object { $_.Severidade -eq 'Info' }) }
    if ($cards.Count -eq 0 -and $infos.Count -eq 0) { return $null }
    $sec = ConvertTo-XamlGui "<StackPanel @@NS@@ Margin=`"0,18,0,0`"><TextBlock Text=`"$(Esc-Gui $Categoria)`" FontSize=`"12`" FontWeight=`"SemiBold`" Foreground=`"@@Muted@@`"/></StackPanel>"
    if ($cards.Count -gt 0) {
        $lista = New-Object System.Windows.Controls.StackPanel
        $lista.Margin = '0,8,0,0'
        foreach ($it in $cards) { [void]$lista.Children.Add((Novo-CartaoResultadoGui $it)) }
        [void]$sec.Children.Add($lista)
    }
    if ($infos.Count -gt 0) {
        $caixaInfo = ConvertTo-XamlGui '<Border @@NS@@ Background="@@Superficie@@" BorderBrush="@@Borda@@" BorderThickness="1" CornerRadius="8" Padding="14,10" Margin="0,8,0,0"/>'
        $gridInfo = New-Object System.Windows.Controls.StackPanel
        foreach ($it in $infos) { [void]$gridInfo.Children.Add((Novo-LinhaInfoGui $it)) }
        $caixaInfo.Child = $gridInfo
        [void]$sec.Children.Add($caixaInfo)
    }
    $sec
}

# Agrupa $Itens por Categoria (na ordem em que aparecem, nao alfabetica - igual ao relatorio HTML) e
# acrescenta uma Novo-SecaoDiagnosticoGui por grupo. Reaproveitado por qualquer aba que mostre uma
# lista de Res (Diagnostico, Limpeza, e futuros modulos).
function Adicionar-SecoesPorCategoriaGui {
    param($Painel, [object[]]$Itens)
    $categorias = @(); foreach ($x in $Itens) { if ($categorias -notcontains $x.Categoria) { $categorias += $x.Categoria } }
    foreach ($cat in $categorias) {
        $sec = Novo-SecaoDiagnosticoGui $cat @($Itens | Where-Object { $_.Categoria -eq $cat })
        if ($sec) { [void]$Painel.Children.Add($sec) }
    }
}

function Novo-ResumoDiagnosticoGui {
    param([object[]]$Todos)
    $nP = @($Todos | Where-Object { $_.Severidade -eq 'Problema' }).Count
    $nA = @($Todos | Where-Object { $_.Severidade -eq 'Atencao' }).Count
    $nOk = @($Todos | Where-Object { $_.Severidade -eq 'Ok' }).Count
    $nNa = @($Todos | Where-Object { $_.Severidade -eq 'Indisponivel' }).Count
    if ($nP -gt 0) { $tom = 'Problema'; $veredito = 'Requer atenção'; $sub = "$nP problema(s) encontrado(s)" + $(if ($nA -gt 0) { " e $nA ponto(s) de melhoria." } else { '.' }) }
    elseif ($nA -gt 0) { $tom = 'Atencao'; $veredito = 'Em bom estado, com pontos de melhoria'; $sub = "$nA ponto(s) de baixo risco encontrado(s)." }
    else { $tom = 'Ok'; $veredito = 'Máquina saudável'; $sub = 'Nenhum problema encontrado nas verificações realizadas.' }
    if ($nNa -gt 0) { $sub += " $nNa verificação(ões) não puderam ser feitas." }

    $banner = ConvertTo-XamlGui @"
<Border @@NS@@ Background="@@Superficie@@" BorderBrush="@@Borda@@" BorderThickness="1" CornerRadius="10" Padding="18,16">
  <StackPanel>
    <TextBlock Text="$(Esc-Gui $veredito)" FontSize="19" FontWeight="SemiBold" Foreground="@@$tom@@"/>
    <TextBlock Text="$(Esc-Gui $sub)" Foreground="@@Muted@@" TextWrapping="Wrap" Margin="0,4,0,0"/>
  </StackPanel>
</Border>
"@
    $stats = New-Object System.Windows.Controls.WrapPanel
    $stats.Margin = '0,12,0,0'
    [void]$stats.Children.Add((Novo-CartaoGui 'Problemas' "$nP" '' 'Problema'))
    [void]$stats.Children.Add((Novo-CartaoGui 'Pontos de atenção' "$nA" '' 'Atencao'))
    [void]$stats.Children.Add((Novo-CartaoGui 'Verificações OK' "$nOk" '' 'Ok'))
    [void]$stats.Children.Add((Novo-CartaoGui 'Não verificados' "$nNa" '' 'Indisponivel'))
    [void]$banner.Child.Children.Add($stats)
    $banner
}

# Roda um scriptblock numa runspace separada (nao trava a janela) e chama $OnConcluir na thread da
# UI quando terminar (via DispatcherTimer, que so dispara na thread dona da janela). O estado fica
# no .Tag do timer, nao em variavel capturada, pra nao depender de closure sobre escopo de funcao.
# $Fila (opcional): um ConcurrentQueue passado por REFERENCIA pro script de fundo (via AddArgument) -
# o mesmo objeto .NET, so isso da pra ler do lado da UI sem passar por serializacao/remoting. Cada
# item enfileirado pelo script de fundo e entregue ao $OnProgresso, na ordem, em tempo real (nunca
# simulado - so dispara quando o script de fundo realmente concluiu aquele passo).
# $OnTick (opcional): chamado a CADA tick (a cada 120ms, enquanto a tarefa ainda roda) com os segundos
# decorridos desde o inicio - tempo DECORRIDO real (nao um "tempo restante" estimado/inventado, que
# seria simulacao: a duracao de cada etapa varia demais, ex. a checagem de Windows Update, pra dar um
# palpite honesto). Usado pra mostrar "rodando ha Xs" mesmo entre um passo e outro, sem inventar nada.
function Iniciar-TarefaGui {
    param([scriptblock]$Script, [scriptblock]$OnConcluir, [scriptblock]$OnProgresso, $Fila, [scriptblock]$OnTick)
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($Script)
    if ($null -ne $Fila) { [void]$ps.AddArgument($Fila) }
    $estado = [pscustomobject]@{ PowerShell = $ps; Async = $ps.BeginInvoke(); OnConcluir = $OnConcluir; OnProgresso = $OnProgresso; Fila = $Fila; OnTick = $OnTick; Inicio = Get-Date }
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(120)
    $timer.Tag = $estado
    $timer.Add_Tick({
        $e = $this.Tag
        if ($e.Fila -and $e.OnProgresso) {
            $item = $null
            while ($e.Fila.TryDequeue([ref]$item)) { & $e.OnProgresso $item }
        }
        if (-not $e.Async.IsCompleted) {
            if ($e.OnTick) { & $e.OnTick ([int]((Get-Date) - $e.Inicio).TotalSeconds) }
            return
        }
        $this.Stop()
        $saida = $null; $erro = $null
        try { $saida = @($e.PowerShell.EndInvoke($e.Async)) } catch { $erro = $_ }
        if (-not $erro -and $e.PowerShell.Streams.Error.Count -gt 0) { $erro = $e.PowerShell.Streams.Error[0] }
        $e.PowerShell.Dispose()
        if ($erro) { Escrever-LogDiagnostico -Nivel 'ERRO' -Mensagem "Tarefa em segundo plano falhou: $($erro.Exception.Message)" }
        & $e.OnConcluir $saida $erro
    })
    $timer.Start()
    $timer
}

# IMPORTANTE sobre handlers de evento (Add_Click/Add_Tick) neste arquivo: uma vez que a funcao que
# CRIOU o controle retorna, o handler PERDE acesso as variaveis locais dela (testado - o handler ve
# $null, nao o objeto real; como $ErrorActionPreference e SilentlyContinue, isso falha em silencio).
# Por isso todo estado que um handler precisa depois do clique fica em variavel $script: (como
# $script:GuiNav/$script:GuiConteudo ja faziam) ou no .Tag do proprio controle - nunca em variavel
# local da funcao que so existe enquanto ela monta a tela.

# Preenche o painel de resultados da aba de Diagnostico: resumo (hero), cartao com os dados da
# maquina e uma secao por categoria. Funcao de nivel superior (nao aninhada) porque e chamada de
# dentro de um Add_Click, que so enxerga funcoes e variaveis $script:/de nivel superior do arquivo.
function Preencher-ResultadoDiagnosticoGui {
    param($Painel, $Todos, $InfoMaquina)
    $Painel.Children.Clear()
    [void]$Painel.Children.Add((Novo-ResumoDiagnosticoGui $Todos))
    if ($InfoMaquina -and $InfoMaquina.Count -gt 0) {
        $caixaMaquina = ConvertTo-XamlGui '<Border @@NS@@ Background="@@Superficie@@" BorderBrush="@@Borda@@" BorderThickness="1" CornerRadius="8" Padding="14,10" Margin="0,12,0,0"/>'
        $gridMaquina = New-Object System.Windows.Controls.StackPanel
        foreach ($k in $InfoMaquina.Keys) { [void]$gridMaquina.Children.Add((Novo-LinhaInfoGui (Res '' 'Info' $k $InfoMaquina[$k]))) }
        $caixaMaquina.Child = $gridMaquina
        [void]$Painel.Children.Add($caixaMaquina)
    }
    Adicionar-SecoesPorCategoriaGui $Painel $Todos
    $botaoHtml = ConvertTo-XamlGui '<Button @@NS@@ Content="Gerar relatório para o cliente (HTML)" Style="{DynamicResource BotaoSecundario}" HorizontalAlignment="Left" Margin="0,18,0,0"/>'
    $botaoHtml.Tag = [pscustomobject]@{ Todos = $Todos; Info = $InfoMaquina }
    $botaoHtml.Add_Click({
        $d = $this.Tag
        $arq = Join-Path $pastaRelatorios "$nomeMaquina`_Diagnostico_$(Get-Date -Format 'yyyy-MM-dd_HHmm').html"
        try { Exportar-RelatorioHtml $d.Todos $d.Info $arq; Start-Process $arq }
        catch { [void][System.Windows.MessageBox]::Show("Não foi possível gerar o relatório.`n$($_.Exception.Message)", 'WinHealth') }
    })
    [void]$Painel.Children.Add($botaoHtml)

    $temDriverDesatualizado = @($Todos | Where-Object { $_.Categoria -eq 'Atualizações de driver' -and $_.Severidade -eq 'Atencao' }).Count -gt 0
    if ($temDriverDesatualizado) {
        $botaoWU = ConvertTo-XamlGui '<Button @@NS@@ Content="Abrir Windows Update (Atualizações opcionais)" Style="{DynamicResource BotaoSecundario}" HorizontalAlignment="Left" Margin="0,10,0,0"/>'
        $botaoWU.Add_Click({ Start-Process 'ms-settings:windowsupdate-optionalupdates' })
        [void]$Painel.Children.Add($botaoWU)
    }
}

# Bloco de progresso REAL reutilizavel: ProgressBar + Expander "Ver detalhes" com log ao vivo, no
# molde da janela de copiar/mover do Windows. Comeca escondido (Visibility=Collapsed); quem usa
# mostra/esconde e atualiza Barra.Value/Log.Children conforme os avisos reais de -OnProgresso chegam
# (ver Iniciar-TarefaGui). Devolve os controles ja "desembrulhados" pra quem chamar guardar no seu
# proprio $script:GuiXxx.
function Novo-PainelProgressoGui {
    $painel = ConvertTo-XamlGui @"
<StackPanel @@NS@@ Margin="0,12,0,0" Visibility="Collapsed">
  <ProgressBar Height="6" Minimum="0"/>
  <Expander Header="Ver detalhes" Margin="0,8,0,0" Foreground="@@Muted@@" FontSize="12.5">
    <Border Background="@@Superficie@@" BorderBrush="@@Borda@@" BorderThickness="1" CornerRadius="6" Padding="10,8" Margin="0,6,0,0">
      <ScrollViewer MaxHeight="140" VerticalScrollBarVisibility="Auto">
        <StackPanel/>
      </ScrollViewer>
    </Border>
  </Expander>
</StackPanel>
"@
    $rolagem = $painel.Children[1].Content.Child
    [pscustomobject]@{ Painel = $painel; Barra = $painel.Children[0]; Rolagem = $rolagem; Log = $rolagem.Content }
}

function Novo-AbaDiagnosticoGui {
    param($Item)
    $elevado = ($script:GuiEstado -eq 'Admin')
    $aba = ConvertTo-XamlGui "<StackPanel @@NS@@>$(Novo-TituloGui $Item.Titulo $Item.Descricao)$(Obter-ChipAdminGui $Item $elevado)</StackPanel>"

    $barra = ConvertTo-XamlGui '<StackPanel @@NS@@ Orientation="Horizontal" Margin="0,18,0,0"/>'
    $botao = ConvertTo-XamlGui '<Button @@NS@@ Content="Rodar diagnóstico" Style="{DynamicResource BotaoPrimario}"/>'
    $status = ConvertTo-XamlGui '<TextBlock @@NS@@ Foreground="@@Muted@@" VerticalAlignment="Center" Margin="14,0,0,0"/>'
    $status.Text = if ($script:GuiUltimoDiagnostico) { "Última execução: $($script:GuiUltimoDiagnostico.Quando.ToString('HH:mm:ss'))" } else { 'Ainda não executado nesta sessão.' }
    [void]$barra.Children.Add($botao); [void]$barra.Children.Add($status)
    [void]$aba.Children.Add($barra)

    # Progresso REAL (nunca simulado): a barra e o texto so avancam quando o passo de verdade termina
    # (ver -OnProgresso do Iniciar-TarefaGui). "Ver detalhes" (Expander) mostra o log completo, igual a
    # setinha de detalhes das janelas de copiar/mover do Windows. Reaproveitado por todo modulo que
    # roda algo demorado em segundo plano (ver Novo-PainelProgressoGui).
    $prog = Novo-PainelProgressoGui
    [void]$aba.Children.Add($prog.Painel)

    $resultado = New-Object System.Windows.Controls.StackPanel
    $resultado.Margin = '0,4,0,0'
    [void]$aba.Children.Add($resultado)

    # $script:GuiDiag guarda os controles desta aba pro Add_Click enxergar depois (ver nota acima).
    # So existe UMA instancia da aba de Diagnostico por vez (recriada a cada Mostrar-AbaGui), entao
    # sobrescrever essa variavel a cada chamada e seguro.
    $script:GuiDiag = [pscustomobject]@{ Botao = $botao; Status = $status; Resultado = $resultado; Progresso = $prog.Painel; Barra = $prog.Barra; Log = $prog.Log; Rolagem = $prog.Rolagem; RotuloAtual = '' }

    if ($script:GuiUltimoDiagnostico) { Preencher-ResultadoDiagnosticoGui $resultado $script:GuiUltimoDiagnostico.Itens $script:GuiUltimoDiagnostico.Info }

    $botao.Add_Click({
        $script:GuiDiag.Botao.IsEnabled = $false
        $script:GuiDiag.Status.Text = 'Coletando informações da máquina...'
        $script:GuiDiag.RotuloAtual = ''
        $script:GuiDiag.Resultado.Children.Clear()
        $script:GuiDiag.Log.Children.Clear()
        $script:GuiDiag.Barra.Maximum = @($script:ChecksDiagnostico).Count
        $script:GuiDiag.Barra.Value = 0
        $script:GuiDiag.Progresso.Visibility = 'Visible'

        $fila = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        $dotSource = ". `"$PSCommandPath`" -CarregarSomente -PastaKit `"$PastaKit`""
        $corpo = @"
param(`$FilaProgresso)
$dotSource
`$itens = @(Coletar-Diagnostico -OnProgresso { param(`$Rotulo, `$I, `$N) `$FilaProgresso.Enqueue([pscustomobject]@{ I = `$I; N = `$N; Rotulo = `$Rotulo }) })
[pscustomobject]@{ Itens = `$itens; Info = `$script:infoMaquina }
"@
        $sb = [scriptblock]::Create($corpo)
        [void](Iniciar-TarefaGui -Script $sb -Fila $fila -OnProgresso {
            param($P)
            $script:GuiDiag.Barra.Value = $P.I
            $script:GuiDiag.RotuloAtual = "($($P.I)/$($P.N)): $($P.Rotulo)"
            $script:GuiDiag.Status.Text = "Verificando $($script:GuiDiag.RotuloAtual)..."
            $linha = ConvertTo-XamlGui "<TextBlock @@NS@@ Text=`"$(Esc-Gui "$($P.I)/$($P.N) - $($P.Rotulo)")`" FontSize=`"11.5`" Foreground=`"@@Muted@@`" Margin=`"0,0,0,2`"/>"
            [void]$script:GuiDiag.Log.Children.Add($linha)
            $script:GuiDiag.Rolagem.ScrollToBottom()
        } -OnTick {
            param($Segundos)
            $rotulo = if ($script:GuiDiag.RotuloAtual) { "Verificando $($script:GuiDiag.RotuloAtual)..." } else { 'Coletando informações da máquina...' }
            $script:GuiDiag.Status.Text = "$rotulo (rodando há ${Segundos}s)"
        } -OnConcluir {
            param($Saida, $Erro)
            $script:GuiDiag.Botao.IsEnabled = $true
            $script:GuiDiag.Progresso.Visibility = 'Collapsed'
            if ($Erro) { $script:GuiDiag.Status.Text = "Não foi possível rodar o diagnóstico: $($Erro.Exception.Message)"; return }
            $pacote = $Saida[0]
            $script:GuiUltimoDiagnostico = [pscustomobject]@{ Itens = @($pacote.Itens); Info = $pacote.Info; Quando = Get-Date }
            $script:GuiDiag.Status.Text = "Última execução: $($script:GuiUltimoDiagnostico.Quando.ToString('HH:mm:ss'))"
            Preencher-ResultadoDiagnosticoGui $script:GuiDiag.Resultado $script:GuiUltimoDiagnostico.Itens $script:GuiUltimoDiagnostico.Info
        })
    })
    $aba
}

# ===================== ABA DE LIMPEZA (GUI) =====================
# Dois passos, igual ao console: calcular (so leitura, mostra tamanhos) e so depois perguntar se pode
# limpar de verdade. A Lixeira e' medida DEPOIS da limpeza (igual ao console) e so e' esvaziada com
# uma escolha separada (botao "Esvaziar" x "Manter") - nunca junto com o resto.

function Novo-LinhaAlvoLimpezaGui {
    param($Linha)
    $direita = switch ($Linha.Estado) {
        'RequerAdmin' { 'Requer administrador' }
        'NaoExiste' { 'Não existe nesta máquina' }
        default { "$(Formatar-Tamanho $Linha.Bytes) ($($Linha.Arquivos) arquivos)" }
    }
    $tom = if ($Linha.Estado -eq 'Ok') { 'Texto' } else { 'Muted' }
    ConvertTo-XamlGui @"
<Grid @@NS@@ Margin="0,0,0,8">
  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
  <TextBlock Grid.Column="0" Text="$(Esc-Gui $Linha.Rotulo)" FontSize="13.5"/>
  <TextBlock Grid.Column="1" Text="$(Esc-Gui $direita)" FontSize="13" Foreground="@@$tom@@" Margin="14,0,0,0"/>
</Grid>
"@
}

function Preencher-PreviaLimpezaGui {
    param($Painel, $Pacote)
    $Painel.Children.Clear()
    $caixa = ConvertTo-XamlGui '<Border @@NS@@ Background="@@Superficie@@" BorderBrush="@@Borda@@" BorderThickness="1" CornerRadius="8" Padding="14,12"><StackPanel/></Border>'
    foreach ($l in $Pacote.Linhas) { [void]$caixa.Child.Children.Add((Novo-LinhaAlvoLimpezaGui $l)) }
    [void]$Painel.Children.Add($caixa)
    $soma = ($Pacote.Linhas | Where-Object { $_.Estado -eq 'Ok' } | Measure-Object -Property Bytes -Sum).Sum
    if (-not $soma) { $soma = 0 }
    [void]$Painel.Children.Add((ConvertTo-XamlGui "<TextBlock @@NS@@ Text=`"$(Esc-Gui "Total estimado: $(Formatar-Tamanho $soma)")`" FontWeight=`"SemiBold`" Margin=`"2,10,0,0`"/>"))
    $botaoLimpar = ConvertTo-XamlGui '<Button @@NS@@ Content="Limpar agora" Style="{DynamicResource BotaoPrimario}" HorizontalAlignment="Left" Margin="0,14,0,0"/>'
    $botaoLimpar.Add_Click({ Executar-LimpezaGui })
    [void]$Painel.Children.Add($botaoLimpar)
}

# Uma linha da lista de inicializacao, com o botao de Ativar/Desativar (mesmo mecanismo do
# Gerenciador de Tarefas - ver Alternar-ItemInicializacao) e um atalho pra Configuracoes > Apps (pra
# desinstalar de verdade, se for o caso - o WinHealth nao executa desinstalador nenhum, so abre a
# tela do Windows). Funcao de nivel superior porque os botoes disparam depois que ela ja retornou
# (mesma regra dos outros handlers): o Item vai no .Tag, nunca por closure.
function Novo-LinhaInicializacaoGui {
    param($Item, $Container)
    $textoToggle = if (-not $Item.ChaveAprovado) { 'Não desativável aqui' } elseif ($Item.Habilitado) { 'Desativar' } else { 'Ativar' }
    # Cada linha fica numa faixa com risco embaixo (BorderThickness so no lado de baixo) - sem isso
    # os 20+ itens ficavam tudo grudado, dificil de saber qual botao e de qual programa (pedido do
    # Gabriel, 28/09/2026).
    $linhaBorda = ConvertTo-XamlGui '<Border @@NS@@ BorderBrush="@@Borda@@" BorderThickness="0,0,0,1" Padding="0,10,0,10"/>'
    $linha = ConvertTo-XamlGui @"
<Grid @@NS@@>
  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
  <StackPanel Grid.Column="0" VerticalAlignment="Center">
    <TextBlock Text="$(Esc-Gui $Item.Nome)" FontSize="13.5"/>
    <TextBlock Text="$(Esc-Gui "$($Item.Origem)$(if (-not $Item.Habilitado) { ' - desativado' })")" FontSize="11.5" Foreground="@@Muted@@"/>
  </StackPanel>
  <Button Grid.Column="1" Content="$(Esc-Gui $textoToggle)" Style="{DynamicResource BotaoSecundario}" Margin="8,0,0,0" IsEnabled="$(if ($Item.ChaveAprovado) { 'True' } else { 'False' })"/>
  <Button Grid.Column="2" Content="Desinstalar..." Style="{DynamicResource BotaoSecundario}" Margin="8,0,0,0"/>
</Grid>
"@
    $linhaBorda.Child = $linha
    $dados = [pscustomobject]@{ Item = $Item; Container = $Container }
    $botaoToggle = $linha.Children[1]
    $botaoToggle.Tag = $dados
    $botaoToggle.Add_Click({
        $d = $this.Tag
        $ok = Alternar-ItemInicializacao $d.Item (-not $d.Item.Habilitado)
        if (-not $ok) { [void][System.Windows.MessageBox]::Show("Não foi possível alterar este item de inicialização.", 'WinHealth'); return }
        Preencher-InicializacaoGui $d.Container
    })
    $botaoDesinstalar = $linha.Children[2]
    $botaoDesinstalar.Add_Click({
        try { Start-Process 'ms-settings:appsfeatures' }
        catch { [void][System.Windows.MessageBox]::Show("Não foi possível abrir Configurações.`n$($_.Exception.Message)", 'WinHealth') }
    })
    $linhaBorda
}

# Monta a secao inteira de inicializacao (resumo + lista com os botoes) dentro de $Container -
# chamada tanto no preenchimento inicial quanto de novo, a cada Ativar/Desativar, pra sempre
# refletir o registro de verdade (a leitura e rapida, poucas chaves - sem precisar de Iniciar-TarefaGui).
function Preencher-InicializacaoGui {
    param($Container)
    $Container.Children.Clear()
    [void]$Container.Children.Add((ConvertTo-XamlGui '<TextBlock @@NS@@ Text="Programas que abrem com o Windows" FontSize="12" FontWeight="SemiBold" Foreground="@@Muted@@"/>'))
    $todos = @(Obter-ProgramasInicializacao)
    $habilitados = @($todos | Where-Object Habilitado)
    if ($habilitados.Count -gt 8) {
        [void]$Container.Children.Add((Novo-CartaoResultadoGui (Res '' 'Atencao' "$($habilitados.Count) programas abrem junto com o Windows" 'Cada um consome memória desde o momento em que o PC liga.' 'Desative os que não precisa na lista abaixo.')))
    }
    $caixa = ConvertTo-XamlGui '<Border @@NS@@ Background="@@Superficie@@" BorderBrush="@@Borda@@" BorderThickness="1" CornerRadius="8" Padding="14,12" Margin="0,8,0,0"><StackPanel/></Border>'
    if ($todos.Count -eq 0) {
        [void]$caixa.Child.Children.Add((ConvertTo-XamlGui '<TextBlock @@NS@@ Text="Nenhum programa encontrado." Foreground="@@Muted@@" FontSize="12.5"/>'))
    } else {
        foreach ($it in $todos) { [void]$caixa.Child.Children.Add((Novo-LinhaInicializacaoGui $it $Container)) }
    }
    [void]$Container.Children.Add($caixa)
}

# Chamada depois de mostrar os cartoes de resultado da limpeza (e depois da escolha da Lixeira, se
# houver uma pendente): acrescenta os programas de inicializacao (com Ativar/Desativar) e o total final.
function Finalizar-ResultadoLimpezaGui {
    param($Painel)
    $secaoInicializacao = New-Object System.Windows.Controls.StackPanel
    $secaoInicializacao.Margin = '0,18,0,0'
    Preencher-InicializacaoGui $secaoInicializacao
    [void]$Painel.Children.Add($secaoInicializacao)
    $total = $script:GuiUltimoResultadoLimpeza.BytesLiberados
    [void]$Painel.Children.Add((ConvertTo-XamlGui "<Border @@NS@@ Background=`"@@OkFundo@@`" BorderBrush=`"@@Ok@@`" BorderThickness=`"1`" CornerRadius=`"8`" Padding=`"14,12`" Margin=`"0,18,0,0`"><TextBlock Text=`"$(Esc-Gui "Limpeza concluída - $(Formatar-Tamanho $total) liberados")`" FontWeight=`"SemiBold`" Foreground=`"@@Ok@@`"/></Border>"))
}

function Preencher-ResultadoLimpezaGui {
    param($Painel, [object[]]$Resultados, [int64]$LixeiraBytes, [int]$LixeiraItens)
    $Painel.Children.Clear()
    Adicionar-SecoesPorCategoriaGui $Painel $Resultados
    if ($LixeiraItens -le 0) { Finalizar-ResultadoLimpezaGui $Painel; return }
    $caixa = ConvertTo-XamlGui @"
<Border @@NS@@ Background="@@AtencaoFundo@@" BorderBrush="@@Atencao@@" BorderThickness="1" CornerRadius="8" Padding="14,12" Margin="0,18,0,0">
  <StackPanel>
    <TextBlock Text="Lixeira" FontSize="14" FontWeight="SemiBold" Foreground="@@Atencao@@"/>
    <TextBlock TextWrapping="Wrap" Margin="0,6,0,12" FontSize="12.5" Text="$(Esc-Gui "A Lixeira tem $LixeiraItens item(ns), $(Formatar-Tamanho $LixeiraBytes). São arquivos que você jogou fora e podem ser recuperados agora. Esvaziar NÃO tem volta.")"/>
    <StackPanel Orientation="Horizontal"/>
  </StackPanel>
</Border>
"@
    $botoes = $caixa.Child.Children[2]
    $botaoEsvaziar = ConvertTo-XamlGui '<Button @@NS@@ Content="Esvaziar Lixeira" Style="{DynamicResource BotaoPrimario}" Margin="0,0,8,0"/>'
    $botaoManter = ConvertTo-XamlGui '<Button @@NS@@ Content="Manter Lixeira" Style="{DynamicResource BotaoSecundario}"/>'
    [void]$botoes.Children.Add($botaoEsvaziar); [void]$botoes.Children.Add($botaoManter)
    $dados = [pscustomobject]@{ Caixa = $caixa; Painel = $Painel; Bytes = $LixeiraBytes }
    $botaoEsvaziar.Tag = $dados
    $botaoEsvaziar.Add_Click({
        $d = $this.Tag
        $this.IsEnabled = $false; $this.Content = 'Esvaziando...'
        try {
            Clear-RecycleBin -Force -ErrorAction Stop
            $script:GuiUltimoResultadoLimpeza.BytesLiberados += $d.Bytes
            $r = Res 'Lixeira' 'Ok' "Lixeira esvaziada: $(Formatar-Tamanho $d.Bytes) liberados"
        } catch {
            $r = Res 'Lixeira' 'Indisponivel' 'Não foi possível esvaziar a Lixeira' $_.Exception.Message
        }
        $i = $d.Painel.Children.IndexOf($d.Caixa)
        $d.Painel.Children.Remove($d.Caixa)
        $d.Painel.Children.Insert($i, (Novo-CartaoResultadoGui $r))
        Finalizar-ResultadoLimpezaGui $d.Painel
    })
    $botaoManter.Tag = $dados
    $botaoManter.Add_Click({
        $d = $this.Tag
        [void]$d.Painel.Children.Remove($d.Caixa)
        Finalizar-ResultadoLimpezaGui $d.Painel
    })
    [void]$Painel.Children.Add($caixa)
}

function Calcular-LimpezaGui {
    $script:GuiLimpeza.BotaoCalcular.IsEnabled = $false
    $script:GuiLimpeza.Status.Text = 'Calculando o que pode ser liberado...'
    $script:GuiLimpeza.Previa.Children.Clear()
    $script:GuiLimpeza.Resultado.Children.Clear()
    $script:GuiLimpeza.Log.Children.Clear()
    $script:GuiLimpeza.Barra.Maximum = @($script:AlvosLimpeza).Count
    $script:GuiLimpeza.Barra.Value = 0
    $script:GuiLimpeza.Progresso.Visibility = 'Visible'

    $fila = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $dotSource = ". `"$PSCommandPath`" -CarregarSomente -PastaKit `"$PastaKit`""
    $corpo = @"
param(`$FilaProgresso)
$dotSource
`$linhas = @()
`$total = @(`$script:AlvosLimpeza).Count
`$i = 0
foreach (`$alvo in `$script:AlvosLimpeza) {
    `$i++
    `$FilaProgresso.Enqueue([pscustomobject]@{ I = `$i; N = `$total; Rotulo = `$alvo.Rotulo })
    if (`$alvo.Admin -and -not `$isAdmin) { `$linhas += [pscustomobject]@{ Rotulo = `$alvo.Rotulo; Estado = 'RequerAdmin'; Bytes = 0; Arquivos = 0 }; continue }
    `$m = Medir-Alvo (& `$alvo.Caminho) `$alvo.Excluir
    if (-not `$m.Existe) { `$linhas += [pscustomobject]@{ Rotulo = `$alvo.Rotulo; Estado = 'NaoExiste'; Bytes = 0; Arquivos = 0 }; continue }
    `$linhas += [pscustomobject]@{ Rotulo = `$alvo.Rotulo; Estado = 'Ok'; Bytes = `$m.Bytes; Arquivos = `$m.Arquivos }
}
[pscustomobject]@{ Linhas = @(`$linhas) }
"@
    $sb = [scriptblock]::Create($corpo)
    [void](Iniciar-TarefaGui -Script $sb -Fila $fila -OnProgresso {
        param($P)
        $script:GuiLimpeza.Barra.Value = $P.I
        $script:GuiLimpeza.Status.Text = "Calculando ($($P.I)/$($P.N)): $($P.Rotulo)..."
        $linha = ConvertTo-XamlGui "<TextBlock @@NS@@ Text=`"$(Esc-Gui "$($P.I)/$($P.N) - $($P.Rotulo)")`" FontSize=`"11.5`" Foreground=`"@@Muted@@`" Margin=`"0,0,0,2`"/>"
        [void]$script:GuiLimpeza.Log.Children.Add($linha)
        $script:GuiLimpeza.Rolagem.ScrollToBottom()
    } -OnConcluir {
        param($Saida, $Erro)
        $script:GuiLimpeza.BotaoCalcular.IsEnabled = $true
        $script:GuiLimpeza.Progresso.Visibility = 'Collapsed'
        if ($Erro) { $script:GuiLimpeza.Status.Text = "Não foi possível calcular: $($Erro.Exception.Message)"; return }
        $script:GuiUltimaPreviaLimpeza = [pscustomobject]@{ Linhas = $Saida[0].Linhas; Quando = Get-Date }
        $script:GuiLimpeza.Status.Text = "Calculado às $($script:GuiUltimaPreviaLimpeza.Quando.ToString('HH:mm:ss'))"
        Preencher-PreviaLimpezaGui $script:GuiLimpeza.Previa $script:GuiUltimaPreviaLimpeza
    })
}

function Executar-LimpezaGui {
    $script:GuiLimpeza.BotaoCalcular.IsEnabled = $false
    $script:GuiLimpeza.Status.Text = 'Limpando...'
    $script:GuiLimpeza.Resultado.Children.Clear()
    $script:GuiLimpeza.Log.Children.Clear()
    $total = @($script:AlvosLimpeza).Count + 1
    $script:GuiLimpeza.Barra.Maximum = $total
    $script:GuiLimpeza.Barra.Value = 0
    $script:GuiLimpeza.Progresso.Visibility = 'Visible'

    $fila = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $dotSource = ". `"$PSCommandPath`" -CarregarSomente -PastaKit `"$PastaKit`""
    $corpo = @"
param(`$FilaProgresso)
$dotSource
`$script:bytesLiberados = [int64]0
`$resultados = @()
`$total = @(`$script:AlvosLimpeza).Count + 1
`$i = 0
foreach (`$alvo in `$script:AlvosLimpeza) {
    `$i++
    `$FilaProgresso.Enqueue([pscustomobject]@{ I = `$i; N = `$total; Rotulo = `$alvo.Rotulo })
    `$resultados += (Limpar-Alvo `$alvo)
}
`$i++
`$FilaProgresso.Enqueue([pscustomobject]@{ I = `$i; N = `$total; Rotulo = 'Cache de DNS' })
`$resultados += (Limpar-CacheDns)
`$lix = Medir-Lixeira
[pscustomobject]@{ Resultados = @(`$resultados); BytesLiberados = `$script:bytesLiberados; LixeiraBytes = `$(if (`$lix) { `$lix.Bytes } else { 0 }); LixeiraItens = `$(if (`$lix) { `$lix.Itens } else { 0 }) }
"@
    $sb = [scriptblock]::Create($corpo)
    [void](Iniciar-TarefaGui -Script $sb -Fila $fila -OnProgresso {
        param($P)
        $script:GuiLimpeza.Barra.Value = $P.I
        $script:GuiLimpeza.Status.Text = "Limpando ($($P.I)/$($P.N)): $($P.Rotulo)..."
        $linha = ConvertTo-XamlGui "<TextBlock @@NS@@ Text=`"$(Esc-Gui "$($P.I)/$($P.N) - $($P.Rotulo)")`" FontSize=`"11.5`" Foreground=`"@@Muted@@`" Margin=`"0,0,0,2`"/>"
        [void]$script:GuiLimpeza.Log.Children.Add($linha)
        $script:GuiLimpeza.Rolagem.ScrollToBottom()
    } -OnConcluir {
        param($Saida, $Erro)
        $script:GuiLimpeza.BotaoCalcular.IsEnabled = $true
        $script:GuiLimpeza.Progresso.Visibility = 'Collapsed'
        if ($Erro) { $script:GuiLimpeza.Status.Text = "Não foi possível limpar: $($Erro.Exception.Message)"; return }
        $pacote = $Saida[0]
        $script:GuiUltimoResultadoLimpeza = [pscustomobject]@{ BytesLiberados = $pacote.BytesLiberados; Quando = Get-Date }
        $script:GuiLimpeza.Status.Text = "Última limpeza: $($script:GuiUltimoResultadoLimpeza.Quando.ToString('HH:mm:ss'))"
        Preencher-ResultadoLimpezaGui $script:GuiLimpeza.Resultado @($pacote.Resultados) $pacote.LixeiraBytes $pacote.LixeiraItens
    })
}

function Novo-AbaLimpezaGui {
    param($Item)
    $elevado = ($script:GuiEstado -eq 'Admin')
    $aba = ConvertTo-XamlGui "<StackPanel @@NS@@>$(Novo-TituloGui $Item.Titulo $Item.Descricao)$(Obter-ChipAdminGui $Item $elevado)</StackPanel>"

    [void]$aba.Children.Add((ConvertTo-XamlGui '<TextBlock @@NS@@ Foreground="@@Muted@@" TextWrapping="Wrap" FontSize="12.5" Text="Remove arquivos temporários e caches. Nenhum documento, foto ou programa é tocado. A Lixeira só é esvaziada se você escolher, depois de ver quanto tem."/>'))

    $barra = ConvertTo-XamlGui '<StackPanel @@NS@@ Orientation="Horizontal" Margin="0,14,0,0"/>'
    $botaoCalcular = ConvertTo-XamlGui '<Button @@NS@@ Content="Calcular o que pode ser liberado" Style="{DynamicResource BotaoPrimario}"/>'
    $status = ConvertTo-XamlGui '<TextBlock @@NS@@ Foreground="@@Muted@@" VerticalAlignment="Center" Margin="14,0,0,0"/>'
    $status.Text = if ($script:GuiUltimaPreviaLimpeza) { "Calculado às $($script:GuiUltimaPreviaLimpeza.Quando.ToString('HH:mm:ss'))" } else { 'Ainda não calculado nesta sessão.' }
    [void]$barra.Children.Add($botaoCalcular); [void]$barra.Children.Add($status)
    [void]$aba.Children.Add($barra)

    $prog = Novo-PainelProgressoGui
    [void]$aba.Children.Add($prog.Painel)

    $previa = New-Object System.Windows.Controls.StackPanel
    $previa.Margin = '0,10,0,0'
    [void]$aba.Children.Add($previa)

    $resultado = New-Object System.Windows.Controls.StackPanel
    $resultado.Margin = '0,4,0,0'
    [void]$aba.Children.Add($resultado)

    # $script:GuiLimpeza guarda os controles pro Add_Click enxergar depois (mesma razao do
    # $script:GuiDiag na aba de Diagnostico). So existe UMA instancia por vez.
    $script:GuiLimpeza = [pscustomobject]@{ BotaoCalcular = $botaoCalcular; Status = $status; Progresso = $prog.Painel; Barra = $prog.Barra; Log = $prog.Log; Rolagem = $prog.Rolagem; Previa = $previa; Resultado = $resultado }

    if ($script:GuiUltimaPreviaLimpeza) { Preencher-PreviaLimpezaGui $previa $script:GuiUltimaPreviaLimpeza }

    $botaoCalcular.Add_Click({ Calcular-LimpezaGui })
    $aba
}

# ===================== ABA DE SCANNER (GUI) =====================
# O Scanner Anti-Minerador v4 continua sendo o MESMO .bat auto-extraivel e interativo de sempre (se
# achar algo suspeito, pergunta o que remover com Read-Host, na PROPRIA janela elevada dele) - nao
# tocamos nessa logica de decisao/remocao. A GUI so lanca o processo elevado (igual o console ja
# fazia) e MONITORA de fora: a funcao W do scanner ja grava cada linha em tempo real no arquivo de
# log (Add-Content), entao a barra de progresso real vem de TAILAR esse arquivo e capturar as linhas
# "ETAPA N de 34" conforme elas sao escritas de verdade - nunca por tempo/simulacao. "Terminou" e
# detectado por um marcador ("SCANNER_CONCLUIDO") que o proprio scanner grava como ultima linha do
# log - unica linha nova adicionada ao .bat pra isso (ver comentario dentro do corpo em
# Rodar-ScannerGui do porque nao da pra confiar no processo/janela pra essa deteccao). Ao final, os
# marcadores [ALERTA] e [BAIXA PRIORIDADE] que a propria funcao W ja grava no log dao a contagem do
# resumo.

function Preencher-ResultadoScannerGui {
    param($Painel, $Pacote)
    $Painel.Children.Clear()
    if ($Pacote.Erro -eq 'NaoEncontrado') {
        [void]$Painel.Children.Add((Novo-CartaoResultadoGui (Res 'Scanner' 'Indisponivel' 'Scanner não encontrado' "Coloque o arquivo 'SCANNER ANTI-MINERADOR v4.bat' dentro de $pastaFerramentas")))
        return
    }
    if ($Pacote.Erro -eq 'Uac') {
        [void]$Painel.Children.Add((Novo-CartaoResultadoGui (Res 'Scanner' 'Atencao' 'Permissão de administrador não concedida' 'Sem ela o scanner não roda. Clique em "Rodar Scanner" novamente e aceite a janela do UAC.')))
        return
    }
    if ($Pacote.Erro -eq 'SemRelatorio') {
        [void]$Painel.Children.Add((Novo-CartaoResultadoGui (Res 'Scanner' 'Indisponivel' 'O scanner não começou a gerar o relatório em 90s' 'Verifique se uma janela "SCANNER ANTI-MINERADOR v4" abriu (às vezes atrás desta janela) e se a permissão de administrador apareceu. Também pode ser o antivírus escaneando o arquivo antes de deixar rodar (risco conhecido - o scanner varre processos/registro de um jeito parecido com malware).' 'Rode de novo; se persistir, abra o .bat manualmente na pasta Ferramentas pra ver a mensagem de erro real, ou confira o Histórico de proteção do Windows Security.')))
        return
    }
    $itens = @()
    if ($Pacote.Alertas -gt 0) { $itens += Res 'Scanner' 'Problema' "$($Pacote.Alertas) sinal(is) de alta prioridade" 'Revise no relatório completo antes de decidir o que remover.' }
    if ($Pacote.AlertasBaixos -gt 0) { $itens += Res 'Scanner' 'Atencao' "$($Pacote.AlertasBaixos) item(ns) de baixa prioridade" 'Geralmente comum (instalador orfão/arquivo assinado); baixo risco.' }
    if ($itens.Count -eq 0) { $itens += Res 'Scanner' 'Ok' 'Nenhum sinal suspeito encontrado' }
    foreach ($it in $itens) { [void]$Painel.Children.Add((Novo-CartaoResultadoGui $it)) }
    $botaoAbrir = ConvertTo-XamlGui '<Button @@NS@@ Content="Abrir relatório completo" Style="{DynamicResource BotaoSecundario}" HorizontalAlignment="Left" Margin="0,6,0,0"/>'
    $botaoAbrir.Tag = $Pacote.LogPath
    $botaoAbrir.Add_Click({
        try { Start-Process $this.Tag }
        catch { [void][System.Windows.MessageBox]::Show("Não foi possível abrir o relatório.`n$($_.Exception.Message)", 'WinHealth') }
    })
    [void]$Painel.Children.Add($botaoAbrir)
}

function Rodar-ScannerGui {
    $script:GuiScanner.Botao.IsEnabled = $false
    $script:GuiScanner.Status.Text = 'Abrindo o Scanner (ele vai pedir permissão de administrador)...'
    $script:GuiScanner.Resultado.Children.Clear()
    $script:GuiScanner.Log.Children.Clear()
    $script:GuiScanner.Barra.Maximum = 34
    $script:GuiScanner.Barra.Value = 0
    $script:GuiScanner.Progresso.Visibility = 'Visible'

    $fila = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $dotSource = ". `"$PSCommandPath`" -CarregarSomente -PastaKit `"$PastaKit`""
    $corpo = @"
param(`$FilaProgresso)
$dotSource
`$caminhoScanner = Join-Path `$pastaFerramentas "SCANNER ANTI-MINERADOR v4.bat"
if (-not (Test-Path `$caminhoScanner)) { return [pscustomobject]@{ Erro = 'NaoEncontrado' } }
if (`$modoRede) {
    `$copiaLocal = Join-Path `$env:TEMP "SCANNER_ANTI-MINERADOR_v4.bat"
    Copy-Item -LiteralPath `$caminhoScanner -Destination `$copiaLocal -Force
    `$caminhoScanner = `$copiaLocal
}
`$inicio = Get-Date
`$argScanner = '"' + `$pastaRelatorios + '"'
# Achado ao vivo (28/09/2026, 4 testes isolados nesta maquina): "Start-Process -Verb RunAs
# -ArgumentList <algo entre aspas>" FALHA (ExitCode=1, o .bat nunca chega a rodar - nem o
# echo/title iniciais aparecem) quando o processo QUE CHAMA ja esta elevado - reproduzido de
# forma identica com um .bat minimo e com o Scanner real, e confirmado que rodar o EXATO
# mesmo comando SEM -Verb RunAs (dispensavel - ja estamos admin) funciona perfeito e gera o
# relatorio. Era exatamente o cenario do Gabriel (ele sempre roda o WinHealth como
# Administrador) - por isso nunca funcionava pra ele, e por isso eu nunca reproduzia testando
# sem estar elevado. So usar -Verb RunAs quando for preciso pedir elevacao de verdade.
try {
    if (`$isAdmin) { `$p = Start-Process -FilePath `$caminhoScanner -ArgumentList `$argScanner -PassThru -ErrorAction Stop }
    else { `$p = Start-Process -FilePath `$caminhoScanner -ArgumentList `$argScanner -Verb RunAs -PassThru -ErrorAction Stop }
} catch { return [pscustomobject]@{ Erro = 'Uac'; Mensagem = `$_.Exception.Message } }
`$arquivo = `$null
`$posicao = 0
`$concluido = `$false
# NAO usar `$p.HasExited nem a janela do processo pra saber se terminou: o handle devolvido por
# -Verb RunAs pra um .bat elevado nao e confiavel atraves da fronteira de elevacao (era a causa real
# do "scanner encerrou sem gerar relatorio" - o loop saia na primeira checagem, antes do scanner
# sequer comecar a escrever), e rastrear a janela pelo titulo tambem nao e confiavel porque no
# Windows Terminal (padrao no Windows 11) quem hospeda a janela nao e o processo do .bat, e o
# fechamento automatico depende da configuracao do usuario. Em vez disso, o proprio scanner grava um
# marcador ("SCANNER_CONCLUIDO") como ULTIMA linha do log, depois de qualquer remocao interativa que
# o usuario tenha respondido - sinal real e 100% confiavel, sem depender de nada do SO.
# 90s (nao 25s): o antivirus pode escanear o .ps1 recem-extraido antes de deixar rodar (risco ja
# documentado do Scanner), e isso pode levar bem mais que alguns segundos numa maquina mais lenta.
`$limiteEsperaArquivo = (Get-Date).AddSeconds(90)
while (`$true) {
    # Reavalia o arquivo mais recente A CADA volta (nao so uma vez): se dois scanners forem
    # lancados perto o bastante (ex.: usuario clicou 2x, ou a colisao de nome de minuto que
    # existia antes do log passar a usar HHmmss), o arquivo "mais novo" pode mudar depois que
    # ja tinhamos travado num. Sem isso, o loop ficava preso pra sempre lendo um arquivo que
    # nunca chegava no SCANNER_CONCLUIDO (achado ao vivo: relatorio real parado em ETAPA 27/34
    # sem marcador, enquanto a janela do scanner mostrava as 34 etapas completas).
    `$achado = Get-ChildItem -LiteralPath `$pastaRelatorios -Filter '*_Scanner_*.txt' -File -ErrorAction SilentlyContinue |
        Where-Object { `$_.LastWriteTime -ge `$inicio.AddSeconds(-2) } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (`$achado) {
        if (`$achado.FullName -ne `$arquivo) { `$arquivo = `$achado.FullName; `$posicao = 0 }
    } elseif (-not `$arquivo -and (Get-Date) -gt `$limiteEsperaArquivo) {
        return [pscustomobject]@{ Erro = 'SemRelatorio' }
    }
    if (`$arquivo) {
        `$conteudo = Get-Content -LiteralPath `$arquivo -Raw -ErrorAction SilentlyContinue
        # Defesa extra: se o conteudo encolheu (arquivo foi apagado/recriado entre esta leitura e
        # a anterior, mesmo caminho), reinicia a posicao em vez de ficar "travado" esperando o
        # arquivo crescer de novo alem de onde ja estava.
        if (`$conteudo -and `$conteudo.Length -lt `$posicao) { `$posicao = 0 }
        if (`$conteudo -and `$conteudo.Length -gt `$posicao) {
            `$novo = `$conteudo.Substring(`$posicao)
            `$posicao = `$conteudo.Length
            foreach (`$m in [regex]::Matches(`$novo, 'ETAPA (\d+) de (\d+) - ([^\r\n=]+)')) {
                `$FilaProgresso.Enqueue([pscustomobject]@{ I = [int]`$m.Groups[1].Value; N = [int]`$m.Groups[2].Value; Rotulo = `$m.Groups[3].Value.Trim() })
            }
            if (`$novo -match 'SCANNER_CONCLUIDO') { `$concluido = `$true }
        }
    }
    if (`$concluido) { break }
    Start-Sleep -Milliseconds 500
}
`$textoFinal = Get-Content -LiteralPath `$arquivo -Raw -ErrorAction SilentlyContinue
`$alertas = ([regex]::Matches(`$textoFinal, '(?m)^\[ALERTA\]')).Count
`$baixos = ([regex]::Matches(`$textoFinal, '(?m)^\[BAIXA PRIORIDADE\]')).Count
[pscustomobject]@{ LogPath = `$arquivo; Alertas = `$alertas; AlertasBaixos = `$baixos }
"@
    $sb = [scriptblock]::Create($corpo)
    [void](Iniciar-TarefaGui -Script $sb -Fila $fila -OnProgresso {
        param($P)
        $script:GuiScanner.Barra.Maximum = $P.N
        $script:GuiScanner.Barra.Value = $P.I
        $script:GuiScanner.Status.Text = "Etapa ($($P.I)/$($P.N)): $($P.Rotulo)..."
        $linha = ConvertTo-XamlGui "<TextBlock @@NS@@ Text=`"$(Esc-Gui "$($P.I)/$($P.N) - $($P.Rotulo)")`" FontSize=`"11.5`" Foreground=`"@@Muted@@`" Margin=`"0,0,0,2`"/>"
        [void]$script:GuiScanner.Log.Children.Add($linha)
        $script:GuiScanner.Rolagem.ScrollToBottom()
    } -OnTick {
        param($Segundos)
        # So mostra o cronometro ANTES da 1a etapa aparecer (depois disso o texto de cima ja mostra
        # a etapa real) - pra deixar claro que nao travou enquanto espera a permissao de admin/
        # extracao/antivirus, sem inventar percentual nenhum (so o tempo decorrido de verdade).
        if ($script:GuiScanner.Barra.Value -eq 0) { $script:GuiScanner.Status.Text = "Abrindo o Scanner (rodando há ${Segundos}s)..." }
    } -OnConcluir {
        param($Saida, $Erro)
        $script:GuiScanner.Botao.IsEnabled = $true
        $script:GuiScanner.Progresso.Visibility = 'Collapsed'
        if ($Erro) { $script:GuiScanner.Status.Text = "Não foi possível rodar o scanner: $($Erro.Exception.Message)"; return }
        $pacote = $Saida[0]
        $script:GuiUltimoScanner = [pscustomobject]@{ Pacote = $pacote; Quando = Get-Date }
        $script:GuiScanner.Status.Text = "Última execução: $($script:GuiUltimoScanner.Quando.ToString('HH:mm:ss'))"
        Preencher-ResultadoScannerGui $script:GuiScanner.Resultado $pacote
    })
}

function Novo-AbaScannerGui {
    param($Item)
    $elevado = ($script:GuiEstado -eq 'Admin')
    $aba = ConvertTo-XamlGui "<StackPanel @@NS@@>$(Novo-TituloGui $Item.Titulo $Item.Descricao)$(Obter-ChipAdminGui $Item $elevado)</StackPanel>"

    [void]$aba.Children.Add((ConvertTo-XamlGui '<TextBlock @@NS@@ Foreground="@@Muted@@" TextWrapping="Wrap" FontSize="12.5" Text="O Scanner abre em uma janela própria e pede permissão de administrador (pra poder encerrar tarefas suspeitas). Ele só verifica - nada é apagado sem você confirmar, na própria janela dele."/>'))

    $barra = ConvertTo-XamlGui '<StackPanel @@NS@@ Orientation="Horizontal" Margin="0,14,0,0"/>'
    $botao = ConvertTo-XamlGui '<Button @@NS@@ Content="Rodar Scanner" Style="{DynamicResource BotaoPrimario}"/>'
    $status = ConvertTo-XamlGui '<TextBlock @@NS@@ Foreground="@@Muted@@" VerticalAlignment="Center" Margin="14,0,0,0"/>'
    $status.Text = if ($script:GuiUltimoScanner) { "Última execução: $($script:GuiUltimoScanner.Quando.ToString('HH:mm:ss'))" } else { 'Ainda não executado nesta sessão.' }
    [void]$barra.Children.Add($botao); [void]$barra.Children.Add($status)
    [void]$aba.Children.Add($barra)

    $prog = Novo-PainelProgressoGui
    [void]$aba.Children.Add($prog.Painel)

    $resultado = New-Object System.Windows.Controls.StackPanel
    $resultado.Margin = '0,4,0,0'
    [void]$aba.Children.Add($resultado)

    # $script:GuiScanner guarda os controles pro Add_Click enxergar depois (mesmo motivo do
    # $script:GuiDiag/$script:GuiLimpeza). So existe UMA instancia por vez.
    $script:GuiScanner = [pscustomobject]@{ Botao = $botao; Status = $status; Progresso = $prog.Painel; Barra = $prog.Barra; Log = $prog.Log; Rolagem = $prog.Rolagem; Resultado = $resultado }

    if ($script:GuiUltimoScanner) { Preencher-ResultadoScannerGui $resultado $script:GuiUltimoScanner.Pacote }

    $botao.Add_Click({ Rodar-ScannerGui })
    $aba
}

# ===================== ABA DE REPARO (GUI) =====================
# DISM -> SFC -> CHKDSK, na mesma ordem e com a mesma logica de sempre (Invoke-Comando +
# Interpretar-Dism/Sfc/Chkdsk, puras, reaproveitadas sem mudanca nenhuma). A unica coisa que muda e
# quem CHAMA essas funcoes: em vez de Executar-EtapaReparo (que escreve direto no console), o script
# de fundo manda cada evento real (inicio da etapa, cada linha nova de saida a cada ~2s, fim da etapa)
# pra fila de progresso. A confirmacao do ponto de restauracao (que no console e' um Read-Host) vira um
# MessageBox nativo ANTES de iniciar a tarefa de fundo - o runspace de fundo nunca pode ter um prompt
# interativo (nao tem console pra responder, ficaria pendurado pra sempre).
function Preencher-ResultadoReparoGui {
    param($Painel, $Pacote, [bool]$PontoOk)
    $Painel.Children.Clear()
    if ($PontoOk) {
        [void]$Painel.Children.Add((Novo-CartaoResultadoGui (Res 'Ponto de restauração' 'Ok' 'Ponto de restauração criado antes do reparo')))
    } else {
        [void]$Painel.Children.Add((Novo-CartaoResultadoGui (Res 'Ponto de restauração' 'Atencao' 'Não foi possível criar o ponto de restauração' 'Você optou por continuar mesmo assim.')))
    }
    $itens = @($Pacote.ResDism, $Pacote.ResSfc, $Pacote.ResChkdsk)
    foreach ($r in $itens) { [void]$Painel.Children.Add((Novo-CartaoResultadoGui $r)) }
    $sevs = @($itens | ForEach-Object { $_.Severidade })
    if ($sevs -contains 'Problema') { $tom = 'Problema'; $txt = 'Reparo concluído com problema(s) - veja os itens acima' }
    elseif ($sevs -contains 'Atencao') { $tom = 'Atencao'; $txt = 'Reparo concluído com ponto(s) de atenção' }
    else { $tom = 'Ok'; $txt = 'Reparo concluído sem problemas' }
    [void]$Painel.Children.Add((ConvertTo-XamlGui @"
<Border @@NS@@ Background="@@$($tom)Fundo@@" BorderBrush="@@$tom@@" BorderThickness="1" CornerRadius="8" Padding="14,12" Margin="0,10,0,0">
  <StackPanel>
    <TextBlock Text="$(Esc-Gui $txt)" FontWeight="SemiBold" Foreground="@@$tom@@"/>
    <TextBlock Text="Reinicie a máquina para finalizar qualquer reparo aplicado." Foreground="@@Muted@@" FontSize="12" Margin="0,4,0,0"/>
  </StackPanel>
</Border>
"@))
}

# Funcao a parte (nao inline) so pra poder ser mockada nos testes: uma chamada estatica de
# [System.Windows.MessageBox]::Show(...) nao pode ser interceptada redefinindo uma funcao PowerShell
# com o mesmo nome (metodo estatico ignora resolucao de comando), entao ela precisa ficar isolada aqui
# dentro - senao a suite de testes abriria um dialogo real esperando um clique que nunca vem.
function Confirmar-ContinuarSemPontoGui {
    $ultimo = Obter-UltimoPontoRestauracao
    $infoUltimo = if ($ultimo) { "O ponto mais recente que já existe é de $($ultimo.ToString('dd/MM/yyyy HH:mm')) - ele continua valendo pra voltar atrás, mesmo sem criar um novo agora." } else { "Não foi encontrado nenhum ponto de restauração existente nesta máquina." }
    $resp = [System.Windows.MessageBox]::Show("Não foi possível criar um ponto NOVO agora (o Windows permite só 1 a cada 24h, ou a Proteção do Sistema pode estar desligada).`n`n$infoUltimo`n`nContinuar mesmo assim?", 'WinHealth', 'YesNo', 'Warning')
    "$resp" -eq 'Yes'
}

function Rodar-ReparoGui {
    if ($script:GuiEstado -ne 'Admin') { return }
    $pontoOk = $false
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description 'WinHealth - antes do reparo do Windows' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        $pontoOk = $true
    } catch {
        if (-not (Confirmar-ContinuarSemPontoGui)) { return }
    }
    $script:GuiReparo.PontoRestauracao = $pontoOk
    $script:GuiReparo.Botao.IsEnabled = $false
    $script:GuiReparo.Status.Text = 'Iniciando o reparo...'
    $script:GuiReparo.Resultado.Children.Clear()
    $script:GuiReparo.Log.Children.Clear()
    $script:GuiReparo.UltimaLinha = $null
    $script:GuiReparo.Barra.Maximum = 3
    $script:GuiReparo.Barra.Value = 0
    $script:GuiReparo.Progresso.Visibility = 'Visible'

    $fila = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $dotSource = ". `"$PSCommandPath`" -CarregarSomente -PastaKit `"$PastaKit`""
    $corpo = @"
param(`$FilaProgresso)
$dotSource
function EnviarProgresso(`$tipo, `$etapa, `$nome, `$decorrido, `$linha) {
    `$FilaProgresso.Enqueue([pscustomobject]@{ Tipo = `$tipo; Etapa = `$etapa; Nome = `$nome; Decorrido = `$decorrido; Linha = `$linha })
}
function RodarEtapaReparo(`$etapa, `$nome, `$exe, `$argumentos, `$codificacao) {
    EnviarProgresso 'Inicio' `$etapa `$nome '00:00:00' ''
    `$cmd = Invoke-Comando `$exe `$argumentos { param(`$d, `$l) EnviarProgresso 'Tick' `$etapa `$nome `$d `$l } `$codificacao
    Add-Content -Path `$logfile -Value "----- `$exe `$(`$cmd.Argumentos) | código `$(`$cmd.Codigo) | duração `$(`$cmd.Duracao.ToString('hh\:mm\:ss')) -----"
    Add-Content -Path `$logfile -Value `$cmd.Saida
    EnviarProgresso 'Fim' `$etapa `$nome `$cmd.Duracao.ToString('hh\:mm\:ss') ''
    `$cmd
}
`$cmdDism = RodarEtapaReparo 1 'DISM' 'DISM.exe' @('/Online', '/Cleanup-Image', '/RestoreHealth') 'Oem'
`$resDism = Interpretar-Dism `$cmdDism.Codigo `$cmdDism.Saida
`$cmdSfc = RodarEtapaReparo 2 'SFC' 'sfc.exe' @('/scannow') 'Oem'
`$resSfc = Interpretar-Sfc `$cmdSfc.Codigo `$cmdSfc.Saida
`$cmdChkdsk = RodarEtapaReparo 3 'CHKDSK' 'chkdsk.exe' @(`$env:SystemDrive, '/scan') 'Ansi'
`$resChkdsk = Interpretar-Chkdsk `$cmdChkdsk.Codigo `$cmdChkdsk.Saida
[pscustomobject]@{ ResDism = `$resDism; ResSfc = `$resSfc; ResChkdsk = `$resChkdsk }
"@
    $sb = [scriptblock]::Create($corpo)
    [void](Iniciar-TarefaGui -Script $sb -Fila $fila -OnProgresso {
        param($P)
        switch ($P.Tipo) {
            'Inicio' {
                $script:GuiReparo.Barra.Value = $P.Etapa - 1
                $script:GuiReparo.Status.Text = "Etapa $($P.Etapa) de 3 ($($P.Nome)): iniciando..."
                $script:GuiReparo.UltimaLinha = $null
                $l = ConvertTo-XamlGui "<TextBlock @@NS@@ Text=`"$(Esc-Gui "Etapa $($P.Etapa) de 3 ($($P.Nome)): iniciando...")`" FontSize=`"11.5`" FontWeight=`"SemiBold`" Margin=`"0,8,0,2`"/>"
                [void]$script:GuiReparo.Log.Children.Add($l)
            }
            'Tick' {
                $script:GuiReparo.Status.Text = "Etapa $($P.Etapa) de 3 ($($P.Nome)): rodando há $($P.Decorrido)"
                if ($P.Linha -and $P.Linha -ne $script:GuiReparo.UltimaLinha) {
                    $script:GuiReparo.UltimaLinha = $P.Linha
                    $l = ConvertTo-XamlGui "<TextBlock @@NS@@ Text=`"$(Esc-Gui "[$($P.Decorrido)] $($P.Linha)")`" FontSize=`"11.5`" Foreground=`"@@Muted@@`" Margin=`"0,0,0,2`"/>"
                    [void]$script:GuiReparo.Log.Children.Add($l)
                }
            }
            'Fim' {
                $script:GuiReparo.Barra.Value = $P.Etapa
                $script:GuiReparo.Status.Text = "Etapa $($P.Etapa) de 3 ($($P.Nome)): concluída em $($P.Decorrido)"
                $l = ConvertTo-XamlGui "<TextBlock @@NS@@ Text=`"$(Esc-Gui "Etapa $($P.Etapa) de 3 ($($P.Nome)) concluída em $($P.Decorrido)")`" FontSize=`"11.5`" FontWeight=`"SemiBold`" Foreground=`"@@Ok@@`" Margin=`"0,2,0,8`"/>"
                [void]$script:GuiReparo.Log.Children.Add($l)
            }
        }
        $script:GuiReparo.Rolagem.ScrollToBottom()
    } -OnConcluir {
        param($Saida, $Erro)
        $script:GuiReparo.Botao.IsEnabled = $true
        $script:GuiReparo.Progresso.Visibility = 'Collapsed'
        if ($Erro) { $script:GuiReparo.Status.Text = "Não foi possível concluir o reparo: $($Erro.Exception.Message)"; return }
        $pacote = $Saida[0]
        $script:GuiUltimoReparo = [pscustomobject]@{ Pacote = $pacote; PontoRestauracao = $script:GuiReparo.PontoRestauracao; Quando = Get-Date }
        $script:GuiReparo.Status.Text = "Última execução: $($script:GuiUltimoReparo.Quando.ToString('HH:mm:ss'))"
        Preencher-ResultadoReparoGui $script:GuiReparo.Resultado $pacote $script:GuiReparo.PontoRestauracao
    })
}

function Novo-AbaReparoGui {
    param($Item)
    $elevado = ($script:GuiEstado -eq 'Admin')
    $aba = ConvertTo-XamlGui "<StackPanel @@NS@@>$(Novo-TituloGui $Item.Titulo $Item.Descricao)$(Obter-ChipAdminGui $Item $elevado)</StackPanel>"

    [void]$aba.Children.Add((ConvertTo-XamlGui @'
<StackPanel @@NS@@ Margin="0,4,0,0">
  <TextBlock Foreground="@@Muted@@" TextWrapping="Wrap" FontSize="12.5" Text="Este reparo roda, NESTA ORDEM (é a ordem correta): 1) DISM - conserta a imagem base do Windows (baixa arquivos da Microsoft); 2) SFC - conserta os arquivos do sistema usando a imagem já corrigida; 3) CHKDSK - verifica erros no disco (modo verificação, não corrige nada sozinho)."/>
  <TextBlock Foreground="@@Atencao@@" TextWrapping="Wrap" FontSize="12.5" Margin="0,8,0,0" Text="A ordem importa: rodar o SFC antes do DISM é o erro mais comum, porque ele repararia usando uma imagem que pode estar corrompida também. Tempo estimado: 15 a 40 minutos. Precisa de internet para o DISM."/>
  <Border Background="@@OkFundo@@" BorderBrush="@@Ok@@" BorderThickness="1" CornerRadius="8" Padding="12,10" Margin="0,12,0,0">
    <TextBlock TextWrapping="Wrap" FontSize="12.5" Foreground="@@Ok@@">
      <Run Text="Ponto de restauração: " FontWeight="SemiBold"/>
      <Run Text="antes de começar, o WinHealth tenta criar um ponto de restauração do Windows automaticamente (é o &quot;ponto de salvamento&quot; do sistema - se algo der errado, dá pra voltar por ele). O Windows só permite criar 1 ponto NOVO a cada 24h - se já tiver um recente, o WinHealth não trava nem impede o reparo: uma caixa mostra a data/hora do ponto que já existe (esse continua servindo pra voltar atrás) e pergunta se quer continuar mesmo sem criar um novo agora. Ou seja: dá pra usar o Reparo mais de uma vez no mesmo dia sem problema."/>
    </TextBlock>
  </Border>
</StackPanel>
'@))

    $barra = ConvertTo-XamlGui '<StackPanel @@NS@@ Orientation="Horizontal" Margin="0,14,0,0"/>'
    $botao = ConvertTo-XamlGui '<Button @@NS@@ Content="Rodar reparo do Windows" Style="{DynamicResource BotaoPrimario}"/>'
    $status = ConvertTo-XamlGui '<TextBlock @@NS@@ Foreground="@@Muted@@" VerticalAlignment="Center" Margin="14,0,0,0"/>'
    if (-not $elevado) {
        $botao.IsEnabled = $false
        $status.Text = 'Requer administrador - reabra o WinHealth como administrador (botão no topo da janela).'
    } elseif ($script:GuiUltimoReparo) {
        $status.Text = "Última execução: $($script:GuiUltimoReparo.Quando.ToString('HH:mm:ss'))"
    } else {
        $status.Text = 'Ainda não executado nesta sessão.'
    }
    [void]$barra.Children.Add($botao); [void]$barra.Children.Add($status)
    [void]$aba.Children.Add($barra)

    $prog = Novo-PainelProgressoGui
    [void]$aba.Children.Add($prog.Painel)

    $resultado = New-Object System.Windows.Controls.StackPanel
    $resultado.Margin = '0,4,0,0'
    [void]$aba.Children.Add($resultado)

    # $script:GuiReparo guarda os controles pro Add_Click enxergar depois (mesmo motivo dos outros).
    # So existe UMA instancia por vez.
    $script:GuiReparo = [pscustomobject]@{ Botao = $botao; Status = $status; Progresso = $prog.Painel; Barra = $prog.Barra; Log = $prog.Log; Rolagem = $prog.Rolagem; Resultado = $resultado; UltimaLinha = $null; PontoRestauracao = $false }

    if ($script:GuiUltimoReparo) { Preencher-ResultadoReparoGui $resultado $script:GuiUltimoReparo.Pacote $script:GuiUltimoReparo.PontoRestauracao }

    $botao.Add_Click({ Rodar-ReparoGui })
    $aba
}

# ===================== ABA DE USB (GUI) =====================
# So leitura (Coletar-EstadoUSB/Avaliar-EstadoUSB, puras, reaproveitadas sem mudanca), rapida o
# suficiente pra nao precisar de barra de progresso - so o botao desabilita durante a checagem real.
# A unica parte interativa do console (Read-Host perguntando se ha pendrive conectado, so quando
# nenhum disco USB aparece) vira dois botoes "Sim"/"Não" na propria aba, com o Estado coletado
# guardado no .Tag (mesma regra dos outros modulos: handler que dispara depois nao pode confiar em
# variavel local da funcao que criou o botao).
function Finalizar-VerificacaoUSBGui {
    param($Estado, [bool]$Conectado)
    if ($script:GuiUltimoUSB) { $script:GuiUltimoUSB.Conectado = $Conectado }
    $Painel = $script:GuiUSB.Resultado
    $Painel.Children.Clear()
    Adicionar-SecoesPorCategoriaGui $Painel @(Avaliar-EstadoUSB $Estado $Conectado)
    $texto = @(Novo-TextoChamado $Estado.DiscosUsb $nomeMaquina "$env:USERDOMAIN\$env:USERNAME" (Get-Date -Format 'dd/MM/yyyy HH:mm'))
    if ($texto.Count -eq 0) { return }
    $arq = Join-Path $pastaRelatorios "$nomeMaquina`_PedidoLiberacaoUSB_$carimbo.txt"
    try { [IO.File]::WriteAllText($arq, ($texto -join "`r`n"), (New-Object Text.UTF8Encoding($true))) } catch {}
    $caixa = ConvertTo-XamlGui @'
<Border @@NS@@ Background="@@Superficie@@" BorderBrush="@@Borda@@" BorderThickness="1" CornerRadius="8" Padding="14,12" Margin="0,14,0,0">
  <StackPanel>
    <TextBlock Text="Texto para o chamado" FontSize="14" FontWeight="SemiBold"/>
    <TextBox AcceptsReturn="True" IsReadOnly="True" TextWrapping="Wrap" FontFamily="Consolas" FontSize="12" Background="Transparent" Foreground="@@Texto@@" BorderThickness="0" Margin="0,8,0,8"/>
    <StackPanel Orientation="Horizontal"/>
  </StackPanel>
</Border>
'@
    $caixa.Child.Children[1].Text = ($texto -join "`r`n")
    $botaoCopiar = ConvertTo-XamlGui '<Button @@NS@@ Content="Copiar texto" Style="{DynamicResource BotaoSecundario}" HorizontalAlignment="Left"/>'
    $botaoCopiar.Tag = ($texto -join "`r`n")
    $botaoCopiar.Add_Click({ try { [System.Windows.Clipboard]::SetText($this.Tag) } catch {} })
    [void]$caixa.Child.Children[2].Children.Add($botaoCopiar)
    [void]$caixa.Child.Children.Add((ConvertTo-XamlGui "<TextBlock @@NS@@ Text=`"$(Esc-Gui "Salvo também em: $arq")`" Foreground=`"@@Muted@@`" FontSize=`"11.5`" Margin=`"0,8,0,0`"/>"))
    [void]$Painel.Children.Add($caixa)
}

function Mostrar-PerguntaPendriveGui {
    param($Estado)
    $Painel = $script:GuiUSB.Resultado
    $Painel.Children.Clear()
    $caixa = ConvertTo-XamlGui @'
<Border @@NS@@ Background="@@AtencaoFundo@@" BorderBrush="@@Atencao@@" BorderThickness="1" CornerRadius="8" Padding="14,12">
  <StackPanel>
    <TextBlock Text="Nenhum pendrive/disco USB visível ao Windows agora" FontSize="14" FontWeight="SemiBold" Foreground="@@Atencao@@"/>
    <TextBlock TextWrapping="Wrap" Margin="0,6,0,12" FontSize="12.5" Text="Há um pendrive fisicamente conectado a esta máquina neste momento?"/>
    <StackPanel Orientation="Horizontal"/>
  </StackPanel>
</Border>
'@
    $botoes = $caixa.Child.Children[2]
    $botaoSim = ConvertTo-XamlGui '<Button @@NS@@ Content="Sim, tem um pendrive conectado" Style="{DynamicResource BotaoPrimario}" Margin="0,0,8,0"/>'
    $botaoNao = ConvertTo-XamlGui '<Button @@NS@@ Content="Não" Style="{DynamicResource BotaoSecundario}"/>'
    [void]$botoes.Children.Add($botaoSim); [void]$botoes.Children.Add($botaoNao)
    $dados = [pscustomobject]@{ Estado = $Estado }
    $botaoSim.Tag = $dados
    $botaoSim.Add_Click({ Finalizar-VerificacaoUSBGui $this.Tag.Estado $true })
    $botaoNao.Tag = $dados
    $botaoNao.Add_Click({ Finalizar-VerificacaoUSBGui $this.Tag.Estado $false })
    [void]$Painel.Children.Add($caixa)
}

function Rodar-UsbGui {
    $script:GuiUSB.Botao.IsEnabled = $false
    $script:GuiUSB.Status.Text = 'Verificando...'
    $script:GuiUSB.Resultado.Children.Clear()

    $dotSource = ". `"$PSCommandPath`" -CarregarSomente -PastaKit `"$PastaKit`""
    $corpo = @"
$dotSource
`$estado = Coletar-EstadoUSB
[pscustomobject]@{ Estado = `$estado }
"@
    $sb = [scriptblock]::Create($corpo)
    [void](Iniciar-TarefaGui -Script $sb -OnConcluir {
        param($Saida, $Erro)
        $script:GuiUSB.Botao.IsEnabled = $true
        if ($Erro) { $script:GuiUSB.Status.Text = "Não foi possível verificar: $($Erro.Exception.Message)"; return }
        $estado = $Saida[0].Estado
        $script:GuiUltimoUSB = [pscustomobject]@{ Estado = $estado; Conectado = $null; Quando = Get-Date }
        $script:GuiUSB.Status.Text = "Última verificação: $($script:GuiUltimoUSB.Quando.ToString('HH:mm:ss'))"
        if (@($estado.DiscosUsb).Count -eq 0) { Mostrar-PerguntaPendriveGui $estado }
        else { Finalizar-VerificacaoUSBGui $estado $true }
    })
}

function Novo-AbaUSBGui {
    param($Item)
    $elevado = ($script:GuiEstado -eq 'Admin')
    $aba = ConvertTo-XamlGui "<StackPanel @@NS@@>$(Novo-TituloGui $Item.Titulo $Item.Descricao)$(Obter-ChipAdminGui $Item $elevado)</StackPanel>"

    [void]$aba.Children.Add((ConvertTo-XamlGui '<TextBlock @@NS@@ Foreground="@@Muted@@" TextWrapping="Wrap" FontSize="12.5" Text="Só leitura: não altera nenhuma configuração da máquina. Detecta bloqueio de USB por política (DLP/GPO) e gera o texto pra pedir liberação por Hardware ID."/>'))

    $barra = ConvertTo-XamlGui '<StackPanel @@NS@@ Orientation="Horizontal" Margin="0,14,0,0"/>'
    $botao = ConvertTo-XamlGui '<Button @@NS@@ Content="Verificar USB" Style="{DynamicResource BotaoPrimario}"/>'
    $status = ConvertTo-XamlGui '<TextBlock @@NS@@ Foreground="@@Muted@@" VerticalAlignment="Center" Margin="14,0,0,0"/>'
    $status.Text = if ($script:GuiUltimoUSB) { "Última verificação: $($script:GuiUltimoUSB.Quando.ToString('HH:mm:ss'))" } else { 'Ainda não verificado nesta sessão.' }
    [void]$barra.Children.Add($botao); [void]$barra.Children.Add($status)
    [void]$aba.Children.Add($barra)

    $resultado = New-Object System.Windows.Controls.StackPanel
    $resultado.Margin = '0,10,0,0'
    [void]$aba.Children.Add($resultado)

    # $script:GuiUSB guarda os controles pro Add_Click enxergar depois (mesmo motivo dos outros).
    $script:GuiUSB = [pscustomobject]@{ Botao = $botao; Status = $status; Resultado = $resultado }

    if ($script:GuiUltimoUSB) {
        if ($null -eq $script:GuiUltimoUSB.Conectado) { Mostrar-PerguntaPendriveGui $script:GuiUltimoUSB.Estado }
        else { Finalizar-VerificacaoUSBGui $script:GuiUltimoUSB.Estado $script:GuiUltimoUSB.Conectado }
    }

    $botao.Add_Click({ Rodar-UsbGui })
    $aba
}

function Mostrar-AbaGui {
    param([string]$Chave)
    if ($Chave -eq 'painel') { $script:GuiConteudo.Content = Novo-PainelGui }
    else {
        $item = $script:Menu | Where-Object { $_.Chave -eq $Chave } | Select-Object -First 1
        if (-not $item) { return }
        $script:GuiConteudo.Content = switch ($item.Chave) {
            '1' { Novo-AbaDiagnosticoGui $item }
            '2' { Novo-AbaScannerGui $item }
            '3' { Novo-AbaReparoGui $item }
            '4' { Novo-AbaLimpezaGui $item }
            '7' { Novo-AbaUSBGui $item }
            default { Novo-AbaModuloGui $item }
        }
    }
    $script:GuiRolagem.ScrollToTop()
}

function Ir-AbaGui {
    param([string]$Chave)
    foreach ($i in $script:GuiNav.Items) { if ($i.Tag -eq $Chave) { $script:GuiNav.SelectedItem = $i; break } }
}

function Abrir-ModuloGui {
    param([string]$Chave)
    $argumentos = "-NoProfile -ExecutionPolicy RemoteSigned -File `"$PSCommandPath`" -PastaKit `"$PastaKit`" -IniciarEm $Chave -SairAoFinal"
    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentos -PassThru -ErrorAction Stop
        [void]$script:GuiFilhos.Add($p)
    } catch {
        [void][System.Windows.MessageBox]::Show("Não foi possível abrir o módulo.`n$($_.Exception.Message)", 'WinHealth')
    }
}

# ===================== TERMINAL DE DIAGNOSTICO (janela separada) =====================
# Le e mostra $script:arquivoLogDiagnostico (ver "LOG DE DIAGNOSTICO" no topo do arquivo). So
# leitura + exportar - nao altera nada do fluxo normal do Kit. Botoes estilizados por conta
# propria (nao usam {StaticResource BotaoPrimario/Secundario} porque essa janela nao vive na
# arvore da janela principal - resolucao de StaticResource so acha o que esta no MESMO
# Window.Resources, e uma janela separada nao herda o dela).
function Obter-ConteudoLogDiagnostico {
    if (-not (Test-Path $script:arquivoLogDiagnostico)) { return 'Nenhum evento registrado ainda nesta máquina.' }
    $t = Get-Content -LiteralPath $script:arquivoLogDiagnostico -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($t)) { 'Nenhum evento registrado ainda nesta máquina.' } else { $t }
}

$script:XamlDiagnosticoGui = @'
<Window @@NS@@ Title="Terminal de Diagnóstico" Width="820" Height="560" MinWidth="600" MinHeight="380"
        WindowStartupLocation="CenterOwner" Background="@@Fundo@@" Foreground="@@Texto@@"
        FontFamily="Segoe UI" FontSize="13">
  <Grid Margin="18">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <StackPanel Grid.Row="0" Margin="0,0,0,10">
      <TextBlock FontSize="17" FontWeight="Bold" Text="Terminal de Diagnóstico"/>
      <TextBlock Foreground="@@Muted@@" FontSize="12" TextWrapping="Wrap" Text="Registro técnico local desta máquina (erros e eventos internos do WinHealth) - não é o relatório do cliente. Útil pra investigar algo que pareceu estranho."/>
    </StackPanel>
    <Border Grid.Row="1" Background="#05070A" BorderBrush="@@Borda@@" BorderThickness="1" CornerRadius="6">
      <ScrollViewer x:Name="RolagemLog" VerticalScrollBarVisibility="Auto" Padding="10">
        <TextBlock x:Name="TxtLog" FontFamily="Consolas" FontSize="11.5" Foreground="@@Ok@@" TextWrapping="Wrap"/>
      </ScrollViewer>
    </Border>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
      <Button x:Name="BtnExportar" Content="Exportar log (.txt)" Background="@@Acento@@" Foreground="@@Fundo@@" FontWeight="SemiBold" Padding="16,8" BorderThickness="0" Margin="0,0,8,0" Cursor="Hand"/>
      <Button x:Name="BtnFechar" Content="Fechar" Background="Transparent" Foreground="@@Texto@@" BorderBrush="@@Borda@@" BorderThickness="1" Padding="16,8" Cursor="Hand"/>
    </StackPanel>
  </Grid>
</Window>
'@

# Guarda a janela/controles em $script: (mesmo motivo de $script:GuiNav/$script:GuiDiag etc, ver
# comentario "IMPORTANTE sobre handlers de evento" acima de Iniciar-TarefaGui): os Add_Click abaixo
# so disparam DEPOIS que esta funcao ja retornou, entao nao podem depender de $w/variaveis locais.
function Novo-JanelaDiagnosticoGui {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $w = ConvertTo-XamlGui $script:XamlDiagnosticoGui
    $script:GuiDiagnostico = [pscustomobject]@{ Janela = $w; Log = $w.FindName('TxtLog'); Rolagem = $w.FindName('RolagemLog') }
    $script:GuiDiagnostico.Log.Text = Obter-ConteudoLogDiagnostico
    $w.Add_ContentRendered({ $script:GuiDiagnostico.Rolagem.ScrollToBottom() })
    $w.FindName('BtnFechar').Add_Click({ $script:GuiDiagnostico.Janela.Close() })
    $w.FindName('BtnExportar').Add_Click({
        try {
            if (-not (Test-Path $script:arquivoLogDiagnostico)) { throw 'Ainda não há nenhum evento registrado pra exportar.' }
            $destino = Join-Path $pastaRelatorios "winhealth_diagnostico_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').txt"
            Copy-Item -LiteralPath $script:arquivoLogDiagnostico -Destination $destino -Force -ErrorAction Stop
            [void][System.Windows.MessageBox]::Show("Log exportado com sucesso para:`n$destino", 'WinHealth')
        } catch { [void][System.Windows.MessageBox]::Show("Não foi possível exportar o log.`n$($_.Exception.Message)", 'WinHealth') }
    })
    $w
}

function Mostrar-TerminalDiagnosticoGui {
    $w = Novo-JanelaDiagnosticoGui
    try { $w.Owner = $script:GuiJanela } catch { }
    [void]$w.ShowDialog()
}

function Novo-JanelaGui {
    param([string]$EstadoAcesso = (Obter-EstadoAcesso $isAdmin $temContaAdmin))
    $ErrorActionPreference = 'Stop'
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $script:GuiEstado = $EstadoAcesso
    $script:GuiFilhos = New-Object System.Collections.ArrayList
    $w = ConvertTo-XamlGui $script:XamlJanela
    $script:GuiJanela = $w
    $script:GuiNav = $w.FindName('Nav')
    $script:GuiConteudo = $w.FindName('Conteudo')
    $script:GuiRolagem = $w.FindName('Rolagem')

    $w.FindName('TxtMaquina').Text = $nomeMaquina
    $w.FindName('TxtRodape').Text = $(if ($modoRede) { "Origem: rede ($PastaKit) - relatórios em $pastaRelatorios" } else { "Pasta do WinHealth: $PastaKit  |  Relatórios: $pastaRelatorios" })

    $chip = $w.FindName('ChipAcesso'); $txt = $w.FindName('TxtAcesso'); $btn = $w.FindName('BtnAdmin')
    switch ($EstadoAcesso) {
        'Admin'            { $txt.Text = 'Administrador'; $tom = 'Ok' }
        'LimitadoElevavel' { $txt.Text = 'Modo limitado'; $tom = 'Atencao'; $btn.Content = 'Reabrir como administrador'; $btn.Visibility = 'Visible' }
        default            { $txt.Text = 'Conta comum · modo limitado'; $tom = 'Atencao'; $btn.Content = 'Usar conta administradora'; $btn.Visibility = 'Visible' }
    }
    $chip.Background = Obter-BrushGui "$($tom)Fundo"
    $txt.Foreground = Obter-BrushGui $tom
    $btn.Add_Click({
        $script:GuiJanela.Hide()
        if (Reabrir-ComoAdmin) { $script:GuiJanela.Close() } else { $script:GuiJanela.Show() }
    })
    $w.FindName('BtnDiagnostico').Add_Click({ Mostrar-TerminalDiagnosticoGui })

    $abas = @(@{ Chave = 'painel'; Aba = 'Painel'; Icone = 'E80F' }) + @($script:Menu | ForEach-Object { @{ Chave = $_.Chave; Aba = $_.Aba; Icone = $_.Icone } })
    foreach ($a in $abas) {
        $li = New-Object System.Windows.Controls.ListBoxItem
        $li.Tag = $a.Chave
        $glifo = [string][char][Convert]::ToInt32($a.Icone, 16)
        $li.Content = ConvertTo-XamlGui "<StackPanel @@NS@@ Orientation=`"Horizontal`"><TextBlock FontFamily=`"$script:FonteIconesGui`" FontSize=`"16`" Text=`"$glifo`" Width=`"30`" VerticalAlignment=`"Center`"/><TextBlock Text=`"$(Esc-Gui $a.Aba)`" VerticalAlignment=`"Center`" TextTrimming=`"CharacterEllipsis`"/></StackPanel>"
        [void]$script:GuiNav.Items.Add($li)
    }
    $script:GuiNav.Add_SelectionChanged({ if ($script:GuiNav.SelectedItem) { Mostrar-AbaGui $script:GuiNav.SelectedItem.Tag } })
    $script:GuiNav.SelectedIndex = 0

    $w.Add_Closing({
        param($s, $e)
        if (@($script:GuiFilhos | Where-Object { -not $_.HasExited }).Count -gt 0) {
            [void][System.Windows.MessageBox]::Show("Ainda há um módulo aberto em outra janela.`nFeche-o antes de fechar o WinHealth.", 'WinHealth')
            $e.Cancel = $true
        }
    })
    $w
}

# Devolve os HWND que precisam ser escondidos/restaurados quando a janela WPF abre: o console
# "classico" (GetConsoleWindow, cobre o caso conhost.exe) E qualquer janela do Windows Terminal
# com o titulo "WinHealth (console)" (o launcher so usa esse titulo em modo -Gui - ver WinHealth.bat).
# Achado testando ao vivo: no Windows Terminal (padrao no Windows 11), esconder so o handle do
# GetConsoleWindow() NAO esconde nada visivel (o titulo "WinHealth" continuava aparecendo pro
# usuario) - a janela de verdade pertence ao processo WindowsTerminal.exe, um processo SEPARADO,
# e so esconder o handle DELE (via titulo, ja que nao tem relacao de processo pai/filho direta com
# o console) funciona de verdade. Mesmo padrao ja descoberto no bug do Scanner (Bug 1, 28/09/2026).
function Obter-JanelasConsoleGui {
    if (-not ('WinHealthConsole' -as [type])) {
        Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class WinHealthConsole { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n); }'
    }
    $handles = @()
    $console = [WinHealthConsole]::GetConsoleWindow()
    if ($console -ne [IntPtr]::Zero) { $handles += $console }
    $handles += @(Get-Process -Name 'WindowsTerminal' -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -eq 'WinHealth (console)' -and $_.MainWindowHandle -ne [IntPtr]::Zero } |
        ForEach-Object { $_.MainWindowHandle })
    $handles
}

function Mostrar-JanelaGui {
    try {
        if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { throw 'o PowerShell não está em modo STA (necessário para janelas)' }
        $w = Novo-JanelaGui
    } catch {
        Escrever-LogDiagnostico -Nivel 'ERRO' -Mensagem "Nao foi possivel abrir a janela: $($_.Exception.Message)"
        Write-Host "  Não foi possível abrir a janela ($($_.Exception.Message)). Seguindo no modo console." -ForegroundColor DarkYellow
        Start-Sleep -Seconds 2
        return $false
    }
    Escrever-LogDiagnostico -Nivel 'INFO' -Mensagem "WinHealth (janela) iniciado - maquina=$nomeMaquina admin=$isAdmin"
    # Captura qualquer excecao que escape de um handler (Add_Click/Add_Tick) sem derrubar a janela
    # inteira: sem isso, um erro assim so aparecia (as vezes) como o app fechando sozinho, sem pista
    # nenhuma do motivo - agora fica registrado no log de diagnostico. $e.Handled = $true evita o
    # crash (a janela continua de pe pro usuario tentar de novo em vez de perder tudo sem aviso).
    try {
        [Windows.Threading.Dispatcher]::CurrentDispatcher.add_UnhandledException({
            param($s, $e)
            Escrever-LogDiagnostico -Nivel 'ERRO' -Mensagem "Excecao nao tratada na GUI: $($e.Exception.GetType().Name): $($e.Exception.Message)`n$($e.Exception.StackTrace)"
            $e.Handled = $true
        })
    } catch { }
    $janelasConsole = @(Obter-JanelasConsoleGui)
    foreach ($h in $janelasConsole) { [void][WinHealthConsole]::ShowWindow($h, 0) }
    try { [void]$w.ShowDialog() }
    finally { foreach ($h in $janelasConsole) { [void][WinHealthConsole]::ShowWindow($h, 5) } }
    Escrever-LogDiagnostico -Nivel 'INFO' -Mensagem 'WinHealth (janela) encerrado'
    $true
}

if ($CarregarSomente) { return }

if ($Gui) { if (Mostrar-JanelaGui) { return } }

# ===================== LOOP PRINCIPAL =====================
Add-Content -Path $logfile -Value "===== WINHEALTH - $nomeMaquina - $(Get-Date) ====="
Escrever-LogDiagnostico -Nivel 'INFO' -Mensagem "WinHealth (console) iniciado - maquina=$nomeMaquina admin=$isAdmin"

if ($IniciarEm) {
    $inicial = $script:Menu | Where-Object { $_.Chave -eq $IniciarEm } | Select-Object -First 1
    if ($inicial) {
        $script:moduloAtual = $inicial.Chave
        try { & $inicial.Acao } catch { Escrever-LogDiagnostico -Nivel 'ERRO' -Mensagem "Modulo '$($inicial.Chave)' falhou: $($_.Exception.Message)" }
    }
    if ($SairAoFinal) { return }
}

do {
    if ($script:encerrar) { break }
    MostrarMenu
    $escolha = (Read-Host "  Escolha uma opção").Trim()
    $item = $script:Menu | Where-Object { $_.Chave -eq $escolha } | Select-Object -First 1
    if ($item) {
        $script:moduloAtual = $item.Chave
        try { & $item.Acao } catch { Escrever-LogDiagnostico -Nivel 'ERRO' -Mensagem "Modulo '$($item.Chave)' falhou: $($_.Exception.Message)" }
    } elseif ($escolha -match '^[Aa]$' -and -not $isAdmin) {
        if (Reabrir-ComoAdmin) { $script:encerrar = $true } else { Pausa }
    } elseif ($escolha -ne '0') {
        Write-Host ""
        Write-Host "  Opção inválida. Digite um número de 0 a $($script:Menu.Count)$(if (-not $isAdmin) { ' ou A' })." -ForegroundColor Red
        Start-Sleep -Seconds 2
    }
} while ($escolha -ne '0' -and -not $script:encerrar)

Write-Host ""
Write-Host "Até a próxima!" -ForegroundColor Cyan
Write-Host "Relatórios desta sessão: $pastaRelatorios" -ForegroundColor Gray
Write-Host ""
