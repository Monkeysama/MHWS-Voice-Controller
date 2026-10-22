# 使用本机 x64 编译器和真实 BASS 做独立验收；只操作进程专属临时目录，不连接游戏。
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) { throw 'No x64 C++ toolchain' }
Import-Module (Join-Path $vsPath 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null
$testDirectory = Join-Path $env:TEMP ('refaudio-run-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDirectory | Out-Null
$testExe = Join-Path $testDirectory 'test-refaudio.exe'
$testObj = Join-Path $testDirectory 'test-refaudio.obj'
& cl.exe /nologo /std:c++17 /utf-8 /EHsc /O2 /MT (Join-Path $PSScriptRoot 'test-refaudio-native.cpp') "/Fo$testObj" "/Fe$testExe" /link /INCREMENTAL:NO
if ($LASTEXITCODE -ne 0) { throw 'Native test compilation failed' }
Push-Location (Join-Path $PSScriptRoot '..')
try {
    & $testExe
    if ($LASTEXITCODE -ne 0) { throw "Native tests failed: $LASTEXITCODE (artifacts: $testDirectory)" }
} finally { Pop-Location }
