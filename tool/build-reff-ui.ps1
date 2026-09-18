param(
    [string]$GameReframeworkRoot = 'C:\Steam\steamapps\common\MonsterHunterWilds\reframework',
    [switch]$SkipDeploy
)

$ErrorActionPreference = 'Stop'

# 构建并部署 VoiceController REFF 页面；只拥有本项目插件目录，不修改 REFF Shell 或其他插件。
$repoRoot = Split-Path -Parent $PSScriptRoot
$webRoot = Join-Path $repoRoot 'web\voice-controller'
$sourcePlugin = Join-Path $repoRoot 'reframework\reff\plugins\voice-controller'
$resolvedGameRoot = [IO.Path]::GetFullPath($GameReframeworkRoot).TrimEnd('\')
$targetPluginsRoot = Join-Path $resolvedGameRoot 'reff\plugins'
$targetPlugin = Join-Path $targetPluginsRoot 'voice-controller'

if (-not (Test-Path -LiteralPath $webRoot -PathType Container)) { throw "REFF UI 源码目录不存在：$webRoot" }
if (-not (Test-Path -LiteralPath $resolvedGameRoot -PathType Container)) { throw "游戏 REFramework 目录不存在：$resolvedGameRoot" }
if (-not ([IO.Path]::GetFullPath($targetPlugin).StartsWith([IO.Path]::GetFullPath($targetPluginsRoot), [StringComparison]::OrdinalIgnoreCase))) {
    throw "插件部署路径越界：$targetPlugin"
}

Push-Location $webRoot
try {
    & corepack pnpm@11.19.0 install --frozen-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'REFF UI 依赖安装失败' }
    & corepack pnpm@11.19.0 run typecheck
    if ($LASTEXITCODE -ne 0) { throw 'REFF UI 类型检查失败' }
    & corepack pnpm@11.19.0 run build
    if ($LASTEXITCODE -ne 0) { throw 'REFF UI 构建失败' }
} finally {
    Pop-Location
}

if (-not $SkipDeploy) {
    [IO.Directory]::CreateDirectory($targetPluginsRoot) | Out-Null
    if (Test-Path -LiteralPath $targetPlugin) { Remove-Item -LiteralPath $targetPlugin -Recurse -Force }
    Copy-Item -LiteralPath $sourcePlugin -Destination $targetPlugin -Recurse -Force
    [DateTime]::UtcNow.ToString('o') | Set-Content -LiteralPath (Join-Path $targetPlugin '.reff-dev-version') -Encoding utf8
}

Write-Host "VoiceController REFF UI 构建完成：$sourcePlugin"
if (-not $SkipDeploy) { Write-Host "已部署：$targetPlugin" }
