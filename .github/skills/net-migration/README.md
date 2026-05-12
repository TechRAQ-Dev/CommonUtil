# net-migration Skill

AI-assisted, two-phase migration of .NET 8/9 repositories to .NET 10.  
Works with any .NET repo — not specific to any project.

---

## Folder structure

```
.github/skills/net-migration/
├── SKILL.md                           ← Copilot agent instructions
├── README.md                          ← This file
└── scripts/
    ├── dotnet10-analyse.ps1           ← Phase 1: scan-only, produces MIGRATION-REPORT.md
    ├── dotnet10-migrate.ps1           ← Phase 2: applies changes, builds, tests
    ├── dotnet10-breaking-changes.json ← Bundled .NET 10 breaking-change catalog
    └── modernize-config.yaml          ← Config for GitHub Copilot modernize tool
```

---

## Prerequisites

| Tool | How to get it | Required for |
|---|---|---|
| .NET 10 SDK | [aka.ms/dotnet/download](https://aka.ms/dotnet/download) | Both phases |
| `dotnet-outdated` | Auto-installed as a local tool by the scripts | Phase 1 + 2 package scan |
| `roslynator.dotnet.cli` | Auto-installed as a local tool by the scripts | Phase 2 code fixes |
| `modernize` | `winget install GitHub.Copilot.modernization.agent --silent` | Phase 1 cloud readiness |
| GitHub CLI (`gh`) | [cli.github.com](https://cli.github.com) | `modernize` authentication |

`dotnet-outdated` and `roslynator` install workspace-locally via `.config/dotnet-tools.json` — no machine-wide installs.

---

## Copying this skill to another repo

1. Copy the entire `.github/skills/net-migration/` folder into the target repo.
2. That's it — all outputs go into `<repo>/migration-reports/`.

---

## Invoking via Copilot Chat

```
@copilot migrate this repo to .NET 10
@copilot assess this repo for .NET 10 readiness
@copilot net-migration /help
```

The `/help` argument prints a concise command reference without running anything.

---

## Phase 1 — Analyse (read-only)

Scans the repo without modifying any files. Produces:

| Output | Location |
|---|---|
| Readiness report | `migration-reports/MIGRATION-REPORT.md` |
| Modernize HTML report | `migration-reports/modernize-report/reports-*/index.html` |
| Outdated packages JSON | `migration-reports/outdated-packages.json` |

**Parameters:**

| Parameter | Default | Description |
|---|---|---|
| `-RepoPath` | current dir | Path to the repo root |
| `-TargetTfm` | `net10.0` | TFM to analyse against |
| `-InstallMissingTools` | `$true` | Auto-install local tools if missing |

```powershell
.\.github\skills\net-migration\scripts\dotnet10-analyse.ps1 -RepoPath .
```

---

## Phase 2 — Migrate (applies changes)

Bumps TFMs, upgrades packages, runs roslynator, builds, and optionally runs tests. Produces:

| Output | Location |
|---|---|
| Migration log | `migration-reports/MIGRATION-LOG.md` |
| Per-step logs | `migration-reports/steps/step-0N-name.log` |
| Checkpoint | `migration-reports/steps/checkpoint.json` |

**Parameters:**

| Parameter | Default | Description |
|---|---|---|
| `-RepoPath` | current dir | Path to the repo root |
| `-TargetTfm` | `net10.0` | TFM for non-Windows projects |
| `-TargetWindowsTfm` | `net10.0-windows` | TFM for WPF/Windows projects |
| `-SdkVersion` | `10.0.100` | SDK version to pin in `global.json` |
| `-DryRun` | off | Preview without writing files |
| `-SkipBuild` | off | Skip `dotnet build` |
| `-SkipTests` | off | Skip `dotnet test` |
| `-RunStep` | all | Run only specific step(s): `-RunStep 8` or `-RunStep 8,9` |
| `-ResumeFromCheckpoint` | off | Skip steps already marked `Completed` in last run |
| `-InstallMissingTools` | `$true` | Auto-install local tools if missing |

**Common commands:**

```powershell
# Dry run — preview planned changes without touching files
.\.github\skills\net-migration\scripts\dotnet10-migrate.ps1 -RepoPath . -DryRun

# Full migration (skip tests for speed, run them separately when ready)
.\.github\skills\net-migration\scripts\dotnet10-migrate.ps1 -RepoPath . -SkipTests

# Re-run only the build step after a manual fix
.\.github\skills\net-migration\scripts\dotnet10-migrate.ps1 -RepoPath . -RunStep 8 -SkipTests

# Run build and tests together
.\.github\skills\net-migration\scripts\dotnet10-migrate.ps1 -RepoPath . -RunStep 8,9

# Resume an interrupted run (skips steps already completed)
.\.github\skills\net-migration\scripts\dotnet10-migrate.ps1 -RepoPath . -ResumeFromCheckpoint
```

---

## Migration steps (Phase 2)

| Step | Name | What it does |
|---|---|---|
| 1 | global.json | Pins .NET SDK to target version |
| 2 | TFM Bump | Updates `TargetFramework` in all `.csproj` files |
| 3 | Package Upgrades | Runs `dotnet-outdated --upgrade` on all projects |
| 4 | Azure Functions | Detects in-process model; warns to migrate to isolated worker |
| 5 | WPF Validation | Confirms WPF projects use the `-windows` TFM suffix |
| 6 | Roslynator | Auto-applies Roslyn code modernization fixes |
| 7 | BinaryFormatter | Detects removed API usage; blocks migration until resolved |
| 8 | Build | `dotnet restore` + transitive CVE scan + `dotnet build` |
| 9 | Tests | `dotnet test` (skipped if `-SkipTests`) |
| 10 | Log | Writes `MIGRATION-LOG.md` with full summary |

---

## What MIGRATION-LOG.md contains

- Changes applied (TFMs, files modified)
- Package upgrades table
- Build result (status, error count, warnings, elapsed time)
- Test result (passed / failed / skipped, with failed test names)
- Security notices (restore-time NU1902 + transitive `dotnet list package --vulnerable --include-transitive`)
- Modernize assess status (pulled from Phase 1 report, with HTML report link)
- Roslynator summary (files fixed, diagnostics resolved, explanatory note when 0)
- Skipped steps
- Per-step timings
- Full raw script log (collapsible)

---

## Known limitations

| Limitation | Detail |
|---|---|
| Transitive CVEs | `dotnet-outdated` only upgrades direct refs. Phase 2 scans `--include-transitive` to catch transitive CVEs. Fix: add an explicit `<PackageReference>` version pin for the vulnerable package. |
| roslynator + `.slnx` | roslynator 0.12.x doesn't support `.slnx`. Falls back to per-project `.csproj` mode automatically. |
| roslynator 0 fixes | Normal when compile errors block analysis, or all diagnostics are unfixable code-quality suggestions. See Raw Script Log for detail. |
| modernize PATH | `winget install` doesn't update the current PowerShell session. The analyse script auto-patches the session PATH from the winget links directory — no restart needed. |
| Azure Functions in-process | Not supported on .NET 10. Must migrate to isolated worker model before Phase 2. The skill provides AI-assisted rewrite guidance. |
