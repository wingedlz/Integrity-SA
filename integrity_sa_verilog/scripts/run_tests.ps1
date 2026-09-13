param(
    [int]$GemmCount = 128,
    [string]$Iverilog = "iverilog",
    [string]$Vvp = "vvp",
    [switch]$SkipMain
)
$ErrorActionPreference = 'Stop'
$projectDir = Split-Path -Parent $PSScriptRoot
$buildDir = Join-Path $projectDir 'build/raw_transport_no_sram'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
$rtlFiles = @('isa_residue.v','isa_pe.v','isa_stream_checker.v','integrity_sa_32x32.v') |
    ForEach-Object { Join-Path $projectDir ('rtl/' + $_) }

function Invoke-VerilogTest {
    param([string]$Top, [string]$TestFile, [string]$LogName, [string[]]$Overrides = @())
    $executable = Join-Path $buildDir ($LogName + '.vvp')
    $compileArgs = @('-g2001','-Wall','-s',$Top,'-o',$executable) + $Overrides + $rtlFiles + @($TestFile)
    $compileOutput = & $Iverilog @compileArgs 2>&1
    $compileCode = $LASTEXITCODE
    Set-Content -LiteralPath (Join-Path $buildDir ($LogName + '.compile.log')) -Value ($compileOutput -join "`n")
    if ($compileCode -ne 0) { throw "Verilog-2001 compilation failed: $Top" }
    $simulationOutput = & $Vvp $executable 2>&1
    $simulationCode = $LASTEXITCODE
    $simulationOutput | Set-Content -LiteralPath (Join-Path $buildDir ($LogName + '.log'))
    $body = $simulationOutput -join "`n"
    $simulationOutput | Where-Object { $_ -match '^(PASS|FAIL|EXPECTED_|FAULT_CASE)' } | Write-Output
    $passPattern = '(?m)^PASS(?::)?\s+' + [regex]::Escape($Top) + '(?::|\s|$)'
    if ($simulationCode -ne 0 -or $body -match '(?m)^(FAIL|ERROR)' -or $body -notmatch $passPattern) {
        throw "Simulation failed or did not finish: $Top ($LogName)"
    }
}

Invoke-VerilogTest 'tb_residue' (Join-Path $projectDir 'tb/tb_residue.v') 'residue'
Invoke-VerilogTest 'tb_stream_checker' (Join-Path $projectDir 'tb/tb_stream_checker.v') 'stream'
if (-not $SkipMain) {
    Invoke-VerilogTest 'tb_integrity_sa' (Join-Path $projectDir 'tb/tb_integrity_sa.v') 'gemm_k32' @("-Ptb_integrity_sa.NUM_GEMMS=$GemmCount")
}
foreach ($depth in @(1,7,31)) {
    Invoke-VerilogTest 'tb_integrity_sa' (Join-Path $projectDir 'tb/tb_integrity_sa.v') "gemm_k$depth" @(
        "-Ptb_integrity_sa.K_DEPTH=$depth", '-Ptb_integrity_sa.NUM_GEMMS=8', '-Ptb_integrity_sa.RUN_FAULTS=0')
}
Write-Output 'ALL_REQUESTED_TESTS_PASS'
