<#
.SYNOPSIS
    Phase 2 — .NET Migration: Apply Migration
    Bumps TFMs, updates packages, runs roslynator, validates build & tests.
    Run AFTER reviewing Phase 1 MIGRATION-REPORT.md from dotnet-analyse.ps1.
    Auto-detects source TFM and target version when -TargetVersion is omitted.

.PARAMETER RepoPath            Repository root. Default: current directory.
.PARAMETER TargetVersion       Target .NET major version (e.g. 10, 11). Default: 0 = auto-detect.
.PARAMETER DryRun              Print planned changes without modifying any files.
.PARAMETER SkipBuild           Skip final build validation.
.PARAMETER SkipTests           Skip test run after migration.
.PARAMETER SkipRoslynator      Skip roslynator automated code fixes.
.PARAMETER RunStep             Run only specific step(s) (e.g. -RunStep 6 or -RunStep 6,8).
.PARAMETER ResumeFromCheckpoint Resume from checkpoint, skipping already-completed steps.

.EXAMPLE
    # Dry run first
    .\dotnet-migrate.ps1 -RepoPath C:\repos\myapp -DryRun

    # Apply migration (auto-detect version)
    .\dotnet-migrate.ps1 -RepoPath C:\repos\myapp

    # Target a specific version
    .\dotnet-migrate.ps1 -RepoPath C:\repos\myapp -TargetVersion 11
#>
param(
    [string]$RepoPath          = (Get-Location).Path,
    [int]$TargetVersion        = 0,
    [bool]$InstallMissingTools = $true,
    [switch]$DryRun,
    [switch]$SkipBuild,
    [switch]$SkipTests,
    [switch]$SkipRoslynator,
    [int[]]$RunStep              = @(),
    [switch]$ResumeFromCheckpoint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$timestamp        = Get-Date -Format "yyyy-MM-dd HH:mm"
$repoName         = Split-Path $RepoPath -Leaf
$logLines         = [System.Collections.Generic.List[string]]::new()
$scriptRoot       = Split-Path -Parent $PSCommandPath
$toolManifestPath = Join-Path $RepoPath ".config\dotnet-tools.json"
$reportsPath      = Join-Path $RepoPath "migration-reports"
$stepsLogDir      = Join-Path $reportsPath "steps"
$checkpointPath   = Join-Path $stepsLogDir "checkpoint.json"
$script:_stepLogOffset = 0

if (-not $DryRun) {
    if (-not (Test-Path $reportsPath)) { New-Item -ItemType Directory -Path $reportsPath -Force | Out-Null }
    if (-not (Test-Path $stepsLogDir))  { New-Item -ItemType Directory -Path $stepsLogDir  -Force | Out-Null }
}

# ── Checkpoint ────────────────────────────────────────────────────────────────

$checkpoint = @{}
if ((Test-Path $checkpointPath) -and ($ResumeFromCheckpoint -or $RunStep.Count -gt 0)) {
    try {
        $loaded = Get-Content $checkpointPath -Raw | ConvertFrom-Json
        $loaded.PSObject.Properties | ForEach-Object { $checkpoint[$_.Name] = $_.Value }
    } catch { }
}

# ── Report collectors ─────────────────────────────────────────────────────────

$stepTimings     = [System.Collections.Generic.List[PSCustomObject]]::new()
$packageUpgrades = [System.Collections.Generic.List[PSCustomObject]]::new()
$securityNotices = [System.Collections.Generic.List[string]]::new()
$roslynatorStats = @{ FilesFixed = 0; Diagnostics = 0 }
$buildResult     = @{ Status = 'Skipped'; Errors = 0; Warnings = 0; Elapsed = ''; ErrorLines = @() }
$testResult      = @{ Status = 'Skipped'; Passed = 0; Failed = 0; Skipped = 0; FailedNames = @() }
$skippedSteps    = [System.Collections.Generic.List[string]]::new()

function Start-StepTimer($name) {
    return [PSCustomObject]@{ Name = $name; Start = [System.Diagnostics.Stopwatch]::StartNew() }
}
function Stop-StepTimer($t) {
    $t.Start.Stop()
    $stepTimings.Add([PSCustomObject]@{ Step = $t.Name; Elapsed = $t.Start.Elapsed.ToString('mm\:ss') })
}

# ── Logging helpers ───────────────────────────────────────────────────────────

function Log($msg)    { Write-Host "  $msg"      -ForegroundColor Cyan;    $logLines.Add("[INFO]  $msg") }
function Warn($msg)   { Write-Host "  ⚠ $msg"   -ForegroundColor Yellow;  $logLines.Add("[WARN]  $msg") }
function Err($msg)    { Write-Host "  ✖ $msg"   -ForegroundColor Red;     $logLines.Add("[ERROR] $msg") }
function Ok($msg)     { Write-Host "  ✔ $msg"   -ForegroundColor Green;   $logLines.Add("[OK]    $msg") }
function Change($msg) { Write-Host "  ➜ $msg"   -ForegroundColor Magenta; $logLines.Add("[CHG]   $msg") }

. "$scriptRoot\lib\common-tools.ps1"

function Step-ShouldRun([int]$n) {
    if ($RunStep.Count -gt 0 -and $n -notin $RunStep) { return $false }
    if ($ResumeFromCheckpoint -and $checkpoint.ContainsKey("step$n")) {
        $entry  = $checkpoint["step$n"]
        $status = if ($entry -is [hashtable]) { $entry['Status'] } else { [string]$entry.Status }
        if ($status -eq 'Completed') {
            Log "Step ${n}: Skipped (already completed per checkpoint)"
            $skippedSteps.Add("Step ${n} (resumed from checkpoint)")
            return $false
        }
    }
    return $true
}

function Save-StepLog([int]$stepNum, [string]$stepName) {
    if ($DryRun) { return }
    $fname       = "step-{0:00}-{1}.log" -f $stepNum, ($stepName -replace '[^\w]', '-')
    $stepLogPath = Join-Path $stepsLogDir $fname
    $count       = $logLines.Count - $script:_stepLogOffset
    if ($count -gt 0) {
        $logLines | Select-Object -Skip $script:_stepLogOffset | Set-Content $stepLogPath -Encoding utf8
    }
    "[STEP-DONE $stepNum $stepName $(Get-Date -Format 'HH:mm:ss')]" | Add-Content $stepLogPath -Encoding utf8
    $script:_stepLogOffset = $logLines.Count
}

function Save-Checkpoint([int]$stepNum, [string]$status, [hashtable]$data = @{}) {
    if ($DryRun) { return }
    $checkpoint["step$stepNum"] = [ordered]@{
        Status    = $status
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Data      = $data
    }
    try { $checkpoint | ConvertTo-Json -Depth 10 | Set-Content $checkpointPath -Encoding utf8 } catch { }
}

$migrationLog = @()
function Record($what, $where, $from, $to) {
    $migrationLog += [PSCustomObject]@{ What=$what; File=$where; From=$from; To=$to }
}

# ── Prerequisites ─────────────────────────────────────────────────────────────

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Err "dotnet CLI not found. Install the .NET SDK first."; exit 1
}

# ── Discover projects (needed for auto-detect) ────────────────────────────────

Log "Discovering .csproj files..."
$csprojFiles = Get-ChildItem -Path $RepoPath -Recurse -Filter "*.csproj" |
    Where-Object { $_.FullName -notmatch "\\bin\\|\\obj\\" }
if ($csprojFiles.Count -eq 0) { Err "No .csproj files found under: $RepoPath"; exit 1 }
Ok "Found $($csprojFiles.Count) project(s)"

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
Write-Host "  .NET $TargetVersion Migration — Phase 2: Apply Migration" -ForegroundColor Cyan
if ($DryRun) { Write-Host "  *** DRY RUN — no files will be modified ***" -ForegroundColor Yellow }
Write-Host "  Repo : $repoName" -ForegroundColor Cyan
Write-Host "  Date : $timestamp" -ForegroundColor Cyan
Write-Host "══════════════════════════════════════════════════════" -ForegroundColor DarkCyan
Write-Host ""

# ── Guard: Phase 1 report ─────────────────────────────────────────────────────

$reportFile = Join-Path $reportsPath "MIGRATION-REPORT.md"
if (-not (Test-Path $reportFile)) {
    Warn "migration-reports\MIGRATION-REPORT.md not found. Run Phase 1 first:"
    Warn "  .\dotnet-analyse.ps1 -RepoPath `"$RepoPath`" -TargetVersion $TargetVersion"
    $cont = Read-Host "  Continue anyway? (y/N)"
    if ($cont -ne "y") { exit 0 }
}

# ── Breaking changes catalog ──────────────────────────────────────────────────

$breakingChangesCatalog = $null
if (Test-Path $breakingChangesCatalogPath) {
    try { $breakingChangesCatalog = Get-Content $breakingChangesCatalogPath -Raw | ConvertFrom-Json -Depth 30 }
    catch { Warn "Failed to parse breaking-changes catalog: $_" }
} else { Log "No breaking-changes catalog for net${TargetVersion} — build hints unavailable" }

# ── Pre-flight: modernize report ──────────────────────────────────────────────

$modernizeReportDir = Join-Path $reportsPath "modernize-report"
if (Test-Path $modernizeReportDir) {
    $modernizeReportJson = Get-ChildItem -Path $modernizeReportDir -Recurse -Filter 'report.json' `
        -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($modernizeReportJson) {
        try {
            $modReport    = Get-Content $modernizeReportJson.FullName -Raw | ConvertFrom-Json
            $modMandatory = @($modReport.projects | ForEach-Object { $_.incidents } |
                              Where-Object { $null -ne $_ -and $_.severity -eq 'mandatory' })
            $modPotential = @($modReport.projects | ForEach-Object { $_.incidents } |
                              Where-Object { $null -ne $_ -and $_.severity -eq 'potential' })
            if ($modMandatory.Count -gt 0) {
                Write-Host ""
                Write-Host "  ⚠ Modernize: $($modMandatory.Count) MANDATORY incident(s):" -ForegroundColor Yellow
                foreach ($inc in $modMandatory) {
                    Warn "  [$($inc.ruleId)] $($inc.title) — $($inc.description)"
                    $securityNotices.Add("[modernize-mandatory] $($inc.ruleId): $($inc.title)")
                }
            }
            if ($modPotential.Count -gt 0) {
                Log "Modernize: $($modPotential.Count) potential issue(s) — see $($modernizeReportJson.FullName)"
            }
            if ($modMandatory.Count -eq 0 -and $modPotential.Count -eq 0) {
                Log "Modernize report: ✅ clean"
            }
        } catch { Log "Modernize report found but could not be parsed: $_" }
    }
}

# ── Step 1: global.json ───────────────────────────────────────────────────────

Write-Host ""
Write-Host "── Step 1: global.json ──" -ForegroundColor DarkGray
$_t1 = Start-StepTimer 'Step 1: global.json'
if (Step-ShouldRun 1) {

$globalJsonPath = Join-Path $RepoPath "global.json"
if (Test-Path $globalJsonPath) {
    $gj     = Get-Content $globalJsonPath -Raw | ConvertFrom-Json
    $oldSdk = $gj.sdk.version
    if ($oldSdk -ne $hook_SdkVersion) {
        Change "global.json: SDK $oldSdk → $hook_SdkVersion"
        Record "global.json SDK" $globalJsonPath $oldSdk $hook_SdkVersion
        if (-not $DryRun) {
            $gj.sdk.version = $hook_SdkVersion
            if ($gj.sdk.PSObject.Properties.Name -notcontains "rollForward") {
                $gj.sdk | Add-Member -MemberType NoteProperty -Name rollForward -Value "latestMinor"
            }
            $gj | ConvertTo-Json -Depth 10 | Set-Content $globalJsonPath -Encoding utf8
        }
    } else { Ok "global.json already targets SDK $hook_SdkVersion" }
} else {
    Change "Creating global.json with SDK $hook_SdkVersion"
    Record "global.json" $globalJsonPath "(new)" $hook_SdkVersion
    Write-FileContent $globalJsonPath @"
{
  "sdk": {
    "version": "$hook_SdkVersion",
    "rollForward": "latestMinor"
  }
}
"@
}
} # end Step 1

# ── Step 2: TFM bump ──────────────────────────────────────────────────────────

Stop-StepTimer $_t1
Save-StepLog 1 'global-json'
Save-Checkpoint 1 'Completed'
Write-Host ""
Write-Host "── Step 2: Target Framework Monikers ──" -ForegroundColor DarkGray
$_t2 = Start-StepTimer 'Step 2: TFM Bump'
if (Step-ShouldRun 2) {

foreach ($proj in $csprojFiles) {
    $relPath  = $proj.FullName.Replace($RepoPath, "").TrimStart('\','/')
    $content  = Get-Content $proj.FullName -Raw
    $original = $content

    foreach ($pat in $hook_SourceTfmPatterns) {
        if ($content -match $pat.Pattern) {
            $content = $content -replace $pat.Pattern, $pat.Replacement
            Change "$relPath : TFM $($pat.Pattern) → $($pat.Replacement)"
            Record "TFM" $proj.FullName $pat.Pattern $pat.Replacement
        }
    }

    if ($content -ne $original) { Write-FileContent $proj.FullName $content }
    else                        { Log "$relPath — TFM already up to date" }
}
} # end Step 2

# ── Step 3: Package versions ──────────────────────────────────────────────────

Stop-StepTimer $_t2
Save-StepLog 2 'tfm-bump'
Save-Checkpoint 2 'Completed'
Write-Host ""
Write-Host "── Step 3: Package Versions ──" -ForegroundColor DarkGray
$_t3 = Start-StepTimer 'Step 3: Package Upgrades'
if (Step-ShouldRun 3) {

$cpmFile = Join-Path $RepoPath "Directory.Packages.props"
$isCpm   = Test-Path $cpmFile

if ($isCpm) {
    Log "CPM detected — updating Directory.Packages.props via dotnet-outdated"
    if (Ensure-DotnetTool "dotnet-outdated" "dotnet-outdated-tool" "dotnet-outdated" (-not $DryRun)) {
        if (-not $DryRun) {
            try { Invoke-RepoTool 'dotnet-outdated' @('--upgrade') | ForEach-Object { Log $_ }; Ok "dotnet-outdated --upgrade complete" }
            catch { Warn "dotnet-outdated failed: $_" }
        } else { Change "[DRY RUN] Would run: dotnet-outdated --upgrade in $RepoPath" }
    } else {
        Warn "dotnet-outdated not installed — run: dotnet tool install --local dotnet-outdated-tool && dotnet tool run dotnet-outdated -- --upgrade"
    }

    $cpmContent  = Get-Content $cpmFile -Raw
    $cpmOriginal = $cpmContent
    $cpmContent  = $cpmContent -replace "(Include=`"Microsoft\.(?:Extensions|AspNetCore|EntityFrameworkCore)[^`"]*`"[^/]*Version=`")($hook_CpmVersionFloor\.\d+\.\d+)(`")", "`${1}$hook_CpmVersionTarget`${3}"
    if ($cpmContent -ne $cpmOriginal) {
        Change "Directory.Packages.props — bumped Microsoft.* source versions → $hook_CpmVersionTarget"
        Record "CPM packages" $cpmFile "source" $hook_CpmVersionTarget
        Write-FileContent $cpmFile $cpmContent
    } else { Log "Directory.Packages.props — no matching Microsoft packages found to bump" }

} else {
    Log "Non-CPM repo — updating package versions in individual .csproj files"
    if (Ensure-DotnetTool "dotnet-outdated" "dotnet-outdated-tool" "dotnet-outdated" (-not $DryRun)) {
        if (-not $DryRun) {
            try {
                $outdatedOutput = Invoke-RepoTool 'dotnet-outdated' @('--upgrade')
                $outdatedOutput | ForEach-Object { Log $_ }
                $outdatedOutput | Where-Object { $_ -match '->' } | ForEach-Object {
                    if ($_ -match '\s+(\S+)\s+([\d\.]+(?:-[\w\.]+)?)\s*->\s*([\d\.]+(?:-[\w\.]+)?)') {
                        $old  = $Matches[2]; $new = $Matches[3]
                        $kind = if ($old.Split('.')[0] -ne $new.Split('.')[0]) { 'Major' }
                                elseif ($old.Split('.')[1] -ne $new.Split('.')[1]) { 'Minor' } else { 'Patch' }
                        $packageUpgrades.Add([PSCustomObject]@{ Package=$Matches[1]; From=$old; To=$new; Kind=$kind })
                    }
                }
                Ok "dotnet-outdated --upgrade complete"
            } catch { Warn "dotnet-outdated failed: $_" }
        } else { Change "[DRY RUN] Would run: dotnet-outdated --upgrade in $RepoPath" }
    } else {
        Warn "dotnet-outdated not installed — package versions in .csproj NOT updated."
        $skippedSteps.Add('Package Upgrades (dotnet-outdated not installed)')
    }
}
} # end Step 3

# ── Steps 4+5: Version-specific checks (delegated to hooks) ───────────────────

Stop-StepTimer $_t3
Save-StepLog 3 'package-upgrades'
Save-Checkpoint 3 'Completed' @{ PackageUpgrades = @($packageUpgrades | ForEach-Object { @{ Package=$_.Package; From=$_.From; To=$_.To; Kind=$_.Kind } }) }
Write-Host ""
Write-Host "── Steps 4+5: Version-specific checks (net$TargetVersion) ──" -ForegroundColor DarkGray
$_t4 = Start-StepTimer 'Steps 4+5: Version Checks'
if (Step-ShouldRun 4) {
    hook_Invoke-VersionChecks $csprojFiles $DryRun $RepoPath
}

# ── Step 6: roslynator fix ────────────────────────────────────────────────────

Stop-StepTimer $_t4
Save-StepLog 4 'version-checks'
Save-Checkpoint 4 'Completed'
Save-Checkpoint 5 'Completed'
Write-Host ""
Write-Host "── Step 6: roslynator fix ──" -ForegroundColor DarkGray
$_t6 = Start-StepTimer 'Step 6: Roslynator'
if (Step-ShouldRun 6) {

if ($SkipRoslynator) {
    Log "roslynator skipped (-SkipRoslynator flag)"
    $skippedSteps.Add('Roslynator (-SkipRoslynator flag)')
} elseif (Ensure-DotnetTool "roslynator" "roslynator.dotnet.cli" "roslynator" (-not $DryRun)) {
    if (-not $DryRun) {
        Log "Running roslynator fix..."
        $slnxFile = Get-ChildItem -Path $RepoPath -Filter '*.slnx' -ErrorAction SilentlyContinue |
                    Where-Object { $_.DirectoryName -eq $RepoPath } | Select-Object -First 1
        $slnFile  = Get-ChildItem -Path $RepoPath -Filter '*.sln'  -ErrorAction SilentlyContinue |
                    Where-Object { $_.DirectoryName -eq $RepoPath } | Select-Object -First 1
        # roslynator 0.12.x does not support .slnx — fall back to per-project
        $roslynTargets = @(if ($slnFile) {
            [string]$slnFile.FullName
        } else {
            if ($slnxFile) { Warn "roslynator does not support .slnx — running per-project" }
            @(Get-ChildItem -Path $RepoPath -Recurse -Filter '*.csproj' -ErrorAction SilentlyContinue |
              Where-Object { $_.FullName -notmatch '\\bin\\|\\obj\\' } |
              Select-Object -ExpandProperty FullName)
        })
        $roslynTimeoutSec = 120
        $roslynHadFailure = $false
        Log "  Launching $($roslynTargets.Count) roslynator job(s) in parallel..."
        $roslynJobList = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($target in $roslynTargets) {
            Log "  roslynator fix: $(Split-Path $target -Leaf) (queued)"
            $job = Start-Job -ScriptBlock {
                param($rp, $t); Set-Location $rp; & dotnet tool run roslynator fix $t 2>&1
            } -ArgumentList $RepoPath, $target
            $roslynJobList.Add(@{ Job = $job; Target = $target })
        }
        foreach ($entry in $roslynJobList) {
            $job = $entry.Job; $target = $entry.Target
            Log "  roslynator fix: $(Split-Path $target -Leaf) (waiting, timeout: ${roslynTimeoutSec}s)"
            $null = Wait-Job -Job $job -Timeout $roslynTimeoutSec
            if ($job.State -eq 'Running') {
                Stop-Job $job; Remove-Job $job -Force
                Warn "  roslynator timed out for $(Split-Path $target -Leaf)"
                $skippedSteps.Add("Roslynator (timed out on $(Split-Path $target -Leaf))")
            } else {
                $out = @(Receive-Job $job); Remove-Job $job
                $out | ForEach-Object { Log $_ }
                if ($out | Where-Object { $_ -match 'Exception|Could not load|\berror\b|FAILED' }) {
                    $roslynHadFailure = $true
                    Warn "  roslynator reported an error for $(Split-Path $target -Leaf); build validation will continue."
                    $skippedSteps.Add("Roslynator (failed on $(Split-Path $target -Leaf))")
                }
                $out | Where-Object { $_ -match '(\d+) file' }       | ForEach-Object { if ($_ -match '(\d+) file') { $roslynatorStats.FilesFixed  += [int]$Matches[1] } }
                $out | Where-Object { $_ -match '(\d+) diagnostic' } | ForEach-Object { if ($_ -match '(\d+) diagnostic') { $roslynatorStats.Diagnostics += [int]$Matches[1] } }
            }
        }
        if ($roslynHadFailure) { Warn "roslynator fix completed with warnings" }
        else { Ok "roslynator fix complete" }
    } else { Change "[DRY RUN] Would run: roslynator fix on $($csprojFiles.Count) project(s)" }
} else {
    Warn "roslynator not installed — automated Roslyn fixes skipped."
    $skippedSteps.Add('Roslynator (not installed)')
}
} # end Step 6

# ── Step 7: BinaryFormatter check ────────────────────────────────────────────

Stop-StepTimer $_t6
Save-StepLog 6 'roslynator'
Save-Checkpoint 6 'Completed' @{ FilesFixed = $roslynatorStats.FilesFixed; Diagnostics = $roslynatorStats.Diagnostics }
Write-Host ""
Write-Host "── Step 7: BinaryFormatter check ──" -ForegroundColor DarkGray
$_t7 = Start-StepTimer 'Step 7: BinaryFormatter Check'
if (Step-ShouldRun 7) {

if ($TargetVersion -ge 10) {
    $bfHits = @(Get-ChildItem -Path $RepoPath -Recurse -Include "*.cs" -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -notmatch "\\bin\\|\\obj\\" } |
               Select-String "BinaryFormatter" -ErrorAction SilentlyContinue)
    if ($bfHits.Count -gt 0) {
        Err "BinaryFormatter usage found ($($bfHits.Count) occurrence(s)) — REMOVED in .NET 10+!"
        $bfHits | ForEach-Object { Err "  $($_.Filename):$($_.LineNumber) — $($_.Line.Trim())" }
        Warn "Replace with System.Text.Json or Newtonsoft.Json."
    } else { Ok "No BinaryFormatter usage detected" }
} else {
    Log "BinaryFormatter check not applicable for .NET $TargetVersion targets"
}
} # end Step 7

# ── Step 8: Build ─────────────────────────────────────────────────────────────

Stop-StepTimer $_t7
Save-StepLog 7 'binaryformatter'
Save-Checkpoint 7 'Completed'
Write-Host ""
Write-Host "── Step 8: Build validation ──" -ForegroundColor DarkGray
$_t8 = Start-StepTimer 'Step 8: Build'
if (Step-ShouldRun 8) {

if ($SkipBuild) {
    Warn "Build skipped (-SkipBuild flag)"
    $skippedSteps.Add('Build (-SkipBuild flag)')
} elseif ($DryRun) {
    Change "[DRY RUN] Would run: dotnet build $RepoPath --configuration Release"
} else {
    Log "Scanning transitive packages for known CVEs..."
    $transitiveVulnOutput = & dotnet list "$RepoPath" package --vulnerable --include-transitive 2>&1
    $transitiveVulnOutput | ForEach-Object { Log $_ }
    $tvFound = $false
    $transitiveVulnOutput | Where-Object { $_ -match '^\s+> ' } | ForEach-Object {
        $notice = "[transitive] $($_.Trim())"
        if ($securityNotices -notcontains $notice) { $securityNotices.Add($notice); $tvFound = $true }
    }
    if ($tvFound) {
        Warn "Transitive vulnerable package(s) found — add explicit version pins to resolve."
    } else { Log "No transitive vulnerable packages detected" }
    $transitiveVulnOutput | Where-Object { $_ -match 'NU1902|NU1903|NU1904' } | ForEach-Object {
        $securityNotices.Add([string]$_)
    }

    Log "Running dotnet build..."
    $buildSw     = [System.Diagnostics.Stopwatch]::StartNew()
    $buildOutput = & dotnet build "$RepoPath" --configuration Release --no-restore 2>&1
    $buildSw.Stop()
    $buildOutput | ForEach-Object { Log $_ }

    $buildErrors   = @($buildOutput | Where-Object { $_ -match 'error CS' })
    $buildWarnings = @($buildOutput | Where-Object { $_ -match ' warning (CS|NU|MSB|NETSDK)' })
    $buildResult.Elapsed  = $buildSw.Elapsed.ToString('mm\:ss')
    $buildResult.Errors   = $buildErrors.Count
    $buildResult.Warnings = $buildWarnings.Count

    if ($LASTEXITCODE -eq 0) {
        $buildResult.Status = 'PASSED'; Ok "Build SUCCEEDED ✔"
    } else {
        $buildResult.Status     = 'FAILED'
        $buildResult.ErrorLines = $buildErrors
        Err "Build FAILED ✖ — review errors above."
        $catalogEntries = Get-BreakingChangesForBuildOutput $breakingChangesCatalog $buildOutput
        if ($null -ne $catalogEntries -and $catalogEntries.Count -gt 0) {
            Warn "Relevant guidance from breaking-changes catalog:"
            Write-BreakingChangeHints $catalogEntries
        }
        Err "Use AI assistance (Copilot) to resolve remaining breaking changes."
    }
}
} # end Step 8

# ── Step 9: Tests ─────────────────────────────────────────────────────────────

Stop-StepTimer $_t8
Save-StepLog 8 'build'
Save-Checkpoint 8 'Completed' @{
    BuildResult = @{ Status=$buildResult.Status; Errors=$buildResult.Errors; Warnings=$buildResult.Warnings; Elapsed=$buildResult.Elapsed }
    SecurityNotices = @($securityNotices)
}
Write-Host ""
Write-Host "── Step 9: Test validation ──" -ForegroundColor DarkGray
$_t9 = Start-StepTimer 'Step 9: Tests'
if (Step-ShouldRun 9) {

if ($SkipTests) {
    Warn "Tests skipped (-SkipTests flag)"
    $skippedSteps.Add('Tests (-SkipTests flag)')
} elseif ($DryRun) {
    Change "[DRY RUN] Would run: dotnet test $RepoPath --configuration Release"
} else {
    Log "Running dotnet test..."
    $testOutput = & dotnet test "$RepoPath" --configuration Release --no-build --logger "console;verbosity=minimal" 2>&1
    $testOutput | ForEach-Object { Log $_ }

    $summaryLine = $testOutput | Where-Object { $_ -match 'Failed:\s*\d+.*Passed:\s*\d+' } | Select-Object -Last 1
    if ($summaryLine) {
        if ($summaryLine -match 'Failed:\s*(\d+)')  { $testResult.Failed  = [int]$Matches[1] }
        if ($summaryLine -match 'Passed:\s*(\d+)')  { $testResult.Passed  = [int]$Matches[1] }
        if ($summaryLine -match 'Skipped:\s*(\d+)') { $testResult.Skipped = [int]$Matches[1] }
    }
    $testResult.FailedNames = @($testOutput | Where-Object { $_ -match '^\s+X\s|Failed\s+' } | ForEach-Object { $_.Trim() })

    if ($LASTEXITCODE -eq 0) {
        $testResult.Status = 'PASSED'; Ok "All tests PASSED ✔"
    } else {
        $testResult.Status = 'FAILED'; Err "Tests FAILED ✖ — review output above."
    }
}
} # end Step 9

Stop-StepTimer $_t9
Save-StepLog 9 'tests'
Save-Checkpoint 9 'Completed' @{ TestResult = @{ Status=$testResult.Status; Passed=$testResult.Passed; Failed=$testResult.Failed; Skipped=$testResult.Skipped } }

# ── Step 10: Write migration log ──────────────────────────────────────────────

Write-Host ""
Write-Host "── Step 10: Migration log ──" -ForegroundColor DarkGray

$logPath    = Join-Path $reportsPath "MIGRATION-LOG.md"
$logContent = [System.Text.StringBuilder]::new()

$logContent.AppendLine("# Migration Log — $repoName") | Out-Null
$logContent.AppendLine("") | Out-Null
$logContent.AppendLine("> **Applied:** $timestamp  ") | Out-Null
$logContent.AppendLine(("> **Target TFM:** ``{0}``  " -f $TargetTfm)) | Out-Null
if ($DryRun) { $logContent.AppendLine("> **Mode:** DRY RUN — no changes applied  ") | Out-Null }
$logContent.AppendLine("") | Out-Null
$logContent.AppendLine("## Changes Applied") | Out-Null
$logContent.AppendLine("") | Out-Null
$logContent.AppendLine("| What | File | From | To |") | Out-Null
$logContent.AppendLine("|---|---|---|---|") | Out-Null
foreach ($entry in $migrationLog) {
    $logContent.AppendLine("| $($entry.What) | ``$($entry.File.Replace($RepoPath,'').TrimStart('\/'))`" | $($entry.From) | $($entry.To) |") | Out-Null
}
if ($migrationLog.Count -eq 0) {
    $logContent.AppendLine("_No file changes recorded (all targets already up to date or DryRun mode)._") | Out-Null
}
$logContent.AppendLine("") | Out-Null

$logContent.AppendLine("## Package Upgrades") | Out-Null
$logContent.AppendLine("") | Out-Null
if ($packageUpgrades.Count -gt 0) {
    $logContent.AppendLine("| Package | From | To | Type |") | Out-Null
    $logContent.AppendLine("|---|---|---|---|") | Out-Null
    foreach ($pkg in $packageUpgrades) {
        $badge = switch ($pkg.Kind) { 'Major' { '🔴 Major' } 'Minor' { '🟡 Minor' } default { '🟢 Patch' } }
        $logContent.AppendLine("| ``$($pkg.Package)`` | $($pkg.From) | $($pkg.To) | $badge |") | Out-Null
    }
} else {
    $logContent.AppendLine("_No package upgrades recorded._") | Out-Null
}
$logContent.AppendLine("") | Out-Null

$logContent.AppendLine("## Build Result") | Out-Null
$logContent.AppendLine("") | Out-Null
$buildIcon = switch ($buildResult.Status) { 'PASSED' { '✅' } 'FAILED' { '❌' } default { '⏭️' } }
$logContent.AppendLine("| | |") | Out-Null
$logContent.AppendLine("|---|---|") | Out-Null
$logContent.AppendLine("| **Status** | $buildIcon $($buildResult.Status) |") | Out-Null
$logContent.AppendLine("| **Errors** | $($buildResult.Errors) |") | Out-Null
$logContent.AppendLine("| **Warnings** | $($buildResult.Warnings) |") | Out-Null
$logContent.AppendLine("| **Elapsed** | $($buildResult.Elapsed) |") | Out-Null
$logContent.AppendLine("") | Out-Null
if ($buildResult.ErrorLines.Count -gt 0) {
    $logContent.AppendLine("**Compiler errors to fix:**") | Out-Null
    $logContent.AppendLine("") | Out-Null
    $logContent.AppendLine("``````") | Out-Null
    $buildResult.ErrorLines | ForEach-Object { $logContent.AppendLine([string]$_) | Out-Null }
    $logContent.AppendLine("``````") | Out-Null
    $logContent.AppendLine("") | Out-Null
}

$logContent.AppendLine("## Test Result") | Out-Null
$logContent.AppendLine("") | Out-Null
$testIcon = switch ($testResult.Status) { 'PASSED' { '✅' } 'FAILED' { '❌' } default { '⏭️' } }
$logContent.AppendLine("| | |") | Out-Null
$logContent.AppendLine("|---|---|") | Out-Null
$logContent.AppendLine("| **Status** | $testIcon $($testResult.Status) |") | Out-Null
$logContent.AppendLine("| **Passed** | $($testResult.Passed) |") | Out-Null
$logContent.AppendLine("| **Failed** | $($testResult.Failed) |") | Out-Null
$logContent.AppendLine("| **Skipped** | $($testResult.Skipped) |") | Out-Null
$logContent.AppendLine("") | Out-Null
if ($testResult.FailedNames.Count -gt 0) {
    $logContent.AppendLine("**Failed tests:**") | Out-Null
    $logContent.AppendLine("") | Out-Null
    $testResult.FailedNames | ForEach-Object { $logContent.AppendLine("- $_") | Out-Null }
    $logContent.AppendLine("") | Out-Null
}

$logContent.AppendLine("## Security Notices") | Out-Null
$logContent.AppendLine("") | Out-Null
$uniqueNotices = @($securityNotices | Sort-Object -Unique)
if ($uniqueNotices.Count -gt 0) {
    $logContent.AppendLine("> ⚠️ Vulnerable packages detected. Update direct packages or add explicit version pins for transitive ones.") | Out-Null
    $logContent.AppendLine("") | Out-Null
    $logContent.AppendLine("``````") | Out-Null
    $uniqueNotices | ForEach-Object { $logContent.AppendLine([string]$_) | Out-Null }
    $logContent.AppendLine("``````") | Out-Null
} else {
    $logContent.AppendLine("_No vulnerable packages detected._") | Out-Null
}
$logContent.AppendLine("") | Out-Null

$logContent.AppendLine("## Modernize Assess") | Out-Null
$logContent.AppendLine("") | Out-Null
$phase1Report    = Join-Path $reportsPath "MIGRATION-REPORT.md"
$modernizeRepDir = Join-Path $reportsPath "modernize-report"
if (Test-Path $phase1Report) {
    $modernizeLine = Get-Content $phase1Report | Where-Object { $_ -match 'modernize assess run' } | Select-Object -First 1
    if ($modernizeLine) {
        $logContent.AppendLine("_(Phase 1 result)_") | Out-Null
        $logContent.AppendLine("") | Out-Null
        $logContent.AppendLine("| Tool | Status |") | Out-Null
        $logContent.AppendLine("|---|---|") | Out-Null
        $logContent.AppendLine($modernizeLine) | Out-Null
    }
    if (Test-Path $modernizeRepDir) {
        $mIdx = Get-ChildItem -Path $modernizeRepDir -Filter 'index.html' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($mIdx) {
            $tick = [char]96
            $logContent.AppendLine("HTML report: $tick$($mIdx.FullName.Replace($RepoPath,'').TrimStart('\\/'))$tick") | Out-Null
        }
    }
} else {
    $logContent.AppendLine("_Phase 1 analysis not run — execute dotnet-analyse.ps1 to generate a modernize assess report._") | Out-Null
}
$logContent.AppendLine("") | Out-Null

$logContent.AppendLine("## Roslynator Summary") | Out-Null
$logContent.AppendLine("") | Out-Null
$logContent.AppendLine("| | |") | Out-Null
$logContent.AppendLine("|---|---|") | Out-Null
$logContent.AppendLine("| **Files fixed** | $($roslynatorStats.FilesFixed) |") | Out-Null
$logContent.AppendLine("| **Diagnostics resolved** | $($roslynatorStats.Diagnostics) |") | Out-Null
$logContent.AppendLine("") | Out-Null
if ($roslynatorStats.FilesFixed -eq 0 -and $roslynatorStats.Diagnostics -eq 0) {
    $tick = [char]96
    $logContent.AppendLine("> ℹ️ 0 fixed is not a failure. It means: (a) compile errors blocked roslynator (fix build first, re-run with ${tick}-RunStep 6${tick}), or (b) remaining diagnostics are code-quality suggestions that can't be auto-fixed.") | Out-Null
    $logContent.AppendLine("") | Out-Null
}

if ($skippedSteps.Count -gt 0) {
    $logContent.AppendLine("## Skipped Steps") | Out-Null
    $logContent.AppendLine("") | Out-Null
    $skippedSteps | ForEach-Object { $logContent.AppendLine("- $_") | Out-Null }
    $logContent.AppendLine("") | Out-Null
}

$logContent.AppendLine("## Step Timings") | Out-Null
$logContent.AppendLine("") | Out-Null
$logContent.AppendLine("| Step | Duration |") | Out-Null
$logContent.AppendLine("|---|---|") | Out-Null
foreach ($t in $stepTimings) { $logContent.AppendLine("| $($t.Step) | $($t.Elapsed) |") | Out-Null }
$logContent.AppendLine("") | Out-Null

$logContent.AppendLine("## Raw Script Log") | Out-Null
$logContent.AppendLine("") | Out-Null
$logContent.AppendLine("<details><summary>Expand full log</summary>") | Out-Null
$logContent.AppendLine("") | Out-Null
$logContent.AppendLine("``````") | Out-Null
$logLines | ForEach-Object { $logContent.AppendLine($_) | Out-Null }
$logContent.AppendLine("``````") | Out-Null
$logContent.AppendLine("") | Out-Null
$logContent.AppendLine("</details>") | Out-Null

if (-not $DryRun) {
    $logContent.ToString() | Out-File $logPath -Encoding utf8
    Ok "Migration log written to migration-reports\MIGRATION-LOG.md"
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "══════════════════════════════════════════════════════" -ForegroundColor DarkGreen
if ($DryRun) {
    Write-Host "  DRY RUN Complete — no files modified" -ForegroundColor Yellow
    Write-Host "  Remove -DryRun flag to apply changes" -ForegroundColor Yellow
} else {
    Write-Host "  Phase 2 Migration Complete" -ForegroundColor Green
    Write-Host "  Log : $logPath" -ForegroundColor Green
}
Write-Host "══════════════════════════════════════════════════════" -ForegroundColor DarkGreen
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Review migration-reports\MIGRATION-LOG.md for all changes applied"
Write-Host "  2. Fix any remaining build errors with AI assistance (Copilot)"
Write-Host "  3. Run smoke/integration tests"
Write-Host "  4. Update CI pipeline to use .NET $TargetVersion SDK"
Write-Host "  5. Raise PR for team review"
Write-Host ""
