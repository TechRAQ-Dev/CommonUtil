---
name: net-migration
description: "Analyze and migrate .NET repositories to a newer version. Use when asked to migrate, upgrade, convert, scan, or assess a .NET repo or solution for .NET 10, .NET 11, or any newer .NET version readiness."
argument-hint: "Repo path, optional target version (e.g. 10 or 11), and whether to run analysis only or full migration"
---

## /help — Command reference

When the user invokes this skill with `/help`, respond with exactly:

---

**net-migration — command reference**

```
Usage:  @copilot <migration intent>
        @copilot net-migration /help

PHASES
  Phase 1 — Analyse (read-only)
    Scans the repo. Scores each project 🟢/🟡/🔴. Flags breaking changes
    and NuGet CVEs. modernize assess is opt-in (slow AI call).
    Output → migration-reports/MIGRATION-REPORT.md

  Phase 2 — Migrate (writes files)
    Bumps TFMs · upgrades packages · roslynator fixes · build · tests.
    Output → migration-reports/MIGRATION-LOG.md

TRIGGER PHRASES
  "migrate this repo to .NET 10"      "migrate this repo to .NET 11"
  "assess this repo for .NET readiness"
  "run Phase 1 only"                  "apply the migration"
  "re-run only the build step"        → -RunStep 8
  "resume from where it left off"     → -ResumeFromCheckpoint

PHASE 1 FLAGS
  -TargetVersion <n>       Target .NET major version (default: auto-detect)
  -RunModernize            Run modernize assess (opt-in, slow)
  -RunUpgradeAssistant     Run .NET Upgrade Assistant analyze on risky projects (opt-in, slow)

PHASE 2 FLAGS
  -TargetVersion <n>       Target .NET major version (default: auto-detect)
  -DryRun                  Preview changes without writing files
  -SkipTests / -SkipBuild  Skip validation steps
  -SkipRoslynator          Skip roslynator (avoids hang on blocking projects)
  -RunStep <n>[,<n>...]    Run specific step(s) only
  -ResumeFromCheckpoint    Skip already-completed steps

STEPS (Phase 2)
  1 global.json  2 TFM bump  3 Package upgrades  4+5 Version-specific checks
  6 Roslynator   7 BinaryFormatter  8 Build  9 Tests

REPORTS
  migration-reports/MIGRATION-REPORT.md     Phase 1 readiness report
  migration-reports/MIGRATION-LOG.md        Phase 2 change log
  migration-reports/modernize-report/       HTML cloud readiness report
  migration-reports/upgrade-assistant-analyze.log  Upgrade Assistant findings
  migration-reports/steps/checkpoint.json   Step resume state

KNOWN LIMITATIONS
  dotnet-outdated misses transitive CVEs → Phase 2 scans --include-transitive
  roslynator doesn't support .slnx      → falls back to per-project .csproj
  roslynator 0 fixes is not a failure   → compile errors or code-quality only
  modernize needs winget install         → script auto-patches session PATH
```

---

# .NET Migration Skill

Scripts:
- `./scripts/dotnet-analyse.ps1` — Phase 1 (read-only analysis)
- `./scripts/dotnet-migrate.ps1` — Phase 2 (applies changes)
- `./scripts/versions/net<N>/breaking-changes.json` — per-version breaking-change catalog
- `./scripts/versions/net<N>/hooks.ps1` — per-version TFM patterns and step overrides
- `./scripts/lib/common-tools.ps1` — shared helpers (dot-sourced by both scripts)

Both scripts **auto-detect the source TFM** from `.csproj` files and target the next major version by default. Override with `-TargetVersion <n>`.

---

## Step 0 — Gather inputs

If the user hasn't provided a repo path, ask once:
> "Which repo should I migrate? Please give me the full path (e.g. `C:\repos\payments-service`)."

Confirm: Phase 1 only first, or straight through both phases? Default: run Phase 1, summarise, then ask before Phase 2.

---

## Step 1 — Check prerequisites

Verify the scripts exist:
- `./scripts/dotnet-analyse.ps1`
- `./scripts/dotnet-migrate.ps1`

Check `dotnet` is on PATH: `dotnet --version`. If missing, stop and ask the user to install the .NET SDK first.

Tools auto-installed as workspace-local dotnet tools (`.config/dotnet-tools.json`):
- `dotnet-outdated-tool` — package staleness
- `roslynator.dotnet.cli` — automated Roslyn fixes (Phase 2)

NuGet CVE scan uses built-in `dotnet list package --vulnerable` — no install needed.

`modernize` is a system tool: `winget install GitHub.Copilot.modernization.agent --silent`. The script auto-patches session PATH after winget install.

`.NET Upgrade Assistant` is a local dotnet tool installed only when `-RunUpgradeAssistant` is used:
```
dotnet tool install --local upgrade-assistant
```
Use it for complex/legacy projects or risky package/API migrations. Do not run it by default on very large repos.

If auto-install is disabled, tell the user:
```
dotnet new tool-manifest --output .config
dotnet tool install --local dotnet-outdated-tool
dotnet tool install --local roslynator.dotnet.cli
dotnet tool install --local upgrade-assistant
```

---

## Step 2 — Phase 1: Analyse

```powershell
./scripts/dotnet-analyse.ps1 -RepoPath "<path>"
# Or target a specific version:
./scripts/dotnet-analyse.ps1 -RepoPath "<path>" -TargetVersion 11
# Optional deeper legacy/API analysis on risky projects:
./scripts/dotnet-analyse.ps1 -RepoPath "<path>" -RunUpgradeAssistant
```

The script auto-detects source TFM and targets `source + 1` by default. Read `migration-reports/MIGRATION-REPORT.md` after it runs.

The catalog at `./scripts/versions/net<N>/breaking-changes.json` is the bundled reference for compatibility risks. The script scans for matching patterns and includes them in the report.

For large repos, keep `modernize` and Upgrade Assistant opt-in. Start with the fast deterministic analysis, then rerun with `-RunUpgradeAssistant` only when Phase 1 shows high-risk projects, legacy Azure Functions, old Azure SDK packages, or repeated build errors.

### Interpret the report

Give the user a plain-English summary:
1. **Overall readiness** — projects 🟢 / 🟡 / 🔴
2. **Biggest risks** — call out 🔴 items explicitly:
   - Azure Functions in-process model (must port to isolated worker first)
   - `BinaryFormatter` usage (removed in .NET 10+)
3. **Package gaps** — any packages with no compatible version? For flagged packages, verify with:
   ```bash
   dnx dotnet-inspect -y -- package <name> --versions
   ```
   This confirms whether a `.net<N>` TFM exists before declaring incompatibility.
4. **WPF third-party controls** — Telerik / DevExpress / Syncfusion flagged?
5. **Estimated effort** — Low / Medium / High with one-sentence rationale

### If there are 🔴 Red items

Explain and offer: fix now with AI assistance, defer, or cancel. If the user wants AI help, apply the fix before Phase 2 (see AI Fix Patterns below).

---

## Step 3 — Phase 2: Migrate (with permission)

Ask:
> "Ready to apply the migration? I'll do a dry run first so you can see planned changes."

**Dry run:**
```powershell
./scripts/dotnet-migrate.ps1 -RepoPath "<path>" -DryRun
```

**Apply:**
```powershell
./scripts/dotnet-migrate.ps1 -RepoPath "<path>"
```

Read `migration-reports/MIGRATION-LOG.md` and summarise what changed.

Notes:
- **Roslynator 0 fixes** is not a failure — means compile errors blocked fixers, or remaining diagnostics are code-quality only. Fix build errors first, then re-run with `-RunStep 6`.
- **Security Notices** covers restore-time NU1902 warnings plus transitive CVE scan results.
- **Steps 4+5** are delegated to `versions/net<N>/hooks.ps1` (Azure Functions + WPF checks).

---

## Step 4 — AI Build-Fix Loop

After Phase 2, run `dotnet build "<path>" --configuration Release`.

**Build succeeds**: Congratulate, remind to run tests, go to Step 5.

**Build fails**: Auto-fix loop (max 5 iterations):
1. Read all errors — file, line, message.
2. Group by error type.
3. Open files, apply fixes.
4. Re-run build.
5. Clean → exit. Still failing → repeat.

After each iteration tell the user: errors fixed, fix types applied, errors remaining.

After 5 iterations still failing: list remaining errors, explain each, give concrete next steps.

### AI Fix Patterns

**BinaryFormatter (net10+):** Replace `BinaryFormatter.Serialize/Deserialize` with `System.Text.Json.JsonSerializer`. Add `using System.Text.Json;`. Keep stream overloads via `SerializeToUtf8Bytes`.

**Azure Functions in-process → isolated worker:** `[FunctionName]` → `[Function]`; inject `ILogger<T>` via DI; replace `FunctionStartup` with `HostBuilder` + `ConfigureFunctionsWorkerDefaults()`; update packages to `Microsoft.Azure.Functions.Worker` 2.x.

**Nullable CS8600–CS8604:** Add `!` null-forgiving operator or null checks; add `?` to type declarations where genuinely nullable.

**Ambiguous overload CS0121:** Add explicit cast or use named parameters.

**Missing using:** Read error, find type namespace, add `using`.

**Removed/obsolete APIs:** Check Microsoft migration docs; use AI knowledge of the target version for idiomatic replacement.

**Catalog-first:** Before a manual fix, check `./scripts/versions/net<N>/breaking-changes.json` for matching error codes or detection patterns. If an entry exists, apply its `fix.summary` and references first.

**Catalog feedback loop:** When you successfully fix a breaking change that is missing from the catalog, add or update an entry in `./scripts/versions/net<N>/breaking-changes.json` before finishing the migration. Include `id`, `title`, `severity`, `area`, `description`, `detectionPatterns`, `fix.summary`, and `references`. Also add compiler/package error codes to `quickReference.byErrorCode` when the fix maps to a repeatable error like `CSxxxx`, `NUxxxx`, `NETSDKxxxx`, or package-specific analyzer IDs. Keep entries generic and reusable; do not include app-specific file paths or customer names.

**dotnet-inspect (API diff):** When a build error involves a renamed, moved, or removed API and the breaking-changes catalog has no entry, use `dotnet-inspect diff` to find the exact change before writing a fix:
```bash
# What changed in a package between versions?
dnx dotnet-inspect -y -- diff --package Foo@old..new --oneline
# Inspect the new API surface of a specific type
dnx dotnet-inspect -y -- member TypeName --package Foo@new --oneline
# Locate a type that may have moved namespace
dnx dotnet-inspect -y -- find "*TypeName*" --platform
```
This gives ground-truth API information rather than relying on model training data — especially valuable for packages that changed significantly between .NET major versions.

---

## Step 5 — Run Tests

```powershell
dotnet test "<path>" --configuration Release --logger "console;verbosity=minimal"
```

Summarise: X passed / Y failed / Z skipped. If failures are .NET API changes, apply the fix loop.

---

## Step 6 — Final Summary

```
✅ Migration Complete — <repo-name>

Projects migrated : X
TFMs updated      : net<source>.0 → net<target>.0
Packages updated  : N
Build iterations  : N
Tests             : X passed / Y failed

Next steps:
1. Review migration-reports/MIGRATION-LOG.md
2. Run integration/smoke tests
3. Update CI pipeline to use .NET <target> SDK
4. Open a PR — branch: feature/dotnet<target>-migration
```

---

## Tone

- Direct and developer-focused. No fluff.
- Explain *why* each change is needed.
- Flag risky changes and ask before making them.
- Keep the user informed — no silent long pauses.
