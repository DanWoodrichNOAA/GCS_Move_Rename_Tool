[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
    [string]$Version = '1.0.0.0'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
$sourcePath = Join-Path $projectRoot 'GcsMoveTool.ps1'
$outputDirectory = Join-Path $projectRoot 'dist'
$outputPath = Join-Path $outputDirectory 'GcsMoveTool.exe'
$temporaryOutputPath = Join-Path $outputDirectory "GcsMoveTool-$([Guid]::NewGuid().ToString('N')).exe"

$compiler = Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue
if ($null -eq $compiler) {
    $installedModule = Get-InstalledModule -Name ps2exe -ErrorAction SilentlyContinue
    if ($null -ne $installedModule) {
        $moduleManifest = Join-Path $installedModule.InstalledLocation 'ps2exe.psd1'
        Import-Module $moduleManifest -Force
        $compiler = Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue
    }
}

if ($null -eq $compiler) {
    throw 'PS2EXE is required. Install it for the current user with: Install-Module ps2exe -Scope CurrentUser'
}

if (-not (Test-Path $outputDirectory)) {
    [void](New-Item -ItemType Directory -Path $outputDirectory)
}

try {
    Invoke-ps2exe `
        -InputFile $sourcePath `
        -OutputFile $temporaryOutputPath `
        -NoConsole `
        -STA `
        -x64 `
        -DPIAware `
        -Title 'GCS Move / Rename' `
        -Description 'Move or rename Google Cloud Storage objects without downloading them.' `
        -Product 'GCS Move / Rename' `
        -Version $Version

    if (-not (Test-Path $temporaryOutputPath)) {
        throw 'PS2EXE did not produce an executable.'
    }

    if (Test-Path $outputPath) {
        [System.IO.File]::Copy($temporaryOutputPath, $outputPath, $true)
    }
    else {
        Move-Item -LiteralPath $temporaryOutputPath -Destination $outputPath
    }
}
finally {
    if (Test-Path $temporaryOutputPath) {
        Remove-Item -LiteralPath $temporaryOutputPath -Force
    }
}

Write-Host "Built $outputPath"