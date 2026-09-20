# =============================================================================
#  Party Limit Begone (Baldur's Gate 3) - Instalador Automatico
#  Mod por Sildur: https://www.nexusmods.com/baldursgate3/mods/327
#
#  Este arquivo NAO deve ser executado sozinho pelo usuario final.
#  O install.bat (gerado por make-installer.ps1) embute este script + os zips
#  do mod. Para alterar algo: edite este arquivo e gere o .bat novo.
#
#  Entradas (variaveis de ambiente, definidas pelo install.bat / testes):
#    PLB_TARGET_DIR    - pasta do jogo (opcional; se vazio, detecta)
#    PLB_FILES_DIR     - pasta com os zips (modo desenvolvimento/teste)
#    PLB_NO_PAUSE      - 1 = nao pausar nem oferecer abrir o jogo (testes)
#    PLB_UNATTENDED    - 1 = nunca perguntar nada (testes)
#    PLB_ELEVATED      - 1 = execucao relancada como administrador
#    PLB_RESULT_FILE   - caminho p/ gravar resultado JSON (execucao elevada)
#    PLB_APPDATA_DIR   - sobrescreve a pasta de mods do AppData (testes)
# =============================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}

# ---------------------------------------------------------------- entradas --
$TargetGameDir   = $env:PLB_TARGET_DIR
$FilesDir        = $env:PLB_FILES_DIR
$AppDataOverride = $env:PLB_APPDATA_DIR
$NoPauseSwitch   = ($env:PLB_NO_PAUSE   -eq '1')
$Unattended      = ($env:PLB_UNATTENDED -eq '1')
$IsElevatedRun   = ($env:PLB_ELEVATED   -eq '1')
$ResultFile      = $env:PLB_RESULT_FILE

$Script:SelfPath = $env:PLB_SELF
if (-not $Script:SelfPath -or -not (Test-Path -LiteralPath $Script:SelfPath)) { $Script:SelfPath = $PSCommandPath }
# $PSCommandPath vem VAZIO quando o codigo roda via Invoke-Expression (install.bat):
# proteger o Split-Path contra string vazia.
if ($Script:SelfPath) { $Script:SelfDir = Split-Path -Parent $Script:SelfPath } else { $Script:SelfDir = $null }

# ---------------------------------------------------------- configuracao do mod --
$Script:PlbVersion      = 'Standalone v3.5 + Multiplayer Patch v1.6'
$Script:ModUrl          = 'https://www.nexusmods.com/baldursgate3/mods/327'
$Script:SteamAppId      = '1086940'
$Script:ExpectedPlayers = '16'
$Script:BackupDirName   = 'PLB-Installer-Backup'
$Script:GameExes        = @('bg3.exe', 'bg3_dx11.exe')

# UUIDs (ModuleInfo) de cada meta.lsx do PLB - "impressao digital" do mod.
# Usados para reconhecer arquivos do PLB com seguranca, sem tocar em mods de
# outras pessoas nem nos arquivos originais do jogo.
$Script:PlbUuids = @{
    'Gustav'     = '991c9c7a-fb80-40cb-8f0d-b92d4e80e9b1'
    'GustavDev'  = '28ac9ce2-2aba-8cda-b3b5-6e922f71b6b8'
    'GustavX'    = 'cb555efe-2d9e-131f-8195-a89329d218ea'
    'Honour'     = 'b77b6210-ac50-4cb1-a3d5-5702fb9c744c'
    'HonourX'    = '767d0062-d82c-279c-e16b-dfee7fe94cdd'
    'ModBrowser' = 'ee5a55ff-eb38-0b27-c5b0-f358dc306d34'
    'PhotoMode'  = '55ef175c-59e3-b44b-3fb2-8f86acc5d550'
    'Shared'     = 'ed539163-bb70-431b-96a7-f5b2eda5376b'
    'SharedDev'  = '3d0c5ff8-c95d-c907-ff3e-34b204f1c630'
}

# ------------------------------------------------------------- estado global --
$Script:Latin1         = [System.Text.Encoding]::GetEncoding(28591)
$Script:Actions        = New-Object System.Collections.Generic.List[string]
$Script:Warnings       = New-Object System.Collections.Generic.List[string]
$Script:InstalledFiles = New-Object System.Collections.Generic.List[string]
$Script:Backups        = New-Object System.Collections.Generic.List[object]
$Script:Quarantined    = New-Object System.Collections.Generic.List[object]
$Script:ConsoleLines   = New-Object System.Collections.Generic.List[string]
$Script:LogBuffer      = New-Object System.Collections.Generic.List[string]
$Script:LogPath        = $null
$Script:QuarantineRoot = $null
$Script:SteamPath      = $null
$Script:LastGameDir    = $null
$Script:Patterns       = @()   # pares de strings Latin-1: @(buscar, trocar)
$Script:ZipStandalone  = $null # hashtable @{ Zip; Stream; Label; Size }
$Script:ZipPatch       = $null

# ------------------------------------------------------------------ logging --
function Add-Log([string]$msg) {
    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg)
    $Script:LogBuffer.Add($line)
    if ($Script:LogPath) {
        try { [System.IO.File]::AppendAllText($Script:LogPath, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false))) } catch {}
    }
}

function Out-Line([string]$text, $color = 'Gray') {
    $Script:ConsoleLines.Add($text)
    Write-Host $text -ForegroundColor $color
}

function Write-Step([string]$msg) {
    Out-Line '' 'Gray'
    Out-Line ("==> " + $msg) 'Cyan'
    Add-Log ("ETAPA: " + $msg)
}

function Write-Ok([string]$msg) {
    Out-Line ("    [OK] " + $msg) 'Green'
    Add-Log ("OK: " + $msg)
}

function Write-Warn2([string]$msg) {
    Out-Line ("    [!!] " + $msg) 'Yellow'
    Add-Log ("AVISO: " + $msg)
    $Script:Warnings.Add($msg)
}

function Write-Fail([string]$msg) {
    Out-Line ("    [X]  " + $msg) 'Red'
    Add-Log ("ERRO: " + $msg)
}

function Fatal([string]$msg) {
    Write-Fail $msg
    throw $msg
}

# ---------------------------------------------------------------- utilidades --
function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object System.Security.Principal.WindowsPrincipal($id)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-CanWrite([string]$dir) {
    try {
        $t = Join-Path $dir ('.__plb_write_test_' + [System.Guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($t, 'x')
        Remove-Item -LiteralPath $t -Force
        return $true
    } catch { return $false }
}

function Get-FileSha256([string]$path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}

function Count-Occurrences([string]$haystack, [string]$needle) {
    if (-not $needle) { return 0 }
    $c = 0; $i = 0
    while (($i = $haystack.IndexOf($needle, $i, [System.StringComparison]::Ordinal)) -ge 0) { $c++; $i += $needle.Length }
    return $c
}

function Disable-QuickEdit {
    # Impede que um clique acidental no console congele a instalacao.
    try {
        if (-not ('PlbNative.Kernel32' -as [type])) {
            Add-Type -Namespace PlbNative -Name Kernel32 -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int h);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out int mode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, int mode);
'@
        }
        $h = [PlbNative.Kernel32]::GetStdHandle(-10)
        $mode = 0
        if ([PlbNative.Kernel32]::GetConsoleMode($h, [ref]$mode)) {
            [void][PlbNative.Kernel32]::SetConsoleMode($h, ($mode -band (-bnot 0x0040)))
        }
    } catch {}
}

# --------------------------------------------------------------- payloads/zip --
function ConvertFrom-Base64ToZip([string]$b64, [string]$label) {
    try { $bytes = [System.Convert]::FromBase64String($b64) } catch {
        Fatal ("Os dados embutidos do {0} estao corrompidos. Baixe o install.bat novamente (o arquivo deve ter cerca de 1,7 MB)." -f $label)
    }
    $ms  = New-Object System.IO.MemoryStream(, $bytes)
    $zip = New-Object System.IO.Compression.ZipArchive($ms, [System.IO.Compression.ZipArchiveMode]::Read)
    return @{ Zip = $zip; Stream = $ms; Label = $label; Size = $bytes.Length }
}

function Get-EntryBytes($zip, [string]$entryName) {
    $e = $zip.GetEntry($entryName)
    if (-not $e) { return $null }
    $s  = $e.Open()
    $ms = New-Object System.IO.MemoryStream
    $s.CopyTo($ms)
    $s.Dispose()
    return $ms.ToArray()
}

function Initialize-ModPackages {
    try {
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
    } catch {}

    $hasEmbedded = $false
    try { if ($ZipStandaloneB64 -and $ZipPatchB64) { $hasEmbedded = $true } } catch { $hasEmbedded = $false }
    # (sem qualificador de escopo de proposito: via Invoke-Expression o payload
    #  vive no escopo global e a resolucao dinamica o encontra normalmente)

    if ($hasEmbedded) {
        $Script:UsingEmbedded = $true
        Write-Step 'Carregando os arquivos do mod (embutidos no instalador)'
        $Script:ZipStandalone = ConvertFrom-Base64ToZip $ZipStandaloneB64 'Standalone'
        $Script:ZipPatch      = ConvertFrom-Base64ToZip $ZipPatchB64 'Multiplayer Patch'
        Write-Ok ("Standalone e Multiplayer Patch carregados ({0:N0} + {1:N0} bytes)" -f $Script:ZipStandalone.Size, $Script:ZipPatch.Size)
        return
    }

    # Modo desenvolvimento/teste: le os zips de uma pasta.
    $dir = $FilesDir
    if (-not $dir) { $dir = Join-Path $Script:SelfDir 'files' }
    Write-Step ('Carregando os arquivos do mod de: ' + $dir)
    if (-not (Test-Path -LiteralPath $dir)) { Fatal ('Pasta de arquivos do mod nao encontrada: ' + $dir) }
    $zips = @(Get-ChildItem -LiteralPath $dir -Filter '*.zip' -File -ErrorAction SilentlyContinue)
    $standalone = $zips | Where-Object { $_.Name -match '(?i)standalone' } | Select-Object -First 1
    $patch      = $zips | Where-Object { $_.Name -match '(?i)multiplayer' } | Select-Object -First 1
    if (-not $standalone) { Fatal 'Zip do Standalone nao encontrado (arquivo com "Standalone" no nome).' }
    if (-not $patch)      { Fatal 'Zip do Multiplayer Patch nao encontrado (arquivo com "Multiplayer" no nome).' }
    $fs = [System.IO.File]::OpenRead($standalone.FullName)
    $Script:ZipStandalone = @{ Zip = (New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)); Stream = $fs; Label = 'Standalone'; Size = $standalone.Length }
    $fp = [System.IO.File]::OpenRead($patch.FullName)
    $Script:ZipPatch = @{ Zip = (New-Object System.IO.Compression.ZipArchive($fp, [System.IO.Compression.ZipArchiveMode]::Read)); Stream = $fp; Label = 'Multiplayer Patch'; Size = $patch.Length }
    Write-Ok 'Standalone e Multiplayer Patch carregados'
}

# ---------------------------------------------------- padroes do patch (.xsc) --
function Convert-HexToLatin1([string]$hex) {
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $hex.Length; $i += 2) {
        [void]$sb.Append([char][System.Convert]::ToByte($hex.Substring($i, 2), 16))
    }
    return $sb.ToString()
}

function Initialize-PatchPatterns {
    $zip   = $Script:ZipPatch.Zip
    $entry = @($zip.Entries | Where-Object { ($_.FullName -replace '\\', '/') -match '(?i)^patchfiles/.*\.xsc$' })[0]
    if (-not $entry) { Fatal 'Script de patch (.xsc) nao encontrado dentro do zip do Multiplayer Patch.' }
    $sr = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
    $text = $sr.ReadToEnd()
    $sr.Dispose()

    $pairs = @()
    foreach ($raw in ($text -split "\r?\n")) {
        $line = $raw.Trim()
        if ($line -notmatch '(?i)^REPLACEALL\s+(.+)$') { continue }
        $body = $Matches[1]
        $idx = $body.IndexOf(' BY ')
        if ($idx -lt 0) { Write-Warn2 ("Linha ignorada no .xsc (sem ' BY '): " + $line); continue }
        $searchHex  = ($body.Substring(0, $idx)  -replace '\s', '')
        $replaceHex = ($body.Substring($idx + 4) -replace '\s', '')
        if ($searchHex  -notmatch '^[0-9A-Fa-f]+$' -or ($searchHex.Length  % 2) -ne 0) { Write-Warn2 ('Padrao de busca invalido no .xsc: ' + $searchHex);  continue }
        if ($replaceHex -notmatch '^[0-9A-Fa-f]+$' -or ($replaceHex.Length % 2) -ne 0) { Write-Warn2 ('Padrao de troca invalido no .xsc: ' + $replaceHex); continue }
        if ($searchHex.Length -ne $replaceHex.Length) { Write-Warn2 'Padroes de tamanhos diferentes no .xsc (ignorado).'; continue }
        $pairs += , @( (Convert-HexToLatin1 $searchHex.ToUpper()), (Convert-HexToLatin1 $replaceHex.ToUpper()) )
    }
    if ($pairs.Count -eq 0) { Fatal 'Nenhum padrao valido encontrado no .xsc do Multiplayer Patch.' }
    $Script:Patterns = $pairs
    Write-Ok ("{0} padroes de patch carregados do script do mod" -f $pairs.Count)
}

# --------------------------------------------------------- deteccao do jogo --
function Test-GameDir([string]$p) {
    if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Container)) { return $false }
    $hasData = Test-Path -LiteralPath (Join-Path $p 'Data') -PathType Container
    $hasExe  = $false
    foreach ($exe in $Script:GameExes) { if (Test-Path -LiteralPath (Join-Path $p ('bin\' + $exe))) { $hasExe = $true } }
    return ($hasData -and $hasExe)
}

function Get-SteamInfo {
    $steam = $null
    try { $steam = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue).InstallPath } catch {}
    if (-not $steam) { try { $steam = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath } catch {} }
    if ($steam) { $Script:SteamPath = $steam }
    $libs = New-Object System.Collections.Generic.List[string]
    if ($steam -and (Test-Path -LiteralPath (Join-Path $steam 'steamapps\libraryfolders.vdf'))) {
        try {
            $vdf = [System.IO.File]::ReadAllText((Join-Path $steam 'steamapps\libraryfolders.vdf'))
            foreach ($m in [regex]::Matches($vdf, '"path"\s+"([^"]+)"')) {
                $libs.Add(($m.Groups[1].Value -replace '\\\\', '\'))
            }
        } catch {}
    }
    if ($steam) { $libs.Add($steam) }
    return $libs
}

function Get-CandidateGameDirs {
    $cands    = New-Object System.Collections.Generic.List[string]
    $gameName = 'Baldurs Gate 3'

    foreach ($lib in (Get-SteamInfo)) { $cands.Add((Join-Path $lib ('steamapps\common\' + $gameName))) }

    foreach ($root in @('HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games', 'HKLM:\SOFTWARE\GOG.com\Games')) {
        try {
            $k = Get-ChildItem -Path $root -ErrorAction SilentlyContinue
            foreach ($sub in $k) {
                $p = (Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction SilentlyContinue).path
                if ($p) { $cands.Add($p) }
            }
        } catch {}
    }

    try {
        $mroot = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
        if (Test-Path -LiteralPath $mroot) {
            foreach ($f in @(Get-ChildItem -LiteralPath $mroot -Filter '*.item' -File -ErrorAction SilentlyContinue)) {
                try {
                    $j = [System.IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
                    if ($j.InstallLocation) { $cands.Add($j.InstallLocation) }
                } catch {}
            }
        }
    } catch {}

    $drives = @()
    try { $drives = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } | ForEach-Object { $_.Name.TrimEnd('\') }) } catch {}
    $patterns = @(
        ('{0}\SteamLibrary\steamapps\common\' + $gameName),
        ('{0}\Steam\steamapps\common\' + $gameName),
        ('{0}\Program Files (x86)\Steam\steamapps\common\' + $gameName),
        ('{0}\Games\' + $gameName),
        ('{0}\GOG Games\' + $gameName),
        ('{0}\' + $gameName)
    )
    foreach ($d in $drives) { foreach ($pat in $patterns) { $cands.Add(($pat -f $d)) } }

    return @($cands | Where-Object { $_ } | Select-Object -Unique)
}

function Find-GameDirByScan {
    Out-Line '    Procurando a pasta do jogo nos discos... (pode demorar 1-2 minutos)' 'Gray'
    $found  = $null
    $drives = @()
    try { $drives = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } | ForEach-Object { $_.RootDirectory.Name }) } catch {}
    $di = 0
    foreach ($root in $drives) {
        $di++
        Write-Progress -Activity "Procurando Baldur's Gate 3" -Status ('Drive ' + $root) -PercentComplete ((100 * ($di - 1)) / [Math]::Max($drives.Count, 1))
        try {
            $hits = @(Get-ChildItem -Path $root -Directory -Filter 'Baldurs*' -Recurse -Depth 5 -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq 'Baldurs Gate 3' })
            foreach ($h in $hits) { if (Test-GameDir $h.FullName) { $found = $h.FullName; break } }
        } catch {}
        if ($found) { break }
    }
    Write-Progress -Activity "Procurando Baldur's Gate 3" -Completed
    return $found
}

function Resolve-GameDir {
    if ($TargetGameDir) {
        $p = [System.Environment]::ExpandEnvironmentVariables($TargetGameDir.Trim().Trim('"'))
        if (Test-GameDir $p) { return $p }
        Fatal ("A pasta indicada nao parece ser a pasta do Baldur's Gate 3 (precisa ter 'Data' e 'bin\bg3.exe'): " + $p)
    }

    Write-Step "Procurando a pasta de instalacao do Baldur's Gate 3"

    # Seam de teste: PLB_DISABLE_AUTODETECT=1 simula "jogo nao encontrado"
    # sem escanear discos nem tocar no registro (usado pela bateria de testes).
    $autodetectDisabled = ($env:PLB_DISABLE_AUTODETECT -eq '1')

    if (-not $autodetectDisabled) {
        foreach ($c in (Get-CandidateGameDirs)) {
            if (Test-GameDir $c) { Write-Ok ('Jogo encontrado: ' + $c); return $c }
        }

        Out-Line '    Nao achei nos lugares comuns. Procurando nos discos...' 'Yellow'
        $scanned = Find-GameDirByScan
        if ($scanned) { Write-Ok ('Jogo encontrado: ' + $scanned); return $scanned }
    }

    if ($Unattended) { Fatal "Nao encontrei a pasta do Baldur's Gate 3 em nenhum lugar." }

    Out-Line '' 'Gray'
    Out-Line '    Nao consegui encontrar a pasta do jogo sozinho.' 'Yellow'
    while ($true) {
        $ans = Read-Host '    Cole o caminho da pasta do jogo (ex.: C:\Program Files (x86)\Steam\steamapps\common\Baldurs Gate 3) ou digite SAIR'
        if ($ans -match '(?i)^\s*(sair|cancelar)\s*$') { Fatal 'Instalacao cancelada pelo usuario.' }
        $p = [System.Environment]::ExpandEnvironmentVariables($ans.Trim().Trim('"'))
        if (Test-GameDir $p) { Write-Ok ('Pasta do jogo: ' + $p); return $p }
        Out-Line '    Essa pasta nao parece certa (precisa conter "Data" e "bin\bg3.exe"). Tente de novo.' 'Yellow'
    }
}

# ---------------------------------------------------------------- permissoes --
function Invoke-ElevatedRerun([string]$gameDir) {
    Out-Line '' 'Gray'
    Out-Line '    A pasta do jogo exige permissoes de administrador.' 'Yellow'
    Out-Line '    Vai aparecer uma janela do Windows pedindo permissao -> clique em "SIM".' 'Yellow'

    $resultFile = Join-Path $env:TEMP ('plb_result_' + [System.Guid]::NewGuid().ToString('N') + '.json')
    $env:PLB_ELEVATED    = '1'
    $env:PLB_NO_PAUSE    = '1'
    $env:PLB_RESULT_FILE = $resultFile
    $env:PLB_TARGET_DIR  = $gameDir

    try {
        Start-Process -FilePath $Script:SelfPath -Verb RunAs -Wait
    } catch {
        Fatal 'Voce cancelou a janela de permissao (UAC) ou ela foi bloqueada. Sem permissao de administrador nao da para instalar. Rode de novo e clique em "SIM".'
    }

    $code = 1
    if (Test-Path -LiteralPath $resultFile) {
        try {
            $r = [System.IO.File]::ReadAllText($resultFile) | ConvertFrom-Json
            foreach ($l in @($r.report)) { Out-Line ([string]$l) 'Gray' }
            $code = [int]$r.exitCode
        } catch {
            Out-Line '    A execucao como administrador terminou, mas nao consegui ler o resultado.' 'Yellow'
        }
        try { Remove-Item -LiteralPath $resultFile -Force } catch {}
    } else {
        Out-Line '    A execucao como administrador nao chegou a gravar um resultado.' 'Yellow'
    }
    if ($code -eq 0) {
        Out-Line '    [OK] Instalacao concluida com sucesso (como administrador).' 'Green'
        Start-Game $gameDir
    }
    exit $code
}

# ---------------------------------------------------------------- quarentena --
function Initialize-BackupDirs([string]$gameDir) {
    $root = Join-Path $gameDir $Script:BackupDirName
    $Script:QuarantineRoot = Join-Path $root ('quarentena\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    foreach ($d in @($root, $Script:QuarantineRoot)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    $Script:LogPath = Join-Path $root 'instalador.log'
    foreach ($l in $Script:LogBuffer) {
        try { [System.IO.File]::AppendAllText($Script:LogPath, $l + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false))) } catch {}
    }
    $Script:LogBuffer.Clear()
}

function Move-ToQuarantine([string]$path, [string]$reason) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $name = Split-Path -Leaf $path
    $dest = Join-Path $Script:QuarantineRoot $name
    $i = 1
    while (Test-Path -LiteralPath $dest) { $i++; $dest = Join-Path $Script:QuarantineRoot (($i.ToString()) + '_' + $name) }
    Move-Item -LiteralPath $path -Destination $dest -Force
    Write-Ok ("Movido para quarentena (motivo: {0}): {1}" -f $reason, $name)
    $Script:Quarantined.Add([pscustomobject]@{ de = $path; para = $dest; motivo = $reason })
}

function Test-IsPlbMeta([string]$metaPath) {
    try {
        $txt = [System.IO.File]::ReadAllText($metaPath)
        foreach ($uuid in $Script:PlbUuids.Values) { if ($txt -match [regex]::Escape($uuid)) { return $true } }
    } catch {}
    return $false
}

function Invoke-JunkScan([string]$gameDir) {
    Write-Step 'Verificando restos de instalacoes/tentativas anteriores'
    $dataMods = Join-Path $gameDir 'Data\Mods'

    # (a) .pak do PLB soltos na raiz de Data\Mods (erro comum: extrair o pak em vez da pasta)
    if (Test-Path -LiteralPath $dataMods) {
        foreach ($f in @(Get-ChildItem -LiteralPath $dataMods -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -match '(?i)(plb|party.?limit|limit.?begone)') { Move-ToQuarantine $f.FullName 'pak do PLB no lugar errado (raiz de Data\Mods)' }
        }
    }

    # (b) pasta "Mods" aninhada dentro de Data\Mods (erro: copiar a pasta do zip para DENTRO de Data\Mods)
    $nested = Join-Path $dataMods 'Mods'
    if (Test-Path -LiteralPath $nested) {
        $hasPlb = $false
        foreach ($m in @(Get-ChildItem -LiteralPath $nested -Filter 'meta.lsx' -Recurse -ErrorAction SilentlyContinue)) {
            if (Test-IsPlbMeta $m.FullName) { $hasPlb = $true; break }
        }
        if ($hasPlb) {
            Move-ToQuarantine $nested 'pasta Mods aninhada (o zip foi copiado para dentro de Data\Mods)'
        } else {
            Write-Warn2 'Existe uma pasta Data\Mods\Mods que NAO contem arquivos do PLB; nao mexi nela (verifique se e um mod de outra pessoa).'
        }
    }

    # (c) arquivos estranhos dentro das pastas oficiais do PLB
    foreach ($folder in $Script:PlbUuids.Keys) {
        $d = Join-Path $dataMods $folder
        if (Test-Path -LiteralPath $d) {
            foreach ($f in @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue)) {
                if ($f.Name -ieq 'meta.lsx') { continue }
                if ($f.Name -match '(?i)(plb|party.?limit|limit.?begone)') { Move-ToQuarantine $f.FullName 'arquivo antigo/desconhecido dentro da pasta do PLB' }
            }
        }
    }

    # (d) ferramentas do patch manual (XVI32 etc.) extraidas na pasta bin ou na raiz
    foreach ($base in @((Join-Path $gameDir 'bin'), $gameDir)) {
        if (-not (Test-Path -LiteralPath $base)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $base -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -ieq 'XVI32.exe' -or $f.Name -ieq 'PLB-MP-Patch.xsc' -or $f.Name -ieq 'PartyLimitBegonePatcher.bat') {
                Move-ToQuarantine $f.FullName 'ferramenta do patch manual fora do lugar'
            }
        }
    }
    foreach ($pf in @((Join-Path $gameDir 'PatchFiles'), (Join-Path $gameDir 'bin\PatchFiles'))) {
        if (Test-Path -LiteralPath $pf) {
            $hasTool = @(Get-ChildItem -LiteralPath $pf -Filter '*.exe' -File -ErrorAction SilentlyContinue).Count -gt 0
            if ($hasTool) { Move-ToQuarantine $pf 'pasta PatchFiles extraida dentro da pasta do jogo' }
        }
    }

    # (e) .pak do PLB na pasta de mods do gerenciador (AppData)
    $appMods = $AppDataOverride
    if (-not $appMods) { $appMods = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Mods" }
    if (Test-Path -LiteralPath $appMods) {
        foreach ($f in @(Get-ChildItem -LiteralPath $appMods -Filter '*.pak' -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -match '(?i)(plb|party.?limit|limit.?begone)') { Move-ToQuarantine $f.FullName 'pak do PLB na pasta de mods do gerenciador (AppData)' }
        }
    }

    # (f) Readme.txt do zip do mod extraido na pasta errada
    foreach ($rd in @((Join-Path $gameDir 'Data\Readme.txt'), (Join-Path $gameDir 'Readme.txt'))) {
        if (Test-Path -LiteralPath $rd) {
            try {
                if ([System.IO.File]::ReadAllText($rd) -match 'Party Limit Begone') { Move-ToQuarantine $rd 'Readme do zip do mod extraido na pasta do jogo' }
            } catch {}
        }
    }

    if ($Script:Quarantined.Count -eq 0) { Write-Ok 'Nenhum resto de instalacao anterior encontrado' }
}

# ----------------------------------------------------------------- standalone --
function Install-Standalone([string]$gameDir) {
    Write-Step 'Instalando o Party Limit Begone (Standalone v3.5)'
    $modsTarget = Join-Path $gameDir 'Data\Mods'
    $zip = $Script:ZipStandalone.Zip
    $metas = @($zip.Entries | Where-Object { ($_.FullName -replace '\\', '/') -match '^Mods/[^/]+/meta\.lsx$' })
    if ($metas.Count -eq 0) { Fatal 'Zip do Standalone nao contem os arquivos esperados (Mods/*/meta.lsx).' }

    $novos = 0; $atualizados = 0; $jaCorretos = 0
    foreach ($e in $metas) {
        $folder     = (((($e.FullName -replace '\\', '/')) -split '/')[1])
        $targetDir  = Join-Path $modsTarget $folder
        $targetFile = Join-Path $targetDir 'meta.lsx'
        if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
        $newBytes = Get-EntryBytes $zip $e.FullName
        if ($null -eq $newBytes -or $newBytes.Length -eq 0) { Write-Warn2 ('Entrada vazia no zip: ' + $e.FullName); continue }

        if (Test-Path -LiteralPath $targetFile) {
            $oldBytes = [System.IO.File]::ReadAllBytes($targetFile)
            $same = ($oldBytes.Length -eq $newBytes.Length)
            if ($same) {
                for ($i = 0; $i -lt $oldBytes.Length; $i++) { if ($oldBytes[$i] -ne $newBytes[$i]) { $same = $false; break } }
            }
            if ($same) { $jaCorretos++; continue }
            Move-ToQuarantine $targetFile 'meta.lsx antigo do PLB (conteudo diferente) - substituido'
            $atualizados++
        } else {
            $novos++
        }
        [System.IO.File]::WriteAllBytes($targetFile, $newBytes)
        $Script:InstalledFiles.Add($targetFile)
    }

    $Script:Actions.Add(("Standalone: {0} meta.lsx novos, {1} atualizados, {2} ja estavam corretos" -f $novos, $atualizados, $jaCorretos))
    Write-Ok ("Standalone instalado em Data\Mods ({0} novos, {1} atualizados, {2} ja corretos)" -f $novos, $atualizados, $jaCorretos)

    # verificacao do conteudo (UUID e NumPlayers de todas as pastas)
    foreach ($folder in $Script:PlbUuids.Keys) {
        $metaPath = Join-Path $modsTarget ($folder + '\meta.lsx')
        if (-not (Test-Path -LiteralPath $metaPath)) { Fatal ('Apos a instalacao, falta o arquivo: ' + $metaPath) }
        $txt = [System.IO.File]::ReadAllText($metaPath)
        if ($txt -notmatch [regex]::Escape($Script:PlbUuids[$folder])) { Fatal ('Verificacao falhou: UUID inesperado em ' + $metaPath) }
        if ($txt -notmatch ('NumPlayers" type="uint8" value="' + $Script:ExpectedPlayers + '"')) { Fatal ('Verificacao falhou: NumPlayers nao e ' + $Script:ExpectedPlayers + ' em ' + $metaPath) }
    }
    Write-Ok ('Verificado: limite de membros do grupo = ' + $Script:ExpectedPlayers + ' (9 pastas conferidas)')
}

# --------------------------------------------------------- patch multiplayer --
function Get-ExeState([string]$exePath) {
    $bytes = [System.IO.File]::ReadAllBytes($exePath)
    $s = $Script:Latin1.GetString($bytes)
    $orig = 0; $patched = 0
    foreach ($p in $Script:Patterns) {
        $orig    += Count-Occurrences $s $p[0]
        $patched += Count-Occurrences $s $p[1]
    }
    $state = 'UNKNOWN'
    $n = $Script:Patterns.Count
    if     ($patched -ge $n -and $orig -eq 0)    { $state = 'PATCHED' }
    elseif ($orig    -ge $n -and $patched -eq 0) { $state = 'ORIGINAL' }
    elseif ($orig -gt 0 -or $patched -gt 0)      { $state = 'PARTIAL' }
    return [pscustomobject]@{ Path = $exePath; Size = $bytes.Length; Text = $s; Orig = $orig; Patched = $patched; State = $state }
}

function Invoke-ExePatch([string]$exePath) {
    $name       = Split-Path -Leaf $exePath
    $backupPath = $exePath + '.backup'

    if (-not (Test-Path -LiteralPath $exePath)) {
        Write-Warn2 ($name + ' nao existe nesta instalacao (normal se o jogo tiver apenas um modo grafico).')
        return 'MISSING'
    }

    $state = Get-ExeState $exePath

    if ($state.State -eq 'PATCHED') {
        Write-Ok ($name + ': patch multiplayer JA estava aplicado - nada a fazer')
        $Script:Actions.Add($name + ' ja estava patcheado (verificado).')
        if (Test-Path -LiteralPath $backupPath) {
            $Script:Backups.Add([pscustomobject]@{ exe = $exePath; backup = $backupPath; sha256Original = (Get-FileSha256 $backupPath) })
        } else {
            Write-Warn2 ($name + ': nao existe backup do exe original. Para reverter no futuro, use "Verificar integridade dos arquivos" no Steam.')
        }
        return 'PATCHED'
    }

    if ($state.State -eq 'UNKNOWN') {
        # Nenhum padrao do mod existe nesse exe: jogo atualizou ou exe diferente.
        # Se temos um backup limpo, restauramos; senao, abortamos sem escrever nada.
        $backupState = $null
        if (Test-Path -LiteralPath $backupPath) { $backupState = Get-ExeState $backupPath }
        if ($backupState -and $backupState.State -eq 'ORIGINAL') {
            Write-Warn2 ($name + ': conteudo desconhecido (jogo atualizado ou modificado). Restaurando o backup limpo e aplicando o patch sobre ele.')
            Copy-Item -LiteralPath $backupPath -Destination $exePath -Force
            $state = Get-ExeState $exePath
        } else {
            Write-Fail ($name + ': nenhum padrao conhecido encontrado - o jogo provavelmente foi ATUALIZADO e o mod ainda nao tem patch para essa versao.')
            Write-Warn2 'Nada foi modificado neste arquivo. Gere um install.bat novo quando o mod for atualizado no Nexus, ou verifique a integridade do jogo no Steam.'
            $Script:Actions.Add($name + ' NAO patcheado: versao do exe desconhecida (nenhum padrao encontrado).')
            return 'FAILED'
        }
    }

    if ($state.State -eq 'PARTIAL') {
        Write-Warn2 ($name + ': patch parcial detectado (tentativa anterior incompleta). Concluindo o patch agora.')
        # Tentativa manual anterior: pode ter deixado um backup ERRADO (feito a
        # partir de um exe ja parcialmente patcheado). Garantimos um backup do
        # estado verdadeiramente original: se um padrao ORIGINAL nao aparece no
        # backup, ele nao serve - substituimos pelo exe atual (que ainda tem
        # mais padroes originais que o backup antigo).
        $needBackup = $true
        if (Test-Path -LiteralPath $backupPath) {
            $bakState = Get-ExeState $backupPath
            if ($bakState.Orig -lt $state.Orig) {
                Write-Warn2 ($name + ': backup antigo estava PATCHeado (veneno). Substituindo pelo exe atual (estado mais original).')
            } else {
                $needBackup = $false
                Write-Ok ($name + ': backup existente e valido (estado original preservado)')
            }
        }
        if ($needBackup) {
            Copy-Item -LiteralPath $exePath -Destination $backupPath -Force
            Write-Ok ($name + ': backup criado (' + (Split-Path -Leaf $backupPath) + ')')
        }
    }

    # backup (estados ORIGINAL e PARTIAL continuam aqui): deve sempre refletir
    # o estado ORIGINAL, nunca um estado patcheado
    $needBackup = $true
    if (Test-Path -LiteralPath $backupPath) {
        $bakState = Get-ExeState $backupPath
        if ($bakState.State -eq 'ORIGINAL') {
            $needBackup = $false
            Write-Ok ($name + ': backup existente e valido (estado original preservado)')
        }
    }
    if ($needBackup) {
        Copy-Item -LiteralPath $exePath -Destination $backupPath -Force
        Write-Ok ($name + ': backup criado (' + (Split-Path -Leaf $backupPath) + ')')
    }
    $Script:Backups.Add([pscustomobject]@{ exe = $exePath; backup = $backupPath; sha256Original = (Get-FileSha256 $backupPath) })

    # aplica o patch (trocas de mesmo tamanho - o arquivo nao muda de tamanho)
    $s = $state.Text
    $replaced = 0
    foreach ($p in $Script:Patterns) {
        $cnt = Count-Occurrences $s $p[0]
        if ($cnt -gt 0) { $s = $s.Replace($p[0], $p[1]); $replaced += $cnt }
    }
    try {
        [System.IO.File]::WriteAllBytes($exePath, $Script:Latin1.GetBytes($s))
    } catch [System.IO.IOException] {
        Fatal ($name + ': o arquivo esta EM USO por outro programa (o jogo ou o launcher esta aberto?). Feche tudo e rode o instalador de novo. Seu backup continua intacto e nada foi quebrado.')
    } catch {
        Fatal ($name + ': nao consegui gravar o arquivo patcheado (' + $_.Exception.Message + '). Seu backup continua intacto.')
    }

    # verificacao pos-escrita
    $after = Get-ExeState $exePath
    if ($after.State -ne 'PATCHED') {
        try { Copy-Item -LiteralPath $backupPath -Destination $exePath -Force } catch {}
        Fatal ($name + ': o patch nao passou na verificacao final. O arquivo foi RESTAURADO do backup. Nao jogue multiplayer com ele neste estado.')
    }
    $Script:Actions.Add(($name + ' patcheado com sucesso (' + $replaced + ' ocorrencias alteradas; 8/8 padroes verificados).'))
    Write-Ok ($name + ': patch multiplayer aplicado e verificado')
    return 'PATCHED'
}

# ------------------------------------------------------------------- processo --
function Test-GameRunning {
    return @(Get-Process -Name 'bg3', 'bg3_dx11' -ErrorAction SilentlyContinue).Count -gt 0
}

function Assert-GameClosed {
    Write-Step 'Conferindo se o jogo esta fechado'
    $tries = 0
    while (Test-GameRunning) {
        $tries++
        if ($tries -gt 5) { Fatal "O Baldur's Gate 3 continua aberto. Feche-o pelo Gerenciador de Tarefas e rode o instalador novamente." }
        if ($Unattended) { Fatal 'O jogo esta aberto e o modo sem perguntas nao pode continuar. Feche o jogo e tente de novo.' }
        Out-Line "    O Baldur's Gate 3 esta ABERTO agora. Feche o jogo e depois" 'Yellow'
        $ans = Read-Host '    pressione ENTER para continuar (ou digite CANCELAR para sair)'
        if ($ans -match '(?i)^\s*(cancelar|sair)\s*$') { Fatal 'Instalacao cancelada pelo usuario.' }
    }
    Write-Ok 'Jogo fechado'
}

# -------------------------------------------------------------------- launch --
function Start-Game([string]$gameDir) {
    try {
        if ($Script:SteamPath) { Start-Process ('steam://rungameid/' + $Script:SteamAppId); return }
    } catch {}
    foreach ($exe in @('bg3_dx11.exe', 'bg3.exe')) {
        $p = Join-Path $gameDir ('bin\' + $exe)
        if (Test-Path -LiteralPath $p) { try { Start-Process -FilePath $p; return } catch {} }
    }
    Write-Warn2 'Nao consegui abrir o jogo automaticamente. Abra-o normalmente.'
}

# ------------------------------------------------------------------ resultado --
function Save-Manifest([string]$gameDir) {
    $root = Join-Path $gameDir $Script:BackupDirName
    $manifestPath = Join-Path $root 'manifest.json'
    $origin = 'arquivos-embutidos-no-install.bat'
    if (-not $Script:UsingEmbedded) { $origin = 'pasta files local' }
    # NOTA: usar .ToArray() em vez de @($lista) - o construtor @() quebra com
    # List[object] vazia em algumas versoes do PowerShell 5.1.
    $manifest = [ordered]@{
        instaladoEm        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        versao             = $Script:PlbVersion
        origemDoMod        = $origin
        pastaDoJogo        = $gameDir
        acoes              = $Script:Actions.ToArray()
        arquivosInstalados = $Script:InstalledFiles.ToArray()
        backups            = $Script:Backups.ToArray()
        quarentena         = $Script:Quarantined.ToArray()
        avisos             = $Script:Warnings.ToArray()
    }
    [System.IO.File]::WriteAllText($manifestPath, (ConvertTo-Json -InputObject $manifest -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok ('Manifesto salvo em: ' + $manifestPath)
    return $manifestPath
}

# --------------------------------------------------------- modo desinstalar --
function Invoke-UninstallMain {
    Out-Line '' 'Gray'
    Out-Line '  ============================================================' 'Cyan'
    Out-Line "    PARTY LIMIT BEGONE - DESINSTALADOR (Baldur's Gate 3)" 'Cyan'
    Out-Line '  ============================================================' 'Cyan'

    $gameDir = Resolve-GameDir
    Out-Line '' 'Gray'
    Write-Ok ('Pasta do jogo: ' + $gameDir)

    if (@(Get-Process -Name 'bg3', 'bg3_dx11' -ErrorAction SilentlyContinue).Count -gt 0) {
        Fatal 'O jogo esta ABERTO. Feche-o antes de desinstalar.'
    }

    $backupRoot = Join-Path $gameDir $Script:BackupDirName
    $dataMods   = Join-Path $gameDir 'Data\Mods'
    $restored = 0; $removed = 0; $nothing = $true

    # 1) restaurar executaveis a partir dos backups
    foreach ($exe in $Script:GameExes) {
        $exePath = Join-Path $gameDir ('bin\' + $exe)
        $bak     = $exePath + '.backup'
        if (Test-Path -LiteralPath $bak) {
            $nothing = $false
            if (Test-Path -LiteralPath $exePath) {
                Copy-Item -LiteralPath $bak -Destination $exePath -Force
                Remove-Item -LiteralPath $bak -Force
                Write-Ok ($exe + ' restaurado do backup (patch multiplayer removido)')
                $restored++
            } else {
                Write-Warn2 ($exe + ' nao existe mais; backup mantido em ' + $bak)
            }
        }
    }

    # 2) remover pastas do PLB em Data\Mods (somente se o meta.lsx for do PLB)
    if (Test-Path -LiteralPath $dataMods) {
        foreach ($folder in $Script:PlbUuids.Keys) {
            $metaPath = Join-Path $dataMods ($folder + '\meta.lsx')
            if (Test-Path -LiteralPath $metaPath) {
                $nothing = $false
                if (Test-IsPlbMeta $metaPath) {
                    Remove-Item -LiteralPath (Join-Path $dataMods $folder) -Recurse -Force
                    Write-Ok ('Removido: Data\Mods\' + $folder)
                    $removed++
                } else {
                    Write-Warn2 ('Data\Mods\' + $folder + '\meta.lsx NAO e do PLB (outro mod?). Nao removi por seguranca.')
                }
            }
        }
    }

    # 3) .pak do PLB na pasta do gerenciador (AppData)
    $appMods = $AppDataOverride
    if (-not $appMods) { $appMods = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Mods" }
    if (Test-Path -LiteralPath $appMods) {
        foreach ($f in @(Get-ChildItem -LiteralPath $appMods -Filter '*.pak' -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -match '(?i)(plb|party.?limit|limit.?begone)') {
                $nothing = $false
                Remove-Item -LiteralPath $f.FullName -Force
                Write-Ok ('Removido da pasta de mods do gerenciador: ' + $f.Name)
            }
        }
    }

    # 4) limpar pasta de backup se ficou vazia (quarentena preservada)
    if (Test-Path -LiteralPath $backupRoot) {
        $remaining = @(Get-ChildItem -LiteralPath $backupRoot -Recurse -File -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $backupRoot -Recurse -Force
            Write-Ok 'Pasta PLB-Installer-Backup vazia removida'
        } else {
            Write-Ok ('Mantida a pasta ' + $Script:BackupDirName + ' (contem ' + $remaining.Count + ' arquivo(s) de quarentena/registro)')
        }
    }

    Out-Line '' 'Gray'
    if ($nothing) {
        Out-Line '  Nenhuma instalacao do Party Limit Begone foi encontrada nesta pasta.' 'Yellow'
        return 0
    }
    Out-Line '  DESINSTALACAO CONCLUIDA!' 'Green'
    Out-Line ('  (' + $restored + ' executavel(is) restaurado(s), ' + $removed + ' pasta(s) do mod removida(s))') 'Gray'
    Out-Line '  Se algum outro jogador continuar com o mod e voce entrar no save dele,' 'Yellow'
    Out-Line '  voce vera o jogo com limite normal de 4 membros - e isso e esperado.' 'Yellow'
    return 0
}

# ---------------------------------------------------------------------- main --
function Invoke-Main {
    if ($env:PLB_MODE -eq 'uninstall') {
        $code = Invoke-UninstallMain
        if (-not $NoPauseSwitch) {
            Out-Line '' 'Gray'
            Read-Host '  Pressione ENTER para fechar esta janela' | Out-Null
        }
        return $code
    }
    $t0 = Get-Date

    Out-Line '' 'Gray'
    Out-Line '  ============================================================' 'Cyan'
    Out-Line "    PARTY LIMIT BEGONE - INSTALADOR AUTOMATICO (Baldur's Gate 3)" 'Cyan'
    Out-Line ('    ' + $Script:PlbVersion) 'Cyan'
    Out-Line ('    Mod por Sildur: ' + $Script:ModUrl) 'DarkCyan'
    Out-Line '  ============================================================' 'Cyan'
    if (-not $NoPauseSwitch) { Out-Line '    Nao clique dentro desta janela enquanto instala. Aguarde.' 'DarkGray' }

    Disable-QuickEdit
    Initialize-ModPackages
    Initialize-PatchPatterns

    $gameDir = Resolve-GameDir
    $Script:LastGameDir = $gameDir
    Initialize-BackupDirs $gameDir
    Assert-GameClosed

    Write-Step 'Conferindo permissoes de escrita'
    if (-not (Test-CanWrite $gameDir)) {
        if (Test-IsAdmin) { Fatal 'Sem permissao de escrita na pasta do jogo mesmo como administrador. Feche o jogo e programas que usem a pasta (sincronizacao do Steam, antivirus) e tente de novo.' }
        if ($NoPauseSwitch -or $Unattended) { Fatal 'Sem permissao de escrita na pasta do jogo e o modo atual nao pode pedir elevacao (UAC).' }
        Invoke-ElevatedRerun $gameDir   # nao retorna
        return 1
    }
    Write-Ok 'Permissoes OK'

    Invoke-JunkScan $gameDir
    Install-Standalone $gameDir

    Write-Step 'Aplicando o patch de multiplayer nos executaveis'
    $results = @{}
    foreach ($exe in $Script:GameExes) {
        $results[$exe] = Invoke-ExePatch (Join-Path $gameDir ('bin\' + $exe))
    }
    $anyFailed = $false
    foreach ($k in $results.Keys) { if ($results[$k] -eq 'FAILED') { $anyFailed = $true } }

    Save-Manifest $gameDir | Out-Null

    # ---------------- checklist final ----------------
    Out-Line '' 'Gray'
    Out-Line '  ================= RESUMO DA INSTALACAO =================' 'Cyan'

    $allOk = $true
    $metaOk = Test-Path -LiteralPath (Join-Path $gameDir 'Data\Mods\Shared\meta.lsx')
    if ($metaOk) { Out-Line '    [OK] Standalone v3.5 instalado (limite de 16 membros)' 'Green' }
    else { $allOk = $false; Out-Line '    [X]  Standalone NAO verificado' 'Red' }

    foreach ($exe in $Script:GameExes) {
        $p = Join-Path $gameDir ('bin\' + $exe)
        if ($results[$exe] -eq 'PATCHED') {
            Out-Line ('    [OK] Patch multiplayer aplicado em ' + $exe) 'Green'
        } elseif ($results[$exe] -eq 'MISSING') {
            Out-Line ('    [--] ' + $exe + ' nao existe nesta instalacao (ok)') 'DarkGray'
        } else {
            $allOk = $false
            Out-Line ('    [X]  ' + $exe + ': NAO foi patcheado (veja os avisos acima)') 'Red'
        }
        $bak = $p + '.backup'
        if (Test-Path -LiteralPath $bak) { Out-Line ('    [OK] Backup disponivel: ' + (Split-Path -Leaf $bak)) 'Green' }
    }

    if ($Script:Quarantined.Count -gt 0) {
        Out-Line ('    [OK] ' + $Script:Quarantined.Count + ' item(ns) antigo(s) movido(s) para quarentena (nada foi apagado)') 'Green'
        Out-Line ('         Quarentena: ' + $Script:QuarantineRoot) 'DarkGray'
    }
    if ($Script:Warnings.Count -gt 0) {
        Out-Line ('    [!!] Avisos: ' + $Script:Warnings.Count + ' - leia as linhas [!!] acima') 'Yellow'
    }
    Out-Line '  ========================================================' 'Cyan'

    $elapsed = [int]((Get-Date) - $t0).TotalSeconds
    $finalCode = 0
    if (-not $allOk -or $anyFailed) { $finalCode = 2 }
    Add-Log ('FIM: exitCode=' + $finalCode + ' tempo=' + $elapsed + 's')

    if ($finalCode -eq 0) {
        Out-Line '' 'Gray'
        Out-Line '  TUDO PRONTO! Agora e so abrir o jogo e jogar (ate 8 jogadores online).' 'Green'
        Out-Line '  TODOS os amigos devem rodar este MESMO instalador para o multiplayer funcionar.' 'Cyan'
        return 0
    }

    Out-Line '' 'Gray'
    Out-Line '  A instalacao terminou COM PENDENCIAS. Leia os itens [X] e [!!] acima.' 'Yellow'
    Out-Line '  Causa mais comum: o jogo atualizou e o mod ainda nao tem patch para a versao nova.' 'Yellow'
    return 2
}

# ----------------------------------------------------------------- top-level --
$global:PLBExitCode = 1
try {
    $global:PLBExitCode = Invoke-Main
} catch {
    $msg    = $_.Exception.Message
    $posMsg = $_.InvocationInfo.PositionMessage
    Write-Fail ('Erro inesperado: ' + $msg)
    if ($posMsg) {
        Add-Log ('POSICAO: ' + ($posMsg -replace "`r?`n", ' | '))
        Out-Line ('    (detalhe tecnico: ' + ($posMsg -replace "`r?`n", ' | ') + ')') 'DarkGray'
    }
    Out-Line '' 'Gray'
    Out-Line '  A instalacao FALHOU. Nada foi apagado; seus backups (se existirem) estao intactos.' 'Yellow'
    Out-Line '  Rode o install.bat de novo. Se o erro persistir, envie um print desta janela.' 'Yellow'
    $Script:ConsoleLines.Add('ERRO: ' + $msg)
    $global:PLBExitCode = 1
} finally {
    if ($ResultFile) {
        try {
            $payload = [ordered]@{ exitCode = [int]$global:PLBExitCode; report = $Script:ConsoleLines.ToArray() }
            [System.IO.File]::WriteAllText($ResultFile, (ConvertTo-Json -InputObject $payload -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
        } catch {}
    }
}

if (-not $NoPauseSwitch -and -not $IsElevatedRun -and $env:PLB_MODE -ne 'uninstall') {
    if ($global:PLBExitCode -eq 0) {
        Out-Line '' 'Gray'
        $ans = Read-Host "  Pressione ENTER para abrir o Baldur's Gate 3 agora (ou digite N e ENTER para sair)"
        if ($ans -notmatch '(?i)^\s*(n|nao)\s*$') {
            Start-Game $Script:LastGameDir
        }
    } else {
        Out-Line '' 'Gray'
        Read-Host '  Pressione ENTER para fechar esta janela' | Out-Null
    }
}

exit $global:PLBExitCode
