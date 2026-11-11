# Builds Resonata for Windows and its installers, one for each processor.
#   .\build.ps1             tests, then both Setups into out\:
#                           Resonata-Setup-<v>.exe (x64) and Resonata-ARM64-Setup-<v>.exe
#   .\build.ps1 -SkipTests  the same without the tests
#   .\build.ps1 -Arch arm64 only one of them (x64 or arm64)
#   .\build.ps1 -TestInstall  also a variant that installs without admin rights,
#                             for trying upgrade and uninstall. Never publish it.
param(
    [switch]$SkipTests,
    [switch]$TestInstall,
    [string]$VersionOverride,
    [ValidateSet('all', 'x64', 'arm64')]
    [string]$Arch = 'all'
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
$script = Join-Path $here 'installer\Resonata.iss'
$architectures = if ($Arch -eq 'all') { @('x64', 'arm64') } else { @($Arch) }

if (-not $SkipTests) {
    Invoke-Checked dotnet @('run', '--project', (Join-Path $here 'tests\Resonata.Tests.csproj'), '-c', 'Release')
}

$iscc = Find-Iscc
foreach ($cpu in $architectures) {
    # An ARM64 PC can run the x64 build too, emulated; its own build runs natively.
    $publish = Join-Path $here "out\publish-$cpu"
    if (Test-Path $publish) { Remove-Item -Recurse -Force $publish }
    Invoke-Checked dotnet @('publish', $project, '-c', 'Release', '-r', "win-$cpu", '--self-contained', 'true',
        '-p:PublishReadyToRun=true', "-p:Version=$version", '-o', $publish, '-v', 'q', '-nologo')

    Invoke-Checked $iscc @('/Q', "/DAppVersion=$version", "/DPublishDir=$publish", "/DArch=$cpu", $script)
    if ($TestInstall) {
        Invoke-Checked $iscc @('/Q', "/DAppVersion=$version", "/DPublishDir=$publish", "/DArch=$cpu", '/DTestInstall', $script)
    }
    $name = if ($cpu -eq 'arm64') { "Resonata-ARM64-Setup-$version.exe" } else { "Resonata-Setup-$version.exe" }
    Write-Host "Built $here\out\$name"
}
