# common-tools.ps1 — shared helpers for dotnet-analyse.ps1 and dotnet-migrate.ps1
# Dot-source AFTER defining Log/Warn/Err/Ok/Change in the calling script.
# Functions rely on calling-scope variables: $RepoPath, $toolManifestPath,
# $InstallMissingTools, $DryRun.

# ── TFM & project helpers ──────────────────────────────────────────────────────

function Get-TfmFromCsproj($csprojPath) {
    [xml]$xml = Get-Content $csprojPath
    $tf = $xml.Project.PropertyGroup | ForEach-Object {
        if ($_.TargetFramework)  { $_.TargetFramework }
        if ($_.TargetFrameworks) { $_.TargetFrameworks }
    } | Select-Object -First 1
    return ($tf -split ";") | ForEach-Object { $_.Trim() }
}

function Get-AppType($csprojPath, [string[]]$tfms) {
    $content = Get-Content $csprojPath -Raw
    $name    = [System.IO.Path]::GetFileNameWithoutExtension($csprojPath)
    if ($content -match "Microsoft\.Azure\.Functions\.Worker") { return "Azure Function" }
    if ($content -match "Microsoft\.NET\.Sdk\.Web")            { return "ASP.NET Web API" }
    if ($content -match "UseWPF.*true|<UseWPF>")              { return "WPF" }
    if ($content -match "Microsoft\.NET\.Sdk\.Worker")         { return "Worker Service" }
    if ($content -match "OutputType.*Exe|<OutputType>Exe")     { return "Console" }
    if ($name -match "\.Test[s]?$|\.Spec[s]?$")               { return "Test Project" }
    return "Class Library"
}

function Score-ReadinessColor($issues) {
    if ($issues -ge 5) { return "🔴 Red   (High effort)" }
    if ($issues -ge 2) { return "🟡 Amber (Medium effort)" }
    return "🟢 Green (Low effort)"
}

function Get-RepoScanPaths($rootPath) {
    return @(Get-ChildItem -Path $rootPath -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch "\\bin\\|\\obj\\|\\.git\\" -and
            $_.Extension -in '.cs', '.csproj', '.props', '.targets', '.json', '.config', '.xaml', '.xml', '.md'
        } |
        Select-Object -ExpandProperty FullName)
}

function Get-RepoInventory($rootPath, [string]$ProjectFilter = '', [string]$AppTypeFilter = '') {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $excludedPathPattern = "\\bin\\|\\obj\\|\\.git\\|\\.vs\\"
    $allFiles = @(Get-ChildItem -Path $rootPath -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $excludedPathPattern })

    $sourceExtensions = [System.Collections.Generic.HashSet[string]]::new([string[]]@('.cs', '.razor', '.cshtml', '.xaml'))
    $configExtensions = [System.Collections.Generic.HashSet[string]]::new([string[]]@('.json', '.config', '.xml', '.props', '.targets', '.yml', '.yaml'))
    $scanExtensions   = [System.Collections.Generic.HashSet[string]]::new([string[]]@('.cs', '.csproj', '.props', '.targets', '.json', '.config', '.xaml', '.xml', '.md', '.razor', '.cshtml', '.yml', '.yaml'))

    $sourceFiles = @($allFiles | Where-Object { $sourceExtensions.Contains($_.Extension.ToLowerInvariant()) })
    $configFiles = @($allFiles | Where-Object { $configExtensions.Contains($_.Extension.ToLowerInvariant()) })
    $scanPaths   = @($allFiles | Where-Object { $scanExtensions.Contains($_.Extension.ToLowerInvariant()) } | Select-Object -ExpandProperty FullName)

    $projectItems = [System.Collections.Generic.List[object]]::new()
    $projectFiles = @($allFiles | Where-Object { $_.Extension -ieq '.csproj' })
    foreach ($proj in $projectFiles) {
        if ($ProjectFilter -and $proj.FullName -notlike "*$ProjectFilter*") { continue }

        $raw = Get-Content $proj.FullName -Raw
        $tfms = @()
        try { $tfms = @(Get-TfmFromCsproj $proj.FullName) } catch { $tfms = @() }
        $appType = Get-AppTypeFromContent $proj.FullName $tfms $raw
        if ($AppTypeFilter -and $appType -notlike "*$AppTypeFilter*") { continue }

        $projectDir = Split-Path $proj.FullName
        $projectSourceFiles = @($sourceFiles | Where-Object { $_.FullName.StartsWith($projectDir, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -ExpandProperty FullName)
        $projectConfigFiles = @($configFiles | Where-Object { $_.FullName.StartsWith($projectDir, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -ExpandProperty FullName)
        $packageRefs = @([regex]::Matches($raw, '<PackageReference\s+[^>]*Include="([^"]+)"[^>]*(?:Version="([^"]+)")?') | ForEach-Object {
            [PSCustomObject]@{ Include = $_.Groups[1].Value; Version = $_.Groups[2].Value }
        })
        $projectRefs = @([regex]::Matches($raw, '<ProjectReference\s+[^>]*Include="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })

        $projectItems.Add([PSCustomObject]@{
            File             = $proj
            FullName         = $proj.FullName
            Name             = [System.IO.Path]::GetFileNameWithoutExtension($proj.FullName)
            RelativePath     = $proj.FullName.Replace($rootPath, '').TrimStart('\','/')
            Directory        = $projectDir
            RawContent       = $raw
            TFMs             = $tfms
            AppType          = $appType
            PackageRefs      = $packageRefs
            ProjectRefs      = $projectRefs
            SourceFiles      = $projectSourceFiles
            ConfigFiles      = $projectConfigFiles
            IsAzureFunction  = $raw -match 'Microsoft\.Azure\.Functions\.Worker|Microsoft\.Azure\.WebJobs|AzureFunctions'
            HasSwagger       = $raw -match 'Swashbuckle|NSwag|Microsoft\.AspNetCore\.OpenApi'
            HasAzureSdk      = $raw -match 'PackageReference[^>]+Include="(Azure\.|Microsoft\.Azure\.|WindowsAzure\.)'
            HasB2C           = $raw -match 'Microsoft\.Identity\.Web|Microsoft\.Identity\.Client|AzureAdB2C|B2C'
        })
    }
    $sw.Stop()

    return [PSCustomObject]@{
        RootPath     = $rootPath
        Projects     = @($projectItems)
        AllFiles     = $allFiles
        SourceFiles  = $sourceFiles
        ConfigFiles  = $configFiles
        ScanPaths    = $scanPaths
        Elapsed      = $sw.Elapsed
        Counts       = [PSCustomObject]@{
            Projects = $projectItems.Count
            Files    = $allFiles.Count
            Source   = $sourceFiles.Count
            Config   = $configFiles.Count
        }
    }
}

function Get-AppTypeFromContent($csprojPath, [string[]]$tfms, [string]$content) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($csprojPath)
    if ($content -match "Microsoft\.Azure\.Functions\.Worker|Microsoft\.Azure\.WebJobs|AzureFunctions") { return "Azure Function" }
    if ($content -match "Microsoft\.NET\.Sdk\.Web")            { return "ASP.NET Web API" }
    if ($content -match "UseWPF.*true|<UseWPF>")              { return "WPF" }
    if ($content -match "Microsoft\.NET\.Sdk\.Worker")         { return "Worker Service" }
    if ($content -match "OutputType.*Exe|<OutputType>Exe")     { return "Console" }
    if ($name -match "\.Test[s]?$|\.Spec[s]?$")               { return "Test Project" }
    return "Class Library"
}

function Get-UsefulDetectionPatterns($patterns) {
    return @($patterns | Where-Object { $_ -and ($_.Length -ge 8 -or $_ -match '[\.\[\]<]') })
}

function Get-DetectedBreakingChanges($catalog, $scanPaths) {
    $results = @()
    if ($null -eq $catalog -or $null -eq $catalog.breakingChanges -or $scanPaths.Count -eq 0) {
        return $results
    }
    $patternToIds = [System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]]::new()
    foreach ($entry in @($catalog.breakingChanges)) {
        foreach ($pattern in @(Get-UsefulDetectionPatterns @($entry.detectionPatterns))) {
            if (-not $patternToIds.ContainsKey($pattern)) {
                $patternToIds[$pattern] = [System.Collections.Generic.List[string]]::new()
            }
            if (-not $patternToIds[$pattern].Contains($entry.id)) {
                $patternToIds[$pattern].Add($entry.id)
            }
        }
    }
    $hitPatterns = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($pattern in @($patternToIds.Keys)) {
        if (Select-String -Path $scanPaths -SimpleMatch $pattern -List -ErrorAction SilentlyContinue) {
            [void]$hitPatterns.Add($pattern)
        }
    }
    $hitEntryIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($pattern in $hitPatterns) {
        foreach ($id in $patternToIds[$pattern]) { [void]$hitEntryIds.Add($id) }
    }
    foreach ($entry in @($catalog.breakingChanges)) {
        if ($hitEntryIds.Contains($entry.id)) {
            $matched = @(Get-UsefulDetectionPatterns @($entry.detectionPatterns) | Where-Object { $hitPatterns.Contains($_) })
            $results += [PSCustomObject]@{
                Entry           = $entry
                MatchedPatterns = @($matched | Sort-Object -Unique)
            }
        }
    }
    return $results
}

function Get-BreakingChangesForBuildOutput($catalog, $buildOutput) {
    $entries = @()
    if ($null -eq $catalog -or $null -eq $catalog.quickReference -or $null -eq $catalog.breakingChanges) {
        return $entries
    }
    $matchedIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($line in @($buildOutput)) {
        foreach ($m in ([regex]::Matches([string]$line, '\b[A-Z]{2,}\d{4,}\b'))) {
            $prop = $catalog.quickReference.byErrorCode.PSObject.Properties[$m.Value]
            if ($null -eq $prop) { continue }
            $v = $prop.Value
            if ($v -is [System.Array]) { foreach ($i in $v) { [void]$matchedIds.Add([string]$i) } }
            else { [void]$matchedIds.Add([string]$v) }
        }
    }
    foreach ($entry in @($catalog.breakingChanges)) {
        if ($matchedIds.Contains([string]$entry.id)) { $entries += $entry }
    }
    return $entries
}

function Write-BreakingChangeHints($entries) {
    foreach ($entry in @($entries)) {
        Warn ("[{0}] {1}" -f $entry.id, $entry.title)
        Warn ("  Fix: {0}" -f $entry.fix.summary)
        if (@($entry.references).Count -gt 0) { Warn ("  Ref: {0}" -f $entry.references[0]) }
    }
}

# ── Tool management ────────────────────────────────────────────────────────────

function Ensure-ToolManifest() {
    if (Test-Path $toolManifestPath) { return $true }
    if (-not $InstallMissingTools) {
        Warn "Tool manifest missing. Create with: dotnet new tool-manifest --output .config"
        return $false
    }
    Log "Creating workspace-local dotnet tool manifest..."
    Push-Location $RepoPath
    try {
        $dir = Split-Path -Parent $toolManifestPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        & dotnet new tool-manifest --output .config --force 2>&1 | ForEach-Object { Log $_ }
        return (Test-Path $toolManifestPath)
    } catch {
        Warn "Failed to create tool manifest: $_"
        return $false
    } finally { Pop-Location }
}

$script:_toolListCache = $null
function Local-ToolInstalled($packageId) {
    if (-not (Test-Path $toolManifestPath)) { return $false }
    if ($null -eq $script:_toolListCache) {
        Push-Location $RepoPath
        try   { $script:_toolListCache = & dotnet tool list --local 2>&1 }
        catch { $script:_toolListCache = @() }
        finally { Pop-Location }
    }
    return ($script:_toolListCache -match [regex]::Escape($packageId))
}

function Invoke-RepoTool([string]$commandName, [string[]]$arguments) {
    $toolArgs = @('tool', 'run', $commandName, '--') + $arguments
    Push-Location $RepoPath
    try { return & dotnet @toolArgs 2>&1 } finally { Pop-Location }
}

function Ensure-DotnetTool($commandName, $packageId, $friendlyName, [bool]$allowInstall = $true) {
    if (Local-ToolInstalled $packageId) { return $true }
    if (-not $allowInstall -or -not $InstallMissingTools) {
        Warn "$friendlyName not found. Install: dotnet tool install --local $packageId"
        return $false
    }
    if (-not (Ensure-ToolManifest)) { return $false }
    Warn "$friendlyName not found — installing $packageId..."
    Push-Location $RepoPath
    try {
        & dotnet tool update --local $packageId 2>&1 | ForEach-Object { Log $_ }
    } catch {
        try { & dotnet tool install --local $packageId 2>&1 | ForEach-Object { Log $_ } }
        catch { Warn "$friendlyName install failed: $_" }
    } finally { Pop-Location }
    $script:_toolListCache = $null
    if (Local-ToolInstalled $packageId) { Ok "$friendlyName installed"; return $true }
    Warn "$friendlyName still unavailable after install."
    return $false
}

function Write-FileContent($path, $content) {
    if ($DryRun) { Change "[DRY RUN] Would write: $path" }
    else { Set-Content -Path $path -Value $content -Encoding utf8 }
}

# ── Version auto-detection ─────────────────────────────────────────────────────

function Get-AutoDetectedVersions($csprojFiles) {
    $counts = @{}
    foreach ($proj in $csprojFiles) {
        try {
            $tfms = if ($proj.PSObject.Properties.Name -contains 'TFMs') { $proj.TFMs } else { Get-TfmFromCsproj $proj.FullName }
            foreach ($tfm in $tfms) {
                if ($tfm -match 'net(\d+)\.') {
                    $major = [int]$Matches[1]
                    $counts[$major] = ($counts.ContainsKey($major) ? $counts[$major] : 0) + 1
                }
            }
        } catch { }
    }
    if ($counts.Count -eq 0) { return $null }
    if ($counts.Count -gt 1) {
        Warn "Mixed TFM versions detected: $($counts.Keys -join ', ') — inferring target from majority"
    }
    $sourceMajor = ($counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
    return @{ Source = $sourceMajor; Target = $sourceMajor + 1 }
}
