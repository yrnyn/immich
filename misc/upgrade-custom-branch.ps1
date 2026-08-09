<#
.SYNOPSIS
Rebases the long-lived timezone-fix branch onto a newer Immich release.

.DESCRIPTION
The current branch must be tz-null-fix. The script finds the newest official vX.Y.Z
tag already contained by that branch, fetches the requested newer upstream tag, and
rebases the custom commits in place. It never creates a release tag or Docker image;
those are created only after review and testing.

.EXAMPLE
./misc/upgrade-custom-branch.ps1 -TargetTag v3.0.3

.EXAMPLE
./misc/upgrade-custom-branch.ps1 -TargetTag v3.0.3 -Push
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidatePattern('^v\d+\.\d+\.\d+$')]
  [string]$TargetTag,

  [switch]$Push
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$MaintenanceBranch = 'tz-null-fix'
$ReleaseSuffix = '-tz-null-fix'

function Invoke-Git {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)

  & git @GitArgs
  if ($LASTEXITCODE -ne 0) {
    throw "git $($GitArgs -join ' ') failed with exit code $LASTEXITCODE."
  }
}

function Test-GitRef {
  param([string]$Ref)

  & git rev-parse --verify --quiet "$Ref^{commit}" *> $null
  return $LASTEXITCODE -eq 0
}

function Confirm-Action {
  param([string]$Prompt)

  $answer = Read-Host "$Prompt [y/N]"
  return $answer.Trim().ToLowerInvariant() -in @('y', 'yes')
}

function Get-BaseReleaseTag {
  param([string]$Branch)

  $tags = @(
    & git tag --merged $Branch --list 'v*' |
      Where-Object { $_ -match '^v\d+\.\d+\.\d+$' } |
      Sort-Object { [Version]$_.Substring(1) } -Descending
  )

  if (-not $tags) {
    throw "No official vX.Y.Z tag is an ancestor of '$Branch'."
  }

  return $tags[0]
}

try {
  $repoRoot = (& git rev-parse --show-toplevel).Trim()
  if ($LASTEXITCODE -ne 0) {
    throw 'Run this script from inside the Git repository.'
  }

  Push-Location $repoRoot

  $workingTree = & git status --porcelain
  if ($LASTEXITCODE -ne 0) {
    throw 'Unable to read the Git working tree status.'
  }
  if ($workingTree) {
    throw 'The working tree is not clean. Commit, stash, or discard local changes before upgrading.'
  }

  $sourceBranch = (& git branch --show-current).Trim()
  if ($sourceBranch -ne $MaintenanceBranch) {
    throw "Current branch '$sourceBranch' must be '$MaintenanceBranch'."
  }

  $sourceTag = Get-BaseReleaseTag $MaintenanceBranch

  $sourceVersion = [Version]$sourceTag.Substring(1)
  $targetVersion = [Version]$TargetTag.Substring(1)
  if ($targetVersion -le $sourceVersion) {
    throw "Target tag '$TargetTag' must be newer than current base tag '$sourceTag'."
  }

  Invoke-Git remote get-url origin *> $null
  Invoke-Git remote get-url upstream *> $null

  Write-Host "Fetching upstream tag $TargetTag..."
  Invoke-Git fetch upstream tag $TargetTag

  if (-not (Test-GitRef $sourceTag)) {
    throw "Source tag '$sourceTag' is unavailable locally. Fetch it and try again."
  }
  if (-not (Test-GitRef $TargetTag)) {
    throw "Target tag '$TargetTag' was not fetched from upstream."
  }

  & git merge-base --is-ancestor $sourceTag $MaintenanceBranch
  if ($LASTEXITCODE -ne 0) {
    throw "Current base tag '$sourceTag' is not an ancestor of '$MaintenanceBranch'."
  }

  Write-Host "`nUpgrade plan:"
  Write-Host "  Maintenance branch: $MaintenanceBranch"
  Write-Host "  Current base tag:   $sourceTag"
  Write-Host "  Target base tag:    $TargetTag"
  Write-Host "`nCommits to replay:"
  Invoke-Git log --oneline "$sourceTag..$MaintenanceBranch"

  if (-not (Confirm-Action "Rebase '$MaintenanceBranch' onto '$TargetTag'?")) {
    Write-Host 'Canceled before rebasing. No Git history was changed.'
    return
  }

  try {
    Invoke-Git rebase --onto $TargetTag $sourceTag
  } catch {
    Write-Error "Rebase stopped on '$MaintenanceBranch'. Resolve the conflicts, then run 'git rebase --continue'."
    Write-Error "To abandon this upgrade attempt, run 'git rebase --abort'."
    throw
  }

  $packageVersion = (Get-Content server/package.json -Raw | ConvertFrom-Json).version
  if ($packageVersion -ne $TargetTag.Substring(1)) {
    throw "server/package.json is $packageVersion, but '$TargetTag' requires $($TargetTag.Substring(1))."
  }

  Invoke-Git range-diff "$sourceTag..$MaintenanceBranch@{1}" "$TargetTag..HEAD"
  Invoke-Git diff --check "$TargetTag...HEAD"
  Invoke-Git diff --stat "$TargetTag...HEAD"

  & git merge-base --is-ancestor $TargetTag HEAD
  if ($LASTEXITCODE -ne 0) {
    throw "Target tag '$TargetTag' is not an ancestor of '$MaintenanceBranch' after rebase."
  }

  $releaseTag = "$TargetTag$ReleaseSuffix"
  Write-Host "`nRebase complete. Verify and test this branch before publishing."
  Write-Host "Release tag: $releaseTag"
  Write-Host "Publish after testing:"
  Write-Host "  git tag -a $releaseTag -m 'Release $releaseTag'"
  Write-Host "  git push origin $releaseTag"

  if ($Push) {
    if (-not (Confirm-Action "Force-push rebased '$MaintenanceBranch' to origin with --force-with-lease?")) {
      Write-Host "Not pushed. After testing: git push --force-with-lease -u origin $MaintenanceBranch"
      return
    }

    Invoke-Git push --force-with-lease -u origin $MaintenanceBranch
  } else {
    Write-Host "Not pushed. After testing: git push --force-with-lease -u origin $MaintenanceBranch"
  }
} finally {
  if (Get-Location) {
    Pop-Location -ErrorAction SilentlyContinue
  }
}
