param(
    [string]$Vivado = 'vivado'
)
$ErrorActionPreference = 'Stop'
$sourceProject = Split-Path -Parent $PSScriptRoot
$resultDir = Join-Path $sourceProject 'build/raw_transport_no_sram/synth'
New-Item -ItemType Directory -Force -Path $resultDir | Out-Null

# Vivado 2023.2 on this host mishandles some Windows Tcl cleanup paths.
# A fresh scratch directory plus --keep-temp preserves a reproducible run.
$synthScratch = Join-Path ([IO.Path]::GetTempPath()) ('integrity_sa_raw_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $synthScratch | Out-Null
New-Item -ItemType Directory -Path (Join-Path $synthScratch 'rtl') | Out-Null
New-Item -ItemType Directory -Path (Join-Path $synthScratch 'scripts') | Out-Null
$rtlNames = @('isa_residue.v','isa_pe.v','isa_stream_checker.v','integrity_sa_32x32.v')
$hashes = foreach ($rtlName in $rtlNames) {
    $sourceFile = Join-Path $sourceProject ('rtl/' + $rtlName)
    $copiedFile = Join-Path $synthScratch ('rtl/' + $rtlName)
    Copy-Item -LiteralPath $sourceFile -Destination $copiedFile
    $sourceHash = (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash
    if ((Get-FileHash -LiteralPath $copiedFile -Algorithm SHA256).Hash -ne $sourceHash) {
        throw "Scratch RTL copy differs: $rtlName"
    }
    [PSCustomObject]@{ File = "rtl/$rtlName"; SHA256 = $sourceHash }
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'synth_check.tcl') -Destination (Join-Path $synthScratch 'scripts/synth_check.tcl')
$hashes | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $resultDir 'rtl_hashes.json')
$runMetadata = [ordered]@{
    Revision = 'raw_transport_no_sram'
    ScratchDirectory = $synthScratch
    Started = (Get-Date).ToString('o')
    Parameters = 'K_DEPTH=32; no SRAM-tag parameter or ports'
    Scope = 'Synthesis and structural checks; device DRC/fit is reported separately'
}
$runMetadata | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $resultDir 'run_metadata.json')
Write-Output "SYNTH_SCRATCH=$synthScratch"

$nativeResult = -1
Push-Location -LiteralPath $synthScratch
try {
    $scriptPath = (Join-Path $synthScratch 'scripts/synth_check.tcl').Replace('\','/')
    $projectPath = $synthScratch.Replace('\','/')
    & $Vivado -mode batch -nojournal -log vivado.log -source $scriptPath -tclargs $projectPath --keep-temp
    $nativeResult = $LASTEXITCODE
} finally {
    Pop-Location
    $scratchReports = Join-Path $synthScratch 'build/raw_transport_no_sram/synth'
    if (Test-Path -LiteralPath $scratchReports) {
        Get-ChildItem -LiteralPath $scratchReports -File | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $resultDir $_.Name)
        }
    }
    $scratchLog = Join-Path $synthScratch 'vivado.log'
    if (Test-Path -LiteralPath $scratchLog) {
        Copy-Item -LiteralPath $scratchLog -Destination (Join-Path $resultDir 'vivado.log')
    }
}

$statusPath = Join-Path $resultDir 'synthesis_status.txt'
if ($nativeResult -ne 0 -or -not (Test-Path -LiteralPath $statusPath)) {
    throw "Vivado synthesis did not complete. See $resultDir"
}
$status = Get-Content -LiteralPath $statusPath -Raw
if ($status -notmatch '(?m)^PASS\s*$') { throw "Synthesis checks failed. See $statusPath" }
$drc = Get-Content -LiteralPath (Join-Path $resultDir 'drc.rpt') -Raw
if ($drc -match '\|\s*Error\s*\|') {
    Write-Output 'SYNTHESIS_AND_STRUCTURE_PASS; FPGA_DRC_NOT_CLEAN (see drc.rpt)'
} else {
    Write-Output 'SYNTHESIS_AND_STRUCTURE_PASS (see drc.rpt for remaining warnings)'
}
