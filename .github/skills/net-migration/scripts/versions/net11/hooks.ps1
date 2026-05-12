# hooks.ps1 — .NET 11 migration hooks (STUB — populate before net11 GA)
# Dot-sourced by dotnet-analyse.ps1 and dotnet-migrate.ps1

$hook_TargetTfm        = "net11.0"
$hook_TargetWindowsTfm = "net11.0-windows"
$hook_SdkVersion       = "11.0.100"   # TODO: update when net11 SDK releases

$hook_SourceTfmPatterns = @(
    @{ Pattern = 'net9\.0-windows';  Replacement = $hook_TargetWindowsTfm },
    @{ Pattern = 'net10\.0-windows'; Replacement = $hook_TargetWindowsTfm },
    @{ Pattern = 'net9\.0';          Replacement = $hook_TargetTfm },
    @{ Pattern = 'net10\.0';         Replacement = $hook_TargetTfm }
)

$hook_CpmVersionFloor  = '(?:9|10)'  # net9 or net10 source
$hook_CpmVersionTarget = '11.0.0'

function hook_Invoke-VersionChecks($csprojFiles, $DryRunFlag, $RepoRootPath) {
    # TODO: add net11-specific checks when breaking changes are published
    Log "No net11-specific version checks defined yet."
}

function hook_Score-ExtraIssues($projPath, $appType, $content) {
    # TODO: add net11-specific issue scoring
    return 0
}
