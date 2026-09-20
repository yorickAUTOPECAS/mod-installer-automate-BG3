# =============================================================================
#  make-installer.ps1 - Gera os .bat finais (install.bat e uninstall.bat)
#
#  Uso (no Windows):
#    powershell -NoProfile -ExecutionPolicy Bypass -File make-installer.ps1
#
#  O que ele faz:
#    1. Le src/install.ps1 e os zips de files/.
#    2. Gera o script completo (logica + payload base64) -> work/install.full.ps1
#    3. Codifica o script completo em base64 e gera install.bat/uninstall.bat,
#       gravando o payload linha a linha com comandos "echo" do proprio cmd.
#       O .bat reconstroi o script no %TEMP% e executa com o Windows PowerShell.
#
#  Por que base64 em dois niveis?
#    O cmd.exe nao consegue "ecoar" de forma confiavel texto com aspas,
#    acentos e parenteses. Entao TODO o conteudo do script vai em base64
#    (texto 100% seguro para o cmd). Dentro do script, os zips do mod tambem
#    vao em base64.Resultado: um unico arquivo .bat autocontido, sem internet.
#
#  Gere sempre no Windows (o .bat precisa terminar as linhas com CRLF).
# =============================================================================

$ErrorActionPreference = 'Stop'

$root     = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcPath  = Join-Path $root 'src\install.ps1'
$filesDir = Join-Path $root 'files'
$outDir   = Join-Path $root 'work'

if (-not (Test-Path -LiteralPath $srcPath)) { throw ("Nao encontrei " + $srcPath) }
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$ps = [System.IO.File]::ReadAllText($srcPath)
if ($ps -match '(?m)^\s*\$ZipStandaloneB64\s*=') { throw 'src/install.ps1 contem payload manual; gere a partir do codigo-fonte limpo.' }

$standalone = Get-ChildItem -LiteralPath $filesDir -Filter '*.zip' -File | Where-Object { $_.Name -match '(?i)standalone' }  | Select-Object -First 1
$patch      = Get-ChildItem -LiteralPath $filesDir -Filter '*.zip' -File | Where-Object { $_.Name -match '(?i)multiplayer' } | Select-Object -First 1
if (-not $standalone) { throw 'Coloque em files\ o zip ...Standalone...zip' }
if (-not $patch)      { throw 'Coloque em files\ o zip ...Multiplayer...zip' }

$zipB64Standalone = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($standalone.FullName))
$zipB64Patch      = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($patch.FullName))

function Split-IntoChunks([string]$text, [int]$size) {
    $list = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $text.Length; $i += $size) {
        $len = [Math]::Min($size, $text.Length - $i)
        $list.Add($text.Substring($i, $len))
    }
    return , $list
}

$chunkSize = 32000   # linhas de string literal dentro do .ps1 (limite do PS: nenhum; mantemos legivel)
$stChunks = Split-IntoChunks $zipB64Standalone $chunkSize
$ptChunks = Split-IntoChunks $zipB64Patch      $chunkSize

function Format-B64Var([string]$name, $chunks) {
    $quoted = "'" + ($chunks -join "' +`r`n  '") + "'"
    return ('$' + $name + ' = (' + "`r`n  " + $quoted + "`r`n" + ')')
}

$payload = New-Object System.Collections.Generic.List[string]
$payload.Add('# ============================================================================')
$payload.Add('#  PAYLOAD EMBUTIDO (gerado automaticamente por make-installer.ps1)')
$payload.Add('#  Nao edite manualmente: os zips originais estao na pasta files/.')
$payload.Add('# ============================================================================')
$payload.Add('')
$payload.Add((Format-B64Var 'ZipStandaloneB64' $stChunks))
$payload.Add('')
$payload.Add((Format-B64Var 'ZipPatchB64' $ptChunks))

$full = ($ps.TrimEnd() + "`r`n`r`n" + ($payload -join "`r`n") + "`r`n")
$fullPath = Join-Path $outDir 'install.full.ps1'
[System.IO.File]::WriteAllText($fullPath, $full, (New-Object System.Text.UTF8Encoding($false)))

# ---- validacao de sintaxe do script completo ----
$tokens = $null; $parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($fullPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    throw ('Erro de sintaxe no script gerado: ' + ($parseErrors[0].Message))
}

# ---- gera os .bat ----
# Cada linha do payload e gravada no arquivo de dados com o prefixo "K"
# (protege contra chunks que comecariam com "off", "/?" etc., que o cmd
#  interpretaria de forma especial apos o "echo").
function New-LauncherBat([string]$mode) {
    $fullB64   = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($full))
    $batChunks = Split-IntoChunks $fullB64 7600   # cmd tem limite de 8191 chars por linha

    foreach ($c in $batChunks) {
        if ($c.Length -gt 7600) { throw 'chunk grande demais para o cmd (limite 8191 por linha)' }
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('@echo off')
    [void]$sb.AppendLine('rem ====================================================================')
    [void]$sb.AppendLine("rem  Party Limit Begone (Baldur's Gate 3) - Instalador automatico")
    [void]$sb.AppendLine('rem  Mod por Sildur: https://www.nexusmods.com/baldursgate3/mods/327')
    [void]$sb.AppendLine('rem  Arquivo gerado por make-installer.ps1. Tudo embutido: nao precisa de internet.')
    [void]$sb.AppendLine('rem  Nao edite este arquivo: edite src/install.ps1 e gere de novo.')
    [void]$sb.AppendLine('rem ====================================================================')
    [void]$sb.AppendLine('setlocal EnableExtensions')
    [void]$sb.AppendLine('title Party Limit Begone - Instalador')
    [void]$sb.AppendLine('where powershell >nul 2>nul')
    [void]$sb.AppendLine('if errorlevel 1 (')
    [void]$sb.AppendLine('  echo [ERRO] O Windows PowerShell nao foi encontrado neste computador.')
    [void]$sb.AppendLine('  echo Ele vem incluido no Windows 10 e 11. Peca ajuda a quem te enviou este arquivo.')
    [void]$sb.AppendLine('  pause')
    [void]$sb.AppendLine('  exit /b 1')
    [void]$sb.AppendLine(')')
    [void]$sb.AppendLine('chcp 65001 >nul')
    [void]$sb.AppendLine('set "PLB_SELF=%~f0"')
    if ($mode -eq 'uninstall') { [void]$sb.AppendLine('set "PLB_MODE=uninstall"') }
    [void]$sb.AppendLine('set "PLB_DATA=%TEMP%\plb_data_%RANDOM%%RANDOM%.txt"')
    [void]$sb.AppendLine('if exist "%PLB_DATA%" del /q "%PLB_DATA%" >nul 2>nul')
    [void]$sb.AppendLine('echo Preparando o instalador... nao feche esta janela')
    foreach ($c in $batChunks) {
        [void]$sb.AppendLine('>>"%PLB_DATA%" echo K' + $c)
    }
    # Decodifica e executa: le as linhas com prefixo K, junta, decodifica base64
    # e roda o script (exit dentro do script define o codigo de saida do processo).
    [void]$sb.AppendLine('powershell -NoProfile -ExecutionPolicy Bypass -Command "$L=[System.Collections.Generic.List[string]]::new(); foreach($ln in [System.IO.File]::ReadAllLines($env:PLB_DATA)){ if($ln.Length -gt 1 -and $ln[0] -eq [char]75){ $L.Add($ln.Substring(1)) } }; $s=[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String([System.String]::Join('''' , $L.ToArray()))); Invoke-Expression $s"')
    [void]$sb.AppendLine('set "PLB_ERR=%errorlevel%"')
    [void]$sb.AppendLine('if exist "%PLB_DATA%" del /q "%PLB_DATA%" >nul 2>nul')
    [void]$sb.AppendLine('exit /b %PLB_ERR%')
    return $sb.ToString()
}

$installBat   = New-LauncherBat 'install'
$uninstallBat = New-LauncherBat 'uninstall'
[System.IO.File]::WriteAllText((Join-Path $root 'install.bat'),   $installBat,   [System.Text.Encoding]::ASCII)
[System.IO.File]::WriteAllText((Join-Path $root 'uninstall.bat'), $uninstallBat, [System.Text.Encoding]::ASCII)

Write-Host '=================================================='
Write-Host ' install.bat e uninstall.bat gerados com sucesso!'
Write-Host ('   install.bat   : {0:N2} MB' -f ((Get-Item (Join-Path $root 'install.bat')).Length   / 1MB))
Write-Host ('   uninstall.bat : {0:N2} MB' -f ((Get-Item (Join-Path $root 'uninstall.bat')).Length / 1MB))
Write-Host ('   zips embutidos: Standalone {0:N0} B | Multiplayer {1:N0} B' -f $standalone.Length, $patch.Length)
Write-Host '=================================================='
