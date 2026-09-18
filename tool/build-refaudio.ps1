[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$vswhereCandidates = @(
    (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe')
)
$vswhere = $vswhereCandidates | Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1
if (-not $vswhere) {
    throw 'Visual Studio Installer (vswhere.exe) was not found.'
}

$vsPath = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if (-not $vsPath) {
    throw 'A Visual Studio installation with the x64 C++ toolchain was not found.'
}

$devShellModule = Join-Path $vsPath 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll'
Import-Module $devShellModule
Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation `
    -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null

$source = Join-Path $PSScriptRoot '..\native\REFAudio.cpp'
$output = Join-Path $PSScriptRoot '..\reframework\plugins\REFAudio.dll'
$object = Join-Path $env:TEMP 'REFAudio.obj'

try {
    & cl.exe /nologo /std:c++17 /utf-8 /EHsc /O2 /MT /LD $source `
        "/Fo$object" "/Fe$output" /link /INCREMENTAL:NO
    if ($LASTEXITCODE -ne 0) {
        throw "REFAudio compilation failed with exit code $LASTEXITCODE."
    }
} finally {
    Remove-Item -LiteralPath $object -Force -ErrorAction SilentlyContinue
}

Write-Host "Built $output"
