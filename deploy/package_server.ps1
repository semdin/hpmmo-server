#!/usr/bin/env powershell
<#
Packages a deployable HPMMO server release.

Contents: world/ services/ contracts/ db/ deploy/ tests/ README.md
Excluded by construction: assets/candidates, client visuals, docs previews,
.git, .godot caches, any *.db (account data must never ship - plan.md Phase 3
exit check "Server packages contain no unnecessary visual assets or account
database files").

Output: <repo>\dist\hpmmo-server-<stamp>.tar.gz + a printed contents summary.
#>
param([string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist'))
$ErrorActionPreference = 'Stop'
$serverRoot = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stageName = "hpmmo-server-$stamp"
$stage = Join-Path $OutDir $stageName
New-Item -ItemType Directory -Force $OutDir | Out-Null
New-Item -ItemType Directory -Force $stage | Out-Null

$include = @('world', 'services', 'contracts', 'db', 'deploy', 'tests')
try {
    foreach ($item in $include) {
        $src = Join-Path $serverRoot $item
        if (-not (Test-Path $src)) { throw "missing $item in server repo" }
        Copy-Item -Recurse -Force $src (Join-Path $stage $item)
    }
    Copy-Item -Force (Join-Path $serverRoot 'README.md') (Join-Path $stage 'README.md')

    # Prune anything that must never ship.
    Get-ChildItem -Recurse -Force $stage -Directory |
        Where-Object { $_.Name -in @('.godot', '__pycache__', '.git') } |
        Remove-Item -Recurse -Force
    Get-ChildItem -Recurse -Force $stage -File |
        Where-Object { $_.Extension -in @('.db', '.pyc', '.log') } |
        Remove-Item -Force

    # Exit-check enforcement: no account databases anywhere; no client visual
    # payloads (candidates/previews/branding) at the package ROOT - the world's
    # own assets under world/assets are server content and must ship.
    $bad = @()
    $bad += Get-ChildItem -Recurse -Force $stage -File | Where-Object { $_.Extension -eq '.db' }
    $bad += Get-ChildItem -Recurse -Force $stage -Directory | Where-Object { $_.Name -eq 'candidates' }
    foreach ($rootForbidden in @('assets', 'docs', 'launcher_cpp', 'tools')) {
        $p = Join-Path $stage $rootForbidden
        if (Test-Path $p) { $bad += Get-Item $p }
    }
    if ($bad) {
        throw ("package contains forbidden entries:`n" + (($bad | ForEach-Object { $_.FullName }) -join "`n"))
    }
    if (-not (Test-Path (Join-Path $stage 'world\assets\models'))) {
        throw 'world assets missing from the package - run dev.ps1 sync-world first'
    }

    $tar = Join-Path $OutDir "$stageName.tar.gz"
    Push-Location $stage
    tar -czf $tar *
    Pop-Location
}
finally {
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
}

$size = (Get-Item $tar).Length
Write-Output "wrote $tar ($([math]::Round($size / 1MB, 1)) MB)"
Write-Output 'contents:'
tar -tzf $tar | ForEach-Object { $_ } | Group-Object { ($_ -split '/')[0] } |
    ForEach-Object { "  {0}/  ({1} entries)" -f $_.Name, $_.Count }
