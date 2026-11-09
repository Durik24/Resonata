# Builds Resonata for Windows and its installer.
#   .\build.ps1             tests, publish, Setup into out\
#   .\build.ps1 -SkipTests  the same without the tests
#   .\build.ps1 -TestInstall  also a variant that installs without admin rights,
#                             for trying upgrade and uninstall. Never publish it.
param(
    [switch]$SkipTests,
    [switch]$TestInstall,
    [string]$VersionOverride
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

function Find-Iscc {
    $inPath = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($inPath) { return $inPath.Source }
    $candidates = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
    )
    foreach ($candidate in $candidates) { if (Test-Path $candidate) { return $candidate } }
    throw 'Inno Setup 6 not found. Install it: winget install --id JRSoftware.InnoSetup -e'
}

function Invoke-Checked {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe failed with exit code $LASTEXITCODE" }
}

$project = Join-Path $here 'src\Resonata.csproj'
$version = if ($VersionOverride) { $VersionOverride } else { ([xml](Get-Content $project)).Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1 }
$publish = Join-Path $here 'out\publish'

if (-not $SkipTests) {
    Invoke-Checked dotnet @('run', '--project', (Join-Path $here 'tests\Resonata.Tests.csproj'), '-c', 'Release')
}

if (Test-Path $publish) { Remove-Item -Recurse -Force $publish }
Invoke-Checked dotnet @('publish', $project, '-c', 'Release', '-r', 'win-x64', '--self-contained', 'true',
    '-p:PublishReadyToRun=true', "-p:Version=$version", '-o', $publish, '-v', 'q', '-nologo')

$iscc = Find-Iscc
$script = Join-Path $here 'installer\Resonata.iss'
Invoke-Checked $iscc @('/Q', "/DAppVersion=$version", "/DPublishDir=$publish", $script)
if ($TestInstall) {
    Invoke-Checked $iscc @('/Q', "/DAppVersion=$version", "/DPublishDir=$publish", '/DTestInstall', $script)
}

Write-Host "Built $here\out\Resonata-Setup-$version.exe"
