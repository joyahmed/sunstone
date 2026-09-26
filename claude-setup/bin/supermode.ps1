# supermode - launch Claude Code for unattended work (Windows).
#
# The PowerShell twin of bin/supermode: SUPERMODE=1 in the environment (the context
# guard is live; a successor inherits it), supermode.settings.json layered on this
# session only (auto-compaction off, guard hook on, gauge in front of the status
# line), every argument passed through to claude. Nothing in ~\.claude\settings.json
# is touched.
#
#   supermode                                       interactive
#   supermode --bg --permission-mode auto "supermode: resume"   a successor
$ErrorActionPreference = 'Stop'
$cfg = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR -replace '^~', $HOME } else { Join-Path $HOME '.claude' }
$settings = Join-Path $cfg 'supermode.settings.json'
if (-not (Test-Path -LiteralPath $settings)) {
  Write-Error "supermode: $settings is missing - run sunstone's setup.ps1 (or copy claude-setup\config\supermode.settings.json there)"
  exit 1
}
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { Write-Error 'supermode: claude is not on PATH'; exit 1 }

# The session's display name: <box>/<repo>. Same reasoning as bin/supermode -
# a session listing titles its rows from the display name, an unnamed session is
# titled from its first task (which can name a DIFFERENT box than the one the row
# leads to), and no session can rename itself from inside. box = first non-empty
# line of ~\.claude\hooks\claude-name.txt, else ~\.claude\bus-side, else the
# short hostname; repo = basename of the work tree, else of the current
# directory. An empty part is dropped, so no name starts or ends with "/", and an
# explicit -n/--name from the caller is left alone.
function Get-FirstLine($p) {
  if (-not (Test-Path -LiteralPath $p)) { return '' }
  try {
    foreach ($l in (Get-Content -LiteralPath $p -TotalCount 20 -ErrorAction Stop)) {
      $t = $l.Trim(); if ($t) { return $t }
    }
  } catch { }
  return ''
}
$nameGiven = $false
foreach ($a in $args) { if ($a -eq '-n' -or $a -eq '--name' -or $a -like '--name=*') { $nameGiven = $true } }
if (-not $nameGiven) {
  $box = Get-FirstLine (Join-Path $cfg 'hooks\claude-name.txt')
  if (-not $box) { $box = Get-FirstLine (Join-Path $cfg 'bus-side') }
  if (-not $box) { $box = ($env:COMPUTERNAME, [System.Net.Dns]::GetHostName() | Where-Object { $_ } | Select-Object -First 1) }
  $top = (& git rev-parse --show-toplevel 2>$null | Select-Object -First 1)
  if (-not $top) { $top = (Get-Location).Path }
  $repo = Split-Path -Leaf $top
  $box  = ($box  -replace '[^A-Za-z0-9._-]', '')
  $repo = ($repo -replace '[^A-Za-z0-9._-]', '')
  $addr = @($box, $repo | Where-Object { $_ }) -join '/'
  if ($addr) { $args = @('--name', $addr) + $args }
}

$env:SUPERMODE = '1'
& claude --settings $settings @args
exit $LASTEXITCODE
