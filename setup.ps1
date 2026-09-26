# sunstone setup (Windows)
# Run: powershell -ExecutionPolicy Bypass -File setup.ps1 [-MemoryRepo <git-url-or-path>] [-CloneTo <dir>] [-SkipMemory] [-SkipOverlay]
# Or right-click → Run with PowerShell (you will be prompted for the memory repo)
#
#   -MemoryRepo <v>      your personal memory repo (any git repo you own): a git URL or a local path.
#                        (-MemoryRepo:<v> is the same.) Also read from the SUNSTONE_MEMORY_REPO
#                        environment variable, or asked interactively when a console is present.
#   -CloneTo <v>         where to clone it when -MemoryRepo is a URL (default: ~\.ai-memory, the
#                        path the hooks also try when ~\.claude\ai-memory-path is missing).
#                        Ignored, with a notice, when -MemoryRepo is a local path.
#   -SkipMemory          do not touch ~\.claude\ai-memory-path
#   -SkipOverlay         install this checkout's trees only; ignore any skills, agents, commands,
#                        hooks, configs or settings.json the personal repo carries in the same layout

param(
    [string]$MemoryRepo = $env:SUNSTONE_MEMORY_REPO,
    [string]$CloneTo = "",
    [switch]$SkipMemory,
    [switch]$SkipOverlay
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# Every destination below hangs off the profile directory. With USERPROFILE
# unset - a service account, a scheduled task, a stripped environment - an
# unguarded $HomeDir is the empty string, every path resolves to the drive
# root, and the install lands in \.claude, \.git-hooks and \CLAUDE.md without
# a word. The .NET call finds the profile even when the variable is gone;
# failing that, refuse, the way setup.sh refuses with ${HOME:?}.
$HomeDir = $env:USERPROFILE
if (-not $HomeDir) { $HomeDir = [Environment]::GetFolderPath("UserProfile") }
if (-not $HomeDir) { throw "USERPROFILE is not set and your profile directory could not be resolved. Nothing has been installed." }

# ⛔ git is a hard dependency of every step that follows: the memory repo is
# resolved with it, and the two guards are installed by pointing the GLOBAL
# core.hooksPath at ~\.git-hooks. Checked here, before the banner, for the same
# reason setup.sh checks it there - a missing git used to surface halfway
# through, and on this side it was worse than a bare error: Invoke-GitQuiet
# swallows the CommandNotFoundException and leaves $LASTEXITCODE holding some
# earlier command's status, so a clone that never happened could read as
# success and the run continued against a directory that is not there. The two
# entry points now refuse identically instead of one dying and one silently
# skipping the whole git-hooks block.
# Get-Command directly rather than Test-Command: the helpers are defined below
# the banner, and this has to run before any of them.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "git is required and was not found on PATH; nothing has been installed."
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " sunstone setup (Windows)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ── Helpers ──────────────────────────────────────

function Backup-Item {
    param([string]$Path, [string]$DestDir)
    if (Test-Path -LiteralPath $Path) {
        # $DestDir is OPTIONAL and only the skills caller passes one. A skill
        # is REGISTERED by its directory existing, so a <name>.bak.<stamp>\
        # written beside it registers as a second, stale skill with an
        # outdated description - one pick away from being used. Hooks and
        # settings keep the in-place default: a .bak file beside them is inert,
        # and changing behaviour that was never broken would be the wrong fix.
        # Mirrors setup.sh backup() gaining an optional destination (98d9c64).
        $stem = $Path
        if ($DestDir) {
            if (-not (Test-Path -LiteralPath $DestDir)) { New-Item -ItemType Directory -Force -Path $DestDir | Out-Null }
            $stem = Join-Path $DestDir (Split-Path -Leaf $Path)
        }
        # Unique even when the same file is replaced twice within one second
        # - the loop New-SettingsSnapshot and setup.sh's backup() both use.
        # Without it the second backup silently overwrites the first.
        $bak = "$stem.bak.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        $i = 1
        while (Test-Path -LiteralPath $bak) { $bak = "$stem.bak.$(Get-Date -Format 'yyyyMMdd_HHmmss')-$i"; $i++ }
        # ⛔ NEVER announce a backup that may not exist. This used to print
        # "backed up: ..." unconditionally after a SilentlyContinue copy, so every
        # such line was an unverified claim - and callers then deleted the
        # original on the strength of it. Verify, and report the truth.
        #
        # $errs matters as much as Test-Path: Copy-Item -Recurse keeps going
        # after a per-file failure, so a partially-copied tree still leaves the
        # destination present. A backup missing files is not a backup when the
        # next statement is Remove-Item -Recurse -Force.
        #
        # This is load-bearing for the skills step specifically: an unreadable
        # tree is now deliberately routed HERE (see Get-TreeSignature), and a
        # recursive copy is exactly what fails on those files.
        $errs = @()
        Copy-Item -Recurse -Force -LiteralPath $Path -Destination $bak -ErrorAction SilentlyContinue -ErrorVariable errs
        if ((Test-Path -LiteralPath $bak) -and $errs.Count -eq 0) {
            Write-Host "  backed up: $Path → $bak"
            return $true
        }
        $why = if ($errs.Count -gt 0) { $errs[0].ToString() } else { "destination was not created" }
        Write-Host "  ! BACKUP FAILED for $Path - $why" -ForegroundColor Red
        Write-Host "    nothing here will be deleted on the strength of a backup that does not exist." -ForegroundColor Red
        if (Test-Path -LiteralPath $bak) {
            Write-Host "    a PARTIAL copy was left at $bak - inspect it before trusting it." -ForegroundColor Red
        }
        return $false
    }
    # Nothing there to lose.
    return $true
}

# The PowerShell stand-in for `diff -rq` in setup.sh's step_skills: a sorted
# list of "<relative path>|<sha256>" for every file in a tree. Comparing two of
# these answers "is this the same skill?" without walking bytes, and it is what
# keeps a re-run of an unchanged tree from making a fresh backup every time.
function Get-TreeSignature {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    $root = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\', '/')
    $lines = @()
    foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($root.Length).TrimStart('\', '/')
        # ⛔ Get-FileHash MUST NOT be allowed to throw here. This function only
        # decides "same or different"; it is not a integrity check, and it has
        # no business aborting an install. Under $ErrorActionPreference = "Stop"
        # a single unreadable file used to kill the whole run - which is exactly
        # what happened on the first end-to-end Windows run (2026-09-11):
        #   Get-FileHash: The file cannot be accessed by the system. :
        #   '...\.codex\skills\agile-product-owner\agile-product-owner\SKILL.md'
        # Those are WSL-created symlinks (reparse tag 0xA000001D,
        # IO_REPARSE_TAG_LX_SYMLINK). Win32 returns error 1920 for them because
        # the tag is Linux-specific; git-bash resolves them, PowerShell cannot.
        # They get onto C: whenever a recursive copy is run from inside WSL -
        # which is the documented workaround for the 9P-share copy failure, so
        # this residue is self-inflicted by our own advice and WILL be present
        # on machines set up that way.
        #
        # An unreadable file folds in as a sentinel instead. The source tree
        # comes from a git clone and is always readable, so the sentinel makes
        # the two signatures differ - which routes to backup-then-replace, the
        # safe outcome. It does NOT make an unchanged tree look changed on a
        # re-run, so this adds no .bak clutter.
        try {
            $lines += "$rel|$((Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash)"
        } catch {
            $lines += "$rel|UNREADABLE"
            if (-not $script:UnreadableWarned) { $script:UnreadableWarned = @{} }
            if (-not $script:UnreadableWarned.ContainsKey($f.FullName)) {
                $script:UnreadableWarned[$f.FullName] = $true
                Write-Host "    note: unreadable, treated as changed: $($f.FullName)"
            }
        }
    }
    return (($lines | Sort-Object) -join "`n")
}

function Test-SameFile {
    param([string]$A, [string]$B)
    try {
        return ((Get-FileHash -LiteralPath $A -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $B -Algorithm SHA256).Hash)
    } catch { return $false }
}

# Copy $Src over $Dst. An existing $Dst that differs is backed up first; an
# identical one is left alone, so a re-run of setup produces no backup clutter.
function Install-File {
    param([string]$Src, [string]$Dst)
    # LINK_HOOKS makes $Dst a symlink back to $Src. Copy-Item resolves the link
    # and then refuses to overwrite the file with itself ("Cannot overwrite the
    # item ... with itself"), which aborted setup at the Ship-Dir that re-ships
    # claude-setup\config\hooks into ~\.claude\hooks. A link already IS the
    # source, so there is nothing to copy and nothing to back up.
    $existing = Get-Item -LiteralPath $Dst -Force -ErrorAction SilentlyContinue
    if ($existing -and $existing.LinkType -eq "SymbolicLink") {
        $lt = @($existing.Target)
        if ($lt -and $lt[0] -eq $Src) { return }
    }
    # ⚠️ Backup-Item returns a value now, and an uncaptured return in PowerShell
    # flows into THIS function's output - which then flows into Ship's. Assign
    # it, both to keep the streams clean and because the answer matters: a
    # single file is about to be overwritten with -Force, and if we could not
    # preserve the old one we leave it alone rather than destroy it silently.
    if ((Test-Path -LiteralPath $Dst) -and -not (Test-SameFile $Src $Dst)) {
        if (-not (Backup-Item $Dst)) {
            Write-Host "    skipped: $Dst left exactly as it was" -ForegroundColor Yellow
            return
        }
    }
    $parent = Split-Path -Parent $Dst
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Copy-Item -LiteralPath $Src -Destination $Dst -Force
}

# Test-StaleSubset - the twin of setup.sh's is_stale_subset(): true when
# $Installed is a STRICT SUBSET of $Repo, i.e. every line of the installed file
# also appears in the repo copy AND the repo copy has at least one line the
# installed file lacks. That is exactly what a copy installed once and never
# refreshed looks like, and it is the ONLY shape safe to replace without asking
# anybody - a file somebody EDITED has lines of its own, which makes this false.
#
# ⚠️ THREE THINGS HERE ARE DELIBERATE AND EACH ONE IS A BUG IF CHANGED BACK.
#  · A case-sensitive ORDINAL set, not a PowerShell hashtable. `@{}` compares
#    string keys CASE-INSENSITIVELY, so two lines differing only in case would
#    count as the same line and an edited file could read as a mere old copy.
#  · An empty repo copy returns false, never true. Same refusal as the awk twin:
#    with nothing to compare against, "missing lines" is meaningless and the
#    answer would license replacing a file on no evidence at all.
#  · Get-Content drops the line terminator, so this is EOL-agnostic where the
#    awk twin is not. .gitattributes keeps the whole tree LF on every platform,
#    so the two agree on the files that actually exist; if a CRLF copy ever does
#    turn up, this side is the LENIENT one - it would call it an old copy where
#    POSIX calls it diverged. Said here rather than left to be discovered.
function Test-StaleSubset {
    param([string]$Installed, [string]$Repo)
    if (-not (Test-Path -LiteralPath $Installed -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $Repo -PathType Leaf)) { return $false }
    try {
        $repoLines = @(Get-Content -LiteralPath $Repo -ErrorAction Stop)
        $instLines = @(Get-Content -LiteralPath $Installed -ErrorAction Stop)
    } catch {
        # Unreadable is not "refreshable". Same bias as Get-TreeSignature: when
        # in doubt, do not be the thing that deleted somebody's file.
        return $false
    }
    if ($repoLines.Count -eq 0) { return $false }
    $repoSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($l in $repoLines) { [void]$repoSet.Add([string]$l) }
    $instSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($l in $instLines) { [void]$instSet.Add([string]$l) }
    foreach ($l in $instSet) { if (-not $repoSet.Contains($l)) { return $false } }
    foreach ($l in $repoSet) { if (-not $instSet.Contains($l)) { return $true } }
    return $false
}

# Install-FileSafe - Install-File for a file people edit in place, and the twin
# of setup.sh's install_copy_safe(). Used for ~\.claude\commands\*.md.
#
# ⛔ WHY IT EXISTS, and it is a measured failure rather than a tidiness idea.
# Commands are installed as plain copies and NOTHING refreshed them between
# runs, so they drift: counted on one box, three of six installed commands were
# strict subsets of their repo copy with zero lines of their own - never
# refreshed since the missing sections landed, one of which was the rule that
# keeps an unattended run from failing its own commit every slice. The obvious
# repair - copy over them every run, which is what Install-File does - is the
# one that must NOT be made here, because this is also the directory a person
# edits a slash command in: it would buy the drift fix by destroying that edit,
# leaving only a .bak in ~\.claude\backups that nobody ever reads again.
#
# Five answers, one of which writes:
#   absent    → plain copy, silently (the normal install; unchanged)
#   identical → nothing at all, so a re-run leaves no backup clutter
#   subset    → REFRESHED, backed up first (Test-StaleSubset proved no local
#               edit is in it), and the refresh is announced
#   diverged  → KEPT and named on stdout. Never replaced, never backed up.
#   symlink   → skipped entirely. A link already tracks its source, so there is
#               nothing to refresh, and turning it back into a copy would
#               re-create the drift the link was made to end.
#
# Behaviour parity with install_copy_safe() in setup.sh is the contract; the
# POSIX side has the regression battery
# (claude-setup/config/hooks/tests/setup-commands-refresh.test.sh), and there is
# no pwsh on the boxes that run it, so a change here is checked by reading both.
function Install-FileSafe {
    param([string]$Src, [string]$Dst)
    $existing = Get-Item -LiteralPath $Dst -Force -ErrorAction SilentlyContinue
    if ($existing -and $existing.LinkType -eq "SymbolicLink") { return }
    if (Test-Path -LiteralPath $Dst) {
        if (Test-SameFile $Src $Dst) { return }
        if (-not (Test-StaleSubset $Dst $Src)) {
            Write-Host "  ! kept $Dst as it is: it differs from the repo copy by more than being out of date, so it was NOT refreshed." -ForegroundColor Yellow
            Write-Host "    compare it with $Src and delete it if the local changes are not wanted."
            return
        }
        # ⚠️ Assign the result: an uncaptured return flows into this function's
        # output and then into Ship's, and the answer matters - a file is about
        # to be overwritten, and without a backup it is left alone instead.
        if (-not (Backup-Item $Dst)) {
            Write-Host "    skipped: $Dst left exactly as it was" -ForegroundColor Yellow
            return
        }
        Copy-Item -LiteralPath $Src -Destination $Dst -Force
        Write-Host "  refreshed: $Dst (an old copy of $Src, with no local edits in it)"
        return
    }
    $parent = Split-Path -Parent $Dst
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Copy-Item -LiteralPath $Src -Destination $Dst -Force
}

# LINK_HOOKS is resolved exactly the way setup.sh's install_file() resolves it:
# the key lives in the PERSONAL repo's sunstone.conf, read from the repo this
# run resolved and otherwise from the recorded path file. That fallback is the
# entire point - -SkipMemory leaves $MemoryRepoPath empty, and reading only it
# is how the POSIX side once shipped a key that was documented, accepted and
# silently ignored.
function Test-LinkHooks {
    $repo = $MemoryRepoPath
    if (-not $repo) { $repo = Read-PathFile "$ClaudeDir\ai-memory-path" }
    if (-not $repo) { return $false }
    return ((Get-ConfValue $repo "LINK_HOOKS" "") -eq "1")
}

# Set once, so a machine that cannot make symlinks says so one time instead of
# once per hook.
$script:LinkHooksFellBack = $false

# Install a hook so that updating the repo updates the LIVE hook - the whole
# reason LINK_HOOKS exists. On Windows only a symlink can do that, and the two
# cheaper-looking options are both wrong in ways worth recording:
#
#   - a junction (New-Item -ItemType Junction) is DIRECTORY-only, so it cannot
#     link an individual hook file at all;
#   - a hard link shares the inode, but git pull writes a new file and renames
#     it over the old one, which SEVERS the link. The live hook would silently
#     stop tracking the repo on the first update that actually mattered, which
#     is worse than an honest copy.
#
# A symlink needs Developer Mode or an elevated shell. When it is refused we
# fall back to a copy rather than leave the machine with no hook: copied hooks
# still work, they just need setup re-run to pick up framework fixes.
function Install-HookFile {
    param([string]$Src, [string]$Dst)
    if (-not (Test-LinkHooks)) { Install-File $Src $Dst; return }

    $item = Get-Item -LiteralPath $Dst -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType -eq "SymbolicLink") {
        $tgt = @($item.Target)
        if ($tgt -and $tgt[0] -eq $Src) { return }
    }
    if ($item) {
        if (-not (Backup-Item $Dst)) {
            Write-Host "    skipped: $Dst left exactly as it was" -ForegroundColor Yellow
            return
        }
        Remove-Item -LiteralPath $Dst -Force -ErrorAction SilentlyContinue
    }
    $parent = Split-Path -Parent $Dst
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

    try {
        New-Item -ItemType SymbolicLink -Path $Dst -Target $Src -ErrorAction Stop | Out-Null
    } catch {
        Install-File $Src $Dst
        if (-not $script:LinkHooksFellBack) {
            $script:LinkHooksFellBack = $true
            Write-Host "  LINK_HOOKS=1, but this shell cannot create symlinks (needs Developer Mode or an elevated shell) - installed copies instead" -ForegroundColor Yellow
        }
    }
}

# Report what is actually on disk, not what was intended - a fallback to a copy
# must not be announced as a link.
function Get-InstallKind {
    param([string]$Dst)
    $i = Get-Item -LiteralPath $Dst -Force -ErrorAction SilentlyContinue
    if ($i -and $i.LinkType -eq "SymbolicLink") { return "linked" }
    return "installed"
}

function Test-Command {
    param([string]$Cmd)
    return (Get-Command $Cmd -ErrorAction SilentlyContinue) -ne $null
}

# Run git where a non-zero exit is an expected answer, not a crash. Under
# $ErrorActionPreference = "Stop", Windows PowerShell 5.1 turns anything a
# native command writes to stderr into a terminating NativeCommandError, so the
# preference is relaxed for this call only and the exit code is returned.
function Invoke-GitQuiet {
    param([string[]]$GitArgs)
    $ErrorActionPreference = "SilentlyContinue"
    & git @GitArgs 2>$null | Out-Null
    return $LASTEXITCODE
}

# Same as Invoke-GitQuiet but returns stdout (empty string when git fails).
function Get-GitOutput {
    param([string[]]$GitArgs)
    $ErrorActionPreference = "SilentlyContinue"
    $out = (& git @GitArgs 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { return "" }
    return $out
}

# Run a node script, show its output, return the exit code (same stderr rule
# as Invoke-GitQuiet: a merge script's own error line must not crash setup).
function Invoke-NodeScript {
    param([string[]]$NodeArgs)
    $ErrorActionPreference = "Continue"
    & node @NodeArgs 2>&1 | ForEach-Object { Write-Host "    $_" }
    return $LASTEXITCODE
}

# First line of a one-line path file, TRIMMED (a path may contain spaces).
function Read-PathFile {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return "" }
    return ((Get-Content -LiteralPath $File -TotalCount 1 -ErrorAction SilentlyContinue) | Out-String).Trim()
}

# Forward slashes: node, bash and python all accept / on Windows, only some
# accept \. Every consumer of the path files and every command written into
# settings.json uses this form.
function ConvertTo-Fwd { param([string]$P) return ($P -replace '\\', '/') }

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    # UTF-8 WITHOUT a BOM: a non-ASCII profile path must survive intact (ASCII
    # would write '?'), and the readers trim only whitespace, so a BOM would
    # break the path (-Encoding UTF8 emits one on Windows PowerShell 5.1).
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

# Read one KEY from <personal-repo>/claude-setup/config/sunstone.conf.
# A tiny KEY=VALUE parser - the file is user content and is never executed.
# Same rules as the hooks: last matching line wins, whitespace around the key
# and the '=' allowed, a '#' starts a comment only at line start or after
# whitespace (so a bare '#' inside a value or a double-quoted value is kept),
# a double-quoted value runs to the next '"', whitespace is trimmed (never
# deleted from inside a value). Returns $Default when the file or the key is
# absent.
function Get-ConfValue {
    param([string]$Repo, [string]$Key, [string]$Default)
    $file = Join-Path $Repo "claude-setup\config\sunstone.conf"
    if (-not (Test-Path -LiteralPath $file)) { return $Default }
    $val = $null
    foreach ($line in (Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)) {
        $t = $line.Trim()
        if ($t -eq "" -or $t.StartsWith("#")) { continue }
        $eq = $t.IndexOf("=")
        if ($eq -lt 1) { continue }
        if ($t.Substring(0, $eq).Trim() -ne $Key) { continue }
        # Leading whitespace is kept until the comment rule has run: KEY=#x is
        # the value "#x", KEY= #x is a comment (empty -> $Default). A quoted
        # value runs to the NEXT '"' - a '#' inside it is literal, anything
        # after the closing quote is ignored, and an unterminated quote takes
        # the rest of the line. Same shape as readConf() in the .js hook; an
        # anchored ^"(.*)"$ regex cannot express it (it is greedy across a
        # second quote, and leaves the quotes in place when anything but a
        # comment follows the closing one).
        $v = $t.Substring($eq + 1)
        if ($v.TrimStart().StartsWith('"')) {
            $v = $v.TrimStart().Substring(1)
            $q = $v.IndexOf('"')
            if ($q -ge 0) { $v = $v.Substring(0, $q) }
        } else {
            $v = ($v -replace '\s#.*$', '').Trim()
        }
        # Last matching line wins, and an EMPTY value un-sets the key so the
        # caller's default applies - `KEY=x` followed by `KEY=` reads as unset,
        # not as "x". setup.sh gets that for free (grep | tail -n1 sees only the
        # last line); this loop has to say it, and used to keep the earlier
        # value instead, so the two installers disagreed about a conf file that
        # comments a key out by blanking it rather than deleting the line.
        if ($v -ne "") { $val = $v } else { $val = $null }
    }
    if ($null -eq $val) { return $Default }
    return $val
}

# ~\.claude\settings.json is edited by merge scripts several times in one run.
# New-SettingsSnapshot returns a fresh backup path (unique even within one
# second); Resolve-SettingsSnapshot removes it again when the merge changed
# nothing, and otherwise says where it is.
$ClaudeDir    = "$HomeDir\.claude"
$ClaudeHooks  = "$ClaudeDir\hooks"
$settingsPath = "$ClaudeDir\settings.json"
# Whether the user had a settings.json BEFORE this run. The hook registration
# below creates one, so without this flag the template merge that follows would
# "back up" a file the user never wrote - a .bak of an intermediate state
# nobody would ever want restored. setup.sh carries the same flag.
$settingsPreexisted = Test-Path -LiteralPath $settingsPath
function New-SettingsSnapshot {
    if (-not (Test-Path -LiteralPath $settingsPath)) { return $null }
    $b = "$settingsPath.bak.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    $i = 1
    while (Test-Path -LiteralPath $b) { $b = "$settingsPath.bak.$(Get-Date -Format 'yyyyMMdd_HHmmss')-$i"; $i++ }
    Copy-Item -LiteralPath $settingsPath -Destination $b -Force
    return $b
}
function Resolve-SettingsSnapshot {
    param([string]$Bak)
    if (-not $Bak) { return }
    if (Test-SameFile $settingsPath $Bak) { Remove-Item -LiteralPath $Bak -Force } else { Write-Host "  backed up: $settingsPath → $Bak" }
}

# ── Personal memory repo (resolved FIRST) ────────
# ai-memory-path -> the PERSONAL memory repo (any git repo you own). This
# framework repo holds only the hooks; the memory tree lives in yours.
#
# This is resolved BEFORE any file or git setting is written: a typo in
# -MemoryRepo or a failed clone throws here with nothing installed, so there is
# nothing to roll back.
Write-Host "Resolving the personal memory repo..." -ForegroundColor Cyan
$pathFile = "$ClaudeDir\ai-memory-path"
$MemoryRepoPath = $null
$cloneToUsed = $false
if ($SkipMemory) {
    Write-Host "  -SkipMemory: leaving $pathFile untouched"
} else {
    # 1) Decide which personal repo to use: parameter/env, else prompt on a console.
    $current = Read-PathFile $pathFile
    # .git may be a file (worktree): Test-Path without -PathType, the same test the hooks use.
    if (-not ($current -and (Test-Path -LiteralPath (Join-Path $current ".git")))) { $current = "" }
    if (-not $MemoryRepo) {
        # Ask whenever stdin is a console, even with stdout redirected.
        $interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
        if ($interactive) {
            $hint = if ($current) { $current } else { "Enter to skip" }
            $MemoryRepo = Read-Host "  Personal memory repo (git URL or local path) [$hint]"
            if (-not $MemoryRepo) { $MemoryRepo = $current }
        } else {
            $MemoryRepo = $current
            if ($current) {
                Write-Host "  no -MemoryRepo given; keeping existing $pathFile -> $current"
            } else {
                Write-Host "  no -MemoryRepo given and no console to ask on; skipping."
                Write-Host "  re-run with:  .\setup.ps1 -MemoryRepo <git-url-or-path>"
            }
        }
    }

    # 2) Resolve it: a local path is used in place; a URL is cloned into -CloneTo,
    #    or by default into ~\.ai-memory - the one path every hook also tries when
    #    ai-memory-path is missing, so a lost path file still finds it. An
    #    existing clone at the destination is reused. A URL is scheme://... or
    #    the scp form, which must START with user@host: (same rule as setup.sh).
    if ($MemoryRepo) {
        if ($MemoryRepo -match '://' -or $MemoryRepo -match '^[^/\\]+@[^/\\]+:') {
            $cloneToUsed = $true
            $dest = if ($CloneTo) { $CloneTo -replace '^~', $HomeDir } else { Join-Path $HomeDir ".ai-memory" }
            if (Test-Path -LiteralPath (Join-Path $dest ".git")) {
                Write-Host "  using existing clone: $dest"
            } elseif (Test-Path -LiteralPath $dest) {
                throw "$dest exists but is not a git repo; pass -CloneTo <dir> or remove it. Nothing has been installed."
            } else {
                Write-Host "  cloning $MemoryRepo -> $dest"
                if ((Invoke-GitQuiet @("clone", "--quiet", $MemoryRepo, $dest)) -ne 0) { throw "git clone of $MemoryRepo failed (a git@host: URL needs an SSH key registered with the host; https:// needs none for a public repo). Nothing has been installed." }
            }
            $MemoryRepoPath = (Resolve-Path -LiteralPath $dest).Path
        } else {
            $spec = $MemoryRepo -replace '^~', $HomeDir
            if (-not (Test-Path -LiteralPath $spec -PathType Container)) {
                throw "$spec is not a directory (and does not look like a git URL). Nothing has been installed."
            }
            $MemoryRepoPath = (Resolve-Path -LiteralPath $spec).Path
            if ((Invoke-GitQuiet @("-C", $MemoryRepoPath, "rev-parse", "--git-dir")) -ne 0) { throw "$MemoryRepoPath is not a git repository; the sync hook needs one. Nothing has been installed." }
        }
        # The first directory this script creates: every throw above it leaves
        # the machine untouched.
        New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null
        Write-Utf8NoBom $pathFile (ConvertTo-Fwd $MemoryRepoPath)
        Write-Host "  ai-memory-path -> $MemoryRepoPath"
    }
}
if ($CloneTo -and -not $cloneToUsed) { Write-Host "  ignored: -CloneTo only applies to a URL" }
Write-Host "  ok"
Write-Host ""

# ── Claude Code memory hooks (Windows) ───────────
# Independent of the repo choice so a later -MemoryRepo run only has to write
# the path file.
Write-Host "Installing portable AI-memory sync..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $ClaudeHooks | Out-Null
# The framework checkout, for the doctor notice (the hook is a copy, so its
# own location says nothing). Written unconditionally, as setup.sh does: where
# this checkout lives is true whether or not node is here to run the hooks,
# and the summary at the end reports it as recorded.
Write-Utf8NoBom "$ClaudeDir\sunstone-path" (ConvertTo-Fwd $ScriptDir)

# Windows has no python3/jq, so the Linux ai-memory-sync.sh / ai-memory-commit.sh
# cannot run here. These node ports produce identical behavior; node is
# required. The doctor notice runs memory-doctor.js from THIS checkout, found
# through ~\.claude\sunstone-path; it is installed as its node port when one
# is shipped, else as the POSIX script run by Git for Windows' bash.
$hkSrc  = "$ScriptDir\claude-setup\config\hooks\ai-memory-sync.js"
$ciSrc  = "$ScriptDir\claude-setup\config\hooks\ai-memory-commit.js"
$mdJs   = "$ScriptDir\claude-setup\config\hooks\memory-doctor-notice.js"
$mdSh   = "$ScriptDir\claude-setup\config\hooks\memory-doctor-notice.sh"
$mrgSrc = "$ScriptDir\claude-setup\config\merge-claude-settings.mjs"
$tplMrg = "$ScriptDir\claude-setup\config\merge-settings-template.mjs"
$slSrc  = "$ScriptDir\claude-setup\config\statusline-command.js"
$hkDst  = "$ClaudeHooks\ai-memory-sync.js"
$ciDst  = "$ClaudeHooks\ai-memory-commit.js"
$slDst  = "$ClaudeDir\statusline-command.js"

# Every path inside a settings.json command is double-quoted: a profile
# directory with a space in it must still run.
$syncCmd   = "node `"$(ConvertTo-Fwd $hkDst)`""
$commitCmd = "node `"$(ConvertTo-Fwd $ciDst)`""
$doctorCmd = $null
function Write-ManualHooks {
    Write-Host "  add these to $settingsPath by hand:" -ForegroundColor Yellow
    Write-Host "      SessionStart: $syncCmd"
    if ($doctorCmd) { Write-Host "      SessionStart: $doctorCmd" }
    Write-Host "      SessionEnd:   $commitCmd   (async)"
}

$memoryHooksOk = $false
if ((Test-Path -LiteralPath $hkSrc) -and (Test-Command node)) {
    Install-HookFile $hkSrc $hkDst
    # The write half of sync: SessionEnd commits memory (no network), SessionStart
    # pushes it on the next run. Split that way so ending a session is never slower.
    Install-HookFile $ciSrc $ciDst
    Write-Host "  $(Get-InstallKind $hkDst) hooks\ai-memory-{sync,commit}.js"
    if (Test-Path -LiteralPath $mdJs) {
        Install-HookFile $mdJs "$ClaudeHooks\memory-doctor-notice.js"
        $doctorCmd = "node `"$(ConvertTo-Fwd "$ClaudeHooks\memory-doctor-notice.js")`""
        Write-Host "  $(Get-InstallKind "$ClaudeHooks\memory-doctor-notice.js") hooks\memory-doctor-notice.js"
    } elseif (Test-Path -LiteralPath $mdSh) {
        Install-HookFile $mdSh "$ClaudeHooks\memory-doctor-notice.sh"
        $doctorCmd = "bash `"$(ConvertTo-Fwd "$ClaudeHooks\memory-doctor-notice.sh")`""
        Write-Host "  $(Get-InstallKind "$ClaudeHooks\memory-doctor-notice.sh") hooks\memory-doctor-notice.sh (runs under Git for Windows' bash)"
    }
    # A statusline is a PREFERENCE, not part of the memory layer, so the
    # framework ships none. A root that carries claude-setup\config\
    # statusline-command.js gets it installed and registered; one that does not
    # simply has no statusLine key written, and the memory hooks register
    # exactly the same either way.
    $slPresent = Test-Path -LiteralPath $slSrc
    if ($slPresent) {
        Install-File $slSrc $slDst
        Write-Host "  installed statusline-command.js"
    }

    # Register SessionStart/SessionEnd memory hooks in settings.json -
    # idempotent, existing entries are kept. Backed up first; the backup is
    # dropped again if the merge turned out to be a no-op.
    #
    # ⚠️ The statusline path is the LAST argument and is optional. It used to be
    # required and second, which meant a checkout without a statusline
    # registered no memory hooks at all - the preference and the feature were
    # wired together.
    $settingsBak = New-SettingsSnapshot
    $memoryHooksOk = $true
    $mrgArgs = @($mrgSrc, $settingsPath, $hkDst, $ciDst)
    if ($slPresent) { $mrgArgs += $slDst }
    if ((Invoke-NodeScript $mrgArgs) -ne 0) { $memoryHooksOk = $false }
    # The doctor notice goes through the template merger: a one-entry template
    # written to a temp file, so the same identity rule (script basename per
    # event) applies and a re-run adds nothing.
    if ($doctorCmd) {
        if (Test-Path -LiteralPath $tplMrg) {
            $tmp = [IO.Path]::GetTempFileName()
            try {
                $tpl = @{ hooks = @{ SessionStart = @(@{ hooks = @(@{ type = "command"; command = $doctorCmd }) }) } }
                Write-Utf8NoBom $tmp (ConvertTo-Json -InputObject $tpl -Depth 10)
                if ((Invoke-NodeScript @($tplMrg, $settingsPath, $tmp)) -ne 0) { $memoryHooksOk = $false }
            } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        } else {
            Write-Host "  ! merge-settings-template.mjs not shipped; the doctor notice was not registered" -ForegroundColor Yellow
            $memoryHooksOk = $false
        }
    }
    Resolve-SettingsSnapshot $settingsBak
    if ($memoryHooksOk) {
        Write-Host "  ok"
    } else {
        Write-Host "  ! could not auto-register the hooks; $settingsPath may be incomplete" -ForegroundColor Red
        Write-ManualHooks
    }
} else {
    # Not fatal - the git hooks and both install roots below still apply - but
    # it must not read as a success: on Windows the memory hooks ARE the node
    # ports (there is no python3/jq for the .sh twins), so without node there
    # is no session memory at all. The summary at the end repeats this.
    if (-not (Test-Path -LiteralPath $hkSrc)) {
        Write-Host "  ! skipped: $hkSrc is missing from this checkout; the memory hooks were NOT installed" -ForegroundColor Red
    } else {
        Write-Host "  ! skipped: node was not found on PATH; the memory hooks were NOT installed" -ForegroundColor Red
        Write-Host "    the Windows hooks are node ports, so node is required for them. Install node and re-run"
        Write-Host "    this script; everything else below is installed either way."
    }
}
Write-Host ""

# ── Global git hooks ─────────────────────────────
# Same files and the same core.hooksPath mechanism as setup.sh. The hooks are
# POSIX sh and run under Git for Windows' bundled sh.
#
# `init.templateDir` alone would not reach existing repos (templates are copied
# at git init / clone only); `core.hooksPath` does, which is why it is used. A
# repo-local core.hooksPath overrides the global one completely - such a repo
# needs the files copied into its own hooks directory as well.
#
# ⚠️ The source of truth is claude-setup\config\git-hooks\*; the live copies are
# ~\.git-hooks\*. Pulling this repo does not update the live copies - re-run
# setup.ps1 after a pull that touches a hook.
#
# WHICH hooks land is not decided here. The files are installed per install
# root by Install-GitHooks, exactly like every other tree, so the personal repo
# can ship guards of its own and can override a shipped one by carrying the
# same filename. This section only prepares the directories and points git at
# them - a one-time global setting, not a per-root one.
#
# The framework itself ships only the two conf-driven guards, pre-commit and
# pre-push. Anything opinionated about commit CONTENT - a message
# rewriter, a template, a linter - belongs in a personal repo rather than
# in a framework other people install: carrying the file there IS the opt-in,
# which is why there is no flag to gate it with.
$gitHooksOk = $false
$GitHooks = "$HomeDir\.git-hooks"
$GitTemplates = "$HomeDir\.git-templates\hooks"
# git itself is not re-checked here: the preflight at the top of the script
# already refused to install anything without it, so the only reason this block
# can be skipped is a checkout that does not carry the hook sources.
if (Test-Path -LiteralPath "$ScriptDir\claude-setup\config\git-hooks") {
    Write-Host "Preparing global git hooks (memory staging guard + force-push guard)..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $GitHooks, $GitTemplates | Out-Null

    # ⛔ ~\.git-templates\hooks must stay EMPTY - see the git-hooks step for why
    # a hook copied there fork-bombs every fresh clone. The hook files themselves
    # are removed per name as each root installs; these are the backups an older
    # setup.ps1 left beside them, which git would copy into a clone just the same.
    Get-ChildItem -LiteralPath $GitTemplates -Filter '*.bak.*' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    # Record whatever global git config is about to be replaced, so an
    # uninstall can restore it rather than only unset it.
    $prevGitConfig = "$ClaudeDir\git-config.previous"
    $wantHooks = ConvertTo-Fwd $GitHooks
    $wantTemplates = ConvertTo-Fwd "$HomeDir\.git-templates"
    foreach ($pair in @(@("core.hooksPath", $wantHooks), @("init.templateDir", $wantTemplates))) {
        $key = $pair[0]; $want = $pair[1]
        $old = Get-GitOutput @("config", "--global", "--get", $key)
        if ($old -and $old -ne $want) {
            New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null
            [IO.File]::AppendAllText($prevGitConfig, "$key=$old`n", (New-Object Text.UTF8Encoding $false))
            Write-Host "  ! global $key was '$old'; replacing it (old value recorded in $prevGitConfig)" -ForegroundColor Red
        }
    }
    git config --global core.hooksPath $wantHooks
    git config --global init.templateDir $wantTemplates
    Write-Host "  core.hooksPath: $(git config --global --get core.hooksPath)"
    $gitHooksOk = $true
    Write-Host "  ok"
    Write-Host ""
} else {
    # setup.sh has no such guard and would die here under `set -e`; this side
    # skips, so it has to SAY it skipped rather than let the summary claim the
    # guards are active.
    Write-Host "Installing global git hooks..." -ForegroundColor Cyan
    Write-Host "  ! skipped: $ScriptDir\claude-setup\config\git-hooks is missing from this checkout" -ForegroundColor Yellow
    Write-Host ""
}

# ── Install roots: this checkout, then the personal repo (the overlay) ─────
#
# The personal memory repo MAY carry the same relative layout as this checkout
# - skills\, agents\, config\, plugins\, claude-setup\commands\,
# claude-setup\config\{agents,hooks,settings.json,CLAUDE.global.md} - and it is
# then applied as a SECOND install root, after this one, with identical rules.
# Whatever both roots ship, the personal copy lands last and wins. This
# checkout may ship none of these trees; then only the personal root
# contributes. -SkipOverlay applies this checkout only.
#
# One function per step, taking the root as its argument; each prints
# "<step>: from <root>" or "<step>: skipped" and records what it installed.

$script:Installed = @()      # steps that installed something from the current root
$script:Overridden = 0       # files of the current step that a later root ships too
$script:SkillsSkipped = 0    # skill trees left untouched because their backup failed
$script:LastRoot = $null     # the root applied last; set before the roots are applied
$script:ClaudeGlobalAny = $false   # any root ships claude-setup\config\CLAUDE.global.md
function Step-Done {
    param([string]$Step, [string]$Root, [string]$Detail = "")
    $suffix = if ($Detail) { " ($Detail)" } else { "" }
    Write-Host "  ${Step}: from $Root$suffix"
    $script:Installed += $Step
}
function Step-Skip { param([string]$Step) Write-Host "  ${Step}: skipped" }
# The one line every step prints.
function Step-End {
    param([string]$Step, [string]$Root, [int]$Count, [string]$Detail)
    if ($Count -gt 0) {
        if ($script:Overridden -gt 0) { $Detail = "$Detail; $($script:Overridden) overridden by the personal root" }
        Step-Done $Step $Root $Detail
    } elseif ($script:Overridden -gt 0) {
        Write-Host "  ${Step}: skipped ($($script:Overridden) overridden by the personal root)"
    } else {
        Step-Skip $Step
    }
    $script:Overridden = 0
}

# Install <Root>\<Rel> at <Dst> unless a LATER root ships the same <Rel>: the
# last root wins without the earlier copy landing first, which would back the
# file up on every run. Returns $true when installed.
# -Safe routes through Install-FileSafe instead: refresh an out-of-date copy,
# keep and name an edited one. For the trees people edit in place (commands).
function Ship {
    param([string]$Root, [string]$Rel, [string]$Dst, [switch]$Link, [switch]$Safe)
    if (-not (Test-Path -LiteralPath (Join-Path $Root $Rel) -PathType Leaf)) { return $false }
    if ($Root -ne $script:LastRoot -and (Test-Path -LiteralPath (Join-Path $script:LastRoot $Rel) -PathType Leaf)) {
        $script:Overridden++
        return $false
    }
    if ($Link) { Install-HookFile (Join-Path $Root $Rel) $Dst }
    elseif ($Safe) { Install-FileSafe (Join-Path $Root $Rel) $Dst }
    else { Install-File (Join-Path $Root $Rel) $Dst }
    return $true
}

# Ship every file of <Root>\<Rel> matching <Filter> into <Dst>; returns the count.
function Ship-Dir {
    param([string]$Root, [string]$Rel, [string]$Dst, [string]$Filter, [switch]$Link, [switch]$Safe)
    $n = 0
    $dir = Join-Path $Root $Rel
    if (Test-Path -LiteralPath $dir -PathType Container) {
        foreach ($f in (Get-ChildItem -LiteralPath $dir -File -Filter $Filter)) {
            if (Ship $Root (Join-Path $Rel $f.Name) (Join-Path $Dst $f.Name) -Link:$Link -Safe:$Safe) { $n++ }
        }
    }
    return $n
}

# skills\<name>\ → ~\.codex\skills, ~\.config\opencode\skills, ~\.claude\skills
# (each <name> replaced whole - a skill is a tree, not a file to diff - and a
# name the later root also ships is left to that root).
function Install-Skills {
    param([string]$Root)
    $n = 0
    $dir = Join-Path $Root "skills"
    if (Test-Path -LiteralPath $dir -PathType Container) {
        foreach ($d in (Get-ChildItem -LiteralPath $dir -Directory)) {
            if ($Root -ne $script:LastRoot -and (Test-Path -LiteralPath (Join-Path $script:LastRoot "skills\$($d.Name)") -PathType Container)) {
                $script:Overridden++
                continue
            }
            foreach ($dest in @("$HomeDir\.codex\skills", "$HomeDir\.config\opencode\skills", "$ClaudeDir\skills")) {
                New-Item -ItemType Directory -Force -Path $dest | Out-Null
                $target = Join-Path $dest $d.Name
                # ⚠️ A skill is replaced WHOLE rather than merged, so an
                # existing <name>\ here may be a skill the user wrote by hand
                # under the same name, not an earlier copy of ours. Back it up
                # first - and only when it DIFFERS, so re-running an unchanged
                # tree leaves no .bak clutter. Mirrors setup.sh:step_skills.
                if (Test-Path -LiteralPath $target) {
                    if ((Get-TreeSignature $d.FullName) -ne (Get-TreeSignature $target)) {
                        # ⛔ If the backup did not happen, do NOT delete. Skip this
                        # skill in this root and carry on: one unbackupable tree
                        # must not cost the user their work, and must not abort
                        # the whole install either - that failure mode is what
                        # Get-TreeSignature's try/catch exists to prevent.
                        if (-not (Backup-Item $target (Join-Path (Split-Path -Parent $dest) "skill-backups"))) {
                            Write-Host "    skipped: $target left exactly as it was" -ForegroundColor Yellow
                            $script:SkillsSkipped++
                            continue
                        }
                    }
                    Remove-Item -Recurse -Force -LiteralPath $target
                }
                Copy-Item -Recurse -LiteralPath $d.FullName -Destination $target
            }
            $n++
        }
    }
    Step-End "skills" $Root $n "$n → ~\.codex\skills, ~\.config\opencode\skills, ~\.claude\skills"
}

# agents\AGENTS.md → ~\AGENTS.md ; agents\CLAUDE.md → ~\CLAUDE.md + ~\.claude\CLAUDE.md
# (a differing existing file is backed up beside itself). A CLAUDE.global.md
# shipped by either root takes ~\.claude\CLAUDE.md instead - see Install-ClaudeGlobal.
function Install-Agents {
    param([string]$Root)
    $got = @(); $n = 0
    if (Ship $Root "agents\AGENTS.md" "$HomeDir\AGENTS.md") { $got += "AGENTS.md → ~\AGENTS.md"; $n++ }
    if (Ship $Root "agents\CLAUDE.md" "$HomeDir\CLAUDE.md") {
        $n++
        if ($script:ClaudeGlobalAny) {
            $got += "CLAUDE.md → ~\CLAUDE.md (~\.claude\CLAUDE.md comes from CLAUDE.global.md)"
        } else {
            Install-File "$Root\agents\CLAUDE.md" "$ClaudeDir\CLAUDE.md"
            $got += "CLAUDE.md → ~\CLAUDE.md, ~\.claude\CLAUDE.md"
        }
    }
    Step-End "agents" $Root $n ($got -join ", ")
}

# config\codex-config.toml, codex-hooks.json, codex-AGENTS.md, codex-rules\ → ~\.codex\
function Install-Codex {
    param([string]$Root)
    $got = @(); $n = 0
    foreach ($pair in @(@("codex-config.toml", "config.toml"), @("codex-hooks.json", "hooks.json"), @("codex-AGENTS.md", "AGENTS.md"))) {
        if (Ship $Root "config\$($pair[0])" "$HomeDir\.codex\$($pair[1])") { $got += $pair[1]; $n++ }
    }
    $r = Ship-Dir $Root "config\codex-rules" "$HomeDir\.codex\rules" "*"
    if ($r -gt 0) { $got += "$r rules"; $n += $r }
    Step-End "codex" $Root $n (($got -join ", ") + " → ~\.codex")
}

# config\opencode-config.jsonc → ~\.config\opencode\opencode.jsonc ; plugins\*.js → ~\.opencode\plugins\
function Install-OpenCode {
    param([string]$Root)
    $got = @(); $n = 0
    if (Ship $Root "config\opencode-config.jsonc" "$HomeDir\.config\opencode\opencode.jsonc") { $got += "opencode.jsonc → ~\.config\opencode"; $n++ }
    $p = Ship-Dir $Root "plugins" "$HomeDir\.opencode\plugins" "*.js"
    if ($p -gt 0) { $got += "$p plugins → ~\.opencode\plugins"; $n += $p }
    Step-End "opencode" $Root $n ($got -join ", ")
}

# claude-setup\config\settings.json → MERGED into ~\.claude\settings.json by
# the template merger: hooks are appended unless the same script is already
# registered under that event, statusLine/env keys are copied only when
# absent, permissions are never touched. Commands in a template may use '~';
# they are left as written. The personal root's merge runs after this
# checkout's because the roots are applied in that order.
function Install-Settings {
    param([string]$Root)
    $tpl = "$Root\claude-setup\config\settings.json"
    if (-not (Test-Path -LiteralPath $tpl)) { Step-Skip "settings"; return }
    if (-not (Test-Command node)) { Write-Host "  settings: skipped (node not found - merge $tpl into $settingsPath by hand)"; return }
    if (-not (Test-Path -LiteralPath $tplMrg)) { Write-Host "  settings: skipped (merger not shipped: $tplMrg - merge $tpl into $settingsPath by hand)"; return }
    # Only a settings.json the user already had is worth backing up; one this
    # run just created a few steps ago is not (see $settingsPreexisted).
    $bak = $null
    if ($settingsPreexisted) { $bak = New-SettingsSnapshot }
    if ((Invoke-NodeScript @($tplMrg, $settingsPath, $tpl)) -eq 0) {
        Step-Done "settings" $Root "merged into $settingsPath"
    } else {
        Write-Host "  ! settings: merge of $tpl failed; merge it into $settingsPath by hand" -ForegroundColor Red
    }
    Resolve-SettingsSnapshot $bak
}

# claude-setup\config\CLAUDE.global.md → ~\.claude\CLAUDE.md. The last root
# that ships one wins, and it beats agents\CLAUDE.md for this one destination.
function Install-ClaudeGlobal {
    param([string]$Root)
    $n = 0
    if (Ship $Root "claude-setup\config\CLAUDE.global.md" "$ClaudeDir\CLAUDE.md") { $n = 1 }
    Step-End "CLAUDE.global.md" $Root $n "→ ~\.claude\CLAUDE.md"
}

# claude-setup\config\git-hooks\* → ~\.git-hooks\ ONLY. Never the template dir.
# An overlay step like every other one: whatever both roots ship, the personal
# copy lands last and wins, and a guard only the personal repo carries is
# installed from there alone. Mirrors setup.sh:step_git_hooks.
function Install-GitHooks {
    param([string]$Root)
    $n = 0
    $dir = Join-Path $Root "claude-setup\config\git-hooks"
    if (Test-Path -LiteralPath $dir -PathType Container) {
        foreach ($f in (Get-ChildItem -LiteralPath $dir -File)) {
            # The later root ships this same guard: it wins, so skip it here.
            if ($Root -ne $script:LastRoot -and
                (Test-Path -LiteralPath (Join-Path $script:LastRoot "claude-setup\config\git-hooks\$($f.Name)"))) {
                $script:Overridden++
                continue
            }
            # An existing hook that differs is REPLACED (backed up first by
            # Install-File). The config check says nothing when core.hooksPath
            # already pointed here, so this is the only place the user learns
            # their own hook logic has just stopped running. Both shipped
            # guards exec <repo>/.git/hooks/<name>, so that is where it belongs.
            $dst = "$GitHooks\$($f.Name)"
            if ((Test-Path -LiteralPath $dst) -and -not (Test-SameFile $f.FullName $dst)) {
                Write-Host "  ! $dst exists and differs; replacing it (backup kept beside it)." -ForegroundColor Yellow
                Write-Host "    if that was your own hook rather than an earlier copy from this framework, its"
                Write-Host "    logic no longer runs: move it into <repo>/.git/hooks/$($f.Name) - the shipped one chains to it."
            }
            Install-File $f.FullName $dst
            # ⛔ DO NOT also install into ~\.git-templates\hooks. init.templateDir
            # copies that directory into every new clone's .git\hooks, so the hook
            # core.hooksPath already runs finds an IDENTICAL COPY OF ITSELF to
            # chain into. `git commit` then hangs in every fresh clone, spawning
            # an unbounded tree of shells - and `timeout` does not bound it.
            #
            # It shipped that way "as a fallback if core.hooksPath is ever unset
            # by hand". That fallback is worth far less than the fork bomb it
            # costs, and core.hooksPath is set unconditionally earlier in this
            # same run anyway.
            #
            # Purge rather than merely skip, so a machine that already carries
            # the copies is REPAIRED by running setup again.
            Remove-Item -LiteralPath "$GitTemplates\$($f.Name)" -Force -ErrorAction SilentlyContinue
            $n++
        }
    }
    Step-End "git-hooks" $Root $n "$n → ~\.git-hooks"
}

# claude-setup\config\supermode.settings.json → ~\.claude\supermode.settings.json and
# claude-setup\bin\supermode.ps1 → ~\.claude\bin\supermode.ps1. Supermode is opt-in per
# launch: the launcher layers that file onto ONE session with `claude --settings`, so
# auto-compaction off and the context guard never enter ~\.claude\settings.json. The
# guard and gauge scripts arrive with the hooks step, /supermode and /supercode with
# the commands step.
function Install-Supermode {
    param([string]$Root)
    $got = @(); $n = 0
    if (Ship $Root "claude-setup\config\supermode.settings.json" "$ClaudeDir\supermode.settings.json") {
        $got += "settings → ~\.claude\supermode.settings.json"; $n++
    }
    if (Ship $Root "claude-setup\bin\supermode.ps1" "$ClaudeDir\bin\supermode.ps1") {
        $got += "launcher → ~\.claude\bin\supermode.ps1"; $n++
        if (-not (($env:PATH -split ';') -contains "$ClaudeDir\bin")) {
            Write-Host "    note: add $ClaudeDir\bin to PATH to type `supermode`, or run the .ps1 by path"
        }
    }
    Step-End "supermode" $Root $n ($got -join ", ")
}

function Install-Root {
    param([string]$Label, [string]$Root)
    $script:Installed = @()
    Write-Host "Installing from the $Label root: $Root" -ForegroundColor Cyan
    Install-Skills $Root
    Install-Agents $Root
    Install-Codex $Root
    Install-OpenCode $Root
    # -Safe: a slash command is a text file that invites a local edit, so an
    # out-of-date copy is refreshed and an edited one is kept and named, rather
    # than every file being overwritten on every run. See Install-FileSafe.
    $n = Ship-Dir $Root "claude-setup\commands" "$ClaudeDir\commands" "*.md" -Safe
    Step-End "commands" $Root $n "$n → ~\.claude\commands"
    # Subagent files: nothing in Claude Code switches the main model on a
    # condition, so these are the mechanism for "escalate this kind of work".
    $n = Ship-Dir $Root "claude-setup\config\agents" "$ClaudeDir\agents" "*.md"
    Step-End "subagents" $Root $n "$n → ~\.claude\agents"
    # Hook scripts are only COPIED; the memory hooks were registered above and
    # anything else is registered by the settings.json of the root that ships it.
    $n = Ship-Dir $Root "claude-setup\config\hooks" $ClaudeHooks "*" -Link
    Step-End "hooks" $Root $n "$n → ~\.claude\hooks (copied, not registered)"
    Install-Supermode $Root
    Install-GitHooks $Root
    Install-Settings $Root
    Install-ClaudeGlobal $Root
    Write-Host ""
    return ,$script:Installed
}

# The overlay root: the repo resolved above, or - with -SkipMemory or when
# nothing was passed and no console asked - the repo already recorded in
# ~\.claude\ai-memory-path (or ~\.ai-memory, the hooks' own fallback).
$OverlayRoot = $null
if (-not $SkipOverlay) {
    if ($MemoryRepoPath) {
        $OverlayRoot = $MemoryRepoPath
    } else {
        $cand = Read-PathFile $pathFile
        if ($cand -and (Test-Path -LiteralPath $cand -PathType Container)) {
            $OverlayRoot = (Resolve-Path -LiteralPath $cand).Path
        } elseif (Test-Path -LiteralPath (Join-Path $HomeDir ".ai-memory\.git")) {
            $OverlayRoot = Join-Path $HomeDir ".ai-memory"
        }
    }
    # The memory repo IS this checkout: one root, not the same one twice.
    if ($OverlayRoot -and ((ConvertTo-Fwd $OverlayRoot).TrimEnd('/') -eq (ConvertTo-Fwd $ScriptDir).TrimEnd('/'))) { $OverlayRoot = $null }
}

$script:LastRoot = if ($OverlayRoot) { $OverlayRoot } else { $ScriptDir }
foreach ($r in @($ScriptDir, $OverlayRoot)) {
    if ($r -and (Test-Path -LiteralPath "$r\claude-setup\config\CLAUDE.global.md")) { $script:ClaudeGlobalAny = $true }
}
$installedFramework = Install-Root "framework" $ScriptDir
$installedPersonal = @()
if ($OverlayRoot) { $installedPersonal = Install-Root "personal" $OverlayRoot }

# ── Verify ───────────────────────────────────────

Write-Host "========================================" -ForegroundColor Green
Write-Host " Setup Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

# A skill left untouched because its backup failed is the one outcome a reader
# must not scroll past - "Setup Complete" would otherwise imply it landed.
if ($script:SkillsSkipped -gt 0) {
    Write-Host "! $($script:SkillsSkipped) skill tree(s) were NOT updated: their backup failed, so the existing" -ForegroundColor Red
    Write-Host "  copy was left exactly as it was rather than deleted. Look for BACKUP FAILED above." -ForegroundColor Red
    Write-Host ""
}

# Each line reports what this run actually did: a skipped block above (no
# node, or a checkout without the hook sources) must not turn into a claim
# that it installed something.
Write-Host "Installed:"
if ($gitHooksOk) {
    # ⚠️ $gitHookNames was never assigned anywhere in this script, so this line
    # printed a literal "{}" - reported by the first successful Windows run,
    # 2026-09-11. Read the LIVE directory instead, exactly as setup.sh:718 does:
    # what matters to the reader is which hooks are in force now, including any
    # the personal root added, not which ones this run happened to write.
    $ghLive = (Get-ChildItem -LiteralPath "$HomeDir\.git-hooks" -File -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Name | Where-Object { $_ -notmatch '\.bak\.' } | Sort-Object) -join ','
    if (-not $ghLive) { $ghLive = "none" }
    Write-Host "  git hooks:     $HomeDir\.git-hooks\{$ghLive} (core.hooksPath; the template dir is kept EMPTY on purpose)"
} else {
    Write-Host "  git hooks:     NOT installed (claude-setup\config\git-hooks missing from this checkout)" -ForegroundColor Yellow
}
$doctorName = if ($doctorCmd) { if ($doctorCmd.StartsWith("node")) { ", memory-doctor-notice.js" } else { ", memory-doctor-notice.sh" } } else { "" }
if (Test-Path -LiteralPath $hkDst) {
    Write-Host "  session hooks: $ClaudeHooks\{ai-memory-sync.js, ai-memory-commit.js$doctorName}"
} else {
    Write-Host "  session hooks: NOT installed - node is required for them on Windows" -ForegroundColor Yellow
}
Write-Host "  framework:     $ScriptDir  (recorded in $ClaudeDir\sunstone-path for the doctor notice)"
Write-Host ""

Write-Host "Install roots:"
Write-Host "  framework: $ScriptDir"
$fw = if ($installedFramework.Count -gt 0) { $installedFramework -join ", " } else { "nothing (this checkout ships none of the optional trees)" }
Write-Host "    installed: $fw"
if ($OverlayRoot) {
    Write-Host "  personal:  $OverlayRoot"
    $pe = if ($installedPersonal.Count -gt 0) { $installedPersonal -join ", " } else { "nothing (the repo carries none of the optional trees)" }
    Write-Host "    installed: $pe"
} elseif ($SkipOverlay) {
    Write-Host "  personal:  skipped (-SkipOverlay)"
} else {
    Write-Host "  personal:  none (no personal repo recorded; its skills\, agents\, config\, plugins\ and"
    Write-Host "             claude-setup\{commands,config} would be installed after the framework's)"
}
Write-Host ""

Write-Host "Memory:"
if ($MemoryRepoPath) {
    $memFile = Get-ConfValue $MemoryRepoPath "MEMORY_FILE" "claude-setup/memory/ABOUT-ME.md"
    $memDir  = Get-ConfValue $MemoryRepoPath "MEMORY_DIR"  "claude-setup/memory"
    Write-Host "  personal repo: $MemoryRepoPath  (recorded in $pathFile)"
    if (Test-Path -LiteralPath (Join-Path $MemoryRepoPath $memFile)) {
        Write-Host "  injected file: $memFile"
    } elseif (Test-Path -LiteralPath (Join-Path $MemoryRepoPath "$memDir/MEMORY.md")) {
        Write-Host "  injected file: $memDir/MEMORY.md  (MEMORY_FILE $memFile not found; using the index)"
    } else {
        Write-Host "  injected file: none yet - create $memFile in the repo and the hook picks it up next session"
    }
    Write-Host "  memory tree:   $memDir  (the SessionEnd hook commits only this path)"
    Write-Host "  optional config: $MemoryRepoPath\claude-setup\config\sunstone.conf"
    # LINK_CLAUDE_MD is a setup.sh feature: a symlink on Windows needs Developer
    # Mode or an elevated shell, so this side keeps installing copies and says
    # so once; memory-doctor's drift check reports a copy edited in place.
    if ((Get-ConfValue $MemoryRepoPath "LINK_CLAUDE_MD" "") -eq "1") {
        Write-Host "  LINK_CLAUDE_MD=1 is set but ignored here: setup.ps1 installs CLAUDE.md as copies (memory-doctor's drift check covers them)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  no personal repo recorded; hooks are installed and stay silent until"
    Write-Host "  $pathFile points at a git repo (or ~\.ai-memory is one)."
    Write-Host "  re-run:  .\setup.ps1 -MemoryRepo <git-url-or-path>"
    Write-Host "  optional config: <personal-repo>\claude-setup\config\sunstone.conf"
}
Write-Host "  config keys (KEY=VALUE, all optional; defaults shown):"
Write-Host "    MEMORY_DIR=claude-setup/memory              tree the SessionEnd hook may commit"
Write-Host "    MEMORY_FILE=claude-setup/memory/ABOUT-ME.md file injected into every session"
Write-Host "    MEMORY_INDEX=claude-setup/memory/MEMORY.md  index memory-doctor checks"
Write-Host '    MEMORY_REPOS="<repo-name>"                  repos with the mixed-staging guard'
Write-Host '    GUARDED_REPOS="sunstone <repo-name>"        repos with the force-push guard'
Write-Host '    MEMORY_META_FILES=""                        files in MEMORY_DIR that are structure, not memories'
Write-Host '    PROJECT_ROOTS=""                            dirs projects live under (memory-doctor slug resolution)'
Write-Host '    QUEUE_FILE=""                               a markdown work queue; set, memory-doctor checks its NOW table'
Write-Host '    QUEUE_NOW_HEADING=""                        its NOW heading (default: the first H2 containing "NOW")'
Write-Host '    QUEUE_NOW_MAX=3                             rows the NOW table may hold'
Write-Host '    BUS_DIR=""                                  session bus dir (outbox-<side>.md per machine); set = on'
Write-Host '    BUS_SIDE=""                                 this machine''s side (default: windows/mac/wsl/linux, detected)'
Write-Host '    LINK_CLAUDE_MD=""                           1 = setup.sh symlinks the two CLAUDE.md files (ignored by setup.ps1)'
Write-Host '    LINK_HOOKS=""                                1 = install hooks as symlinks, so a repo pull updates them (needs Developer Mode or an elevated shell; falls back to copies)'
Write-Host ""
Write-Host "Restart Claude Code to pick up the hooks."
