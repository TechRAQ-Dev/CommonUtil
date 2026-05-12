<#
.SYNOPSIS
    Phase 1 — .NET Migration: Analyse & Report
    Scans a repo without modifying any files. Produces migration-reports/MIGRATION-REPORT.md.
    Auto-detects source TFM and target version when -TargetVersion is omitted.

.PARAMETER RepoPath       Path to the repository root. Default: current directory.
.PARAMETER TargetVersion  Target .NET major version (e.g. 10, 11). Default: 0 = auto-detect.
.PARAMETER OutputPath     Report output directory. Default: RepoPath\migration-reports.
.PARAMETER RunModernize   Run modernize assess (slow AI cloud-readiness report, opt-in).
.PARAMETER RunUpgradeAssistant   Run .NET Upgrade Assistant analyze on risky projects (slow, opt-in).

.EXAMPLE
    .\dotnet-analyse.ps1 -RepoPath C:\repos\myapp
    .\dotnet-analyse.ps1 -RepoPath C:\repos\myapp -TargetVersion 11
#>
param(
    [string]$RepoPath          = (Get-Location).Path,
    [int]$TargetVersion        = 0,
    [string]$OutputPath        = $null,
    [bool]$InstallMissingTools = $true,
    [switch]$RunModernize,
    [switch]$RunUpgradeAssistant,
    [int]$MaxParallel          = 0,
    [switch]$Fast,
    [switch]$DetailedReport,
    [string]$ProjectFilter     = '',
    [string]$AppTypeFilter     = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $OutputPath) { $OutputPath = Join-Path $RepoPath "migration-reports" }
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

$report           = [System.Text.StringBuilder]::new()
$timestamp        = Get-Date -Format "yyyy-MM-dd HH:mm"
$repoName         = Split-Path $RepoPath -Leaf
$scriptRoot       = Split-Path -Parent $PSCommandPath
$toolManifestPath = Join-Path $RepoPath ".config\dotnet-tools.json"

function Log($msg)            { Write-Host "  $msg" -ForegroundColor Cyan }
function Warn($msg)           { Write-Host "  ⚠ $msg" -ForegroundColor Yellow }
function Err($msg)            { Write-Host "  ✖ $msg" -ForegroundColor Red }
function Ok($msg)             { Write-Host "  ✔ $msg" -ForegroundColor Green }
function Change($msg)         { Write-Host "  ➜ $msg" -ForegroundColor Magenta }
function Append($line = "")   { [void]$report.AppendLine($line) }

. "$scriptRoot\lib\common-tools.ps1"

# ── Prerequisites ─────────────────────────────────────────────────────────────

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Err "dotnet CLI not found. Install the .NET SDK first."; exit 1
}

# ── Inventory ─────────────────────────────────────────────────────────────────

if ($MaxParallel -le 0) { $MaxParallel = [Math]::Min(8, [Environment]::ProcessorCount) }
Log "Building repository inventory (single scan, MaxParallel=$MaxParallel)..."
$inventory = Get-RepoInventory $RepoPath $ProjectFilter $AppTypeFilter
$csprojFiles = @($inventory.Projects)
if ($csprojFiles.Count -eq 0) { Err "No .csproj files found under: $RepoPath"; exit 1 }
Ok "Inventory: $($inventory.Counts.Projects) project(s), $($inventory.Counts.Source) source file(s), $($inventory.Counts.Config) config file(s) in $($inventory.Elapsed.ToString('mm\:ss'))"

# ── Auto-detect version ───────────────────────────────────────────────────────

if ($TargetVersion -eq 0) {
    $detected = Get-AutoDetectedVersions $csprojFiles
    if ($null -eq $detected) {
        Err "Could not detect source TFM. Specify -TargetVersion explicitly."; exit 1
    }
    $TargetVersion = $detected.Target
    Log "Auto-detected: source net$($detected.Source).0 → target net${TargetVersion}.0"
}

$hooksPath = "$scriptRoot\versions\net$TargetVersion\hooks.ps1"
if (-not (Test-Path $hooksPath)) { Err "No hooks for .NET $TargetVersion at: $hooksPath"; exit 1 }
. $hooksPath

$breakingChangesCatalogPath = "$scriptRoot\versions\net$TargetVersion\breaking-changes.json"
$TargetTfm = $hook_TargetTfm

# ── Banner ────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "══════════════════════════════════════════════════════" -ForegroundColor DarkCyan
Write-Host "  .NET $TargetVersion Migration — Phase 1: Analyse & Report" -ForegroundColor Cyan
Write-Host "  Repo : $repoName" -ForegroundColor Cyan
Write-Host "  Date : $timestamp" -ForegroundColor Cyan
Write-Host "══════════════════════════════════════════════════════" -ForegroundColor DarkCyan
Write-Host ""

# ── Tool availability ─────────────────────────────────────────────────────────

$hasModernize = $null -ne (Get-Command modernize -ErrorAction SilentlyContinue)
if (-not $hasModernize) {
    $wl = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links"
    if (Test-Path (Join-Path $wl "modernize.exe")) {
        $env:PATH = "$wl;$env:PATH"; $hasModernize = $true
        Log "modernize found via winget links — session PATH updated"
    }
}
if (-not $hasModernize) { Warn "modernize not found — install: winget install GitHub.Copilot.modernization.agent --silent" }
if (-not $RunModernize) { $hasModernize = $false }

$hasDotnetOutdated = Ensure-DotnetTool "dotnet-outdated" "dotnet-outdated-tool" "dotnet-outdated"
$hasUpgradeAssistant = $false
if ($RunUpgradeAssistant) {
    $hasUpgradeAssistant = Ensure-DotnetTool "upgrade-assistant" "upgrade-assistant" ".NET Upgrade Assistant"
}

$breakingChangesCatalog = $null
if (Test-Path $breakingChangesCatalogPath) {
    try { $breakingChangesCatalog = Get-Content $breakingChangesCatalogPath -Raw | ConvertFrom-Json -Depth 30 }
    catch { Warn "Failed to parse breaking-changes catalog: $_" }
} else { Warn "Breaking-changes catalog not found: $breakingChangesCatalogPath" }

$repoScanPaths           = $inventory.ScanPaths
$detectedBreakingChanges = @(Get-DetectedBreakingChanges $breakingChangesCatalog $repoScanPaths)

# ── CPM + global.json detection ───────────────────────────────────────────────

$cpmFile  = Join-Path $RepoPath "Directory.Packages.props"
$cpmFound = Test-Path $cpmFile
if ($cpmFound) { Ok "CPM detected — Directory.Packages.props found" }
else           { Log "CPM not detected — per-.csproj package management" }

$globalJsonPath = Join-Path $RepoPath "global.json"
$currentSdk     = "Not specified"
if (Test-Path $globalJsonPath) {
    $gj = Get-Content $globalJsonPath | ConvertFrom-Json
    if ($gj.sdk.version) { $currentSdk = $gj.sdk.version }
    Log "global.json found — SDK: $currentSdk"
}

# ── Per-project analysis ──────────────────────────────────────────────────────

$projectSummaries = @()

foreach ($proj in $csprojFiles) {
    $relPath = $proj.RelativePath
    Log "Analysing: $relPath"

    $tfms    = $proj.TFMs
    $content = $proj.RawContent
    $appType = $proj.AppType
    $issues  = 0

    # TFM gap
    if ($tfms | Where-Object { $_ -notmatch "net$TargetVersion" }) { $issues++ }

    # BinaryFormatter (removed net10+)
    if ($TargetVersion -ge 10) {
        $bfUsage = @(if ($proj.SourceFiles.Count -gt 0) {
            Select-String -Path $proj.SourceFiles -SimpleMatch "BinaryFormatter" -ErrorAction SilentlyContinue
        })
        if ($bfUsage) { $issues += 2 }
    } else { $bfUsage = @() }

    # WPF third-party controls (generic)
    $wpfThirdParty = $false
    if ($appType -eq "WPF" -and $content -match "Telerik|DevExpress|Syncfusion|ActiPro|Infragistics") {
        $wpfThirdParty = $true; $issues++
    }

    # Version-specific extra scoring from hooks
    $issues += hook_Score-ExtraIssues $proj.FullName $appType $content

    $projectSummaries += [PSCustomObject]@{
        RelPath       = $relPath
        AppType       = $appType
        TFMs          = ($tfms -join ", ")
        BFUsage       = ($bfUsage.Count -gt 0)
        WpfThirdParty = $wpfThirdParty
        PackageCount   = @($proj.PackageRefs).Count
        IsAzureFunction = $proj.IsAzureFunction
        HasSwagger     = $proj.HasSwagger
        HasAzureSdk    = $proj.HasAzureSdk
        HasB2C         = $proj.HasB2C
        IssueCount    = $issues
        Readiness     = Score-ReadinessColor $issues
    }
}

# ── modernize assess ──────────────────────────────────────────────────────────

$modernizeReportPath = Join-Path $OutputPath "modernize-report"
$modernizeConfigPath = Join-Path $scriptRoot "modernize-config.yaml"

if ($hasModernize) {
    Log "Running modernize assess..."
    if (Test-Path $modernizeReportPath) { Remove-Item $modernizeReportPath -Recurse -Force }
    try {
        Push-Location $RepoPath
        $mArgs = @('assess', '--source', '.', '--format', 'html', '--output-path', $modernizeReportPath)
        if (Test-Path $modernizeConfigPath) { $mArgs += @('--assess-config', $modernizeConfigPath) }
        & modernize @mArgs 2>&1 | ForEach-Object { Log $_ }
        Pop-Location
        $mIdx = Get-ChildItem -Path $modernizeReportPath -Filter 'index.html' -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
        if ($mIdx) { Ok "modernize assess complete — $($mIdx.FullName.Substring($RepoPath.Length).TrimStart('\/'))" }
        else       { Warn "modernize ran but index.html not found" }
    } catch {
        Pop-Location -ErrorAction SilentlyContinue
        Warn "modernize assess failed: $_"
    }
} else {
    Log "Skipping modernize assess $(if (-not $RunModernize) { '(pass -RunModernize to enable)' } else { '— not installed' })"
}

# ── .NET Upgrade Assistant analyze ────────────────────────────────────────────

$upgradeAssistantLogPath = Join-Path $OutputPath "upgrade-assistant-analyze.log"
$upgradeAssistantRun = $false
if ($RunUpgradeAssistant -and $hasUpgradeAssistant) {
    Log "Running .NET Upgrade Assistant analyze on risky projects..."
    $uaTargets = @($projectSummaries | Where-Object {
        $_.IssueCount -ge 2 -or $_.IsAzureFunction -or $_.HasAzureSdk -or $_.HasB2C
    } | Select-Object -First 25)
    if ($uaTargets.Count -eq 0) {
        $uaTargets = @($projectSummaries | Select-Object -First 10)
    }
    $uaLog = [System.Collections.Generic.List[string]]::new()
    $uaLog.Add("# .NET Upgrade Assistant analyze")
    $uaLog.Add("Generated: $timestamp")
    $uaLog.Add("Targets: $($uaTargets.Count)")
    foreach ($target in $uaTargets) {
        $targetPath = Join-Path $RepoPath $target.RelPath
        $uaLog.Add("")
        $uaLog.Add("## $($target.RelPath)")
        try {
            $uaOutput = Invoke-RepoTool 'upgrade-assistant' @('analyze', $targetPath)
            $uaOutput | ForEach-Object { $uaLog.Add([string]$_); Log $_ }
            $upgradeAssistantRun = $true
        } catch {
            $msg = "Upgrade Assistant analyze failed for $($target.RelPath): $_"
            $uaLog.Add($msg)
            Warn $msg
        }
    }
    $uaLog | Set-Content $upgradeAssistantLogPath -Encoding utf8
    if ($upgradeAssistantRun) { Ok ".NET Upgrade Assistant analysis saved to upgrade-assistant-analyze.log" }
} else {
    Log "Skipping .NET Upgrade Assistant analyze $(if (-not $RunUpgradeAssistant) { '(pass -RunUpgradeAssistant to enable)' } else { '— not installed' })"
}

# ── CVE scan + dotnet-outdated in parallel ────────────────────────────────────

Log "Running NuGet vulnerability scan..."
$cveJob = Start-Job -ScriptBlock {
    param($rp); Set-Location $rp; & dotnet list package --vulnerable 2>&1
} -ArgumentList $RepoPath

$outdatedPath = Join-Path $OutputPath "outdated-packages.json"
$outdatedData = $null
$odJob        = $null
if ($hasDotnetOutdated) {
    Log "Running dotnet-outdated..."
    $odJob = Start-Job -ScriptBlock {
        param($rp, $op); & dotnet-outdated $rp --output $op --output-format json 2>&1
    } -ArgumentList $RepoPath, $outdatedPath
}

$null = Wait-Job $cveJob -Timeout 90
if ($cveJob.State -eq 'Running') {
    Stop-Job $cveJob; Remove-Job $cveJob -Force
    Warn "CVE scan timed out (90s) — skipped"
} else {
    try {
        $cveOut = Receive-Job $cveJob -ErrorAction SilentlyContinue
        Remove-Job $cveJob -Force
        $cveOut | ForEach-Object { Log $_ }
        if ($cveOut | Where-Object { $_ -match 'has the following vulnerable' }) {
            Warn "Vulnerable packages detected — update before migrating"
        } else { Ok "No vulnerable packages detected" }
    } catch { Warn "CVE scan failed: $_" }
}

if ($odJob) {
    $null = Wait-Job $odJob -Timeout 90
    if ($odJob.State -eq 'Running') {
        Stop-Job $odJob; Remove-Job $odJob -Force; Warn "dotnet-outdated timed out — skipped"
    } else {
        try {
            Receive-Job $odJob -ErrorAction SilentlyContinue | ForEach-Object { Log $_ }
            Remove-Job $odJob -Force
            if (Test-Path $outdatedPath) {
                try { $outdatedData = Get-Content $outdatedPath -Raw | ConvertFrom-Json } catch {}
            }
            Ok "dotnet-outdated complete — saved to outdated-packages.json"
        } catch { Warn "dotnet-outdated failed: $_" }
    }
} else { Warn "Skipping dotnet-outdated (not installed)" }

# ── Build MIGRATION-REPORT.md ─────────────────────────────────────────────────

Append "# Migration Report — $repoName"
Append ""
Append "> **Generated:** $timestamp  "
Append ("> **Target TFM:** ``$TargetTfm``  ")
Append "> **Phase:** 1 — Analyse (no files modified)  "
Append ""
Append "---"
Append ""
Append "## Summary"
Append ""
Append "| Field | Value |"
Append "|---|---|"
Append "| Repo | $repoName |"
Append "| Total projects | $($csprojFiles.Count) |"
Append "| Source files inventoried | $($inventory.Counts.Source) |"
Append "| Config/deployment files inventoried | $($inventory.Counts.Config) |"
Append "| Inventory time | $($inventory.Elapsed.ToString('mm\:ss')) |"
Append "| Azure Functions projects | $(@($projectSummaries | Where-Object IsAzureFunction).Count) |"
Append "| Swagger/OpenAPI projects | $(@($projectSummaries | Where-Object HasSwagger).Count) |"
Append "| Azure SDK projects | $(@($projectSummaries | Where-Object HasAzureSdk).Count) |"
Append "| B2C/auth projects | $(@($projectSummaries | Where-Object HasB2C).Count) |"
Append "| CPM enabled | $(if ($cpmFound) { 'Yes' } else { 'No' }) |"
Append "| global.json SDK | $currentSdk |"
Append "| local tool manifest | $(if (Test-Path $toolManifestPath) { '.config/dotnet-tools.json' } else { 'Not created' }) |"
Append "| modernize assess run | $(if ($hasModernize) { 'Yes' } elseif (-not $RunModernize) { 'Skipped (use -RunModernize)' } else { 'Skipped (not installed)' }) |"
Append "| Upgrade Assistant analyze run | $(if ($upgradeAssistantRun) { 'Yes' } elseif (-not $RunUpgradeAssistant) { 'Skipped (use -RunUpgradeAssistant)' } else { 'Skipped (not installed or failed)' }) |"
Append "| dotnet-outdated run | $(if ($hasDotnetOutdated) { 'Yes' } else { 'Skipped (not installed)' }) |"
Append "| NuGet CVE scan run | Yes |"
Append "| breaking changes catalog | $(if ($null -ne $breakingChangesCatalog) { 'Loaded' } else { 'Missing' }) |"
Append ""
Append "---"
Append ""
Append "## Project Inventory & Readiness"
Append ""
Append "| Project | App Type | Current TFM(s) | Issues | Readiness |"
Append "|---|---|---|---|---|"
foreach ($p in $projectSummaries) {
    Append ('| `{0}` | {1} | `{2}` | {3} | {4} |' -f $p.RelPath, $p.AppType, $p.TFMs, $p.IssueCount, $p.Readiness)
}

Append ""
Append "---"
Append ""
Append "## Flagged Issues"
Append ""

$redItems   = @($projectSummaries | Where-Object { $_.IssueCount -ge 5 })
$amberItems = @($projectSummaries | Where-Object { $_.IssueCount -ge 2 -and $_.IssueCount -lt 5 })

if ($redItems.Count -gt 0) {
    Append "### 🔴 High Effort (must resolve before migration)"
    Append ""
    foreach ($p in $redItems) {
        Append ('**`{0}`**' -f $p.RelPath)
        if ($p.BFUsage)       { Append "- ⚠️ \`BinaryFormatter\` usage — **removed in .NET 10+**. Replace with \`System.Text.Json\`." }
        if ($p.WpfThirdParty) { Append "- ⚠️ WPF third-party controls — verify vendor .NET $TargetVersion support." }
        Append ""
    }
}

if ($amberItems.Count -gt 0) {
    Append "### 🟡 Medium Effort (review before migration)"
    Append ""
    foreach ($p in $amberItems) {
        Append ('**`{0}`**' -f $p.RelPath)
        if ($p.BFUsage)       { Append "- ⚠️ \`BinaryFormatter\` usage detected." }
        if ($p.WpfThirdParty) { Append "- ⚠️ WPF third-party controls detected." }
        Append ""
    }
}

if ($redItems.Count -eq 0 -and $amberItems.Count -eq 0) {
    Append "✅ No high or medium effort issues detected. Repo looks ready for Phase 2."
    Append ""
}

Append "---"
Append ""
Append "## Breaking Changes Guidance"
Append ""
Append "_Source: versions/net$TargetVersion/breaking-changes.json_"
Append ""

if ($detectedBreakingChanges.Count -gt 0) {
    foreach ($match in $detectedBreakingChanges) {
        $entry = $match.Entry
        Append ('### [{0}] {1}' -f $entry.id, $entry.title)
        Append ('- Severity: **{0}**' -f $entry.severity)
        Append ('- Area: {0}' -f $entry.area)
        Append ('- Why it matters: {0}' -f $entry.description)
        Append ('- Suggested fix: {0}' -f $entry.fix.summary)
        Append ('- Matched patterns: `{0}`' -f (($match.MatchedPatterns -join '`, `')))
        if (@($entry.references).Count -gt 0) { Append ('- Reference: {0}' -f $entry.references[0]) }
        Append ""
    }
} else {
    Append '_No breaking-change patterns matched in this repo._'
    Append ""
}

Append "---"
Append ""
Append "## Outdated Packages"
Append ""

if ($null -ne $outdatedData -and $outdatedData.Projects) {
    $wroteOutdatedPackage = $false
    foreach ($proj in $outdatedData.Projects) {
        $pkgs = @(foreach ($tf in @($proj.TargetFrameworks)) {
            foreach ($dep in @($tf.Dependencies)) { if ($null -ne $dep) { $dep } }
        })
        if ($pkgs.Count -gt 0) {
            $wroteOutdatedPackage = $true
            Append ('### `{0}`' -f $proj.Name)
            Append ""
            Append '| Package | Current | Latest |'
            Append '|---|---|---|'
            foreach ($pkg in $pkgs) {
                Append ('| {0} | {1} | {2} |' -f $pkg.Name, $pkg.ResolvedVersion, $pkg.LatestVersion)
            }
            Append ""
        }
    }
    if (-not $wroteOutdatedPackage) {
        Append '_No outdated packages detected._'
        Append ""
    }
} else {
    Append "_$(if ($hasDotnetOutdated) { 'No outdated packages detected.' } else { 'dotnet-outdated not available.' })_"
    Append ""
}

Append "---"
Append ""
Append "## Next Steps"
Append ""
Append "1. Resolve all 🔴 Red items before proceeding."
Append "2. BinaryFormatter: replace with ``System.Text.Json`` or ``Newtonsoft.Json``."
Append "3. Azure Functions in-process: port to isolated worker model."
Append "4. Review breaking-changes guidance above."
Append "5. Run Phase 2:"
Append ""
Append '```powershell'
Append ('.github/skills/net-migration/scripts/dotnet-migrate.ps1 -RepoPath "{0}" -TargetVersion {1}' -f $RepoPath, $TargetVersion)
Append '```'
Append ""
Append "---"
Append "_Generated by dotnet-analyse.ps1 — Phase 1 only. No files modified._"

# ── Write report ──────────────────────────────────────────────────────────────

$reportFile = Join-Path $OutputPath "MIGRATION-REPORT.md"
$report.ToString() | Out-File $reportFile -Encoding utf8

$jsonReportPath = Join-Path $OutputPath "MIGRATION-REPORT.json"
$jsonReport = [PSCustomObject]@{
    GeneratedAt = $timestamp
    Repo        = $repoName
    TargetVersion = $TargetVersion
    TargetTfm   = $TargetTfm
    Inventory   = [PSCustomObject]@{
        Counts  = $inventory.Counts
        Elapsed = $inventory.Elapsed.ToString()
    }
    Tools       = [PSCustomObject]@{
        ModernizeRun = [bool]$hasModernize
        UpgradeAssistantRun = [bool]$upgradeAssistantRun
        DotnetOutdatedRun = [bool]$hasDotnetOutdated
        UpgradeAssistantLog = $(if ($upgradeAssistantRun) { $upgradeAssistantLogPath } else { $null })
    }
    Projects    = $projectSummaries
    BreakingChanges = @($detectedBreakingChanges | ForEach-Object {
        [PSCustomObject]@{
            Id = $_.Entry.id
            Title = $_.Entry.title
            Severity = $_.Entry.severity
            Area = $_.Entry.area
            MatchedPatterns = $_.MatchedPatterns
        }
    })
}
$jsonReport | ConvertTo-Json -Depth 20 | Out-File $jsonReportPath -Encoding utf8

if ($DetailedReport) {
    $issuesPath = Join-Path $OutputPath "issues"
    if (-not (Test-Path $issuesPath)) { New-Item -ItemType Directory -Path $issuesPath -Force | Out-Null }
    @($projectSummaries | Group-Object AppType | ForEach-Object {
        [PSCustomObject]@{ AppType = $_.Name; Count = $_.Count; Projects = @($_.Group.RelPath) }
    }) | ConvertTo-Json -Depth 10 | Out-File (Join-Path $issuesPath "app-types.json") -Encoding utf8
    @($projectSummaries | Where-Object { $_.IssueCount -gt 0 }) |
        ConvertTo-Json -Depth 10 | Out-File (Join-Path $issuesPath "projects-with-issues.json") -Encoding utf8
}

Write-Host ""
Write-Host "══════════════════════════════════════════════════════" -ForegroundColor DarkGreen
Write-Host "  Phase 1 Complete" -ForegroundColor Green
Write-Host "  Report: $reportFile" -ForegroundColor Green
Write-Host "  JSON  : $jsonReportPath" -ForegroundColor Green
if ($hasDotnetOutdated) { Write-Host "  Pkgs  : $outdatedPath" -ForegroundColor Green }
Write-Host "══════════════════════════════════════════════════════" -ForegroundColor DarkGreen
Write-Host ""
Write-Host "Review migration-reports\MIGRATION-REPORT.md, then run dotnet-migrate.ps1" -ForegroundColor Yellow
