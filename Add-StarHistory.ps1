<#
.SYNOPSIS
    Adds a "Star History" chart to the README of every public repo you own,
    inserted right under the first H1 title. Uses the GitHub CLI ("gh") and
    the Contents API (PUT = create-a-commit-via-API, no git clone needed).

.DESCRIPTION
    For each public repo (forks and archived repos excluded by default):
      1. Fetches the README via `gh api repos/{owner}/{repo}/readme`
      2. Skips it if a star-history.com chart is already present (no overwrite)
      3. Finds the first "# Title" (H1) line
      4. Inserts the Star History block right after it, leaving everything
         else in the file untouched
      5. Commits the change straight to GitHub with `gh api ... --method PUT`
         (this IS the "http put" approach - it creates a real commit without
         a local git checkout)

.PARAMETER Owner
    GitHub user/org to process. Defaults to the currently authenticated `gh` user.

.PARAMETER CommitMessage
    Commit message used for every update. Default: "docs: add star history chart".

.PARAMETER Legend
    star-history.com legend position query param. Default: "top-left".

.PARAMETER IncludeForks
    Include forked repos too (excluded by default).

.PARAMETER DryRun
    Show what would change without writing anything.

.EXAMPLE
    .\Add-StarHistory.ps1 -DryRun

.EXAMPLE
    .\Add-StarHistory.ps1 -Owner myusername -CommitMessage "docs: star history"

.NOTES
    - Requires `gh` installed and authenticated (`gh auth login`) with repo scope.
    - The "sealed_token" query param you get from star-history.com's own site
      is generated per-request by their frontend and can't be reproduced
      generically here - the chart URLs below omit it and still work fine
      against the public api.star-history.com endpoint, just without that
      site-specific caching token.
#>

[CmdletBinding()]
param(
    [string]$Owner,
    [string]$CommitMessage = "docs: add star history chart",
    [string]$Legend = "top-left",
    [switch]$IncludeForks,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Assert-GhReady {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Error "GitHub CLI 'gh' not found in PATH. Install it from https://cli.github.com/"
        exit 1
    }
    gh auth status *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Not authenticated with gh. Run 'gh auth login' first."
        exit 1
    }
}

Assert-GhReady

if (-not $Owner) {
    $Owner = gh api user --jq ".login"
}

Write-Host "Fetching public repos for '$Owner'..." -ForegroundColor Cyan

$listArgs = @(
    $Owner,
    "--limit", "1000",
    "--visibility", "public",
    "--no-archived",
    "--json", "name,defaultBranchRef"
)
if (-not $IncludeForks) { $listArgs += "--source" }

$reposRaw = gh repo list @listArgs
if ($LASTEXITCODE -ne 0 -or -not $reposRaw) {
    Write-Error "Failed to list repos for '$Owner'."
    exit 1
}
$repos = $reposRaw | ConvertFrom-Json

Write-Host "Found $($repos.Count) public repo(s).`n" -ForegroundColor Cyan

$results = @()

foreach ($repo in $repos) {
    $name     = $repo.name
    $branch   = $repo.defaultBranchRef.name
    if (-not $branch) { $branch = "main" }
    $fullName = "$Owner/$name"

    Write-Host "Processing $fullName (branch: $branch)..." -ForegroundColor Yellow

    # 1) Fetch README metadata + content
    $readmeJson = gh api "repos/$fullName/readme" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $readmeJson) {
        Write-Host "  -> No README found, skipping." -ForegroundColor DarkGray
        $results += [pscustomobject]@{ Repo = $fullName; Status = "No README" }
        continue
    }

    $readmeObj = $readmeJson | ConvertFrom-Json
    $sha       = $readmeObj.sha
    $path      = $readmeObj.path
    $b64       = $readmeObj.content -replace "`n", ""
    $bytes     = [Convert]::FromBase64String($b64)
    $content   = [System.Text.Encoding]::UTF8.GetString($bytes)

    # 2) Don't override anything that's already there
    if ($content -match "star-history\.com") {
        Write-Host "  -> Star History chart already present, skipping." -ForegroundColor DarkGray
        $results += [pscustomobject]@{ Repo = $fullName; Status = "Already present" }
        continue
    }

    # 3) Find first H1 title line
    $lines = $content -split "`r?`n"
    $titleIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*#\s+\S') {
            $titleIndex = $i
            break
        }
    }

    $repoParamEncoded = $fullName -replace '/', '%2F'   # matches the example's repos=owner%2Frepo format

    $chartBlock = @"

## Star History

<a href="https://www.star-history.com/?repos=$repoParamEncoded&type=date&legend=$Legend">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=$fullName&type=date&theme=dark&legend=$Legend" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=$fullName&type=date&legend=$Legend" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=$fullName&type=date&legend=$Legend" />
 </picture>
</a>

"@
    $chartLines = $chartBlock -split "`r?`n"

    # 4) Insert right after the title, leave the rest of the file alone
    if ($titleIndex -ge 0) {
        $before = $lines[0..$titleIndex]
        $after  = if ($titleIndex + 1 -lt $lines.Count) { $lines[($titleIndex + 1)..($lines.Count - 1)] } else { @() }
        $newLines = $before + $chartLines + $after
    } else {
        Write-Host "  -> No H1 title found; inserting at top of file instead." -ForegroundColor DarkGray
        $newLines = $chartLines + $lines
    }

    $newContent = ($newLines -join "`n")

    if ($DryRun) {
        Write-Host "  -> [DryRun] Would update '$path' on branch '$branch'." -ForegroundColor Green
        $results += [pscustomobject]@{ Repo = $fullName; Status = "DryRun - would update" }
        continue
    }

    # 5) Commit via the Contents API (PUT) - no local git needed
    $newContentB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($newContent))
    $putBody = @{
        message = $CommitMessage
        content = $newContentB64
        sha     = $sha
        branch  = $branch
    } | ConvertTo-Json -Compress

    $tmpFile = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $tmpFile -Value $putBody -NoNewline -Encoding UTF8

    $encodedPath = ($path -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    $apiOutput = gh api "repos/$fullName/contents/$encodedPath" --method PUT --input $tmpFile 2>&1
    $exitCode  = $LASTEXITCODE
    Remove-Item $tmpFile -ErrorAction SilentlyContinue

    if ($exitCode -eq 0) {
        Write-Host "  -> Updated and committed." -ForegroundColor Green
        $results += [pscustomobject]@{ Repo = $fullName; Status = "Updated" }
    } else {
        Write-Host "  -> Failed: $apiOutput" -ForegroundColor Red
        $results += [pscustomobject]@{ Repo = $fullName; Status = "Failed" }
    }

    Start-Sleep -Milliseconds 400   # be gentle on the API / rate limits
}

Write-Host "`n===== Summary =====" -ForegroundColor Cyan
$results | Format-Table -AutoSize
