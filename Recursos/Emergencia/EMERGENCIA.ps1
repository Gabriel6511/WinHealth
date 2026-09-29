# ========================================================================
#  MODO EMERGENCIA - motor de diagnostico/reparo offline (roda dentro do WinPE)
#  Nao precisa de nenhum clique: da boot pelo pendrive e ele faz tudo sozinho.
#  So etapas SEGURAS e REVERSIVEIS rodam sem perguntar nada. Nada que possa
#  destruir dados roda sem confirmacao.
# ========================================================================

$ErrorActionPreference = "SilentlyContinue"
$logLinhas = New-Object System.Collections.Generic.List[string]

function W {
    param($texto, $cor = "White")
    Write-Host $texto -ForegroundColor $cor
    $logLinhas.Add($texto)
}
function Secao($texto) {
    W ""
    W "==================================================================" "Cyan"
    W "  $texto" "Cyan"
    W "==================================================================" "Cyan"
}

Secao "MODO EMERGENCIA - iniciando diagnostico automatico"
W "Hora de inicio: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# ------------------------------------------------------------------------
# 1) Descobrir onde estamos: qual letra e o pendrive (onde salvar o
#    relatorio) e qual letra e o Windows instalado que vamos tentar salvar.
# ------------------------------------------------------------------------
Secao "Localizando pendrive e instalacao do Windows"

$pastaScript = $PSScriptRoot
if (-not $pastaScript) { $pastaScript = Split-Path -Parent $MyInvocation.MyCommand.Path }
$letraPendrive = (Get-Item $pastaScript).PSDrive.Name + ":"
W "Pendrive de emergencia detectado em: $letraPendrive"

$letraWindows = $null
foreach ($letra in @('C','D','E','F','G','H')) {
    $caminho = "$letra`:\Windows\System32\ntoskrnl.exe"
    if (Test-Path $caminho) {
        # confere que nao e o proprio WinPE (X: normalmente), e nao e o pendrive
        if ("$letra`:" -ne $letraPendrive) {
            $letraWindows = "$letra`:"
            break
        }
    }
}

if (-not $letraWindows) {
    W "NAO foi possivel localizar uma instalacao do Windows nesta maquina." "Red"
    W "Isso pode significar: disco com problema grave, particao criptografada" "Red"
    W "(BitLocker), ou a instalacao esta em outra letra nao testada." "Red"
    W ""
    W "Nada mais sera executado. Veja o relatorio salvo no pendrive." "Yellow"
} else {
    W "Windows instalado encontrado em: $letraWindows" "Green"
}

# pasta de relatorios no pendrive
$pastaRel = Join-Path $letraPendrive "Relatorios-Emergencia"
if (-not (Test-Path $pastaRel)) { New-Item -ItemType Directory -Path $pastaRel | Out-Null }
$carimbo = Get-Date -Format "yyyy-MM-dd_HHmm"
$pastaSessao = Join-Path $pastaRel $carimbo
New-Item -ItemType Directory -Path $pastaSessao | Out-Null

if ($letraWindows) {

# ------------------------------------------------------------------------
# 2) Copiar evidencias ANTES de mexer em qualquer coisa (minidumps, logs).
#    Isso nunca falha nem altera nada - roda sempre.
# ------------------------------------------------------------------------
Secao "Salvando evidencias (minidumps e logs de evento)"

$pastaDumps = Join-Path $pastaSessao "Minidumps"
$origemDumps = Join-Path $letraWindows "Windows\Minidump"
if (Test-Path $origemDumps) {
    $arquivosDump = Get-ChildItem $origemDumps -Filter *.dmp -ErrorAction SilentlyContinue
    if ($arquivosDump) {
        New-Item -ItemType Directory -Path $pastaDumps | Out-Null
        Copy-Item "$origemDumps\*.dmp" $pastaDumps -ErrorAction SilentlyContinue
        W "Copiados $($arquivosDump.Count) arquivo(s) de tela azul (minidump) para analise." "Green"
        W "Use o WinDbg ou o BlueScreenView (fora do pendrive) para ler o motivo exato." "White"
    } else {
        W "Pasta de minidump existe mas esta vazia (sem crash recente registrado)." "White"
    }
} else {
    W "Nenhuma pasta de minidump encontrada." "White"
}

$pastaLogs = Join-Path $pastaSessao "EventLogs"
New-Item -ItemType Directory -Path $pastaLogs | Out-Null
foreach ($logNome in @("System","Application")) {
    $origemEvtx = Join-Path $letraWindows "Windows\System32\winevt\Logs\$logNome.evtx"
    if (Test-Path $origemEvtx) {
        Copy-Item $origemEvtx $pastaLogs -ErrorAction SilentlyContinue
        $saidaTxt = Join-Path $pastaLogs "$logNome-ultimos-erros.txt"
        & wevtutil qe $origemEvtx /lf:true "/q:*[System[(Level=1 or Level=2)]]" /c:40 /f:text 2>$null | Out-File $saidaTxt -Encoding UTF8
        W "Log '$logNome' copiado + ultimos erros/criticos extraidos." "Green"
    }
}

# ------------------------------------------------------------------------
# 3) Saude do disco (so leitura, nunca altera nada) - roda sempre.
# ------------------------------------------------------------------------
Secao "Verificando saude do disco"
try {
    $discos = Get-PhysicalDisk -ErrorAction Stop
    foreach ($d in $discos) {
        $linha = "Disco: $($d.FriendlyName) | Status: $($d.HealthStatus) | Tipo: $($d.MediaType)"
        if ($d.HealthStatus -ne "Healthy") { W $linha "Red" } else { W $linha "Green" }
    }
} catch {
    W "Nao foi possivel ler o status SMART dos discos neste ambiente." "Yellow"
}

# ------------------------------------------------------------------------
# 4) REPARO DE BOOT - seguro e reversivel. bcdboot/bootrec so reescrevem
#    os arquivos de inicializacao, nunca tocam nos dados do usuario.
#    Roda automaticamente, sem perguntar, porque nao ha risco de perda de
#    dados - so ajuda a maquina a voltar a ligar.
# ------------------------------------------------------------------------
Secao "Reparando inicializacao (boot)"

W "Etapa 1/3: bootrec /fixmbr"
$out1 = & bootrec /fixmbr 2>&1 | Out-String
W $out1.Trim()

W "Etapa 2/3: bootrec /fixboot"
$out2 = & bootrec /fixboot 2>&1 | Out-String
W $out2.Trim()

W "Etapa 3/3: reconstruindo a BCD (bcdboot, mais confiavel que o bootrec /rebuildbcd)"
$destinoSistema = ($letraPendrive.TrimEnd(':') -eq 'X') # so por clareza, nao usado
$out3 = & bcdboot "$letraWindows\Windows" /s $($letraWindows.Substring(0,1)) /f ALL 2>&1 | Out-String
W $out3.Trim()

if ($out3 -match "êxito|sucesso|success" -or $out1 -match "êxito|sucesso|success") {
    W "Reparo de boot concluido. Se o problema era so o setor de boot, a" "Green"
    W "maquina deve iniciar normalmente no proximo reboot." "Green"
} else {
    W "Os comandos rodaram, mas nao deu para confirmar sucesso pela saida." "Yellow"
    W "Isso e normal em alguns casos - o relatorio completo tem o texto exato." "Yellow"
}

# ------------------------------------------------------------------------
# 5) SFC OFFLINE - so verifica e repara arquivos de sistema, usando os
#    proprios arquivos do Windows instalado como fonte quando possivel.
#    Seguro: nunca mexe em arquivos pessoais.
# ------------------------------------------------------------------------
Secao "Verificando arquivos de sistema (SFC offline)"
W "Isso pode demorar de 5 a 15 minutos. Aguarde..."
$outSfc = & sfc /scannow "/offbootdir=$($letraWindows.Substring(0,1)):\" "/offwindir=$letraWindows\Windows" 2>&1 | Out-String
W $outSfc.Trim()
if ($outSfc -match "não encontrou nenhuma violação|did not find any integrity violations") {
    W "Nenhum arquivo de sistema corrompido encontrado." "Green"
} elseif ($outSfc -match "reparou com êxito|successfully repaired") {
    W "Arquivos de sistema corrompidos foram encontrados e reparados." "Green"
} elseif ($outSfc -match "não foi possível reparar|was unable to fix") {
    W "Encontrou arquivos corrompidos mas NAO conseguiu reparar todos." "Red"
    W "Proximo passo manual: DISM /Image:$letraWindows /Cleanup-Image /RestoreHealth" "Yellow"
    W "usando como fonte a instalacao do Windows 11 (ISO) - precisa de internet" "Yellow"
    W "ou da pasta sources\install.wim de uma midia de instalacao." "Yellow"
} else {
    W "SFC rodou; verifique o texto completo acima/no relatorio para detalhes." "Yellow"
}

# ------------------------------------------------------------------------
# 6) CHKDSK - so leitura (/scan), NAO usa /f nem /r sozinho, porque essas
#    opcoes podem mexer na estrutura do disco. Isso fica como recomendacao
#    manual no relatorio, nunca automatico.
# ------------------------------------------------------------------------
Secao "Verificando integridade do disco (CHKDSK - somente leitura)"
$letraDiscoWin = $letraWindows.Substring(0,1)
$outChk = & chkdsk "$letraDiscoWin`:" /scan 2>&1 | Out-String
W $outChk.Trim()
if ($outChk -match "encontrou problemas|found problems|errors were found") {
    W "CHKDSK encontrou problemas na estrutura do disco." "Red"
    W "Reparo requer: chkdsk $letraDiscoWin`: /f /r  (demorado, NAO roda sozinho" "Yellow"
    W "aqui porque grava no disco - rode manualmente se necessario)." "Yellow"
} else {
    W "Nenhum problema estrutural encontrado no disco (varredura rapida)." "Green"
}

} # fim do bloco "if letraWindows encontrado"

# ------------------------------------------------------------------------
# 7) Salvar relatorio final no pendrive
# ------------------------------------------------------------------------
Secao "Finalizando"
$arquivoRelatorio = Join-Path $pastaSessao "relatorio_emergencia.txt"
$logLinhas | Out-File $arquivoRelatorio -Encoding UTF8
W "Relatorio completo salvo em:"
W "  $arquivoRelatorio" "Cyan"
W ""
W "O QUE FAZER AGORA:"
W "  1. Retire o pendrive"
W "  2. Reinicie a maquina normalmente (sem o pendrive)"
W "  3. Se ainda nao ligar, leia o relatorio acima - ele mostra exatamente"
W "     o que foi tentado e o que encontrou de errado."
W ""
W "Reiniciando automaticamente em 60 segundos. Pressione qualquer tecla" "Yellow"
W "para CANCELAR o reinicio automatico e continuar usando o WinPE." "Yellow"

$contagem = 60
$cancelado = $false
while ($contagem -gt 0) {
    Write-Host "`rReiniciando em $contagem s... (pressione uma tecla para cancelar)   " -NoNewline -ForegroundColor Yellow
    if ([Console]::KeyAvailable) {
        [Console]::ReadKey($true) | Out-Null
        $cancelado = $true
        break
    }
    Start-Sleep -Seconds 1
    $contagem--
}
Write-Host ""

if ($cancelado) {
    W "Reinicio cancelado pelo usuario. Voce esta no WinPE - pode abrir o" "Green"
    W "prompt de comando ou o gerenciador de arquivos do Hiren's para" "Green"
    W "investigar mais a fundo." "Green"
} else {
    W "Reiniciando..."
    wpeutil reboot
}
