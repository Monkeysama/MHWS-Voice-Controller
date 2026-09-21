[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v\d+\.\d+\.\d+$')]
    [string]$Tag,

    [string]$OutputDirectory = "dist"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# 发布脚本只打包运行时白名单；临时目录由脚本独占，绝不读取或覆盖用户配置。
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $repositoryRoot "reframework/reff/plugins/voice-controller/manifest.json"
$packagePath = Join-Path $repositoryRoot "web/voice-controller/package.json"
$releaseVersion = $Tag.Substring(1)

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$webPackage = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
if ([string]$manifest.version -ne $releaseVersion) {
    throw "REFF manifest version '$($manifest.version)' does not match tag '$Tag'."
}
if ([string]$webPackage.version -ne $releaseVersion) {
    throw "Web package version '$($webPackage.version)' does not match tag '$Tag'."
}

$runtimeFiles = @(
    "reframework/autorun/VoiceController.lua",
    "reframework/autorun/VoiceController",
    "reframework/data/REFAudio/REFAudio_BASS.dll",
    "reframework/plugins/REFAudio.dll",
    "reframework/reff/plugins/voice-controller"
)

$missingFiles = @()
foreach ($relativePath in $runtimeFiles) {
    $sourcePath = Join-Path $repositoryRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        $missingFiles += $relativePath
    }
}
if ($missingFiles.Count -gt 0) {
    throw "Release inputs are missing: $($missingFiles -join ', ')"
}

$resolvedOutput = if ([IO.Path]::IsPathRooted($OutputDirectory)) {
    [IO.Path]::GetFullPath($OutputDirectory)
} else {
    [IO.Path]::GetFullPath((Join-Path $repositoryRoot $OutputDirectory))
}
$archiveName = "MHWS-Voice-Controller-$Tag.zip"
$archivePath = Join-Path $resolvedOutput $archiveName
$stagingRoot = Join-Path ([IO.Path]::GetTempPath()) ("mhws-voice-controller-release-" + [Guid]::NewGuid().ToString("N"))

try {
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

    foreach ($relativePath in $runtimeFiles) {
        $sourcePath = Join-Path $repositoryRoot $relativePath
        $destinationPath = Join-Path $stagingRoot $relativePath
        $destinationParent = Split-Path -Parent $destinationPath
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Recurse -Force
    }

    # 防止未来误把运行时生成物加入白名单目录后带进发布包。
    $forbiddenNames = @(
        "replacement.json",
        "saved_events.json",
        "audio_probe.log",
        "diagnostics.json",
        "recent.json",
        "audio_catalog.json"
    )
    $forbiddenFiles = @(Get-ChildItem -LiteralPath $stagingRoot -Recurse -File | Where-Object {
        $_.Name -in $forbiddenNames -or $_.Extension -in @(".tmp", ".bak")
    })
    if ($forbiddenFiles.Count -gt 0) {
        $forbiddenPaths = @($forbiddenFiles | ForEach-Object { $_.FullName })
        throw "Forbidden user or runtime data entered the release: $($forbiddenPaths -join ', ')"
    }

    New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null
    if (Test-Path -LiteralPath $archivePath) {
        [IO.File]::Delete($archivePath)
    }
    Compress-Archive -Path (Join-Path $stagingRoot "*") -DestinationPath $archivePath -CompressionLevel Optimal

    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    $checksumPath = "$archivePath.sha256"
    [IO.File]::WriteAllText(
        $checksumPath,
        "$archiveHash  $archiveName`n",
        [Text.UTF8Encoding]::new($false))

    Write-Output $archivePath
    Write-Output $checksumPath
} finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}
