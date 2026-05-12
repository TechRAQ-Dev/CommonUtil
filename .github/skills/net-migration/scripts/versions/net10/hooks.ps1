# hooks.ps1 — .NET 10 migration hooks
# Dot-sourced by dotnet-analyse.ps1 and dotnet-migrate.ps1
# Defines all net10-specific values and step overrides.

$hook_TargetTfm        = "net10.0"
$hook_TargetWindowsTfm = "net10.0-windows"
$hook_SdkVersion       = "10.0.100"

# TFM replacement patterns applied in Step 2 (order matters — longer patterns first)
$hook_SourceTfmPatterns = @(
    @{ Pattern = 'net8\.0-windows';  Replacement = $hook_TargetWindowsTfm },
    @{ Pattern = 'net9\.0-windows';  Replacement = $hook_TargetWindowsTfm },
    @{ Pattern = 'net8\.0';          Replacement = $hook_TargetTfm },
    @{ Pattern = 'net9\.0';          Replacement = $hook_TargetTfm }
)

# CPM (Directory.Packages.props) Microsoft.* package version bump
$hook_CpmVersionFloor  = '[89]'      # regex: source major version(s)
$hook_CpmVersionTarget = '10.0.0'   # replacement version string

# ── hook_Invoke-VersionChecks ─────────────────────────────────────────────────
# Called from Steps 4+5 of dotnet-migrate.ps1.
# Handles Azure Functions isolated-worker enforcement and WPF TFM correction.

function hook_Invoke-VersionChecks($csprojFiles, $DryRunFlag, $RepoRootPath) {
    # ── Step 4: Azure Functions ────────────────────────────────────────────────
    $funcProjects = @($csprojFiles | Where-Object {
        (Get-Content $_.FullName -Raw) -match "Microsoft\.Azure\.Functions\.Worker|AzureFunctions"
    })

    foreach ($fp in $funcProjects) {
        $relPath = $fp.FullName.Replace($RepoRootPath, "").TrimStart('\','/')
        $content = Get-Content $fp.FullName -Raw

        if ($content -notmatch "Microsoft\.Azure\.Functions\.Worker" -and
            $content -match "Microsoft\.Azure\.WebJobs") {
            Err "$relPath — In-process model detected. Port to isolated worker before migrating."
            continue
        }

        $new = $content
        $new = $new -replace '(Microsoft\.Azure\.Functions\.Worker"[^/]*Version=")1\.(\d+\.\d+)(")', '${1}2.0.0${3}'
        $new = $new -replace '(Microsoft\.Azure\.Functions\.Worker\.Sdk"[^/]*Version=")1\.(\d+\.\d+)(")', '${1}2.0.0${3}'
        if ($new -ne $content) {
            Change "$relPath — Azure Functions worker packages updated to 2.x"
            Write-FileContent $fp.FullName $new
        } else { Ok "$relPath — Azure Functions packages current" }

        $hostJson = Join-Path (Split-Path $fp.FullName) "host.json"
        if (Test-Path $hostJson) {
            $hj = Get-Content $hostJson -Raw
            if ($hj -notmatch '"extensionBundle"') {
                if (-not $DryRunFlag) {
                    try {
                        $hjObj = $hj | ConvertFrom-Json
                        $hjObj | Add-Member -NotePropertyName 'extensionBundle' -NotePropertyValue (
                            [PSCustomObject]@{ id = 'Microsoft.Azure.Functions.ExtensionBundle'; version = '[4.*, 5.0.0)' }
                        ) -Force
                        Write-FileContent $hostJson ($hjObj | ConvertTo-Json -Depth 10)
                        Change "$relPath/host.json — extensionBundle added (v4)"
                    } catch { Warn "$relPath/host.json — could not add extensionBundle: $_" }
                } else { Change "[DRY RUN] Would add extensionBundle to $relPath/host.json" }
            } elseif ($hj -match '"version":\s*"\[3\.') {
                Write-FileContent $hostJson ($hj -replace '"version":\s*"\[3\.[^"]*"', '"version": "[4.*, 5.0.0)"')
                Change "$relPath/host.json — extensionBundle bumped to [4.*, 5.0.0)"
            } elseif ($hj -match '"version":\s*"\[4\.') {
                Ok "$relPath/host.json — extensionBundle already v4"
            } else { Warn "$relPath/host.json — extensionBundle version unrecognised; review manually" }
        }

        if ($content -match 'Worker\.Extensions\.ServiceBus' -and $content -match 'WebJobs\.Extensions\.ServiceBus') {
            Warn "$relPath — both Worker.Extensions.ServiceBus and WebJobs.Extensions.ServiceBus referenced; remove the WebJobs one."
        }
    }
    if ($funcProjects.Count -eq 0) { Log "No Azure Function projects detected" }

    # ── Step 5: WPF ────────────────────────────────────────────────────────────
    $wpfProjects = @($csprojFiles | Where-Object {
        (Get-Content $_.FullName -Raw) -match "<UseWPF>true</UseWPF>|UseWPF.*=.*true"
    })

    foreach ($wp in $wpfProjects) {
        $relPath = $wp.FullName.Replace($RepoRootPath, "").TrimStart('\','/')
        $content = Get-Content $wp.FullName -Raw
        if ($content -match "net10\.0-windows") {
            Ok "$relPath — TFM is net10.0-windows ✔"
        } elseif ($content -match "net10\.0(?!-windows)") {
            Write-FileContent $wp.FullName ($content -replace ">net10\.0<", ">net10.0-windows<")
            Change "$relPath — TFM corrected to net10.0-windows"
        } else { Warn "$relPath — WPF TFM needs review" }
    }
    if ($wpfProjects.Count -eq 0) { Log "No WPF projects detected" }
}

# ── hook_Score-ExtraIssues ────────────────────────────────────────────────────
# Called per-project during Phase 1 analysis.
# Returns an int to add to the project issue score.

function hook_Score-ExtraIssues($projPath, $appType, $content) {
    $score = 0
    # Azure Functions in-process (must port to isolated worker before net10)
    if ($appType -eq "Azure Function" -and
        $content -match "Microsoft\.Azure\.WebJobs\.Extensions" -and
        $content -notmatch "Microsoft\.Azure\.Functions\.Worker") {
        $score += 3
    }
    # WPF third-party control libraries
    if ($appType -eq "WPF" -and $content -match "Telerik|DevExpress|Syncfusion|ActiPro|Infragistics") {
        $score += 1
    }
    return $score
}
