# say.ps1 - speak one sentence in a natural Windows voice. Installed by sunstone to
# ~/.claude/hooks/say.ps1; say.sh hands it text from WSL. Used by supermode to announce
# progress ("<this> is done. Taking up <that>.") when nobody is watching the terminal.
#   powershell -NoProfile -ExecutionPolicy Bypass -File say.ps1 -Text "Slice 3 is done."
# WinRT female voice (neural if installed, else OneCore Zira), SAPI Zira as fallback,
# never silent without leaving a note in %TEMP%\claude-say-errors.log. No chime.
param([Parameter(Mandatory = $true)][string]$Text)
$ErrorActionPreference = 'SilentlyContinue'
$errLog = Join-Path $env:TEMP 'claude-say-errors.log'
function Note($msg) { "$(Get-Date -Format o) $msg" | Out-File -Append -Encoding utf8 $errLog }
$spoken = $false
try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
  function Await($op, $t) { $asTask.MakeGenericMethod($t).Invoke($null, @($op)).GetAwaiter().GetResult() }
  [Windows.Media.SpeechSynthesis.SpeechSynthesizer, Windows.Media, ContentType = WindowsRuntime] | Out-Null
  [Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType = WindowsRuntime] | Out-Null
  $all = [Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices
  $fem = @($all | Where-Object { "$($_.Gender)" -eq 'Female' })
  $v = $fem | Where-Object { $_.DisplayName -match 'Aria|Jenny|Michelle|Natural|Sonia|Libby|Clara|Emily|Ava|Nova' } | Select-Object -First 1
  if (-not $v) { $v = $fem | Select-Object -First 1 }
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
  (New-Object Media.SoundPlayer $tmp).PlaySync()
  $spoken = $true
} catch { Note "WinRT path failed: $($_.Exception.Message)" }
if (-not $spoken) {
  try {
    Add-Type -AssemblyName System.Speech
    $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
    try { $s.SelectVoice('Microsoft Zira Desktop') } catch { $s.SelectVoiceByHints('Female') }
    $s.Speak($Text)
  } catch { Note "SAPI fallback failed too (nothing was spoken): $($_.Exception.Message)" }
}
