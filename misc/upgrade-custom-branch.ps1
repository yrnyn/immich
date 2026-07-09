<#
.SYNOPSIS
Creates a versioned custom branch by replaying the timezone patch on a newer Immich release.

.DESCRIPTION
The current branch must use the naming pattern vX.Y.Z-tz-null-fix. The script fetches
the requested upstream tag, creates vA.B.C-tz-null-fix, replays the custom commits onto
that tag, updates and commits the custom-image workflow, and checks the resulting patch.
Existing versioned custom branches are never changed. The script asks before it
creates/rebases a branch and, when -Push is supplied, again before it publishes to origin.
The confirmed push starts the custom-image GitHub Actions workflow for the new version.

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
  if (-not $sourceBranch) {
    throw 'Detached HEAD is not supported. Switch to a versioned custom branch first.'
  }

  if ($sourceBranch -notmatch '^(?<sourceTag>v\d+\.\d+\.\d+)(?<suffix>-tz-null-fix)$') {
    throw "Current branch '$sourceBranch' must match vX.Y.Z-tz-null-fix."
  }

  $sourceTag = $Matches.sourceTag
  $newBranch = "$TargetTag$($Matches.suffix)"

  $sourceVersion = [Version]$sourceTag.Substring(1)
  $targetVersion = [Version]$TargetTag.Substring(1)
  if ($targetVersion -le $sourceVersion) {
    throw "Target tag '$TargetTag' must be newer than source tag '$sourceTag'."
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

  & git merge-base --is-ancestor $sourceTag $sourceBranch
  if ($LASTEXITCODE -ne 0) {
    throw "Source tag '$sourceTag' is not an ancestor of '$sourceBranch'."
  }

  if (Test-GitRef "refs/heads/$newBranch") {
    throw "Local branch '$newBranch' already exists; it will not be changed."
  }

  $remoteBranch = & git ls-remote --heads origin "refs/heads/$newBranch"
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to check whether '$newBranch' already exists on origin."
  }
  if ($remoteBranch) {
    throw "Remote branch '$newBranch' already exists; it will not be changed."
  }

  Write-Host "`nUpgrade plan:"
  Write-Host "  Source branch: $sourceBranch"
  Write-Host "  Source tag:    $sourceTag"
  Write-Host "  Target tag:    $TargetTag"
  Write-Host "  New branch:    $newBranch"
  Write-Host "`nCommits to replay:"
  Invoke-Git log --oneline "$sourceTag..$sourceBranch"

  if (-not (Confirm-Action "Create '$newBranch' and rebase these commits onto '$TargetTag'?")) {
    Write-Host 'Canceled before creating a branch. No Git history was changed.'
    return
  }

  Write-Host "Creating $newBranch from $sourceBranch..."
  Invoke-Git switch -c $newBranch $sourceBranch

  try {
    Invoke-Git rebase --onto $TargetTag $sourceTag
  } catch {
    Write-Error "Rebase stopped on '$newBranch'. Resolve the conflicts, then run 'git rebase --continue'."
    Write-Error "To abandon this upgrade attempt, run 'git rebase --abort' and then switch back to '$sourceBranch'."
    throw
  }

  Invoke-Git range-diff "$sourceTag..$sourceBranch" "$TargetTag..HEAD"

  $workflowPath = Join-Path $repoRoot '.github/workflows/build-custom-server.yml'
  if (-not (Test-Path -LiteralPath $workflowPath)) {
    throw "Custom-image workflow '$workflowPath' does not exist."
  }

  if (-not (Confirm-Action "Update the custom-image workflow for '$newBranch' and commit it?")) {
    Write-Host "Workflow was not changed. '$newBranch' remains local and is not ready to trigger a new image build."
    return
  }

  $workflow = [System.IO.File]::ReadAllText($workflowPath) -replace "`r`n", "`n"
  $branchPattern = '(?m)^      - v\d+\.\d+\.\d+-tz-null-fix$'
  $tagPattern = '(?m)^  IMAGE_TAG: v\d+\.\d+\.\d+-tz-null-fix$'
  if ([regex]::Matches($workflow, $branchPattern).Count -ne 1 -or [regex]::Matches($workflow, $tagPattern).Count -ne 1) {
    throw "Custom-image workflow must contain exactly one versioned branch trigger and IMAGE_TAG."
  }

  $workflow = [regex]::Replace($workflow, $branchPattern, "      - $newBranch")
  $workflow = [regex]::Replace($workflow, $tagPattern, "  IMAGE_TAG: $newBranch")
  [System.IO.File]::WriteAllText($workflowPath, $workflow, [System.Text.UTF8Encoding]::new($false))

  Invoke-Git add -- .github/workflows/build-custom-server.yml
  Invoke-Git diff --cached -- .github/workflows/build-custom-server.yml
  Invoke-Git commit -m "ci: build custom image for $TargetTag"

  Invoke-Git diff --check "$TargetTag...HEAD"
  Invoke-Git diff --stat "$TargetTag...HEAD"

  & git merge-base --is-ancestor $TargetTag HEAD
  if ($LASTEXITCODE -ne 0) {
    throw "Target tag '$TargetTag' is not an ancestor of '$newBranch' after rebase."
  }

  Write-Host "`nUpgrade branch '$newBranch' is ready."
  Write-Host "Review: git diff $TargetTag...HEAD -- server/src/services/metadata.service.ts"

  if ($Push) {
    if (-not (Confirm-Action "Push '$newBranch' to origin?")) {
      Write-Host "Not pushed. Publishing this branch will start the custom-image workflow: git push -u origin $newBranch"
      return
    }

    Write-Host "Pushing $newBranch to origin..."
    Invoke-Git push -u origin $newBranch
  } else {
    Write-Host "Not pushed. After review and testing, publish with: git push -u origin $newBranch"
  }
} finally {
  if (Get-Location) {
    Pop-Location -ErrorAction SilentlyContinue
  }
}
