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
$env:SUPERMODE = '1'
& claude --settings $settings @args
exit $LASTEXITCODE
