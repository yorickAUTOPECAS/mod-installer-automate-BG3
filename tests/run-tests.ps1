# =============================================================================
#  tests/run-tests.ps1 - Testa o install.bat real (cmd -> powershell -> script)
#  Cenario por cenario, com pastas falsas (nada do seu PC e tocado).
#
#  SEGURANCA (3 camadas, apos um incidente em que o teste patcheou o jogo real):
#    1. Passa o alvo via variavel de ambiente $envOverrides (nome escolhido
#       para NAO colidir com o namespace $env: do PowerShell).
#    2. Guarda de sandbox: o teste se recusa a rodar se o alvo definido
#       nao estiver dentro da pasta temporaria do teste.
#    3. Seam PLB_DISABLE_AUTODETECT: sem alvo definido, o instalador
#       nao escaneia discos/registro - impossivel achar o jogo real.
#
#  Uso: powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
# =============================================================================

$ErrorActionPreference = 'Stop'
$root    = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$bat     = Join-Path $root 'install.bat'
$ubat    = Join-Path $root 'uninstall.bat'
$sandbox = Join-Path $env:TEMP ('plb_tests_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$Latin1  = [System.Text.Encoding]::GetEncoding(28591)

$pass = 0; $fail = 0
# Alvo invalido usado no T8: fora da sandbox DE PROPOSITO (nao existe, nunca sera tocado)
$TestInvalidDir = 'C:\nao_existe_00'

function Test-TargetAllowed([string]$t) {
    if (-not $t) { return $true }
    if ($t -eq $TestInvalidDir) { return $true }
    return $t.StartsWith($sandbox)
}

function Out2([string]$t, $c = 'Gray') { Write-Host $t -ForegroundColor $c }

function Convert-HexToBytes([string]$hex) {
    $n = $hex.Length / 2
    $b = New-Object byte[] $n
    for ($i = 0; $i -lt $n; $i++) { $b[$i] = [System.Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
    return $b
}

function New-FakeGame {
    param([string]$dir)
    if (-not $dir.StartsWith($sandbox)) { throw "GUARDA DE SANDBOX: '$dir' fora da sandbox!" }
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'Data\Mods') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'bin') | Out-Null
    $appData = Join-Path $dir 'appdata\Larian Studios\Baldurs Gate 3\Mods'
    New-Item -ItemType Directory -Force -Path $appData | Out-Null
    foreach ($exe in @('bg3.exe', 'bg3_dx11.exe')) {
        $bytes = New-Object System.Collections.Generic.List[byte]
        $bytes.AddRange([System.Text.Encoding]::ASCII.GetBytes('MZF Placeholder ' + $exe + ' - Fake BG3 executable for tests only. '))
        foreach ($hex in @('83FD040F8CA0FEFF', '4183FE040F8C66FF', '4180FE040F8691FE', 'C6403804488B4E08', 'C6403804488B4B08', 'C64138044C894140', '0183FB040F8DA000', '4183FC04488B4424')) {
            $bytes.AddRange([byte[]](Convert-HexToBytes $hex))
        }
        [System.IO.File]::WriteAllBytes((Join-Path $dir ('bin\' + $exe)), $bytes.ToArray())
    }
    return $appData
}

function Get-MarkerCount([string]$exePath, [string]$markerHex) {
    $s = $Latin1.GetString([System.IO.File]::ReadAllBytes($exePath))
    $needle = $Latin1.GetString((Convert-HexToBytes $markerHex))
    $c = 0; $i = 0
    while (($i = $s.IndexOf($needle, $i, [System.StringComparison]::Ordinal)) -ge 0) { $c++; $i += $needle.Length }
    return $c
}

function Invoke-Bat {
    param([string]$which = 'install', [hashtable]$envOverrides = @{})
    foreach ($k in $envOverrides.Keys) {
        if ($k -notmatch '^PLB_') { throw "GUARDA: variavel de teste fora do namespace PLB_: $k" }
    }
    # Guarda de sandbox: ou o alvo esta DENTRO da sandbox, ou a autodeteccao
    # esta desligada e nao ha alvo (teste de "nao encontrado").
    if (-not (Test-TargetAllowed ([string]$envOverrides['PLB_TARGET_DIR']))) {
        throw "GUARDA DE SANDBOX: alvo fora da pasta temporaria do teste!"
    }
    $old = @{}
    foreach ($k in $envOverrides.Keys) { $old[$k] = [System.Environment]::GetEnvironmentVariable($k); [System.Environment]::SetEnvironmentVariable($k, [string]$envOverrides[$k]) }
    try {
        $f = $bat
        if ($which -eq 'uninstall') { $f = $ubat }
        $out = & cmd.exe /c "`"$f`" <nul" 2>&1
        return @{ Output = ($out -join "`n"); ExitCode = $LASTEXITCODE }
    } finally {
        foreach ($k in $old.Keys) { [System.Environment]::SetEnvironmentVariable($k, $old[$k]) }
    }
}

function Check-Report([hashtable]$r, [string]$label) {
    Out2 ''
    Out2 ('--- ' + $label + ' (exit=' + $r.ExitCode + ') ---') 'Cyan'
    foreach ($l in ($r.Output -split "`n")) { Out2 ('  | ' + $l) 'DarkGray' }
    Out2 ''
}

function Assert-True([bool]$cond, [string]$label, [string]$detail) {
    if ($cond) { $script:pass++; Out2 ('  PASS  ' + $label) 'Green' }
    else       { $script:fail++; Out2 ('  FAIL  ' + $label + '  ->  ' + $detail) 'Red' }
}

# Variaveis base: nunca autodetectar (a sandbox nunca contem um "jogo real")
$BaseEnv = @{ PLB_NO_PAUSE = '1'; PLB_UNATTENDED = '1'; PLB_DISABLE_AUTODETECT = '1' }

function New-Env([hashtable]$extra, [string]$gameDir, [string]$appData, [string]$sandboxRoot) {
    $h = @{}
    foreach ($k in $BaseEnv.Keys) { $h[$k] = $BaseEnv[$k] }
    $h['PLB_TARGET_DIR']  = $gameDir
    $h['PLB_APPDATA_DIR'] = $appData
    foreach ($k in $extra.Keys) { $h[$k] = $extra[$k] }
    if (-not (Test-TargetAllowed $gameDir)) { throw "GUARDA: alvo fora da sandbox: $gameDir" }
    return $h
}

# ============================================================ teste 1: limpa ==
$g1   = Join-Path $sandbox 't1'
$app1 = New-FakeGame $g1
$origExeHash = (Get-FileHash (Join-Path $g1 'bin\bg3.exe')).Hash
Write-Host ('  (hash do exe falso: ' + $origExeHash.Substring(0, 12) + '...)') 'DarkGray'

$r = Invoke-Bat 'install' (New-Env @{} $g1 $app1)
Check-Report $r 'T1: instalacao limpa'
Assert-True ($r.ExitCode -eq 0) 'T1a exit 0' ('exit=' + $r.ExitCode)
Assert-True (Test-Path (Join-Path $g1 'Data\Mods\Shared\meta.lsx')) 'T1b meta.lsx instalado' 'faltou'
$metaTxt = [System.IO.File]::ReadAllText((Join-Path $g1 'Data\Mods\Shared\meta.lsx'))
Assert-True ($metaTxt -match 'NumPlayers" type="uint8" value="16"') 'T1c NumPlayers=16' 'errado'
Assert-True ((Get-MarkerCount (Join-Path $g1 'bin\bg3.exe') '4183FE08') -eq 1) 'T1d bg3.exe patcheado' 'marcador ausente'
Assert-True ((Get-MarkerCount (Join-Path $g1 'bin\bg3_dx11.exe') '4183FE08') -eq 1) 'T1e bg3_dx11.exe patcheado' 'marcador ausente'
Assert-True ((Test-Path (Join-Path $g1 'bin\bg3.exe.backup')) -and (Test-Path (Join-Path $g1 'bin\bg3_dx11.exe.backup'))) 'T1f backups criados' 'faltando'
Assert-True ((Get-FileHash (Join-Path $g1 'bin\bg3.exe.backup')).Hash -eq $origExeHash) 'T1g backup = original' 'diferente'
Assert-True (Test-Path (Join-Path $g1 'PLB-Installer-Backup\manifest.json')) 'T1h manifesto salvo' 'faltando'
Assert-True ($r.Output -match 'Tudo pronto|TUDO PRONTO') 'T1i mensagem final de sucesso' 'sem mensagem'

# ==================================================== teste 2: rodar de novo ==
$r = Invoke-Bat 'install' (New-Env @{} $g1 $app1)
Check-Report $r 'T2: reinstalacao (idempotente)'
Assert-True ($r.ExitCode -eq 0) 'T2a exit 0' ('exit=' + $r.ExitCode)
Assert-True ($r.Output -match 'JA estava aplicado') 'T2b patch ja aplicado reconhecido' 'nao detectou'
Assert-True ((Get-FileHash (Join-Path $g1 'bin\bg3.exe.backup')).Hash -eq $origExeHash) 'T2c backup segue = original' 'mudou'

# ==================================== teste 3: exe parcialmente patcheado ==
$g3   = Join-Path $sandbox 't3'
$app3 = New-FakeGame $g3
$partial = $Latin1.GetString([System.IO.File]::ReadAllBytes((Join-Path $g3 'bin\bg3.exe')))
# deixa exatamente 1 dos 8 padroes ja aplicado (tentativa manual pela metade)
$partial = $partial.Replace($Latin1.GetString((Convert-HexToBytes 'C6403804')), $Latin1.GetString((Convert-HexToBytes 'C6403808')))
[System.IO.File]::WriteAllBytes((Join-Path $g3 'bin\bg3.exe'), $Latin1.GetBytes($partial))
$r = Invoke-Bat 'install' (New-Env @{} $g3 $app3)
Check-Report $r 'T3: exe parcialmente patcheado'
Assert-True ($r.ExitCode -eq 0) 'T3a exit 0' ('exit=' + $r.ExitCode)
Assert-True ($r.Output -match 'parcial') 'T3b detectou estado parcial' 'nao avisou'
Assert-True ((Get-MarkerCount (Join-Path $g3 'bin\bg3.exe') '4183FE08') -eq 1) 'T3c terminou patcheado' 'marcador ausente'
Assert-True ((Get-MarkerCount (Join-Path $g3 'bin\bg3.exe.backup') '4183FE04') -eq 1) 'T3d backup manteve padrao original (nao virou veneno)' 'backup patcheado!'
Assert-True ((Get-FileHash (Join-Path $g3 'bin\bg3.exe')).Hash -ne (Get-FileHash (Join-Path $g3 'bin\bg3.exe.backup')).Hash) 'T3e backup != exe final' 'iguais'

# ================================= teste 3b: backup envenenado (parcial + backup patcheado) ==
$g3b   = Join-Path $sandbox 't3b'
$app3b = New-FakeGame $g3b
$partial3b = $Latin1.GetString([System.IO.File]::ReadAllBytes((Join-Path $g3b 'bin\bg3.exe')))
$partial3b = $partial3b.Replace($Latin1.GetString((Convert-HexToBytes 'C6403804')), $Latin1.GetString((Convert-HexToBytes 'C6403808')))
[System.IO.File]::WriteAllBytes((Join-Path $g3b 'bin\bg3.exe'), $Latin1.GetBytes($partial3b))
# backup envenenado: conteudo TOTALMENTE patcheado (erro classico de quem tentou na mao 2x)
$poison = $Latin1.GetString([System.IO.File]::ReadAllBytes((Join-Path $g1 'bin\bg3.exe')))
$poison = $poison.Replace($Latin1.GetString((Convert-HexToBytes '4183FE04')), $Latin1.GetString((Convert-HexToBytes '4183FE08')))
[System.IO.File]::WriteAllBytes((Join-Path $g3b 'bin\bg3.exe.backup'), $Latin1.GetBytes($poison))
$r = Invoke-Bat 'install' (New-Env @{} $g3b $app3b)
Check-Report $r 'T3b: backup envenenado detectado e substituido'
Assert-True ($r.ExitCode -eq 0) 'T3b-a exit 0' ('exit=' + $r.ExitCode)
Assert-True ($r.Output -match 'veneno') 'T3b-b detectou backup envenenado' 'nao avisou'
Assert-True ((Get-MarkerCount (Join-Path $g3b 'bin\bg3.exe.backup') '4183FE04') -eq 1) 'T3b-c backup substituido por estado mais original' 'backup segue envenenado'
Assert-True ((Get-MarkerCount (Join-Path $g3b 'bin\bg3.exe') '4183FE08') -eq 1) 'T3b-d exe final patcheado' 'marcador ausente'

# ================================== teste 4: jogo atualizado (UNKNOWN) ==
$g4   = Join-Path $sandbox 't4'
$app4 = New-FakeGame $g4
[System.IO.File]::WriteAllBytes((Join-Path $g4 'bin\bg3.exe'), [System.Text.Encoding]::ASCII.GetBytes('MZF new version bytes totally different'))
$r = Invoke-Bat 'install' (New-Env @{} $g4 $app4)
Check-Report $r 'T4: jogo atualizado (exe desconhecido)'
Assert-True ($r.ExitCode -eq 2) 'T4a exit 2 (pendencia)' ('exit=' + $r.ExitCode)
$bg3After = [System.IO.File]::ReadAllText((Join-Path $g4 'bin\bg3.exe'))
Assert-True ($bg3After -eq 'MZF new version bytes totally different') 'T4b exe INTOCADO (abortou sem escrever)' 'escreveu no exe!'
Assert-True ($r.Output -match 'ATUALIZADO') 'T4c mensagem explica versao nova' 'sem explicacao'
Assert-True ((Get-MarkerCount (Join-Path $g4 'bin\bg3_dx11.exe') '4183FE08') -eq 1) 'T4d o outro exe (dx11) ainda foi patcheado' 'nao patcheou'
Assert-True ($r.Output -match 'PENDENCIAS') 'T4e resumo marca pendencia' 'sem pendencia'
Assert-True (Test-Path (Join-Path $g4 'bin\bg3_dx11.exe.backup')) 'T4f backup do dx11 criado' 'faltando'

# =============================== teste 5: restos de tentativa manual ==
$g5   = Join-Path $sandbox 't5'
$app5 = New-FakeGame $g5
New-Item -ItemType Directory -Force -Path (Join-Path $g5 'Data\Mods\Mods\Shared') | Out-Null
Copy-Item (Join-Path $g1 'Data\Mods\Shared\meta.lsx') (Join-Path $g5 'Data\Mods\Mods\Shared\meta.lsx')
$rmeadme = Join-Path $g5 'Data\Readme.txt'
# repare: string de teste contem "Party Limit Begone" para o instalador reconhecer
'Party Limit Begone readme de teste' | Set-Content $rmeadme
'PLB pak placeholder' | Set-Content (Join-Path $g5 'Data\Mods\PartyLimitBegone.pak')
$third = Join-Path $g5 'Data\Mods\SomeOtherMod'
New-Item -ItemType Directory -Force -Path $third | Out-Null
'outro mod' | Set-Content (Join-Path $third 'meta.lsx')
'nao sou do plb' | Set-Content (Join-Path $app5 'OtherMod.pak')
$r = Invoke-Bat 'install' (New-Env @{} $g5 $app5)
Check-Report $r 'T5: restos de tentativa manual + mods de terceiros'
Assert-True ($r.ExitCode -eq 0) 'T5a exit 0' ('exit=' + $r.ExitCode)
Assert-True (-not (Test-Path (Join-Path $g5 'Data\Mods\Mods'))) 'T5b Mods aninhada levada para quarentena' 'continua la'
Assert-True (Test-Path (Join-Path $g5 'PLB-Installer-Backup\quarentena')) 'T5c quarentena criada' 'faltando'
Assert-True ((@(Get-ChildItem (Join-Path $g5 'PLB-Installer-Backup\quarentena') -Recurse -File)).Count -ge 3) 'T5d itens na quarentena (Mods/, pak, Readme)' 'menos que o esperado'
Assert-True (Test-Path (Join-Path $g5 'Data\Mods\SomeOtherMod\meta.lsx')) 'T5e mod de terceiro INTACTO' 'foi tocado!'
Assert-True (Test-Path (Join-Path $app5 'OtherMod.pak')) 'T5f pak de terceiro no AppData INTACTO' 'foi tocado!'
Assert-True (-not (Test-Path (Join-Path $g5 'Data\Readme.txt'))) 'T5g readme do zip removido da pasta do jogo' 'continua'
Assert-True ((Get-MarkerCount (Join-Path $g5 'bin\bg3.exe') '4183FE08') -eq 1) 'T5h patch aplicado normalmente' 'marcador ausente'

# ==================================== teste 6: desinstalacao completa ==
$r = Invoke-Bat 'uninstall' (New-Env @{} $g1 $app1)
Check-Report $r 'T6: desinstalacao'
Assert-True ($r.ExitCode -eq 0) 'T6a exit 0' ('exit=' + $r.ExitCode)
Assert-True (-not (Test-Path (Join-Path $g1 'Data\Mods\Shared'))) 'T6b pasta do mod removida' 'continua'
Assert-True ((Get-FileHash (Join-Path $g1 'bin\bg3.exe')).Hash -eq $origExeHash) 'T6c exe restaurado ao original' 'diferente'
Assert-True (-not (Test-Path (Join-Path $g1 'bin\bg3.exe.backup'))) 'T6d backup consumido' 'continua'
Assert-True ((Get-MarkerCount (Join-Path $g1 'bin\bg3.exe') '4183FE04') -eq 1) 'T6e bytes originais de volta' 'ainda patcheado'

# ==================================== teste 7: desinstalacao sem nada ==
$g7   = Join-Path $sandbox 't7'
$app7 = New-FakeGame $g7
$r = Invoke-Bat 'uninstall' (New-Env @{} $g7 $app7)
Check-Report $r 'T7: desinstalacao sem nada instalado'
Assert-True ($r.ExitCode -eq 0) 'T7a exit 0 (nao explode)' ('exit=' + $r.ExitCode)
Assert-True ($r.Output -match 'Nenhuma instalacao') 'T7b mensagem amigavel' 'sem mensagem'

# ==================================== teste 8: pasta invalida ==
$r = Invoke-Bat 'install' (New-Env @{} $TestInvalidDir '' $sandbox)
Check-Report $r 'T8: pasta de jogo invalida (unattended)'
Assert-True ($r.ExitCode -eq 1) 'T8a exit 1' ('exit=' + $r.ExitCode)
Assert-True ($r.Output -match 'nao parece ser a pasta') 'T8b mensagem clara' 'sem mensagem'

# ==================================== teste 9: sem pasta (autodeteccao desligada) ==
$h = @{ PLB_NO_PAUSE = '1'; PLB_UNATTENDED = '1'; PLB_DISABLE_AUTODETECT = '1' }
$r = Invoke-Bat 'install' $h
Check-Report $r 'T9: jogo nao encontrado (unattended, autodeteccao desligada)'
Assert-True ($r.ExitCode -eq 1) 'T9a exit 1' ('exit=' + $r.ExitCode)
Assert-True ($r.Output -match 'Nao encontrei') 'T9b mensagem amigavel' 'sem mensagem'

Out2 ''
Out2 '==================================================' 'Cyan'
Out2 (' RESULTADO: ' + $pass + ' passaram, ' + $fail + ' falharam') $(if ($fail -eq 0) { 'Green' } else { 'Red' })
Out2 (' Sandbox: ' + $sandbox) 'DarkGray'
Out2 '==================================================' 'Cyan'
if ($fail -gt 0) { exit 1 } else { exit 0 }
