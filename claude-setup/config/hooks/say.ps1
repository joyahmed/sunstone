# say.ps1 - speak one sentence through Windows speech. Installed by sunstone to
# ~/.claude/hooks/say.ps1; say.sh hands it text (from WSL, or from Git Bash on a
# native Windows box). Used by supermode to announce progress ("<this> is done.
# Taking up <that>.") when nobody is watching the terminal.
#   powershell -NoProfile -ExecutionPolicy Bypass -File say.ps1 -Text "Slice 3 is done."
#   powershell -NoProfile -ExecutionPolicy Bypass -File say.ps1 -Text "..." -Voice "<id>"
#
# ⛔ NO VOICE NAME IS WRITTEN IN THIS FILE, and that is a rule, not an accident.
# Until 2026-09-26 the WinRT rung below chose its voice by matching a list of ten
# voice names hardcoded here. On a box where none of those ten was installed the
# match failed, the code fell through to "first female voice in the list", and every
# spoken line came out in a voice nobody had chosen - while the file looked like it
# was expressing a preference. A voice is a per-machine, per-person setting: it
# belongs in configuration, one value, read at run time. This file only resolves it.
#
# WHICH VOICE, in this precedence order:
#   1. -Voice <id>                  explicit argument (say.sh passes what it resolved)
#   2. $env:CLAUDE_VOICE            environment (say.sh forwards it, WSLENV included)
#   3. %USERPROFILE%\.claude\hooks\claude-voice.txt      this side's configured voice
#   4. nothing configured -> the voice Windows itself is set to use
# That is the same resolution chime.sh and voice-bake.sh already do on the shell
# side ($CLAUDE_VOICE, else claude-voice.txt beside the other name files) - one
# mechanism, spelled once per language, not a third invention here.
#
# ⚠️ The file is read from %USERPROFILE%, so the two sides are genuinely separate:
# a WSL $HOME is /home/<user> and a Windows one is C:\Users\<user>, and each side's
# say.sh resolves its own side's file. When say.sh on WSL forwards a voice it is
# forwarding that side's choice on purpose.
#
# THE LADDER, in order, first rung that speaks wins:
#   0. edge-tts - NOT here. It is say.sh's rung, above this script, because the
#      synthesiser is a command-line tool and say.sh owns the command line. It is
#      the only rung that can speak a neural voice which WinRT and SAPI cannot
#      reach at all (a Narrator-locked voice is one of those).
#   1. WinRT / OneCore  - the configured voice if it is installed, else the platform default.
#   2. SAPI             - the configured voice if that engine knows it, else its own default.
#   3. nothing spoke    - a line in %TEMP%\claude-say-errors.log saying so.
# Never silent without leaving a note. No chime.
param(
  [Parameter(Mandatory = $true)][string]$Text,
  [string]$Voice = ''
)
$ErrorActionPreference = 'SilentlyContinue'
$errLog = Join-Path $env:TEMP 'claude-say-errors.log'
function Note($msg) { "$(Get-Date -Format o) $msg" | Out-File -Append -Encoding utf8 $errLog }

# ── Which voice. Returns '' when nothing is configured, which every rung below
#    reads as "use the platform default" - never as "pick one for the user".
function Resolve-ClaudeVoice {
  if ($Voice) { return $Voice.Trim() }
  if ($env:CLAUDE_VOICE) { return $env:CLAUDE_VOICE.Trim() }
  $base = $env:USERPROFILE
  if (-not $base) { $base = $env:HOMEDRIVE + $env:HOMEPATH }
  if (-not $base) { return '' }
  $f = Join-Path $base '.claude\hooks\claude-voice.txt'
  try {
    if (Test-Path -LiteralPath $f) {
      $raw = Get-Content -LiteralPath $f -Raw
      if ($raw) { return ($raw -replace "[`r`n]", '').Trim() }
    }
  } catch { }
  return ''
}
$wanted = Resolve-ClaudeVoice

# ── Rung 1: WinRT / OneCore. Synthesises to a stream, and the bytes are played
#    from an OPENED STREAM rather than by handing SoundPlayer a path: the path
#    constructor can return from PlaySync() without a sound having come out, and
#    the stream form is the one measured audible on this class of machine.
$spoken = $false
try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
  function Await($op, $t) { $asTask.MakeGenericMethod($t).Invoke($null, @($op)).GetAwaiter().GetResult() }
  [Windows.Media.SpeechSynthesis.SpeechSynthesizer, Windows.Media, ContentType = WindowsRuntime] | Out-Null
  [Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType = WindowsRuntime] | Out-Null
  $all = [Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices
  $v = $null
  if ($wanted) {
    # Exact display name first, then a substring of either the display name or the
    # voice id, because one configured value has to serve engines that spell the
    # same voice differently. No preference list: if the configured voice is not
    # here, this rung has nothing to say about which voice should be used instead.
    $v = $all | Where-Object { "$($_.DisplayName)" -eq $wanted } | Select-Object -First 1
    if (-not $v) { $v = $all | Where-Object { "$($_.DisplayName)" -like "*$wanted*" -or "$($_.Id)" -like "*$wanted*" } | Select-Object -First 1 }
    if (-not $v) { Note "configured voice '$wanted' is not an installed WinRT voice; using the platform default" }
  }
  $synth = New-Object Windows.Media.SpeechSynthesis.SpeechSynthesizer
  if ($v) { $synth.Voice = $v }
  $synth.Options.SpeakingRate = 0.9
  $synth.Options.AudioVolume  = 1.0
  $stream = Await ($synth.SynthesizeTextToStreamAsync($Text)) ([Windows.Media.SpeechSynthesis.SpeechSynthesisStream])
  $size = [uint32]$stream.Size
  $dr = New-Object Windows.Storage.Streams.DataReader($stream.GetInputStreamAt(0))
  [void](Await ($dr.LoadAsync($size)) ([uint32]))
  $bytes = New-Object byte[] $size
  $dr.ReadBytes($bytes)
  $tmp = Join-Path $env:TEMP 'claude-say.wav'
  [System.IO.File]::WriteAllBytes($tmp, $bytes)
  $player = New-Object Media.SoundPlayer
  $player.Stream = [System.IO.File]::OpenRead($tmp)
  $player.PlaySync()
  $player.Stream.Close()
  $spoken = $true
} catch { Note "WinRT path failed: $($_.Exception.Message)" }

# ── Rung 2: SAPI. Quality floor, not a goal. It knows a different and smaller set
#    of voices, so the configured value is tried and then let go of - what it falls
#    back to is SAPI's own default, i.e. what this machine is set up to use.
if (-not $spoken) {
  try {
    Add-Type -AssemblyName System.Speech
    $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
    if ($wanted) {
      try { $s.SelectVoice($wanted) } catch {
        # SAPI spells some voices with a suffix the other engines do not use; one
        # configured value, so try that spelling before giving up on the choice.
        try { $s.SelectVoice("$wanted Desktop") } catch { Note "SAPI does not know the configured voice '$wanted'; using its default" }
      }
    }
    $s.Speak($Text)
  } catch { Note "SAPI fallback failed too (nothing was spoken): $($_.Exception.Message)" }
}
