# ============================================================
# ANALIZADOR DE MULTITRACKS V2.24.23 - WINDOWS
# Estudio PG
# Requiere ffmpeg.exe y ffprobe.exe en esta misma carpeta.
# ============================================================

# FFmpeg escribe mensajes informativos por STDERR incluso cuando funciona correctamente.
# En Windows PowerShell, usar "Stop" hace que esos mensajes se conviertan en errores fatales.
$ErrorActionPreference = "Continue"

# ------------------------------------------------------------
# PERFIL DE RENDIMIENTO / DESARROLLO
# ------------------------------------------------------------
# El cronómetro empieza después de elegir la carpeta para no medir tiempo humano.
$PerfTotal = New-Object System.Diagnostics.Stopwatch
$PerfRows = New-Object System.Collections.Generic.List[object]
$PerfRowMap = @{}
$PerfDuplicateRows = New-Object System.Collections.Generic.List[object]
$ProgressPerf = [ordered]@{ StateWrites = 0; StateWriteMs = 0.0 }

$Perf = [ordered]@{
    FFprobeCalls          = 0
    FileStatsCalls        = 0
    StereoCalls           = 0
    DuplicateHashCalls    = 0
    FingerprintFiles      = 0
    FingerprintCalls      = 0
    DuplicatePairCalls    = 0
    EffectiveDepthCalls   = 0
    EffectiveDepthSkippedSilence = 0
    ConversionCalls       = 0
    CopyCalls             = 0
    FFprobeMs             = 0.0
    FileStatsMs           = 0.0
    StereoMs              = 0.0
    DuplicateHashMs       = 0.0
    FingerprintMs         = 0.0
    DuplicatePairMs       = 0.0
    EffectiveDepthMs      = 0.0
    ConversionMs          = 0.0
    CopyMs                = 0.0
    ReportMs              = 0.0
}

$Optimization = [ordered]@{
    MetadataSinglePassFiles = 0
    StereoRmsReusedFiles    = 0
    StereoRmsFallbackFiles  = 0
    DirectLevelStatsFiles   = 0
    LevelStatsFallbackFiles = 0
    AxcorrelateCalls        = 0
    DepthEarlyExit24        = 0
    DepthEarlyExit32        = 0
    DepthFullScan24         = 0
    DepthFullScan32         = 0
    DepthSamplesTotal       = 0L
    DepthSamplesScanned     = 0L
    DepthBytesTotal         = 0L
    DepthBytesScanned       = 0L
    DepthErrors             = 0
}

$DuplicateStats = [ordered]@{
    TheoreticalPairs      = 0
    EffectivePairs        = 0
    NonHashPairs          = 0
    ExactHashMatches      = 0
    FingerprintMode       = 'OMITIDO'
    FingerprintFiles      = 0
    FingerprintRuns       = 0
    FingerprintRejected   = 0
    FullComparisons       = 0
    SignalMatches         = 0
    TransitiveSkipped     = 0
    HashMode              = 'OMITIDO'
}

function New-PerfRow {
    param([pscustomobject]$Info)

    $sizeBytes = 0L
    try { $sizeBytes = (Get-Item -LiteralPath $Info.File).Length } catch {}

    return [pscustomobject]@{
        RelativePath      = $Info.RelativePath
        SizeMB            = [math]::Round($sizeBytes / 1MB, 2)
        SizeBytes         = $sizeBytes
        DurationSec       = [math]::Round($Info.DurationSec, 3)
        Channels          = $Info.Channels
        SampleRate        = $Info.SampleRate
        BitDepth          = $Info.BitDepth
        FFprobeMs         = 0.0
        FileStatsMs       = 0.0
        StereoMs          = 0.0
        EffectiveDepthMs  = 0.0
        HashMs            = 0.0
        TotalMainMs       = 0.0
    }
}

function Get-PerfRow {
    param([string]$RelativePath)
    if ($PerfRowMap.ContainsKey($RelativePath)) { return $PerfRowMap[$RelativePath] }
    return $null
}

Add-Type -AssemblyName System.Windows.Forms

Add-Type -AssemblyName System.Drawing

# ------------------------------------------------------------
# VENTANA DE PROGRESO - PROCESO INDEPENDIENTE
# ------------------------------------------------------------
# La UI corre en otro proceso PowerShell para que el reloj siga actualizándose
# aunque el proceso principal esté bloqueado esperando a FFmpeg/FFprobe.

if ($PSScriptRoot) {
    $ScriptDir = $PSScriptRoot
}
elseif (Get-Variable -Name ScriptRoot -ErrorAction SilentlyContinue) {
    $ScriptDir = $ScriptRoot
}
else {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$ReportPublicationPath = Join-Path $ScriptDir 'PublicacionInformes.ps1'
if (-not (Test-Path -LiteralPath $ReportPublicationPath -PathType Leaf)) {
    throw "No se encontró el módulo de publicación protegida: $ReportPublicationPath"
}
. $ReportPublicationPath
$ProgressUIPath = Join-Path $ScriptDir "ProgressUI.ps1"
$ProgressStateFile = Join-Path $env:TEMP ("AnalizadorMultitracksProgress_" + [guid]::NewGuid().ToString("N") + ".json")
$ProgressReadyFile = "$ProgressStateFile.ready"
$script:ProgressProcess = $null
$script:DirectLevelValidation = [ordered]@{
    Checked = 0
    Failed = 0
    Disabled = $false
    MaxPeakDiffDb = 0.0
    MaxRmsDiffDb = 0.0
}
$script:EtaEstimatedTotalSec = $null
$script:EtaLastBasePercent = -1.0
$script:EtaLastLoggedBasePercent = -1.0
$script:EtaSamples = @()
$script:EtaClock = New-Object System.Diagnostics.Stopwatch
$script:EtaDiag = [ordered]@{
    Calls = 0
    BelowTime = 0
    BelowPercent = 0
    Eligible = 0
    Samples = 0
}

function Write-ProgressState {
    param(
        [int]$Percent,
        [string]$Stage,
        [string]$Item = "",
        [bool]$Completed = $false,
        [double]$EtaPercent = -1.0
    )

    if ($Percent -lt 0)   { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }
    if ($EtaPercent -lt 0) { $EtaPercent = [double]$Percent }
    if ($EtaPercent -gt 100) { $EtaPercent = 100.0 }

    $script:EtaDiag.Calls++

    $elapsedMs = 0L
    if ($null -ne $script:EtaClock -and ($script:EtaClock.IsRunning -or $script:EtaClock.ElapsedMilliseconds -gt 0)) {
        $elapsedMs = [long]$script:EtaClock.ElapsedMilliseconds
    }
    $elapsedSec = $elapsedMs / 1000.0

    if ($elapsedSec -lt 8.0) { $script:EtaDiag.BelowTime++ }
    if ($EtaPercent -lt 20.0) { $script:EtaDiag.BelowPercent++ }

    $remainingSec = $null
    if (-not $Completed -and $EtaPercent -ge 20.0 -and $EtaPercent -lt 100.0 -and $elapsedSec -ge 8.0) {
        $script:EtaDiag.Eligible++

        # Siempre calculamos un total bruto cuando la llamada es elegible.
        # La estimación suavizada sólo cambia cuando el porcentaje base avanza.
        $rawTotal = ($elapsedSec * 100.0) / [math]::Max($EtaPercent, 0.001)

        if ($null -eq $script:EtaEstimatedTotalSec) {
            $script:EtaEstimatedTotalSec = [double]$rawTotal
            $script:EtaLastBasePercent = [double]$EtaPercent
        }
        elseif ($EtaPercent -gt ($script:EtaLastBasePercent + 0.0001)) {
            if ($rawTotal -gt $script:EtaEstimatedTotalSec) {
                # Si el proceso resulta más lento de lo previsto, corregir rápido.
                $script:EtaEstimatedTotalSec = ($script:EtaEstimatedTotalSec * 0.25) + ($rawTotal * 0.75)
            }
            else {
                # Si resulta más rápido, bajar la estimación suavemente.
                $script:EtaEstimatedTotalSec = ($script:EtaEstimatedTotalSec * 0.75) + ($rawTotal * 0.25)
            }
            $script:EtaLastBasePercent = [double]$EtaPercent
        }

        $remainingSec = [math]::Max(0.0, [double]$script:EtaEstimatedTotalSec - $elapsedSec)

        # El registro técnico sigue el porcentaje ETA real, no el porcentaje visual entero.
        # Guardar aproximadamente una muestra por cada punto porcentual de avance.
        if ($script:EtaLastLoggedBasePercent -lt 0.0 -or
            $EtaPercent -ge ($script:EtaLastLoggedBasePercent + 1.0)) {

            $etaSample = [pscustomobject]@{
                ElapsedSec        = [math]::Round($elapsedSec, 3)
                VisiblePercent    = $Percent
                EtaPercent        = [math]::Round($EtaPercent, 2)
                RemainingSec      = [math]::Round($remainingSec, 3)
                EstimatedTotalSec = [math]::Round($script:EtaEstimatedTotalSec, 3)
                Stage             = $Stage
            }
            $script:EtaSamples += $etaSample
            $script:EtaDiag.Samples = $script:EtaSamples.Count
            $script:EtaLastLoggedBasePercent = [double]$EtaPercent
        }
    }

    $state = [ordered]@{
        Percent      = $Percent
        EtaPercent   = [math]::Round($EtaPercent, 2)
        Stage        = $Stage
        Item         = $Item
        Completed    = $Completed
        ElapsedMs    = $elapsedMs
        RemainingSec = if ($null -eq $remainingSec) { $null } else { [math]::Round($remainingSec, 3) }
        UpdatedUtc   = [DateTime]::UtcNow.ToString("o")
    }

    $json = $state | ConvertTo-Json -Compress
    $tmp = "$ProgressStateFile.tmp"
    $swProgressWrite = [System.Diagnostics.Stopwatch]::StartNew()
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)
    Move-Item -LiteralPath $tmp -Destination $ProgressStateFile -Force
    $swProgressWrite.Stop()
    $ProgressPerf.StateWrites++
    $ProgressPerf.StateWriteMs += $swProgressWrite.Elapsed.TotalMilliseconds
}

function Show-ProgressWindow {
    if (-not (Test-Path -LiteralPath $ProgressUIPath)) { throw "No se encontró la interfaz de progreso: $ProgressUIPath" }

    Remove-Item -LiteralPath $ProgressReadyFile -Force -ErrorAction SilentlyContinue
    Write-ProgressState -Percent 0 -EtaPercent 0 -Stage "Preparando análisis..." -Item "" -Completed $false

    $argString = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -StateFile "{1}" -ReadyFile "{2}"' -f `
        $ProgressUIPath, $ProgressStateFile, $ProgressReadyFile

    try {
        $script:ProgressProcess = Start-Process -FilePath "powershell.exe" -ArgumentList $argString -PassThru
        $deadline = (Get-Date).AddSeconds(4)
        while ((Get-Date) -lt $deadline) {
            if (Test-Path -LiteralPath $ProgressReadyFile) { break }
            if ($script:ProgressProcess.HasExited) { throw "La interfaz de progreso se cerró antes de mostrarse." }
            Start-Sleep -Milliseconds 100
        }
        if (-not (Test-Path -LiteralPath $ProgressReadyFile)) { throw "La interfaz de progreso no confirmó su apertura." }
    }
    catch {
        Write-DiagnosticError ("No se pudo abrir la ventana de progreso: " + $_.Exception.Message)
        throw
    }
}

function Update-ProgressWindow {
    param(
        [int]$Percent,
        [string]$Stage,
        [string]$Item = "",
        [double]$EtaPercent = -1.0
    )
    Write-ProgressState -Percent $Percent -EtaPercent $EtaPercent -Stage $Stage -Item $Item -Completed ($Percent -ge 100)
}

function Close-ProgressWindow {
    try {
        if (Test-Path -LiteralPath $ProgressStateFile) {
            Write-ProgressState -Percent 100 -EtaPercent 100 -Stage "Proceso terminado" -Item "Análisis completado." -Completed $true
            Start-Sleep -Milliseconds 700
            Remove-Item -LiteralPath $ProgressStateFile -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $ProgressReadyFile -Force -ErrorAction SilentlyContinue
        }
    }
    catch {}
}

$DiagnosticLog = Join-Path $ScriptDir "ERRORES_ANALIZADOR.txt"

function Write-DiagnosticError {
    param([string]$Message)

    try {
        $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -LiteralPath $DiagnosticLog -Value ("[{0}] {1}" -f $stamp, $Message) -Encoding UTF8
    }
    catch {}
}

$FFMPEG  = Join-Path $ScriptDir "ffmpeg.exe"
$FFPROBE = Join-Path $ScriptDir "ffprobe.exe"

# ------------------------------------------------------------
# UMBRALES — paridad con Mac Intel V2.12.14
# ------------------------------------------------------------
# Todos los residuales de clasificación se expresan RELATIVOS al RMS de la señal
# luego de compensar la diferencia de nivel L/R.
$DUAL_MONO_MAX_LEVEL_DIFF          = 0.01
$DUAL_MONO_MAX_RESIDUAL            = -70.0
$MONO_PAN_MAX_RESIDUAL             = -100.0
$PRACTICAL_DUAL_MAX_LEVEL_DIFF     = 0.10
$PRACTICAL_DUAL_MAX_RESIDUAL       = -50.0
$PRACTICAL_DUAL_MIN_CORRELATION    = 0.99999
$REVIEW_MAX_RESIDUAL               = -50.0
$HIGH_CORR_MAX_LEVEL_DIFF          = 1.0
$HIGH_CORR_MAX_RESIDUAL            = -30.0
$HIGH_CORR_MIN_CORRELATION         = 0.9995
$PROBABLE_DUAL_MAX_RESIDUAL         = -35.0
$PROBABLE_DUAL_MIN_CORRELATION      = 0.9999
$PROBABLE_DUAL_MAX_LEVEL_DIFF       = 0.10
$PROBABLE_DUAL_MAX_TEMPORAL_STD     = 0.05
$PROBABLE_DUAL_MAX_TEMPORAL_RANGE   = 0.50
$PROBABLE_DUAL_MIN_ACTIVE_WINDOWS   = 8

$DUPLICATE_MAX_RESIDUAL            = -100.0
$DUPLICATE_SAME_LEVEL_DIFF         = 0.01
$DUP_FP_TOLERANCE                  = 1.5
$DUP_FP_WINDOW                     = 0.30
$DUP_FP_MIN_NONHASH_PAIRS          = 25

# Control de nivel por pico máximo.
$LOW_LEVEL_THRESHOLD               = -20.0
$VERY_LOW_LEVEL_THRESHOLD          = -60.0

$Invariant = [System.Globalization.CultureInfo]::InvariantCulture

# ------------------------------------------------------------
# FUNCIONES AUXILIARES
# ------------------------------------------------------------

function Parse-DbValue {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    if ($Value -eq "-inf") { return [double]::NegativeInfinity }
    $n = 0.0
    if ([double]::TryParse($Value, [System.Globalization.NumberStyles]::Float, $Invariant, [ref]$n)) {
        return $n
    }
    return $null
}

function Format-Db {
    param([double]$Value)
    if ([double]::IsNegativeInfinity($Value)) { return "prácticamente nulo" }
    return ("{0:0.0} dB" -f $Value)
}

function Format-Seconds {
    param([double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $mins = [math]::Floor($Seconds / 60)
    $secs = $Seconds - ($mins * 60)
    if ($mins -gt 0) {
        return ("{0} min {1:00.000} s" -f $mins, $secs)
    }
    return ("{0:0.000} s" -f $secs)
}

function Get-ModeValue {
    param(
        [array]$Items,
        [string]$Property
    )
    if (-not $Items -or $Items.Count -eq 0) { return $null }
    return ($Items |
        Group-Object -Property $Property |
        Sort-Object Count -Descending |
        Select-Object -First 1).Name
}

function Get-BitDepthModeSummary {
    param([object[]]$Items)

    $groups = @($Items | Where-Object { $_.BitDepth -gt 0 } | Group-Object -Property BitDepth | Sort-Object Count -Descending)
    if ($groups.Count -eq 0) {
        return [pscustomobject]@{ Values=@(); TopCount=0; PredominantDepth=0; Label='no determinada' }
    }
    $topCount = [int]$groups[0].Count
    $values = @($groups | Where-Object { $_.Count -eq $topCount } | ForEach-Object { [int]$_.Name } | Sort-Object)
    $depth = if ($values.Count -eq 1) { [int]$values[0] } else { 0 }
    $label = if ($depth -gt 0) { "$depth bits" } else { "empate entre $($values -join ' y ') bits ($topCount WAV por profundidad)" }
    return [pscustomobject]@{ Values=[int[]]$values; TopCount=$topCount; PredominantDepth=$depth; Label=$label }
}

function Get-ConversionCategoryBreakdown {
    param([object[]]$PlannedActions, [object[]]$ConversionResults)

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($category in @('DUAL MONO EXACTO','DUAL MONO PRÁCTICO','DUAL MONO PRÁCTICO PROBABLE','MONO PANEADO')) {
        $planned = @($PlannedActions | Where-Object { $_.Category -eq $category }).Count
        $completed = @($ConversionResults | Where-Object { $_.Category -eq $category -and $_.Status -eq 'COMPLETADA' }).Count
        $failed = @($ConversionResults | Where-Object { $_.Category -eq $category -and $_.Status -eq 'FALLIDA' }).Count
        $rows.Add([pscustomobject]@{ Category=$category; Planned=$planned; Completed=$completed; Failed=$failed })
    }
    return $rows.ToArray()
}

function Get-ProbableDualMonoDecision {
    param([object]$Stereo, [object]$Stats)

    $decision = [pscustomobject]@{ CoreCriteriaMet=$false; Eligible=$false; InsufficientWindows=$false; Reason='' }
    if ($null -eq $Stereo -or -not $Stereo.Valid -or $null -eq $Stats) { return $decision }
    if ($null -eq $Stereo.Correlation -or $null -eq $Stereo.LevelDiff -or $null -eq $Stereo.Residual) { return $decision }

    $residualPass = [double]::IsNegativeInfinity([double]$Stereo.Residual) -or ([double]$Stereo.Residual -le $PROBABLE_DUAL_MAX_RESIDUAL)
    if (-not $residualPass -or [double]$Stereo.Correlation -lt $PROBABLE_DUAL_MIN_CORRELATION -or
        [double]$Stereo.LevelDiff -gt $PROBABLE_DUAL_MAX_LEVEL_DIFF) { return $decision }

    $decision.CoreCriteriaMet = $true
    $activeWindows = [int]$Stats.TemporalActiveWindows
    if ($activeWindows -lt $PROBABLE_DUAL_MIN_ACTIVE_WINDOWS -or
        $null -eq $Stats.TemporalBalanceStdDb -or $null -eq $Stats.TemporalBalanceRangeDb) {
        $decision.InsufficientWindows = $true
        $decision.Reason = "estabilidad temporal no evaluable: $activeWindows/$PROBABLE_DUAL_MIN_ACTIVE_WINDOWS ventanas activas requeridas"
        return $decision
    }
    if ([double]$Stats.TemporalBalanceStdDb -gt $PROBABLE_DUAL_MAX_TEMPORAL_STD -or
        [double]$Stats.TemporalBalanceRangeDb -gt $PROBABLE_DUAL_MAX_TEMPORAL_RANGE) {
        $decision.Reason = 'estabilidad temporal supera el umbral; conservar en REVISAR'
        return $decision
    }
    $decision.Eligible = $true
    $decision.Reason = 'cumple los umbrales experimentales; hipótesis métrica, no confirmación'
    return $decision
}

function Get-AudioInfo {
    param([string]$File)

    $json = & $FFPROBE -v error -select_streams a:0 `
        -show_entries stream=sample_rate,channels,bits_per_sample,bits_per_raw_sample,duration_ts,time_base,codec_name `
        -show_entries format=duration `
        -of json -- "$File" 2>$null

    if ($LASTEXITCODE -ne 0 -or -not $json) {
        throw "ffprobe no pudo analizar: $File"
    }

    $obj = ($json -join "`n") | ConvertFrom-Json
    $s = $obj.streams[0]

    $bitDepth = 0
    if ($s.bits_per_sample -and [int]$s.bits_per_sample -gt 0) {
        $bitDepth = [int]$s.bits_per_sample
    }
    elseif ($s.bits_per_raw_sample -and "$($s.bits_per_raw_sample)" -ne "N/A") {
        $tmp = 0
        if ([int]::TryParse("$($s.bits_per_raw_sample)", [ref]$tmp)) {
            $bitDepth = $tmp
        }
    }

    $duration = 0.0
    if ($obj.format.duration) {
        [double]::TryParse("$($obj.format.duration)", [System.Globalization.NumberStyles]::Float, $Invariant, [ref]$duration) | Out-Null
    }

    [pscustomobject]@{
        File         = $File
        Name         = [System.IO.Path]::GetFileName($File)
        SampleRate   = [int]$s.sample_rate
        Channels     = [int]$s.channels
        BitDepth     = $bitDepth
        DurationTs   = if ($s.duration_ts) { [long]$s.duration_ts } else { 0L }
        DurationSec  = $duration
        Codec        = "$($s.codec_name)"
    }
}

function Get-FileStatsFfmpeg {
    param([string]$File)

    $raw = & $FFMPEG -nostdin -hide_banner -nostats -i "$File" `
        -af "astats=metadata=1:reset=0:measure_perchannel=RMS_level:measure_overall=Peak_level+RMS_level" `
        -f null NUL 2>&1

    $section = ""
    $channel = 0
    $peak = [double]::NegativeInfinity
    $sawPeak = $false
    $rms = $null
    $leftRms = $null
    $rightRms = $null

    foreach ($lineObj in $raw) {
        $line = [string]$lineObj
        if ($line -match 'Channel:\s*(\d+)') {
            $section = "channel"
            $channel = [int]$Matches[1]
        }
        elseif ($line -match 'Overall') {
            $section = "overall"
            $channel = 0
        }

        if ($line -match 'Peak level dB:\s*(-inf|-?[\d\.]+)') {
            $v = Parse-DbValue $Matches[1]
            if ($null -ne $v) {
                $sawPeak = $true
                if (-not [double]::IsNegativeInfinity($v) -and $v -gt $peak) { $peak = $v }
            }
        }

        if ($line -match 'RMS level dB:\s*(-inf|-?[\d\.]+)') {
            $v = Parse-DbValue $Matches[1]
            if ($section -eq "channel" -and $channel -eq 1) { $leftRms = $v }
            elseif ($section -eq "channel" -and $channel -eq 2) { $rightRms = $v }
            elseif ($section -eq "overall") { $rms = $v }
        }
    }

    if (-not $sawPeak) { $peak = $null }

    [pscustomobject]@{
        Peak     = $peak
        RMS      = $rms
        LeftRms  = $leftRms
        RightRms = $rightRms
        TemporalBalanceStdDb = $null
        TemporalBalanceRangeDb = $null
        TemporalActiveWindows = 0
        TemporalTotalWindows = 0
    }
}

function Get-FileStats {
    param([string]$File)

    if (-not $script:DirectLevelValidation.Disabled) {
        try {
            $s = [PGWavFastTools]::LevelStats($File)
            if ($null -ne $s -and $s.Valid) {
                $directObj = [pscustomobject]@{
                    Peak     = [double]$s.PeakDb
                    RMS      = [double]$s.RmsDb
                    LeftRms  = if ($s.HasLeft) { [double]$s.LeftRmsDb } else { $null }
                    RightRms = if ($s.HasRight) { [double]$s.RightRmsDb } else { $null }
                    TemporalBalanceStdDb = if ([double]::IsNaN([double]$s.TemporalBalanceStdDb)) { $null } else { [double]$s.TemporalBalanceStdDb }
                    TemporalBalanceRangeDb = if ([double]::IsNaN([double]$s.TemporalBalanceRangeDb)) { $null } else { [double]$s.TemporalBalanceRangeDb }
                    TemporalActiveWindows = [int]$s.TemporalActiveWindows
                    TemporalTotalWindows = [int]$s.TemporalTotalWindows
                    Direct   = $true
                }

                # Validación automática de las primeras 5 lecturas.
                # Si Peak o RMS difieren más de 0,02 dB respecto de FFmpeg,
                # se abandona el modo directo para el resto de la ejecución.
                if ($script:DirectLevelValidation.Checked -lt 5) {
                    $ffCheck = Get-FileStatsFfmpeg -File $File
                    $script:DirectLevelValidation.Checked++

                    if ($null -ne $ffCheck) {
                        $peakDiff = 0.0
                        $rmsDiff = 0.0

                        if ([double]::IsNegativeInfinity([double]$directObj.Peak) -and [double]::IsNegativeInfinity([double]$ffCheck.Peak)) {
                            $peakDiff = 0.0
                        }
                        elseif (-not [double]::IsInfinity([double]$directObj.Peak) -and -not [double]::IsInfinity([double]$ffCheck.Peak)) {
                            $peakDiff = [math]::Abs([double]$directObj.Peak - [double]$ffCheck.Peak)
                        }
                        else { $peakDiff = 999.0 }

                        if ([double]::IsNegativeInfinity([double]$directObj.RMS) -and [double]::IsNegativeInfinity([double]$ffCheck.RMS)) {
                            $rmsDiff = 0.0
                        }
                        elseif (-not [double]::IsInfinity([double]$directObj.RMS) -and -not [double]::IsInfinity([double]$ffCheck.RMS)) {
                            $rmsDiff = [math]::Abs([double]$directObj.RMS - [double]$ffCheck.RMS)
                        }
                        else { $rmsDiff = 999.0 }

                        if ($peakDiff -gt $script:DirectLevelValidation.MaxPeakDiffDb) {
                            $script:DirectLevelValidation.MaxPeakDiffDb = $peakDiff
                        }
                        if ($rmsDiff -gt $script:DirectLevelValidation.MaxRmsDiffDb) {
                            $script:DirectLevelValidation.MaxRmsDiffDb = $rmsDiff
                        }

                        if ($peakDiff -gt 0.02 -or $rmsDiff -gt 0.02) {
                            $script:DirectLevelValidation.Failed++
                            $script:DirectLevelValidation.Disabled = $true
                            $script:Optimization.LevelStatsFallbackFiles++
                            $ffCheck | Add-Member -NotePropertyName Direct -NotePropertyValue $false -Force
                            return $ffCheck
                        }
                    }
                }

                $script:Optimization.DirectLevelStatsFiles++
                return $directObj
            }
        }
        catch {}
    }

    $script:Optimization.LevelStatsFallbackFiles++
    $ff = Get-FileStatsFfmpeg -File $File
    if ($null -ne $ff) {
        $ff | Add-Member -NotePropertyName Direct -NotePropertyValue $false -Force
    }
    return $ff
}

function Get-ChannelRms {
    param([string]$File, [int]$Channel)
    $raw = & $FFMPEG -nostdin -hide_banner -nostats -i "$File" `
        -af "pan=mono|c0=c${Channel},astats=metadata=1:reset=0:measure_perchannel=none:measure_overall=RMS_level" `
        -f null NUL 2>&1
    $text = $raw -join "`n"
    $m = [regex]::Matches($text, 'RMS level dB:\s*(-inf|-?[\d\.]+)')
    if ($m.Count -eq 0) { return $null }
    return Parse-DbValue $m[$m.Count-1].Groups[1].Value
}

function Estimate-CorrelationFromResidual {
    param([double]$RelativeResidual)
    if ([double]::IsNegativeInfinity($RelativeResidual)) { return 1.0 }
    $c = 1.0 - ([math]::Pow(10.0, $RelativeResidual / 10.0) / 2.0)
    if ($c -gt 1.0) { $c = 1.0 }
    if ($c -lt -1.0) { $c = -1.0 }
    return $c
}

function Get-StereoAnalysis {
    param(
        [string]$File,
        [object]$LeftRms,
        [object]$RightRms
    )

    $left = $LeftRms
    $right = $RightRms

    if ($null -eq $left -or $null -eq $right) {
        $Optimization.StereoRmsFallbackFiles++
        $left = Get-ChannelRms -File $File -Channel 0
        $right = Get-ChannelRms -File $File -Channel 1
    }
    else {
        $Optimization.StereoRmsReusedFiles++
    }

    if ($null -eq $left -or $null -eq $right) {
        return [pscustomobject]@{ Valid=$false; LeftRms=$left; RightRms=$right; LevelDiff=$null; Residual=$null; ResidualAbsolute=$null; Correlation=$null; Stronger='L' }
    }

    if ([double]::IsNegativeInfinity($left) -and [double]::IsNegativeInfinity($right)) {
        return [pscustomobject]@{ Valid=$true; LeftRms=$left; RightRms=$right; LevelDiff=0.0; Residual=[double]::NegativeInfinity; ResidualAbsolute=[double]::NegativeInfinity; Correlation=1.0; Stronger='L' }
    }

    if ([double]::IsNegativeInfinity($left) -or [double]::IsNegativeInfinity($right)) {
        return [pscustomobject]@{
            Valid=$true; LeftRms=$left; RightRms=$right; LevelDiff=[double]::PositiveInfinity;
            Residual=0.0; ResidualAbsolute=0.0; Correlation=0.0;
            Stronger=if ($left -gt $right) { 'L' } else { 'R' }
        }
    }

    $gainComp = $right - $left
    $levelDiff = [math]::Abs($left - $right)
    $stronger = if ($left -ge $right) { 'L' } else { 'R' }
    $gainText = $gainComp.ToString('0.########', $Invariant)

    $raw = & $FFMPEG -nostdin -hide_banner -nostats -i "$File" `
        -filter_complex "[0:a]channelsplit=channel_layout=stereo[L][R];[L]volume=${gainText}dB[L2];[L2][R]amerge=inputs=2[M];[M]pan=mono|c0=c0-c1,astats=metadata=1:reset=0:measure_perchannel=none:measure_overall=RMS_level" `
        -f null NUL 2>&1

    $text = $raw -join "`n"
    $matches = [regex]::Matches($text, 'RMS level dB:\s*(-inf|-?[\d\.]+)')
    if ($matches.Count -eq 0) {
        return [pscustomobject]@{ Valid=$false; LeftRms=$left; RightRms=$right; LevelDiff=$levelDiff; Residual=$null; ResidualAbsolute=$null; Correlation=$null; Stronger=$stronger }
    }

    $absoluteResidual = Parse-DbValue $matches[$matches.Count-1].Groups[1].Value
    if ($null -eq $absoluteResidual) {
        return [pscustomobject]@{ Valid=$false; LeftRms=$left; RightRms=$right; LevelDiff=$levelDiff; Residual=$null; ResidualAbsolute=$null; Correlation=$null; Stronger=$stronger }
    }

    $referenceRms = [math]::Max($left, $right)
    $relativeResidual = if ([double]::IsNegativeInfinity($absoluteResidual)) { [double]::NegativeInfinity } else { $absoluteResidual - $referenceRms }
    $correlation = Estimate-CorrelationFromResidual $relativeResidual

    [pscustomobject]@{
        Valid=$true
        LeftRms=$left
        RightRms=$right
        LevelDiff=$levelDiff
        Residual=$relativeResidual
        ResidualAbsolute=$absoluteResidual
        Correlation=$correlation
        Stronger=$stronger
    }
}

function Get-AudioHash {
    param([string]$File)
    try {
        $h = [PGWavFastTools]::HashData($File)
        if ([string]::IsNullOrWhiteSpace($h)) { return 'SIN_HASH' }
        return $h
    }
    catch {
        return 'SIN_HASH'
    }
}

function Get-QuickFingerprint {
    param([pscustomobject]$Info)
    if ($Info.DurationSec -le 0) { return $null }

    try {
        $rawFp = [PGWavFastTools]::Fingerprint($Info.File, [double]$DUP_FP_WINDOW)
        $Perf.FingerprintCalls += 3
        if ($null -eq $rawFp -or $rawFp.Length -ne 3) { return $null }

        $out = @()
        $finite = 0
        foreach ($v in $rawFp) {
            if ([double]::IsNaN([double]$v)) {
                $out += $null
            }
            else {
                $out += [double]$v
                if (-not [double]::IsNegativeInfinity([double]$v)) { $finite++ }
            }
        }
        if ($finite -lt 2) { return $null }
        return $out
    }
    catch {
        return $null
    }
}

function Test-FingerprintMatch {
    param([object[]]$A, [object[]]$B)
    if ($null -eq $A -or $null -eq $B -or $A.Count -ne 3 -or $B.Count -ne 3) { return $null }
    for ($i=0; $i -lt 3; $i++) {
        if ($null -eq $A[$i] -or $null -eq $B[$i]) {
            if (-not ($null -eq $A[$i] -and $null -eq $B[$i])) { return $false }
            continue
        }
        if ([math]::Abs([double]$A[$i] - [double]$B[$i]) -gt $DUP_FP_TOLERANCE) { return $false }
    }
    return $true
}

function Convert-ToMono {
    param(
        [string]$Source,
        [string]$Destination,
        [string]$Channel,
        [string]$Codec
    )

    $channelIndex = if ($Channel -eq "R") { 1 } else { 0 }

    $destDir = Split-Path -Parent $Destination
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    }

    & $FFMPEG -nostdin -hide_banner -loglevel error -y -i "$Source" `
        -map_metadata 0 `
        -af "pan=mono|c0=c${channelIndex}" `
        -c:a "$Codec" `
        "$Destination"

    if ($LASTEXITCODE -ne 0) {
        throw "FFmpeg no pudo convertir a mono: $Source"
    }
}

function Test-GeneratedMonoFile {
    param(
        [Parameter(Mandatory=$true)][string]$File,
        [Parameter(Mandatory=$true)]$SourceInfo
    )

    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "FFmpeg no creó la salida esperada: $File" }
    if ((Get-Item -LiteralPath $File).Length -le 0) { throw "La salida de conversión está vacía: $File" }

    $swProbe = [System.Diagnostics.Stopwatch]::StartNew()
    try { $result = Get-AudioInfo $File }
    finally {
        $swProbe.Stop()
        $Perf.FFprobeCalls++
        $Perf.FFprobeMs += $swProbe.Elapsed.TotalMilliseconds
    }

    if ($result.Channels -ne 1) { throw "La salida no es mono (canales=$($result.Channels)): $File" }
    if ($result.SampleRate -ne $SourceInfo.SampleRate) {
        throw "La salida cambió la frecuencia de muestreo ($($SourceInfo.SampleRate) -> $($result.SampleRate) Hz): $File"
    }
    if ($SourceInfo.BitDepth -gt 0 -and $result.BitDepth -ne $SourceInfo.BitDepth) {
        throw "La salida cambió la profundidad de bits ($($SourceInfo.BitDepth) -> $($result.BitDepth)): $File"
    }
    if ($SourceInfo.DurationSec -gt 0 -and $result.DurationSec -gt 0 -and
        [math]::Abs($result.DurationSec - $SourceInfo.DurationSec) -gt (1.0 / [math]::Max(1,$SourceInfo.SampleRate))) {
        throw "La duración de la salida difiere del original en más de una muestra: $File"
    }
    return $result
}

function Invoke-MonoConversionAction {
    param(
        [Parameter(Mandatory=$true)]$Action,
        [Parameter(Mandatory=$true)][string]$OutputFile,
        [Parameter(Mandatory=$true)][string]$BackupFile
    )

    $info = $Action.Info
    $swConversion = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Convert-ToMono $info.File $OutputFile $Action.Channel $info.Codec
        [void](Test-GeneratedMonoFile -File $OutputFile -SourceInfo $info)
        $swConversion.Stop()
        $Perf.ConversionCalls++
        $Perf.ConversionMs += $swConversion.Elapsed.TotalMilliseconds
        return [pscustomobject]@{
            RelativePath=$info.RelativePath; Category=$Action.Category; Status='COMPLETADA'
            Output=$OutputFile; BackupPath=$null; BackupStatus='No requerido'; Error=$null; PartialCleanupError=$null
        }
    }
    catch {
        if ($swConversion.IsRunning) { $swConversion.Stop() }
        $Perf.ConversionMs += $swConversion.Elapsed.TotalMilliseconds
        $conversionError = $_.Exception.Message
        $partialCleanupError = $null
        if (Test-Path -LiteralPath $OutputFile -PathType Leaf) {
            try { Remove-Item -LiteralPath $OutputFile -Force -ErrorAction Stop }
            catch { $partialCleanupError = $_.Exception.Message }
        }

        $backupStatus = 'No se pudo crear'
        $backupError = $null
        $swFallback = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            Copy-AudioFile $info.File $BackupFile
            if (-not (Test-Path -LiteralPath $BackupFile -PathType Leaf)) { throw "No se encontró la copia de respaldo: $BackupFile" }
            if ((Get-Item -LiteralPath $BackupFile).Length -ne (Get-Item -LiteralPath $info.File).Length) { throw "El tamaño de la copia no coincide con el original: $BackupFile" }
            $backupStatus = 'RESPALDO CONSERVADO'
            $Perf.CopyCalls++
        }
        catch {
            $backupError = $_.Exception.Message
            $backupStatus = "RESPALDO FALLIDO: $backupError"
        }
        finally {
            $swFallback.Stop()
            $Perf.CopyMs += $swFallback.Elapsed.TotalMilliseconds
        }

        return [pscustomobject]@{
            RelativePath=$info.RelativePath; Category=$Action.Category; Status='FALLIDA'
            Output=$null; BackupPath=$BackupFile; BackupStatus=$backupStatus; Error=$conversionError
            BackupError=$backupError; PartialCleanupError=$partialCleanupError
        }
    }
}

function Copy-AudioFile {
    param(
        [string]$Source,
        [string]$Destination
    )

    $destDir = Split-Path -Parent $Destination
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Get-RelativePathSafe {
    param(
        [string]$Base,
        [string]$Path
    )
    $baseFull = [System.IO.Path]::GetFullPath($Base).TrimEnd('\') + '\'
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    $baseUri = New-Object System.Uri($baseFull)
    $pathUri = New-Object System.Uri($pathFull)
    $rel = $baseUri.MakeRelativeUri($pathUri).ToString()
    return [System.Uri]::UnescapeDataString($rel).Replace('/', '\')
}

function Test-DuplicateSignalPair {
    param([pscustomobject]$A, [pscustomobject]$B)

    if ($A.Channels -ne 1 -and $A.Channels -ne 2) { return $null }
    if ($null -eq $A.RMS -or $null -eq $B.RMS) { return $null }
    if ([double]::IsNegativeInfinity($A.RMS) -or [double]::IsNegativeInfinity($B.RMS)) { return $null }

    $gain = [double]$B.RMS - [double]$A.RMS
    $gainText = $gain.ToString('0.########', $Invariant)

    if ($A.Channels -eq 1) {
        $filter = "[0:a]volume=${gainText}dB[A];[A][1:a]amerge=inputs=2[M];[M]pan=mono|c0=c0-c1,astats=metadata=1:reset=0:measure_perchannel=none:measure_overall=RMS_level"
    }
    else {
        $filter = "[0:a]volume=${gainText}dB[A];[A][1:a]amerge=inputs=2[M];[M]pan=stereo|c0=c0-c2|c1=c1-c3,astats=metadata=1:reset=0:measure_perchannel=none:measure_overall=RMS_level"
    }

    $raw = & $FFMPEG -nostdin -hide_banner -nostats -i "$($A.File)" -i "$($B.File)" `
        -filter_complex $filter -f null NUL 2>&1
    $text = $raw -join "`n"
    $matches = [regex]::Matches($text, 'RMS level dB:\s*(-inf|-?[\d\.]+)')
    if ($matches.Count -eq 0) { return $null }

    $absoluteResidual = Parse-DbValue $matches[$matches.Count-1].Groups[1].Value
    if ($null -eq $absoluteResidual) { return $null }

    $relativeResidual = if ([double]::IsNegativeInfinity($absoluteResidual)) { [double]::NegativeInfinity } else { $absoluteResidual - [double]$B.RMS }

    if ([double]::IsNegativeInfinity($relativeResidual) -or $relativeResidual -le $DUPLICATE_MAX_RESIDUAL) {
        return [pscustomobject]@{
            Duplicate = $true
            LevelDb = $gain
            Residual = $relativeResidual
        }
    }
    return $null
}

function Get-AvailableProcessedDir {
    param([string]$Parent, [string]$Leaf)
    $base = Join-Path $Parent ($Leaf + ' [PROCESADO]')
    if (-not (Test-Path -LiteralPath $base)) { return $base }
    $n = 2
    while ($true) {
        $candidate = Join-Path $Parent ($Leaf + " [PROCESADO $n]")
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
        $n++
    }
}

# ------------------------------------------------------------
# VALIDACIONES INICIALES
# ------------------------------------------------------------


# ------------------------------------------------------------
# PROFUNDIDAD EFECTIVA / AUDIO ALMACENADO A MAYOR PROFUNDIDAD
# ------------------------------------------------------------
# Lectura directa de muestras PCM. Esta lógica fue validada por separado
# en el prototipo V0.5 antes de integrarse al Analizador.

$EffectiveDepthSource = @"
using System;
using System.IO;
using System.Diagnostics;

public class PGEffectiveDepthResult
{
    public bool Valid;
    public string Error;
    public string Encoding;
    public int ContainerBits;
    public int ValidBits;
    public long TotalSamples;
    public long NonZeroSamples;
    public int CommonZeroLSBs;
    public int InferredUsedBits;
    public string StrictResult;
    public string PatternResult;
    public double Grid16ExactPct;
    public double Grid16Within2Pct;
    public double Grid16ResidualRms;
    public double Grid16ResidualEntropy;
    public int Grid16DistinctResiduals;
    public bool EarlyExit;
    public string EarlyExitReason;
    public long SamplesScanned;
    public long BytesScanned;
    public long DataBytes;
    public double AnalysisMs;
}

public static class PGEffectiveDepthAnalyzer
{
    static string FourCC(BinaryReader br) { return new string(br.ReadChars(4)); }

    static double Entropy(long[] counts, long total)
    {
        if (total <= 0) return 0.0;
        double h = 0.0;
        for (int i = 0; i < counts.Length; i++)
        {
            long c = counts[i];
            if (c <= 0) continue;
            double p = (double)c / total;
            h -= p * (Math.Log(p) / Math.Log(2.0));
        }
        return h;
    }

    public static PGEffectiveDepthResult Analyze(string path)
    {
        Stopwatch sw = Stopwatch.StartNew();
        PGEffectiveDepthResult r = new PGEffectiveDepthResult();
        r.Valid = false;
        r.Error = "";
        r.Encoding = "DESCONOCIDO";
        r.PatternResult = "NO APLICA";
        r.EarlyExitReason = "";

        try
        {
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (BinaryReader br = new BinaryReader(fs))
            {
                string riff = FourCC(br);
                if (riff != "RIFF" && riff != "RF64") throw new Exception("No es WAV RIFF/RF64.");
                br.ReadUInt32();
                if (FourCC(br) != "WAVE") throw new Exception("WAVE invalido.");

                ushort formatTag = 0;
                ushort channels = 0;
                ushort bits = 0;
                ushort validBits = 0;
                Guid subFormat = Guid.Empty;
                long dataStart = -1;
                long dataSize = 0;

                while (fs.Position + 8 <= fs.Length)
                {
                    string id = FourCC(br);
                    uint size = br.ReadUInt32();
                    long chunkStart = fs.Position;

                    if (id == "fmt ")
                    {
                        formatTag = br.ReadUInt16();
                        channels = br.ReadUInt16();
                        br.ReadUInt32();
                        br.ReadUInt32();
                        br.ReadUInt16();
                        bits = br.ReadUInt16();
                        validBits = bits;

                        if (formatTag == 0xFFFE && size >= 40)
                        {
                            ushort cbSize = br.ReadUInt16();
                            if (cbSize >= 22)
                            {
                                validBits = br.ReadUInt16();
                                br.ReadUInt32();
                                byte[] g = br.ReadBytes(16);
                                subFormat = new Guid(g);
                            }
                        }
                    }
                    else if (id == "data")
                    {
                        dataStart = fs.Position;
                        dataSize = (size == UInt32.MaxValue) ? (fs.Length - dataStart) : size;
                        break;
                    }

                    long next = chunkStart + size + (size % 2);
                    if (next > fs.Length) break;
                    fs.Position = next;
                }

                if (dataStart < 0 || channels == 0 || bits == 0)
                    throw new Exception("No se pudo leer fmt/data.");

                bool isPCM = formatTag == 1;
                bool isFloat = formatTag == 3;
                if (formatTag == 0xFFFE)
                {
                    string gs = subFormat.ToString().ToLowerInvariant();
                    if (gs.StartsWith("00000001-")) isPCM = true;
                    if (gs.StartsWith("00000003-")) isFloat = true;
                }

                r.ContainerBits = bits;
                r.ValidBits = validBits == 0 ? bits : validBits;
                r.DataBytes = dataSize;

                if (isFloat)
                {
                    r.Encoding = "PCM FLOAT";
                    r.CommonZeroLSBs = -1;
                    r.InferredUsedBits = -1;
                    r.StrictResult = "FLOAT 32 - PROFUNDIDAD EFECTIVA NO DETERMINADA";
                    r.PatternResult = "NO APLICA";
                    r.Valid = true;
                    sw.Stop(); r.AnalysisMs = sw.Elapsed.TotalMilliseconds;
                    return r;
                }

                if (!isPCM)
                {
                    r.Encoding = "OTRO / NO PCM";
                    r.StrictResult = "PROFUNDIDAD EFECTIVA NO DETERMINADA";
                    r.PatternResult = "NO APLICA";
                    r.Valid = true;
                    sw.Stop(); r.AnalysisMs = sw.Elapsed.TotalMilliseconds;
                    return r;
                }

                r.Encoding = "PCM ENTERO";
                if (bits != 16 && bits != 24 && bits != 32)
                {
                    r.StrictResult = "PCM ENTERO - PROFUNDIDAD NO SOPORTADA";
                    r.PatternResult = "NO APLICA";
                    r.Valid = true;
                    sw.Stop(); r.AnalysisMs = sw.Elapsed.TotalMilliseconds;
                    return r;
                }

                // PCM16: la profundidad ya está definida por el propio contenedor.
                if (bits == 16)
                {
                    r.CommonZeroLSBs = 0;
                    r.InferredUsedBits = 16;
                    r.StrictResult = "PCM ENTERO 16";
                    r.PatternResult = "NO APLICA";
                    r.Valid = true;
                    sw.Stop(); r.AnalysisMs = sw.Elapsed.TotalMilliseconds;
                    return r;
                }

                int bytesPerSample = bits / 8;
                long totalSamples = dataSize / bytesPerSample;
                r.TotalSamples = totalSamples;
                fs.Position = dataStart;

                long nonZero = 0;
                long samplesSeen = 0;
                bool exact16Possible = true;
                bool exact24Possible = true;
                bool earlyNoPattern = false;
                long[] residualCounts = bits == 24 ? new long[256] : null;
                long gridExact = 0;
                long grid2 = 0;
                double gridSq = 0.0;

                int chunkSize = 4 * 1024 * 1024;
                chunkSize -= chunkSize % bytesPerSample;
                byte[] buffer = new byte[chunkSize];
                long remaining = dataSize;

                while (remaining > 0)
                {
                    int want = (int)Math.Min((long)chunkSize, remaining);
                    want -= want % bytesPerSample;
                    if (want <= 0) break;
                    int got = 0;
                    while (got < want)
                    {
                        int n = fs.Read(buffer, got, want - got);
                        if (n <= 0) break;
                        got += n;
                    }
                    if (got <= 0) break;
                    int usable = got - (got % bytesPerSample);
                    remaining -= got;
                    r.BytesScanned += got;

                    if (bits == 24)
                    {
                        for (int i = 0; i + 2 < usable; i += 3)
                        {
                            samplesSeen++;
                            byte b0 = buffer[i];
                            byte b1 = buffer[i + 1];
                            byte b2 = buffer[i + 2];
                            if ((b0 | b1 | b2) == 0) continue;

                            nonZero++;
                            if (b0 != 0) exact16Possible = false;
                            int residual = b0 >= 128 ? b0 - 256 : b0; // -128..+127: 256 estados
                            int abs = Math.Abs(residual);
                            residualCounts[residual + 128]++;
                            if (abs == 0) gridExact++;
                            if (abs <= 2) grid2++;
                            gridSq += (double)residual * residual;
                        }

                        if (!exact16Possible && nonZero > 0)
                        {
                            long remainingSamples = totalSamples - samplesSeen;
                            if (remainingSamples < 0) remainingSamples = 0;
                            long bestDen = nonZero + remainingSamples;
                            if (bestDen > 0)
                            {
                                double bestGrid2 = 100.0 * (grid2 + remainingSamples) / bestDen;
                                double bestExact = 100.0 * (gridExact + remainingSamples) / bestDen;
                                if (bestGrid2 < 95.0 && bestExact < 90.0)
                                {
                                    earlyNoPattern = true;
                                    r.EarlyExit = true;
                                    r.EarlyExitReason = "PCM24: imposible alcanzar umbral FUERTE/PARCIAL";
                                    break;
                                }
                            }
                        }
                    }
                    else
                    {
                        for (int i = 0; i + 3 < usable; i += 4)
                        {
                            samplesSeen++;
                            uint raw = (uint)(buffer[i] | (buffer[i+1] << 8) | (buffer[i+2] << 16) | (buffer[i+3] << 24));
                            if (raw == 0) continue;
                            nonZero++;
                            if ((raw & 0xFFU) != 0)
                            {
                                exact24Possible = false;
                                exact16Possible = false;
                                r.EarlyExit = true;
                                r.EarlyExitReason = "PCM32: LSB inferiores descartan patrón exacto 24/16";
                                break;
                            }
                            if ((raw & 0xFFFFU) != 0) exact16Possible = false;
                        }
                        if (!exact24Possible) break;
                    }
                }

                r.SamplesScanned = samplesSeen;
                r.NonZeroSamples = nonZero;

                if (!r.EarlyExit && remaining <= 0 && nonZero == 0)
                {
                    r.CommonZeroLSBs = bits;
                    r.InferredUsedBits = 0;
                    r.StrictResult = "PROFUNDIDAD EFECTIVA NO DETERMINABLE - SILENCIO DIGITAL";
                    r.PatternResult = "NO APLICA";
                    r.Valid = true;
                    sw.Stop(); r.AnalysisMs = sw.Elapsed.TotalMilliseconds;
                    return r;
                }

                if (bits == 24)
                {
                    if (!earlyNoPattern && exact16Possible)
                    {
                        r.StrictResult = "16 BITS EFECTIVOS EN CONTENEDOR PCM DE 24";
                        r.CommonZeroLSBs = 8;
                        r.InferredUsedBits = 16;
                    }
                    else
                    {
                        r.StrictResult = "PCM 24 - SIN PATRON EXACTO DE 16 BITS";
                        r.CommonZeroLSBs = 0;
                        r.InferredUsedBits = 24;
                    }

                    if (earlyNoPattern)
                    {
                        r.PatternResult = "SIN PATRON CLARO DE CUANTIZACION PREVIA DE 16 BITS";
                    }
                    else if (nonZero > 0)
                    {
                        r.Grid16ExactPct = 100.0 * gridExact / nonZero;
                        r.Grid16Within2Pct = 100.0 * grid2 / nonZero;
                        r.Grid16ResidualRms = Math.Sqrt(gridSq / nonZero);
                        r.Grid16ResidualEntropy = Entropy(residualCounts, nonZero);
                        int distinct = 0;
                        for (int i = 0; i < residualCounts.Length; i++) if (residualCounts[i] > 0) distinct++;
                        r.Grid16DistinctResiduals = distinct;

                        if (!exact16Possible)
                        {
                            bool strong = r.Grid16Within2Pct >= 95.0 && r.Grid16ResidualRms <= 2.0 && r.Grid16ResidualEntropy <= 3.0 && r.Grid16DistinctResiduals <= 32;
                            bool partial = r.Grid16ExactPct >= 90.0 && r.Grid16ResidualEntropy <= 1.5 && r.Grid16ResidualRms <= 5.0;
                            if (strong) r.PatternResult = "PATRON FUERTEMENTE COMPATIBLE CON CUANTIZACION PREVIA DE 16 BITS";
                            else if (partial) r.PatternResult = "PATRON PARCIAL COMPATIBLE CON GRILLA DE 16 BITS";
                            else r.PatternResult = "SIN PATRON CLARO DE CUANTIZACION PREVIA DE 16 BITS";
                        }
                        else r.PatternResult = "NO APLICA: PATRON EXACTO DE 16 BITS";
                    }
                }
                else
                {
                    if (exact24Possible && exact16Possible)
                    {
                        r.StrictResult = "16 BITS EFECTIVOS EN CONTENEDOR PCM ENTERO DE 32";
                        r.CommonZeroLSBs = 16;
                        r.InferredUsedBits = 16;
                    }
                    else if (exact24Possible)
                    {
                        r.StrictResult = "24 BITS EFECTIVOS EN CONTENEDOR PCM ENTERO DE 32";
                        r.CommonZeroLSBs = 8;
                        r.InferredUsedBits = 24;
                    }
                    else
                    {
                        r.StrictResult = "PCM ENTERO 32 - SIN PATRON EXACTO DE 24/16 BITS";
                        r.CommonZeroLSBs = 0;
                        r.InferredUsedBits = 32;
                    }
                    r.PatternResult = "NO APLICA";
                }

                r.Valid = true;
                sw.Stop(); r.AnalysisMs = sw.Elapsed.TotalMilliseconds;
                return r;
            }
        }
        catch (Exception ex)
        {
            r.Error = ex.Message;
            sw.Stop(); r.AnalysisMs = sw.Elapsed.TotalMilliseconds;
            return r;
        }
    }
}
"@

Add-Type -TypeDefinition $EffectiveDepthSource -Language CSharp

$FastWavToolsSource = @"
using System;
using System.IO;
using System.Security.Cryptography;
using System.Collections.Generic;

public class PGWavFastInfo
{
    public bool Valid;
    public string Error;
    public long DataStart;
    public long DataSize;
    public int SampleRate;
    public int Channels;
    public int Bits;
    public int BlockAlign;
    public int Encoding; // 1 PCM, 3 FLOAT
}

public class PGWavLevelStats
{
    public bool Valid;
    public string Error;
    public double PeakDb;
    public double RmsDb;
    public double LeftRmsDb;
    public double RightRmsDb;
    public bool HasLeft;
    public bool HasRight;
    public long FramesScanned;
    public long SamplesScanned;
    public double TemporalBalanceStdDb;
    public double TemporalBalanceRangeDb;
    public int TemporalActiveWindows;
    public int TemporalTotalWindows;
}

public static class PGWavFastTools
{
    static string FourCC(BinaryReader br) { return new string(br.ReadChars(4)); }

    static void AddTemporalBalanceWindow(List<double> balances, double sumSqL, long countL, double sumSqR, long countR)
    {
        if (countL <= 0 || countR <= 0) return;
        double rmsL = Math.Sqrt(sumSqL / countL);
        double rmsR = Math.Sqrt(sumSqR / countR);
        if (rmsL <= 0.0 || rmsR <= 0.0) return;
        double balanceDb = 20.0 * Math.Log10(rmsL) - 20.0 * Math.Log10(rmsR);
        if (!Double.IsNaN(balanceDb) && !Double.IsInfinity(balanceDb)) balances.Add(balanceDb);
    }

    static PGWavFastInfo ReadInfo(string path)
    {
        PGWavFastInfo r = new PGWavFastInfo();
        r.Valid = false;
        r.Error = "";
        try
        {
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (BinaryReader br = new BinaryReader(fs))
            {
                string riff = FourCC(br);
                if (riff != "RIFF" && riff != "RF64") throw new Exception("No es WAV RIFF/RF64.");
                br.ReadUInt32();
                if (FourCC(br) != "WAVE") throw new Exception("WAVE inválido.");

                ushort formatTag = 0;
                ushort channels = 0;
                uint sampleRate = 0;
                ushort blockAlign = 0;
                ushort bits = 0;
                Guid subFormat = Guid.Empty;
                long dataStart = -1;
                long dataSize = 0;

                while (fs.Position + 8 <= fs.Length)
                {
                    string id = FourCC(br);
                    uint size = br.ReadUInt32();
                    long chunkStart = fs.Position;

                    if (id == "fmt ")
                    {
                        formatTag = br.ReadUInt16();
                        channels = br.ReadUInt16();
                        sampleRate = br.ReadUInt32();
                        br.ReadUInt32();
                        blockAlign = br.ReadUInt16();
                        bits = br.ReadUInt16();

                        if (formatTag == 0xFFFE && size >= 40)
                        {
                            ushort cbSize = br.ReadUInt16();
                            if (cbSize >= 22)
                            {
                                br.ReadUInt16(); // valid bits
                                br.ReadUInt32(); // channel mask
                                byte[] g = br.ReadBytes(16);
                                subFormat = new Guid(g);
                            }
                        }
                    }
                    else if (id == "data")
                    {
                        dataStart = fs.Position;
                        dataSize = (size == UInt32.MaxValue) ? (fs.Length - dataStart) : Math.Min((long)size, fs.Length - dataStart);
                        break;
                    }

                    long next = chunkStart + size + (size % 2);
                    if (next > fs.Length) break;
                    fs.Position = next;
                }

                if (dataStart < 0 || channels == 0 || sampleRate == 0 || bits == 0 || blockAlign == 0)
                    throw new Exception("No se pudo leer fmt/data.");

                int encoding = 0;
                if (formatTag == 1) encoding = 1;
                else if (formatTag == 3) encoding = 3;
                else if (formatTag == 0xFFFE)
                {
                    string gs = subFormat.ToString().ToLowerInvariant();
                    if (gs.StartsWith("00000001-")) encoding = 1;
                    else if (gs.StartsWith("00000003-")) encoding = 3;
                }

                if (encoding == 0) throw new Exception("Formato WAV no soportado para lectura directa.");

                r.Valid = true;
                r.DataStart = dataStart;
                r.DataSize = dataSize;
                r.SampleRate = (int)sampleRate;
                r.Channels = channels;
                r.Bits = bits;
                r.BlockAlign = blockAlign;
                r.Encoding = encoding;
                return r;
            }
        }
        catch (Exception ex)
        {
            r.Error = ex.Message;
            return r;
        }
    }

    public static PGWavLevelStats LevelStats(string path)
    {
        PGWavLevelStats r = new PGWavLevelStats();
        r.Valid = false;
        r.Error = "";
        r.PeakDb = Double.NaN;
        r.RmsDb = Double.NaN;
        r.LeftRmsDb = Double.NaN;
        r.RightRmsDb = Double.NaN;
        r.TemporalBalanceStdDb = Double.NaN;
        r.TemporalBalanceRangeDb = Double.NaN;
        r.TemporalActiveWindows = 0;
        r.TemporalTotalWindows = 0;

        PGWavFastInfo info = ReadInfo(path);
        if (!info.Valid)
        {
            r.Error = info.Error;
            return r;
        }

        int bytesPerSample = info.Bits / 8;
        if (bytesPerSample <= 0 ||
            (info.Encoding == 3 && info.Bits != 32) ||
            (info.Encoding == 1 && info.Bits != 16 && info.Bits != 24 && info.Bits != 32))
        {
            r.Error = "Formato no soportado para LevelStats directo.";
            return r;
        }

        try
        {
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                fs.Position = info.DataStart;
                long remaining = info.DataSize;
                int targetBufferBytes = 4 * 1024 * 1024;
                int alignedBufferBytes = targetBufferBytes - (targetBufferBytes % info.BlockAlign);
                if (alignedBufferBytes < info.BlockAlign) alignedBufferBytes = info.BlockAlign;
                byte[] buffer = new byte[alignedBufferBytes];

                double peakAbs = 0.0;
                double sumSqAll = 0.0;
                double sumSqL = 0.0;
                double sumSqR = 0.0;
                long countAll = 0;
                long countL = 0;
                long countR = 0;
                long frames = 0;
                long windowSqLCount = 0;
                long windowSqRCount = 0;
                double windowSumSqL = 0.0;
                double windowSumSqR = 0.0;
                List<double> temporalBalances = new List<double>();

                while (remaining > 0)
                {
                    int want = (int)Math.Min((long)buffer.Length, remaining);
                    if (remaining > info.BlockAlign && (want % info.BlockAlign) != 0)
                    {
                        want -= (want % info.BlockAlign);
                    }
                    if (want <= 0) want = (int)Math.Min((long)info.BlockAlign, remaining);

                    int got = fs.Read(buffer, 0, want);
                    if (got <= 0) break;

                    int usable = got - (got % info.BlockAlign);
                    for (int frameOff = 0; frameOff < usable; frameOff += info.BlockAlign)
                    {
                        if (info.Channels >= 2 && frames > 0 && (frames % info.SampleRate) == 0)
                        {
                            AddTemporalBalanceWindow(temporalBalances, windowSumSqL, windowSqLCount, windowSumSqR, windowSqRCount);
                            windowSumSqL = 0.0; windowSumSqR = 0.0;
                            windowSqLCount = 0; windowSqRCount = 0;
                        }
                        int sampleOff = frameOff;
                        for (int ch = 0; ch < info.Channels; ch++)
                        {
                            double x = ReadSample(buffer, sampleOff, info.Bits, info.Encoding);
                            double ax = Math.Abs(x);
                            if (ax > peakAbs) peakAbs = ax;

                            double sq = x * x;
                            sumSqAll += sq;
                            countAll++;

                            if (ch == 0)
                            {
                                sumSqL += sq;
                                countL++;
                                windowSumSqL += sq;
                                windowSqLCount++;
                            }
                            else if (ch == 1)
                            {
                                sumSqR += sq;
                                countR++;
                                windowSumSqR += sq;
                                windowSqRCount++;
                            }

                            sampleOff += bytesPerSample;
                        }
                        frames++;
                    }

                    remaining -= got;
                    if (usable == 0) break;
                }

                if (info.Channels >= 2)
                {
                    AddTemporalBalanceWindow(temporalBalances, windowSumSqL, windowSqLCount, windowSumSqR, windowSqRCount);
                    r.TemporalTotalWindows = (int)Math.Ceiling(frames / (double)info.SampleRate);
                    r.TemporalActiveWindows = temporalBalances.Count;
                    if (temporalBalances.Count > 0)
                    {
                        double sum = 0.0, min = temporalBalances[0], max = temporalBalances[0];
                        for (int i = 0; i < temporalBalances.Count; i++)
                        {
                            double value = temporalBalances[i];
                            sum += value;
                            if (value < min) min = value;
                            if (value > max) max = value;
                        }
                        double mean = sum / temporalBalances.Count;
                        double variance = 0.0;
                        for (int i = 0; i < temporalBalances.Count; i++)
                        {
                            double delta = temporalBalances[i] - mean;
                            variance += delta * delta;
                        }
                        r.TemporalBalanceStdDb = Math.Sqrt(variance / temporalBalances.Count);
                        r.TemporalBalanceRangeDb = max - min;
                    }
                }

                r.FramesScanned = frames;
                r.SamplesScanned = countAll;

                if (countAll <= 0)
                {
                    r.Error = "Sin muestras legibles.";
                    return r;
                }

                r.PeakDb = peakAbs <= 0.0 ? Double.NegativeInfinity : 20.0 * Math.Log10(peakAbs);

                double rmsAll = Math.Sqrt(sumSqAll / countAll);
                r.RmsDb = rmsAll <= 0.0 ? Double.NegativeInfinity : 20.0 * Math.Log10(rmsAll);

                if (countL > 0)
                {
                    double rmsL = Math.Sqrt(sumSqL / countL);
                    r.LeftRmsDb = rmsL <= 0.0 ? Double.NegativeInfinity : 20.0 * Math.Log10(rmsL);
                    r.HasLeft = true;
                }

                if (countR > 0)
                {
                    double rmsR = Math.Sqrt(sumSqR / countR);
                    r.RightRmsDb = rmsR <= 0.0 ? Double.NegativeInfinity : 20.0 * Math.Log10(rmsR);
                    r.HasRight = true;
                }

                r.Valid = true;
                return r;
            }
        }
        catch (Exception ex)
        {
            r.Error = ex.Message;
            return r;
        }
    }

    public static string HashData(string path)
    {
        PGWavFastInfo info = ReadInfo(path);
        if (!info.Valid) return "SIN_HASH";

        try
        {
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (MD5 md5 = MD5.Create())
            {
                fs.Position = info.DataStart;
                long remaining = info.DataSize;
                byte[] buffer = new byte[4 * 1024 * 1024];

                while (remaining > 0)
                {
                    int want = (int)Math.Min((long)buffer.Length, remaining);
                    int got = fs.Read(buffer, 0, want);
                    if (got <= 0) break;
                    md5.TransformBlock(buffer, 0, got, null, 0);
                    remaining -= got;
                }
                md5.TransformFinalBlock(new byte[0], 0, 0);
                byte[] hash = md5.Hash;
                char[] chars = new char[hash.Length * 2];
                const string hex = "0123456789abcdef";
                for (int i = 0; i < hash.Length; i++)
                {
                    chars[i * 2] = hex[hash[i] >> 4];
                    chars[i * 2 + 1] = hex[hash[i] & 15];
                }
                return new string(chars);
            }
        }
        catch
        {
            return "SIN_HASH";
        }
    }

    static double ReadSample(byte[] b, int off, int bits, int encoding)
    {
        if (encoding == 3 && bits == 32)
        {
            return (double)BitConverter.ToSingle(b, off);
        }

        if (encoding != 1) return 0.0;

        if (bits == 16)
        {
            short v = (short)(b[off] | (b[off + 1] << 8));
            return v / 32768.0;
        }
        if (bits == 24)
        {
            int v = b[off] | (b[off + 1] << 8) | (b[off + 2] << 16);
            if ((v & 0x800000) != 0) v |= unchecked((int)0xFF000000);
            return v / 8388608.0;
        }
        if (bits == 32)
        {
            int v = b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);
            return v / 2147483648.0;
        }
        return 0.0;
    }

    static double WindowRmsDb(string path, PGWavFastInfo info, long startFrame, long frameCount)
    {
        if (frameCount <= 0) return Double.NaN;
        int bytesPerSample = info.Bits / 8;
        if (bytesPerSample <= 0) return Double.NaN;

        long startByte = info.DataStart + startFrame * info.BlockAlign;
        long bytesWanted = frameCount * info.BlockAlign;
        if (bytesWanted <= 0) return Double.NaN;

        double sumSq = 0.0;
        long sampleCount = 0;

        try
        {
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                fs.Position = startByte;
                byte[] buffer = new byte[Math.Min(1024 * 1024, (int)Math.Min((long)Int32.MaxValue, Math.Max((long)info.BlockAlign, bytesWanted)))];
                long remaining = bytesWanted;

                while (remaining > 0)
                {
                    int want = (int)Math.Min((long)buffer.Length, remaining);
                    int got = fs.Read(buffer, 0, want);
                    if (got <= 0) break;

                    int usable = got - (got % info.BlockAlign);
                    for (int frameOff = 0; frameOff < usable; frameOff += info.BlockAlign)
                    {
                        int sampleOff = frameOff;
                        for (int ch = 0; ch < info.Channels; ch++)
                        {
                            double x = ReadSample(buffer, sampleOff, info.Bits, info.Encoding);
                            sumSq += x * x;
                            sampleCount++;
                            sampleOff += bytesPerSample;
                        }
                    }
                    remaining -= usable;
                    if (usable == 0) break;
                }
            }

            if (sampleCount <= 0) return Double.NaN;
            double rms = Math.Sqrt(sumSq / sampleCount);
            if (rms <= 0.0) return Double.NegativeInfinity;
            return 20.0 * Math.Log10(rms);
        }
        catch
        {
            return Double.NaN;
        }
    }

    public static double[] Fingerprint(string path, double windowSec)
    {
        PGWavFastInfo info = ReadInfo(path);
        if (!info.Valid || info.SampleRate <= 0 || info.BlockAlign <= 0 || info.DataSize <= 0)
            return new double[] { Double.NaN, Double.NaN, Double.NaN };

        long totalFrames = info.DataSize / info.BlockAlign;
        if (totalFrames <= 0)
            return new double[] { Double.NaN, Double.NaN, Double.NaN };

        long windowFrames = Math.Max(1L, (long)Math.Round(windowSec * info.SampleRate));
        if (windowFrames > totalFrames) windowFrames = totalFrames;

        double[] fractions = new double[] { 0.20, 0.50, 0.80 };
        double[] rms = new double[3];

        for (int i = 0; i < 3; i++)
        {
            long center = (long)Math.Round(totalFrames * fractions[i]);
            long start = center - (windowFrames / 2);
            if (start < 0) start = 0;
            if (start + windowFrames > totalFrames) start = Math.Max(0, totalFrames - windowFrames);
            rms[i] = WindowRmsDb(path, info, start, windowFrames);
        }

        double sum = 0.0;
        int finite = 0;
        for (int i = 0; i < 3; i++)
        {
            if (!Double.IsNaN(rms[i]) && !Double.IsNegativeInfinity(rms[i]))
            {
                sum += rms[i];
                finite++;
            }
        }

        if (finite < 2)
            return new double[] { Double.NaN, Double.NaN, Double.NaN };

        double avg = sum / finite;
        double[] fp = new double[3];
        for (int i = 0; i < 3; i++)
        {
            if (Double.IsNaN(rms[i]) || Double.IsNegativeInfinity(rms[i])) fp[i] = Double.NaN;
            else fp[i] = rms[i] - avg;
        }
        return fp;
    }
}
"@

Add-Type -TypeDefinition $FastWavToolsSource -Language CSharp

function Get-EffectiveDepthSummary {
    param([object]$Depth)

    if ($null -eq $Depth -or -not $Depth.Valid) {
        return "PROFUNDIDAD EFECTIVA NO DETERMINADA"
    }

    if ($Depth.StrictResult -eq "16 BITS EFECTIVOS EN CONTENEDOR PCM DE 24") {
        return "16 bits efectivos en contenedor 24"
    }
    if ($Depth.StrictResult -eq "24 BITS EFECTIVOS EN CONTENEDOR PCM ENTERO DE 32") {
        return "24 bits efectivos en contenedor 32"
    }
    if ($Depth.StrictResult -eq "16 BITS EFECTIVOS EN CONTENEDOR PCM ENTERO DE 32") {
        return "16 bits efectivos en contenedor 32"
    }
    if ($Depth.PatternResult -eq "PATRON FUERTEMENTE COMPATIBLE CON CUANTIZACION PREVIA DE 16 BITS") {
        return "Patrón fuertemente compatible con cuantización previa de 16 bits"
    }
    if ($Depth.PatternResult -eq "PATRON PARCIAL COMPATIBLE CON GRILLA DE 16 BITS") {
        return "Patrón parcial compatible con grilla de 16 bits"
    }
    if ($Depth.Encoding -eq "PCM FLOAT") {
        return "FLOAT - profundidad efectiva no determinada"
    }

    return "Sin patrón relevante de profundidad efectiva"
}

function New-SilentEffectiveDepth {
    param([pscustomobject]$Info)
    $d = New-Object PGEffectiveDepthResult
    $d.Valid = $true
    $d.Error = ""
    $d.ContainerBits = $Info.BitDepth
    $d.ValidBits = $Info.BitDepth
    $d.TotalSamples = 0
    $d.NonZeroSamples = 0
    $d.SamplesScanned = 0
    $d.BytesScanned = 0
    $d.DataBytes = 0
    $d.AnalysisMs = 0.0
    $d.PatternResult = "NO APLICA"
    if ($Info.IsFloat) {
        $d.Encoding = "PCM FLOAT"
        $d.CommonZeroLSBs = -1
        $d.InferredUsedBits = -1
        $d.StrictResult = "FLOAT 32 - PROFUNDIDAD EFECTIVA NO DETERMINADA"
    }
    elseif ($Info.Codec -match '^pcm_') {
        $d.Encoding = "PCM ENTERO"
        if ($Info.BitDepth -eq 16) {
            $d.CommonZeroLSBs = 0
            $d.InferredUsedBits = 16
            $d.StrictResult = "PCM ENTERO 16"
        }
        else {
            $d.CommonZeroLSBs = $Info.BitDepth
            $d.InferredUsedBits = 0
            $d.StrictResult = "PROFUNDIDAD EFECTIVA NO DETERMINABLE - SILENCIO DIGITAL"
        }
    }
    else {
        $d.Encoding = "OTRO / NO PCM"
        $d.StrictResult = "PROFUNDIDAD EFECTIVA NO DETERMINADA"
    }
    return $d
}

if (-not (Test-Path $FFMPEG)) {
    Write-DiagnosticError "No se encontró ffmpeg.exe en: $ScriptDir"
    [System.Windows.Forms.MessageBox]::Show("No se encontró ffmpeg.exe junto al programa.", "Analizador de Multitracks V2.24.23") | Out-Null
    exit 1
}
if (-not (Test-Path $FFPROBE)) {
    Write-DiagnosticError "No se encontró ffprobe.exe en: $ScriptDir"
    [System.Windows.Forms.MessageBox]::Show("No se encontró ffprobe.exe junto al programa.", "Analizador de Multitracks V2.24.23") | Out-Null
    exit 1
}

$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
$dialog.Description = "Elegí la carpeta raíz que contiene los WAV de la sesión"
$dialog.ShowNewFolderButton = $false

if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
    Write-Host "Operación cancelada."
    exit 0
}

$SourceDir = $dialog.SelectedPath.TrimEnd('\')
$parent = Split-Path -Parent $SourceDir
$leaf   = Split-Path -Leaf $SourceDir
$OutputDirBase = Join-Path $parent ($leaf + " [PROCESADO]")
$OutputDir = $OutputDirBase

# La carpeta [PROCESADO] se crea solamente si hay conversiones reales.
$BasicReportPath = Join-Path $SourceDir "INFORME_ANALISIS_BASICO.txt"
$DetailedReportPath = Join-Path $SourceDir "INFORME_ANALISIS_DETALLADO.txt"

# Resolver transacciones anteriores antes de leer o procesar la sesión.
# Se inspeccionan la carpeta de origen y sus salidas [PROCESADO] relacionadas.
$reportDirsToRecover = New-Object System.Collections.Generic.List[string]
$reportDirsToRecover.Add($SourceDir)
$processedNamePattern = '^' + [regex]::Escape($leaf) + ' \[PROCESADO(?: \d+)?\]$'
foreach ($candidateDir in @(Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $processedNamePattern })) {
    $reportDirsToRecover.Add($candidateDir.FullName)
}
foreach ($candidatePath in @($reportDirsToRecover | Select-Object -Unique)) {
    $candidateLock = Join-Path $candidatePath '.AnalizadorMultitracks.publicacion.lock'
    $candidateTransactions = @(Get-ChildItem -LiteralPath $candidatePath -Directory -Filter '.AnalizadorMultitracks_txn_*' -ErrorAction SilentlyContinue)
    if ((Test-Path -LiteralPath $candidateLock) -or $candidateTransactions.Count -gt 0) {
        Resolve-PendingReportTransactions -TargetDirectory $candidatePath
    }
}

$wavFiles = @(Get-ChildItem -LiteralPath $SourceDir -Recurse -File |
    Where-Object { $_.Extension -ieq ".wav" } |
    Sort-Object FullName)

if ($wavFiles.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show("No se encontraron archivos WAV en la carpeta seleccionada.", "Analizador de Multitracks V2.24.23") | Out-Null
    exit 0
}

$totalInputBytes = [long](($wavFiles | Measure-Object Length -Sum).Sum)
if ($totalInputBytes -le 0) { $totalInputBytes = 1L }

$PerfTotal.Start()
$script:EtaClock.Reset()
$script:EtaClock.Start()

Show-ProgressWindow
Update-ProgressWindow -Percent 0 -EtaPercent 0 -Stage "Preparando análisis..." -Item "$($wavFiles.Count) archivo(s) WAV encontrados"

Write-Host ""
Write-Host "========================================"
Write-Host "ANALIZADOR DE MULTITRACKS V2.24.23 - ESTUDIO PG"
Write-Host "========================================"
Write-Host ""
Write-Host "Carpeta original:"
Write-Host $SourceDir
Write-Host ""
Write-Host "Carpeta procesada:"
Write-Host $OutputDir
Write-Host ""

# ------------------------------------------------------------
# PREANÁLISIS TÉCNICO
# ------------------------------------------------------------

$infos = @()
$preIndex = 0
foreach ($wav in $wavFiles) {
    $preIndex++
    $prePercent = [math]::Min(5, [math]::Floor(($preIndex / [double]$wavFiles.Count) * 5))
    Update-ProgressWindow -Percent $prePercent -EtaPercent $prePercent -Stage "Leyendo información técnica..." -Item ("Archivo {0} de {1}: {2}" -f $preIndex, $wavFiles.Count, $wav.Name)
    try {
        $swProbe = [System.Diagnostics.Stopwatch]::StartNew()
        $info = Get-AudioInfo $wav.FullName
        $swProbe.Stop()

        $Perf.FFprobeCalls++
        $Perf.FFprobeMs += $swProbe.Elapsed.TotalMilliseconds
        $Optimization.MetadataSinglePassFiles++

        $rel = Get-RelativePathSafe $SourceDir $wav.FullName
        $info | Add-Member -NotePropertyName RelativePath -NotePropertyValue $rel -Force
        $info | Add-Member -NotePropertyName IsFloat -NotePropertyValue ([bool]($info.Codec -match '^pcm_f(32|64)')) -Force
        $info | Add-Member -NotePropertyName FileSizeBytes -NotePropertyValue ([long]$wav.Length) -Force
        $info | Add-Member -NotePropertyName Peak -NotePropertyValue $null -Force
        $info | Add-Member -NotePropertyName RMS -NotePropertyValue $null -Force
        $info | Add-Member -NotePropertyName LeftRms -NotePropertyValue $null -Force
        $info | Add-Member -NotePropertyName RightRms -NotePropertyValue $null -Force
        $info | Add-Member -NotePropertyName AudioHash -NotePropertyValue 'SIN_HASH' -Force
        $info | Add-Member -NotePropertyName Fingerprint -NotePropertyValue $null -Force
        $info | Add-Member -NotePropertyName EffectiveDepth -NotePropertyValue $null -Force
        $info | Add-Member -NotePropertyName EffectiveDepthSummary -NotePropertyValue 'PROFUNDIDAD EFECTIVA NO DETERMINADA' -Force

        $infos += $info

        $perfRow = New-PerfRow $info
        $perfRow.FFprobeMs = [math]::Round($swProbe.Elapsed.TotalMilliseconds, 1)
        $PerfRows.Add($perfRow)
        $PerfRowMap[$rel] = $perfRow
    }
    catch {
        Write-Host "ERROR al analizar: $($wav.FullName)"
        Write-Host $_.Exception.Message
        Write-DiagnosticError ("FFprobe / metadatos: " + $wav.FullName + " -> " + $_.Exception.Message)
    }
}

if ($infos.Count -eq 0) {
    Write-Host "No se pudo analizar ningún WAV."
    Close-ProgressWindow
    exit 1
}

# Para ETA se cuentan únicamente los archivos que superaron el preanálisis.
$totalInputBytes = [long](($infos | Measure-Object FileSizeBytes -Sum).Sum)
if ($totalInputBytes -le 0) { $totalInputBytes = 1L }

# Predominantes de la sesión.
$referenceSampleRate = [int](Get-ModeValue $infos "SampleRate")
$bitDepthMode = Get-BitDepthModeSummary -Items $infos
$bitDepthModeValues = @($bitDepthMode.Values)
$referenceBitDepth = [int]$bitDepthMode.PredominantDepth
$referenceBitDepthText = [string]$bitDepthMode.Label

# Duración predominante redondeada a 1 ms para evitar pequeñas variaciones de contenedor.
$durationGroups = $infos | ForEach-Object {
    [pscustomobject]@{
        Info = $_
        Key  = [math]::Round($_.DurationSec, 3)
    }
} | Group-Object Key | Sort-Object Count -Descending
# Tomamos el valor numérico directamente del objeto original.
# No usamos Group.Name porque Windows en español puede interpretar 201,912 como 201912.
$referenceDuration = [double]$durationGroups[0].Group[0].Info.DurationSec

# ------------------------------------------------------------
# PROCESAMIENTO PRINCIPAL
# ------------------------------------------------------------

# Primera pasada: analizar y decidir acciones SIN copiar ni convertir.
$actions = New-Object System.Collections.Generic.List[object]
$needsProcessedFolder = $false

$detail = New-Object System.Collections.Generic.List[string]
$silentFiles = New-Object System.Collections.Generic.List[object]
$lowFiles = New-Object System.Collections.Generic.List[object]
$veryLowFiles = New-Object System.Collections.Generic.List[object]
$floatOverFiles = New-Object System.Collections.Generic.List[object]
$reviewFiles = New-Object System.Collections.Generic.List[string]
$probableDualFiles = New-Object System.Collections.Generic.List[object]
$probableDualEvaluations = New-Object System.Collections.Generic.List[object]

$countMono = 0
$countStereo = 0
$countDual = 0
$countDualPractical = 0
$countDualPracticalProbable = 0
$countPanned = 0
$countReview = 0
$countHighCorr = 0
$countSilent = 0

$script:MainCompletedBytes = 0L

function Complete-MainFile {
    param(
        [pscustomobject]$Info,
        [object]$PerfRow,
        [System.Diagnostics.Stopwatch]$Stopwatch,
        [int]$Index,
        [int]$Total
    )

    $Stopwatch.Stop()
    if ($null -ne $PerfRow) { $PerfRow.TotalMainMs = [math]::Round($Stopwatch.Elapsed.TotalMilliseconds, 1) }
    $script:MainCompletedBytes += [long]$Info.FileSizeBytes

    $fileFraction = $Index / [double]$Total
    $byteFraction = [math]::Min(1.0, $script:MainCompletedBytes / [double]$totalInputBytes)
    $visible = 5 + [math]::Floor($fileFraction * 90.0)
    $etaBase = 5.0 + (90.0 * ((0.60 * $fileFraction) + (0.40 * $byteFraction)))
    Update-ProgressWindow -Percent $visible -EtaPercent $etaBase -Stage "Analizando archivos..." -Item ("Completados {0} de {1}: {2}" -f $Index, $Total, $Info.RelativePath)
}

$mainIndex = 0
foreach ($info in $infos) {
    $mainIndex++
    $swMain = [System.Diagnostics.Stopwatch]::StartNew()
    $perfRow = Get-PerfRow $info.RelativePath

    $doneBefore = $mainIndex - 1
    $fileFractionBefore = $doneBefore / [double]$infos.Count
    $byteFractionBefore = [math]::Min(1.0, $script:MainCompletedBytes / [double]$totalInputBytes)
    $visibleBefore = 5 + [math]::Floor($fileFractionBefore * 90.0)
    $etaBefore = 5.0 + (90.0 * ((0.60 * $fileFractionBefore) + (0.40 * $byteFractionBefore)))
    Update-ProgressWindow -Percent $visibleBefore -EtaPercent $etaBefore -Stage "Analizando archivos..." -Item ("Archivo {0} de {1}: {2}" -f $mainIndex, $infos.Count, $info.RelativePath)

    $src = $info.File
    $rel = $info.RelativePath
    Write-Host "Analizando: $rel"

    # --------------------------------------------------------
    # NIVEL / RMS GLOBAL + RMS L/R EN UNA SOLA DECODIFICACIÓN
    # --------------------------------------------------------
    $swStats = [System.Diagnostics.Stopwatch]::StartNew()
    $stats = Get-FileStats $src
    $swStats.Stop()
    $Perf.FileStatsCalls++
    $Perf.FileStatsMs += $swStats.Elapsed.TotalMilliseconds
    if ($null -ne $perfRow) { $perfRow.FileStatsMs = [math]::Round($swStats.Elapsed.TotalMilliseconds, 1) }

    $info.Peak = $stats.Peak
    $info.RMS = $stats.RMS
    $info.LeftRms = $stats.LeftRms
    $info.RightRms = $stats.RightRms

    # Silencio digital: no se escanea LSB ni se compara como duplicado.
    if ($null -ne $stats.Peak -and [double]::IsNegativeInfinity([double]$stats.Peak)) {
        $depth = New-SilentEffectiveDepth $info
        $info.EffectiveDepth = $depth
        $info.EffectiveDepthSummary = Get-EffectiveDepthSummary $depth
        $Perf.EffectiveDepthSkippedSilence++

        $detail.Add("$rel -> SIN AUDIO (silencio digital)")
        $silentFiles.Add([pscustomobject]@{ Name=$rel })
        $countSilent++
        $actions.Add([pscustomobject]@{ Info=$info; Action='COPY'; Channel=$null; NewName=$null })
        Write-Host "SIN AUDIO"
        Write-Host ""
        Complete-MainFile -Info $info -PerfRow $perfRow -Stopwatch $swMain -Index $mainIndex -Total $infos.Count
        continue
    }

    # FLOAT sobre 0 dBFS: dato objetivo, no diagnóstico de clipping.
    if ($info.IsFloat -and $null -ne $stats.Peak -and $stats.Peak -gt 0.0) {
        $floatOverFiles.Add([pscustomobject]@{ Name=$rel; Peak=$stats.Peak })
    }

    if ($null -ne $stats.Peak) {
        if ($stats.Peak -le $VERY_LOW_LEVEL_THRESHOLD) {
            $veryLowFiles.Add([pscustomobject]@{ Name=$rel; Peak=$stats.Peak })
        }
        elseif ($stats.Peak -le $LOW_LEVEL_THRESHOLD) {
            $lowFiles.Add([pscustomobject]@{ Name=$rel; Peak=$stats.Peak })
        }
    }

    # --------------------------------------------------------
    # PROFUNDIDAD EFECTIVA OPTIMIZADA
    # --------------------------------------------------------
    $swDepth = [System.Diagnostics.Stopwatch]::StartNew()
    $depth = [PGEffectiveDepthAnalyzer]::Analyze($src)
    $swDepth.Stop()
    $Perf.EffectiveDepthCalls++
    $Perf.EffectiveDepthMs += $swDepth.Elapsed.TotalMilliseconds
    if ($null -ne $perfRow) { $perfRow.EffectiveDepthMs = [math]::Round($swDepth.Elapsed.TotalMilliseconds, 1) }

    $info.EffectiveDepth = $depth
    $info.EffectiveDepthSummary = Get-EffectiveDepthSummary $depth

    if (-not $depth.Valid) { $Optimization.DepthErrors++ }
    if ($depth.ContainerBits -eq 24) {
        if ($depth.EarlyExit) { $Optimization.DepthEarlyExit24++ } else { $Optimization.DepthFullScan24++ }
    }
    elseif ($depth.ContainerBits -eq 32 -and $depth.Encoding -eq 'PCM ENTERO') {
        if ($depth.EarlyExit) { $Optimization.DepthEarlyExit32++ } else { $Optimization.DepthFullScan32++ }
    }
    $Optimization.DepthSamplesTotal += [long]$depth.TotalSamples
    $Optimization.DepthSamplesScanned += [long]$depth.SamplesScanned
    $Optimization.DepthBytesTotal += [long]$depth.DataBytes
    $Optimization.DepthBytesScanned += [long]$depth.BytesScanned

    if ($info.Channels -eq 1) {
        $detail.Add("$rel -> MONO ORIGINAL")
        $countMono++
        $actions.Add([pscustomobject]@{ Info=$info; Action='COPY'; Channel=$null; NewName=$null })
        Write-Host "MONO ORIGINAL"
        Write-Host ""
        Complete-MainFile -Info $info -PerfRow $perfRow -Stopwatch $swMain -Index $mainIndex -Total $infos.Count
        continue
    }

    if ($info.Channels -ne 2) {
        $reason = "Archivo de $($info.Channels) canales"
        $detail.Add("$rel -> REVISAR | $reason")
        $reviewFiles.Add("$rel -> $reason")
        $countReview++
        $actions.Add([pscustomobject]@{ Info=$info; Action='COPY'; Channel=$null; NewName=$null })
        Write-Host "REVISAR -> $reason"
        Write-Host ""
        Complete-MainFile -Info $info -PerfRow $perfRow -Stopwatch $swMain -Index $mainIndex -Total $infos.Count
        continue
    }

    $swStereo = [System.Diagnostics.Stopwatch]::StartNew()
    $st = Get-StereoAnalysis -File $src -LeftRms $info.LeftRms -RightRms $info.RightRms
    $swStereo.Stop()
    $Perf.StereoCalls++
    $Perf.StereoMs += $swStereo.Elapsed.TotalMilliseconds
    if ($null -ne $perfRow) { $perfRow.StereoMs = [math]::Round($swStereo.Elapsed.TotalMilliseconds, 1) }

    if (-not $st.Valid) {
        $reason = "No se pudo completar el análisis L/R"
        $detail.Add("$rel -> REVISAR | $reason")
        $reviewFiles.Add("$rel -> $reason")
        $countReview++
        $actions.Add([pscustomobject]@{ Info=$info; Action='COPY'; Channel=$null; NewName=$null })
        Write-Host "REVISAR -> análisis incompleto"
        Write-Host ""
        Complete-MainFile -Info $info -PerfRow $perfRow -Stopwatch $swMain -Index $mainIndex -Total $infos.Count
        continue
    }

    $base = [System.IO.Path]::GetFileNameWithoutExtension($info.Name)
    $monoName = $base + " [MONO].wav"

    # DUAL MONO EXACTO — criterios actuales de la rama Intel.
    if (($st.LevelDiff -lt $DUAL_MONO_MAX_LEVEL_DIFF) -and
        ([double]::IsNegativeInfinity($st.Residual) -or $st.Residual -le $DUAL_MONO_MAX_RESIDUAL)) {
        $detail.Add(("{0} -> DUAL MONO EXACTO -> canal {1} -> {2}" -f $rel, $st.Stronger, $monoName))
        $countDual++
        $needsProcessedFolder = $true
        $actions.Add([pscustomobject]@{ Info=$info; Action='MONO'; Category='DUAL MONO EXACTO'; Channel=$st.Stronger; NewName=$monoName })
        Write-Host "DUAL MONO EXACTO -> SE CONVERTIRÁ A MONO"
        Write-Host "Canal conservado: $($st.Stronger)"
        Write-Host ""
        Complete-MainFile -Info $info -PerfRow $perfRow -Stopwatch $swMain -Index $mainIndex -Total $infos.Count
        continue
    }

    # MONO PANEADO — antes que Dual Mono Práctico, igual que Intel.
    if (($st.LevelDiff -ge $DUAL_MONO_MAX_LEVEL_DIFF) -and
        ([double]::IsNegativeInfinity($st.Residual) -or $st.Residual -le $MONO_PAN_MAX_RESIDUAL)) {
        $detail.Add(("{0} -> MONO PANEADO -> canal {1} -> {2}" -f $rel, $st.Stronger, $monoName))
        $countPanned++
        $needsProcessedFolder = $true
        $actions.Add([pscustomobject]@{ Info=$info; Action='MONO'; Category='MONO PANEADO'; Channel=$st.Stronger; NewName=$monoName })
        Write-Host "MONO PANEADO -> SE CONVERTIRÁ A MONO"
        Write-Host "Canal conservado: $($st.Stronger)"
        Write-Host ""
        Complete-MainFile -Info $info -PerfRow $perfRow -Stopwatch $swMain -Index $mainIndex -Total $infos.Count
        continue
    }

    # DUAL MONO PRÁCTICO.
    if (($st.Correlation -ge $PRACTICAL_DUAL_MIN_CORRELATION) -and
        ($st.LevelDiff -le $PRACTICAL_DUAL_MAX_LEVEL_DIFF) -and
        ([double]::IsNegativeInfinity($st.Residual) -or $st.Residual -le $PRACTICAL_DUAL_MAX_RESIDUAL)) {
        $detail.Add(("{0} -> DUAL MONO PRÁCTICO -> canal {1} -> {2}" -f $rel, $st.Stronger, $monoName))
        $countDual++
        $countDualPractical++
        $needsProcessedFolder = $true
        $actions.Add([pscustomobject]@{ Info=$info; Action='MONO'; Category='DUAL MONO PRÁCTICO'; Channel=$st.Stronger; NewName=$monoName })
        Write-Host "DUAL MONO PRÁCTICO -> SE CONVERTIRÁ A MONO"
        Write-Host "Canal conservado: $($st.Stronger)"
        Write-Host ""
        Complete-MainFile -Info $info -PerfRow $perfRow -Stopwatch $swMain -Index $mainIndex -Total $infos.Count
        continue
    }

    # Categoría experimental recuperada de V2.24.22. Se evalúa después de las reglas existentes.
    $probableDecision = Get-ProbableDualMonoDecision -Stereo $st -Stats $stats
    if ($probableDecision.CoreCriteriaMet) {
        $evaluation = [pscustomobject]@{
            Name=$rel; Correlation=[double]$st.Correlation; LevelDiff=[double]$st.LevelDiff; Residual=[double]$st.Residual
            TemporalStd=$stats.TemporalBalanceStdDb; TemporalRange=$stats.TemporalBalanceRangeDb
            ActiveWindows=[int]$stats.TemporalActiveWindows; TotalWindows=[int]$stats.TemporalTotalWindows
            Decision=if ($probableDecision.Eligible) { 'CONVERTIDO A MONO - DUAL MONO PRÁCTICO PROBABLE' } else { 'REVISAR' }
            Reason=$probableDecision.Reason
        }
        $probableDualEvaluations.Add($evaluation)
    }
    if ($probableDecision.Eligible) {
        $probableDualFiles.Add([pscustomobject]@{ Name=$rel; Metrics=$evaluation })
        $countDualPracticalProbable++
        $corrText = $st.Correlation.ToString('0.000000', $Invariant)
        $diffText = $st.LevelDiff.ToString('0.000', $Invariant)
        $resText = Format-Db $st.Residual
        $stdText = ([double]$stats.TemporalBalanceStdDb).ToString('0.000', $Invariant)
        $rangeText = ([double]$stats.TemporalBalanceRangeDb).ToString('0.000', $Invariant)
        $detail.Add(('{0} -> DUAL MONO PRÁCTICO PROBABLE -> se convertirá a mono | hipótesis métrica | correlación {1} | diferencia L/R {2} dB | residual {3} | estabilidad temporal SD {4} dB, rango {5} dB | ventanas activas {6}/{7}' -f $rel,$corrText,$diffText,$resText,$stdText,$rangeText,$stats.TemporalActiveWindows,$stats.TemporalTotalWindows))
        $countDual++
        $needsProcessedFolder = $true
        $actions.Add([pscustomobject]@{ Info=$info; Action='MONO'; Category='DUAL MONO PRÁCTICO PROBABLE'; Channel=$st.Stronger; NewName=$monoName })
        Write-Host 'DUAL MONO PRÁCTICO PROBABLE -> SE CONVERTIRÁ A MONO (HIPÓTESIS MÉTRICA)'
        Write-Host "Canal conservado: $($st.Stronger)"
        Write-Host ""
        Complete-MainFile -Info $info -PerfRow $perfRow -Stopwatch $swMain -Index $mainIndex -Total $infos.Count
        continue
    }

    # POSIBLE MONO / ESTÉREO ALTAMENTE CORRELACIONADO: sólo revisión manual.
    if (($st.Correlation -ge $HIGH_CORR_MIN_CORRELATION) -and
        ($st.LevelDiff -le $HIGH_CORR_MAX_LEVEL_DIFF) -and
        ([double]::IsNegativeInfinity($st.Residual) -or $st.Residual -le $HIGH_CORR_MAX_RESIDUAL)) {
        $corrText = $st.Correlation.ToString('0.00000', $Invariant)
        $diffText = $st.LevelDiff.ToString('0.00', $Invariant)
        $reason = "Posible mono / estéreo altamente correlacionado | correlación aprox. $corrText | diferencia L/R $diffText dB"
        if ($probableDecision.CoreCriteriaMet -and $probableDecision.Reason) { $reason += " | $($probableDecision.Reason)" }
        $detail.Add("$rel -> REVISAR | $reason")
        $reviewFiles.Add("$rel -> $reason")
        $countReview++
        $countHighCorr++
        $actions.Add([pscustomobject]@{ Info=$info; Action='COPY'; Channel=$null; NewName=$null })
        Write-Host "POSIBLE MONO / ESTÉREO ALTAMENTE CORRELACIONADO -> REVISAR"
        Write-Host ""
        Complete-MainFile -Info $info -PerfRow $perfRow -Stopwatch $swMain -Index $mainIndex -Total $infos.Count
        continue
    }

    if ([double]::IsNegativeInfinity($st.Residual) -or $st.Residual -le $REVIEW_MAX_RESIDUAL) {
        $resText = Format-Db $st.Residual
        $diffText = if ([double]::IsPositiveInfinity($st.LevelDiff)) { 'infinita' } else { $st.LevelDiff.ToString('0.00', $Invariant) + ' dB' }
        $reason = "Residual relativo: $resText | Diferencia L/R: $diffText"
        $detail.Add("$rel -> REVISAR | $reason")
        $reviewFiles.Add("$rel -> $reason")
        $countReview++
        $actions.Add([pscustomobject]@{ Info=$info; Action='COPY'; Channel=$null; NewName=$null })
        Write-Host "REVISAR"
        Write-Host ""
        Complete-MainFile -Info $info -PerfRow $perfRow -Stopwatch $swMain -Index $mainIndex -Total $infos.Count
        continue
    }

    $detail.Add("$rel -> STEREO REAL")
    $countStereo++
    $actions.Add([pscustomobject]@{ Info=$info; Action='COPY'; Channel=$null; NewName=$null })
    Write-Host "STEREO REAL"
    Write-Host ""
    Complete-MainFile -Info $info -PerfRow $perfRow -Stopwatch $swMain -Index $mainIndex -Total $infos.Count
}

# ------------------------------------------------------------
# CONTROL DE FORMATO Y DURACIÓN
# ------------------------------------------------------------

$sampleRateDiff = @($infos | Where-Object { $_.SampleRate -ne $referenceSampleRate })
$bitDepthDiff = @($infos | Where-Object { $_.BitDepth -gt 0 -and $_.BitDepth -notin $bitDepthModeValues })
$floatFiles = @($infos | Where-Object { $_.IsFloat })
$formatGroups = @($infos | Group-Object {
    if ($_.IsFloat) { if ($_.BitDepth -gt 0) { "FLOAT $($_.BitDepth) bits" } else { 'FLOAT, profundidad no determinada' } }
    elseif ($_.BitDepth -gt 0) { "PCM entero $($_.BitDepth) bits" }
    else { 'Formato/profundidad no determinados' }
} | Sort-Object Name)
$formatComposition = if ($formatGroups.Count -gt 0) {
    (@($formatGroups | ForEach-Object { "{0}: {1}" -f $_.Name,$_.Count }) -join ' | ')
} else { 'no determinada' }

# Tolerancia de una muestra a la frecuencia predominante.
$durationTolerance = 1.5 / [double]$referenceSampleRate
$durationDiff = @($infos | Where-Object {
    [math]::Abs($_.DurationSec - $referenceDuration) -gt $durationTolerance
})

# ------------------------------------------------------------
# COMPARACIÓN DE DUPLICADOS — DESACTIVADA TEMPORALMENTE
# V2.24.23 prioriza el rendimiento del análisis principal.
# Se conserva la implementación en versiones de desarrollo anteriores;
# esta versión no calcula fingerprints ni compara señales entre archivos.
# ------------------------------------------------------------
$duplicateGroups = @()
$duplicateExtraCount = 0
$dupInfos = @()
$candidatePairs = @()
$duplicateEdges = @()
$components = @()
$DuplicateStats.TheoreticalPairs = 0
$DuplicateStats.EffectivePairs = 0
$DuplicateStats.NonHashPairs = 0
$DuplicateStats.FingerprintMode = 'DESACTIVADO'
$DuplicateStats.FingerprintFiles = 0
$DuplicateStats.FingerprintRuns = 0
$DuplicateStats.FingerprintRejected = 0
$DuplicateStats.FullComparisons = 0
$DuplicateStats.SignalMatches = 0
$DuplicateStats.TransitiveSkipped = 0
$DuplicateStats.ExactHashMatches = 0

# ------------------------------------------------------------
# CREACIÓN DE SALIDA SOLO SI HAY CONVERSIONES
# ------------------------------------------------------------
Update-ProgressWindow -Percent 96 -EtaPercent 96 -Stage "Preparando resultados..." -Item ""
$conversionErrors = New-Object System.Collections.Generic.List[string]
$backupErrors = New-Object System.Collections.Generic.List[string]
$conversionResults = New-Object System.Collections.Generic.List[object]

if ($needsProcessedFolder) {
    # Nunca borrar una salida previa. Se elige automáticamente [PROCESADO 2], [PROCESADO 3], etc.
    $OutputDir = Get-AvailableProcessedDir -Parent $parent -Leaf $leaf
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

    foreach ($a in $actions) {
        $info = $a.Info
        $rel = $info.RelativePath
        $relDir = Split-Path -Parent $rel
        $destDir = if ([string]::IsNullOrWhiteSpace($relDir)) { $OutputDir } else { Join-Path $OutputDir $relDir }

        if ($a.Action -eq 'MONO') {
            $dest = Join-Path $destDir $a.NewName
            $fallback = Join-Path $destDir $info.Name
            $result = Invoke-MonoConversionAction -Action $a -OutputFile $dest -BackupFile $fallback
            $conversionResults.Add($result)
            if ($result.Status -eq 'FALLIDA') {
                $conversionErrors.Add("$rel -> $($result.Error)")
                Write-DiagnosticError ("Conversión: $rel -> " + $result.Error)
                if ($result.BackupError) {
                    $backupErrors.Add("$rel -> $($result.BackupError)")
                    Write-DiagnosticError ("Respaldo tras conversión fallida: $rel -> " + $result.BackupError)
                }
                if ($result.PartialCleanupError) {
                    $conversionErrors.Add("$rel -> no se pudo retirar salida parcial: $($result.PartialCleanupError)")
                    Write-DiagnosticError ("Salida parcial tras conversión fallida: $rel -> " + $result.PartialCleanupError)
                }
            }
        }
        else {
            $dest = Join-Path $destDir $info.Name
            $swCopy = [System.Diagnostics.Stopwatch]::StartNew()
            Copy-AudioFile $info.File $dest
            $swCopy.Stop()
            $Perf.CopyCalls++
            $Perf.CopyMs += $swCopy.Elapsed.TotalMilliseconds
        }
    }

    $BasicReportPath = Join-Path $OutputDir "INFORME_ANALISIS_BASICO.txt"
    $DetailedReportPath = Join-Path $OutputDir "INFORME_ANALISIS_DETALLADO.txt"
    $TechnicalReportPath = Join-Path $OutputDir "INFORME_TECNICO_DESARROLLO.txt"
}
else {
    $BasicReportPath = Join-Path $SourceDir "INFORME_ANALISIS_BASICO.txt"
    $DetailedReportPath = Join-Path $SourceDir "INFORME_ANALISIS_DETALLADO.txt"
    $TechnicalReportPath = Join-Path $SourceDir "INFORME_TECNICO_DESARROLLO.txt"
}

$plannedConversionActions = @($actions | Where-Object { $_.Action -eq 'MONO' })
$plannedConversionCount = $plannedConversionActions.Count
$completedConversionResults = @($conversionResults | Where-Object { $_.Status -eq 'COMPLETADA' })
$failedConversionResults = @($conversionResults | Where-Object { $_.Status -eq 'FALLIDA' })
$conversionCategoryBreakdown = @(Get-ConversionCategoryBreakdown -PlannedActions $plannedConversionActions -ConversionResults $conversionResults.ToArray())

# ------------------------------------------------------------
# INFORME
# ------------------------------------------------------------

$report = New-Object System.Collections.Generic.List[string]

$report.Add("========================================")
$report.Add("ANALIZADOR DE MULTITRACKS V2.24.23 - INFORME DETALLADO - ESTUDIO PG")
$report.Add("========================================")
$report.Add("")
$report.Add("Carpeta original:")
$report.Add($SourceDir)
$report.Add("")
if ($needsProcessedFolder) {
    $report.Add("Carpeta procesada:")
    $report.Add($OutputDir)
    $report.Add("")
    $report.Add("ESTADO: SE GENERÓ CARPETA PROCESADA PORQUE HABÍA ARCHIVOS PARA CONVERTIR.")
}
else {
    $report.Add("Carpeta procesada:")
    $report.Add("NO GENERADA")
    $report.Add("")
    $report.Add("ESTADO: NO SE REQUIEREN MODIFICACIONES AUTOMÁTICAS. SOLO SE GENERÓ ESTE INFORME.")
}
$report.Add("")
$report.Add("========================================")
$report.Add("DETALLE")
$report.Add("========================================")
$report.Add("")
$trackNumber = 0
foreach ($line in $detail) {
    $trackNumber++
    $report.Add(("{0}. {1}" -f $trackNumber, $line))
}

$report.Add("")
$report.Add("========================================")
$report.Add("CONTROL DE FORMATO Y DURACIÓN")
$report.Add("========================================")
$report.Add("")
$report.Add("Valores predominantes de la sesión:")
$report.Add("")
$report.Add(("Frecuencia de muestreo predominante: {0} kHz" -f ($referenceSampleRate / 1000.0).ToString("0.###", $Invariant)))
$report.Add("Composición de formatos: $formatComposition")
$report.Add("Profundidad de bits predominante: $referenceBitDepthText")
$report.Add("Duración: $(Format-Seconds $referenceDuration)")
$report.Add("")

$report.Add("----------------------------------------")
$report.Add("FRECUENCIA DE MUESTREO")
$report.Add("----------------------------------------")
$report.Add("")
if ($sampleRateDiff.Count -eq 0) {
    $report.Add("OK - Todos los archivos analizados usan la frecuencia de muestreo predominante.")
}
else {
    $report.Add("ATENCIÓN - $($sampleRateDiff.Count) archivo(s) tienen una frecuencia de muestreo diferente.")
    $report.Add("")
    $n = 1
    foreach ($x in $sampleRateDiff) {
        $report.Add("$n. $($x.RelativePath)")
        $report.Add(("   Frecuencia de muestreo: {0} kHz" -f ($x.SampleRate / 1000.0).ToString("0.###", $Invariant)))
        $report.Add("")
        $n++
    }
}
$report.Add("")

$report.Add("----------------------------------------")
$report.Add("PROFUNDIDAD DE BITS")
$report.Add("----------------------------------------")
$report.Add("")
if ($bitDepthDiff.Count -eq 0) {
    $report.Add("OK - Todos los archivos con profundidad detectable coinciden con el valor predominante.")
}
else {
    $report.Add("ATENCIÓN - $($bitDepthDiff.Count) archivo(s) tienen una profundidad diferente.")
    $report.Add("")
    $n = 1
    foreach ($x in $bitDepthDiff) {
        $report.Add("$n. $($x.RelativePath)")
        $report.Add("   Profundidad: $($x.BitDepth) bits")
        $report.Add("")
        $n++
    }
}
$report.Add("")

$report.Add("----------------------------------------")
$report.Add("ARCHIVOS FLOAT")
$report.Add("----------------------------------------")
$report.Add("")
if ($floatFiles.Count -eq 0) {
    $report.Add("Ninguno.")
}
else {
    $floatGroups = @($floatFiles | Group-Object BitDepth | Sort-Object { [int]$_.Name })
    foreach ($g in $floatGroups) {
        $depthLabel = if ([int]$g.Name -gt 0) { "$($g.Name) bits" } else { "profundidad no determinada" }
        $report.Add("FLOAT $depthLabel`: $($g.Count) archivo(s)")
    }
    $report.Add("La profundidad confirmada de estos archivos participa en el cálculo global de profundidad de bits predominante.")
    if (@($floatGroups | Where-Object { [int]$_.Name -le 0 }).Count -gt 0) {
        $report.Add("Los archivos FLOAT con profundidad no determinada no participan del cálculo.")
    }
}
$report.Add("")

$report.Add("----------------------------------------")
$report.Add("PROFUNDIDAD EFECTIVA / ALMACENAMIENTO")
$report.Add("----------------------------------------")
$report.Add("")
$report.Add("Este control distingue entre la profundidad del contenedor y la información digital observada en las muestras.")
$report.Add("Las categorías FUERTE y PARCIAL son inferencias estadísticas y no demuestran el historial completo del archivo.")
$report.Add("")

$depthRelevant = @($infos | Where-Object {
    $_.EffectiveDepthSummary -ne "Sin patrón relevante de profundidad efectiva" -and
    $_.EffectiveDepthSummary -ne "FLOAT - profundidad efectiva no determinada"
})

if ($depthRelevant.Count -eq 0) {
    $report.Add("OK - No se detectaron archivos almacenados a mayor profundidad ni patrones relevantes de cuantización previa.")
}
else {
    $report.Add("ATENCIÓN - $($depthRelevant.Count) archivo(s) presentan información relevante de profundidad efectiva.")
    $report.Add("")
    $n = 1

    foreach ($x in $depthRelevant) {
        $d = $x.EffectiveDepth

        $report.Add("$n. $($x.RelativePath)")
        $report.Add("   Resultado: $($x.EffectiveDepthSummary)")
        $report.Add("   Formato: $($d.Encoding.ToLower()) $($d.ContainerBits) bits")

        # Evidencia resumida según el tipo de hallazgo.
        if ($d.StrictResult -eq "16 BITS EFECTIVOS EN CONTENEDOR PCM DE 24") {
            $report.Add("   Evidencia: 8 LSB inferiores en cero")
        }
        elseif ($d.StrictResult -eq "24 BITS EFECTIVOS EN CONTENEDOR PCM ENTERO DE 32") {
            $report.Add("   Evidencia: 8 LSB inferiores en cero")
        }
        elseif ($d.StrictResult -eq "16 BITS EFECTIVOS EN CONTENEDOR PCM ENTERO DE 32") {
            $report.Add("   Evidencia: 16 LSB inferiores en cero")
        }
        elseif ($d.PatternResult -eq "PATRON FUERTEMENTE COMPATIBLE CON CUANTIZACION PREVIA DE 16 BITS") {
            $report.Add(("   Evidencia: {0:0.0}% dentro de +/-2 LSB de la grilla de 16 bits | RMS residual {1:0.00} LSB" -f `
                $d.Grid16Within2Pct, $d.Grid16ResidualRms))
        }
        elseif ($d.PatternResult -eq "PATRON PARCIAL COMPATIBLE CON GRILLA DE 16 BITS") {
            $report.Add(("   Evidencia: {0:0.0}% de coincidencia exacta con la grilla de 16 bits | RMS residual {1:0.00} LSB" -f `
                $d.Grid16ExactPct, $d.Grid16ResidualRms))
        }
        else {
            $report.Add("   Evidencia: patrón relevante detectado en los bits menos significativos")
        }

        $report.Add("")
        $n++
    }
}
$report.Add("")

$report.Add("----------------------------------------")
$report.Add("LONGITUD DE AUDIO")
$report.Add("----------------------------------------")
$report.Add("")
$report.Add("Duración de referencia: $(Format-Seconds $referenceDuration)")
$report.Add("")
if ($durationDiff.Count -eq 0) {
    $report.Add("OK - Todos los archivos tienen la misma duración dentro de una tolerancia de una muestra.")
}
else {
    $report.Add("ATENCIÓN - $($durationDiff.Count) archivo(s) tienen distinta longitud.")
    $report.Add("")
    $n = 1
    foreach ($x in $durationDiff) {
        $diffSec = $x.DurationSec - $referenceDuration
        # Expresamos la diferencia en muestras normalizadas al sample rate predominante.
        $diffSamples = [math]::Round($diffSec * $referenceSampleRate)
        $signSec = if ($diffSec -ge 0) { "+" } else { "" }
        $signSamples = if ($diffSamples -ge 0) { "+" } else { "" }

        $report.Add("$n. $($x.RelativePath)")
        $report.Add("   Duración: $(Format-Seconds $x.DurationSec)")
        $report.Add(("   Diferencia: {0}{1:0.000} s" -f $signSec, $diffSec))
        $report.Add(("   Diferencia técnica: {0}{1} muestras (normalizadas a {2} Hz)" -f $signSamples, $diffSamples, $referenceSampleRate))
        $report.Add("")
        $n++
    }
}

$report.Add("")
$report.Add("========================================")
$report.Add("CONTROL FLOAT SOBRE 0 dBFS")
$report.Add("========================================")
$report.Add("")
$report.Add("Este control no diagnostica clipping. Sólo informa archivos floating point cuyo pico supera 0 dBFS.")
$report.Add("")
$report.Add("----------------------------------------")
$report.Add("FLOAT SOBRE 0 dBFS")
$report.Add("----------------------------------------")
$report.Add("")
if ($floatOverFiles.Count -eq 0) {
    $report.Add("Ninguno.")
}
else {
    $n = 1
    foreach ($x in $floatOverFiles) {
        $report.Add("$n. $($x.Name)")
        $report.Add(("   Pico máximo: {0:0.000} dBFS" -f $x.Peak))
        $report.Add("   Nota: en audio floating point superar 0 dBFS no demuestra clipping por sí solo.")
        $report.Add("")
        $n++
    }
}

$report.Add("")
$report.Add("========================================")
$report.Add("CONTROL DE NIVEL")
$report.Add("========================================")
$report.Add("")
$report.Add("Archivos sin audio: $($silentFiles.Count)")
$report.Add("Archivos con nivel bajo (-20 a -60 dBFS): $($lowFiles.Count)")
$report.Add("Archivos con nivel extremadamente bajo (<= -60 dBFS): $($veryLowFiles.Count)")
$report.Add("")

$report.Add("----------------------------------------")
$report.Add("SIN AUDIO")
$report.Add("----------------------------------------")
$report.Add("")
if ($silentFiles.Count -eq 0) {
    $report.Add("Ninguno.")
}
else {
    $n = 1
    foreach ($x in $silentFiles) {
        $report.Add("$n. $($x.Name)")
        $report.Add("   Silencio digital durante toda la duración.")
        $report.Add("")
        $n++
    }
}

$report.Add("")
$report.Add("----------------------------------------")
$report.Add("NIVEL BAJO")
$report.Add("----------------------------------------")
$report.Add("")
if ($lowFiles.Count -eq 0) {
    $report.Add("Ninguno.")
}
else {
    $n = 1
    foreach ($x in $lowFiles) {
        $report.Add("$n. $($x.Name)")
        $report.Add(("   Pico máximo: {0:0.0} dBFS" -f $x.Peak))
        $report.Add("")
        $n++
    }
}

$report.Add("")
$report.Add("----------------------------------------")
$report.Add("NIVEL EXTREMADAMENTE BAJO")
$report.Add("----------------------------------------")
$report.Add("")
if ($veryLowFiles.Count -eq 0) {
    $report.Add("Ninguno.")
}
else {
    $n = 1
    foreach ($x in $veryLowFiles) {
        $report.Add("$n. $($x.Name)")
        $report.Add(("   Pico máximo: {0:0.0} dBFS" -f $x.Peak))
        $report.Add("")
        $n++
    }
}

$report.Add("")
$report.Add("")
$report.Add("========================================")
$report.Add("RESUMEN")
$report.Add("========================================")
$report.Add("")
$report.Add("Total WAV: $($infos.Count)")
$report.Add("")
$report.Add("Mono originales: $countMono")
$report.Add("Stereo reales: $countStereo")
$report.Add("Conversiones previstas: $plannedConversionCount")
$report.Add("Conversiones completadas: $($completedConversionResults.Count)")
$report.Add("Conversiones fallidas: $($failedConversionResults.Count)")
foreach ($row in $conversionCategoryBreakdown) {
    $report.Add(("{0}: previstas {1} | completadas {2} | fallidas {3}" -f $row.Category,$row.Planned,$row.Completed,$row.Failed))
}
$report.Add("Para revisar: $countReview")
$report.Add("  Posible mono / estéreo altamente correlacionado: $countHighCorr")
$report.Add("")
$report.Add("Archivos sin audio: $($silentFiles.Count)")
$report.Add("Nivel bajo: $($lowFiles.Count)")
$report.Add("Nivel extremadamente bajo: $($veryLowFiles.Count)")
$report.Add("Float sobre 0 dBFS: $($floatOverFiles.Count)")
$report.Add("")
$report.Add("Archivos con distinta frecuencia de muestreo: $($sampleRateDiff.Count)")
$report.Add("Archivos con distinta profundidad: $($bitDepthDiff.Count)")
$report.Add("Archivos con distinta longitud: $($durationDiff.Count)")
$report.Add("")
$report.Add("========================================")
$report.Add("RESULTADO DE CONVERSIONES")
$report.Add("========================================")
$report.Add("")
if ($conversionResults.Count -eq 0) {
    $report.Add("No se planificaron conversiones.")
}
else {
    foreach ($result in $conversionResults) {
        if ($result.Status -eq 'COMPLETADA') {
            $report.Add(("{0} [{1}] -> CONVERSIÓN COMPLETADA | salida: {2}" -f $result.RelativePath,$result.Category,$result.Output))
        }
        else {
            $report.Add(("{0} [{1}] -> CONVERSIÓN FALLIDA | {2} | {3} | ruta de copia: {4}" -f $result.RelativePath,$result.Category,$result.Error,$result.BackupStatus,$result.BackupPath))
        }
    }
}
$report.Add("")
$report.Add("========================================")
$report.Add("ARCHIVOS PARA REVISAR")
$report.Add("========================================")
$report.Add("")
if ($reviewFiles.Count -eq 0) {
    $report.Add("Ninguno.")
}
else {
    $n = 1
    foreach ($r in $reviewFiles) {
        $report.Add("$n. $r")
        $n++
    }
}


# ------------------------------------------------------------
# INFORME BÁSICO
# ------------------------------------------------------------

$basic = New-Object System.Collections.Generic.List[string]

$notConvertedCount = [math]::Max(0, $infos.Count - $completedConversionResults.Count)

$basic.Add("========================================")
$basic.Add("ANALIZADOR DE MULTITRACKS V2.24.23 - INFORME BÁSICO - ESTUDIO PG")
$basic.Add("========================================")
$basic.Add("")
$basic.Add("Carpeta analizada:")
$basic.Add($SourceDir)
$basic.Add("")
if ($needsProcessedFolder) {
    $basic.Add("Carpeta procesada:")
    $basic.Add($OutputDir)
}
else {
    $basic.Add("Carpeta procesada: NO GENERADA - no fue necesaria.")
}

$basic.Add("")
$basic.Add("========================================")
$basic.Add("FORMATO PARA CREAR LA SESIÓN")
$basic.Add("========================================")
$basic.Add("")
$basic.Add(("Frecuencia de muestreo predominante: {0} kHz" -f ($referenceSampleRate / 1000.0).ToString("0.###", $Invariant)))
$basic.Add("Profundidad de bits predominante: $referenceBitDepthText")
$basic.Add("Total WAV: $($infos.Count)")
$basic.Add("Composición de formatos: $formatComposition")
$basic.Add("")

$formatWarnings = New-Object System.Collections.Generic.List[string]
if ($sampleRateDiff.Count -gt 0) { $formatWarnings.Add("$($sampleRateDiff.Count) archivo(s) con otra frecuencia de muestreo") }
if ($bitDepthDiff.Count -gt 0) { $formatWarnings.Add("$($bitDepthDiff.Count) archivo(s) con otra profundidad") }
if ($durationDiff.Count -gt 0) { $formatWarnings.Add("$($durationDiff.Count) archivo(s) con distinta duración") }

if ($formatWarnings.Count -eq 0) {
    $basic.Add("Formato y duración: sin advertencias.")
}
else {
    $basic.Add("ATENCIÓN:")
    foreach ($w in $formatWarnings) { $basic.Add("- $w") }
}

$basic.Add("")
$basic.Add("========================================")
$basic.Add("ACCIONES REALIZADAS")
$basic.Add("========================================")
$basic.Add("")
$basic.Add("Conversiones previstas: $plannedConversionCount")
$basic.Add("Conversiones completadas: $($completedConversionResults.Count)")
$basic.Add("Conversiones fallidas: $($failedConversionResults.Count)")
foreach ($row in $conversionCategoryBreakdown) {
    $basic.Add(("{0}: previstas {1} | completadas {2} | fallidas {3}" -f $row.Category,$row.Planned,$row.Completed,$row.Failed))
}
$basic.Add("Archivos para revisar: $countReview")
$basic.Add("WAV sin conversión mono completada: $notConvertedCount")
$basic.Add("Mono originales: $countMono | estéreo real: $countStereo")
if ($countDualPracticalProbable -gt 0) { $basic.Add("Nota: DUAL MONO PRÁCTICO PROBABLE es una hipótesis métrica, no una confirmación auditiva.") }

$basic.Add("")
$basic.Add("CONVERSIONES FALLIDAS Y RESPALDOS")
$basic.Add("--------------------------")
if ($failedConversionResults.Count -eq 0) {
    $basic.Add("No hubo conversiones fallidas.")
}
else {
    foreach ($result in $failedConversionResults) {
        $basic.Add(("{0} [{1}] -> FALLIDA: {2}; {3}; copia: {4}" -f $result.RelativePath,$result.Category,$result.Error,$result.BackupStatus,$result.BackupPath))
    }
}

$basic.Add("")
$basic.Add("========================================")
$basic.Add("PROFUNDIDAD EFECTIVA")
$basic.Add("========================================")
$basic.Add("")

$depthExact24to16 = @($infos | Where-Object { $_.EffectiveDepth.StrictResult -eq "16 BITS EFECTIVOS EN CONTENEDOR PCM DE 24" })
$depthExact32to24 = @($infos | Where-Object { $_.EffectiveDepth.StrictResult -eq "24 BITS EFECTIVOS EN CONTENEDOR PCM ENTERO DE 32" })
$depthExact32to16 = @($infos | Where-Object { $_.EffectiveDepth.StrictResult -eq "16 BITS EFECTIVOS EN CONTENEDOR PCM ENTERO DE 32" })
$depthStrong = @($infos | Where-Object { $_.EffectiveDepth.PatternResult -eq "PATRON FUERTEMENTE COMPATIBLE CON CUANTIZACION PREVIA DE 16 BITS" })
$depthPartial = @($infos | Where-Object { $_.EffectiveDepth.PatternResult -eq "PATRON PARCIAL COMPATIBLE CON GRILLA DE 16 BITS" })

$depthRelevantTotal = $depthExact24to16.Count + $depthExact32to24.Count + $depthExact32to16.Count + $depthStrong.Count + $depthPartial.Count

if ($depthRelevantTotal -eq 0) {
    $basic.Add("Sin hallazgos relevantes de profundidad efectiva.")
}
else {
    if ($depthExact24to16.Count -gt 0) { $basic.Add("16 bits efectivos en contenedor 24: $($depthExact24to16.Count)") }
    if ($depthExact32to24.Count -gt 0) { $basic.Add("24 bits efectivos en contenedor 32: $($depthExact32to24.Count)") }
    if ($depthExact32to16.Count -gt 0) { $basic.Add("16 bits efectivos en contenedor 32: $($depthExact32to16.Count)") }
    if ($depthStrong.Count -gt 0) { $basic.Add("Patrón FUERTE compatible con cuantización previa de 16 bits: $($depthStrong.Count)") }
    if ($depthPartial.Count -gt 0) { $basic.Add("Patrón PARCIAL compatible con grilla de 16 bits: $($depthPartial.Count)") }
    $basic.Add("")
    $basic.Add("Detalle y evidencia: ver Informe de análisis detallado.pdf")
}

$basic.Add("")
$basic.Add("========================================")
$basic.Add("OTRAS ADVERTENCIAS")
$basic.Add("========================================")
$basic.Add("")

if ($silentFiles.Count -eq 0 -and $lowFiles.Count -eq 0 -and $veryLowFiles.Count -eq 0 -and $floatOverFiles.Count -eq 0) {
    $basic.Add("Nivel: sin advertencias.")
}
else {
    if ($silentFiles.Count -gt 0) { $basic.Add("Sin audio: $($silentFiles.Count)") }
    if ($lowFiles.Count -gt 0) { $basic.Add("Nivel bajo: $($lowFiles.Count)") }
    if ($veryLowFiles.Count -gt 0) { $basic.Add("Nivel extremadamente bajo: $($veryLowFiles.Count)") }
    if ($floatOverFiles.Count -gt 0) { $basic.Add("FLOAT > 0 dBFS: $($floatOverFiles.Count)") }
}

$basic.Add("")
$basic.Add("========================================")
$basic.Add("ARCHIVOS PARA REVISAR")
$basic.Add("========================================")
$basic.Add("")
if ($reviewFiles.Count -eq 0) {
    $basic.Add("Ninguno.")
}
else {
    $n = 1
    foreach ($r in $reviewFiles) {
        $basic.Add("$n. $r")
        $n++
    }
}

Update-ProgressWindow -Percent 98 -EtaPercent 98 -Stage "Generando informes..." -Item "Básico + detallado + técnico"

# Preparar los cinco artefactos fuera de sus rutas finales. La recuperación
# pendiente se resuelve antes de adquirir un bloqueo nuevo.
$FinalBasicReportPath = $BasicReportPath
$FinalDetailedReportPath = $DetailedReportPath
$FinalTechnicalReportPath = $TechnicalReportPath
$ReportTargetDirectory = Split-Path -Parent $FinalBasicReportPath
$reportRecoveryPath = $null
$reportTransaction = $null
function Get-RetainedReportTxtLocations {
    param($Transaction, [string]$RecoveryPath)
    if ($RecoveryPath -and (Test-Path -LiteralPath $RecoveryPath -PathType Container)) { return @($RecoveryPath) }
    if ($null -eq $Transaction) { return @('(no se pudo determinar la ubicación de los TXT)') }
    $locations = @()
    foreach ($name in @('INFORME_ANALISIS_BASICO.txt','INFORME_ANALISIS_DETALLADO.txt','INFORME_TECNICO_DESARROLLO.txt')) {
        $stagePath = Join-Path $Transaction.Stage $name
        $partialPath = Join-Path $Transaction.Root ('publicado_parcial_' + $name)
        if (Test-Path -LiteralPath $stagePath -PathType Leaf) { $locations += $stagePath }
        elseif (Test-Path -LiteralPath $partialPath -PathType Leaf) { $locations += $partialPath }
        else { $locations += "No localizado: $stagePath ; $partialPath" }
    }
    return $locations
}
try {
    Resolve-PendingReportTransactions -TargetDirectory $ReportTargetDirectory
    $reportTransaction = New-ReportTransaction -TargetDirectory $ReportTargetDirectory
    $BasicReportPath = Join-Path $reportTransaction.Stage 'INFORME_ANALISIS_BASICO.txt'
    $DetailedReportPath = Join-Path $reportTransaction.Stage 'INFORME_ANALISIS_DETALLADO.txt'
    $TechnicalReportPath = Join-Path $reportTransaction.Stage 'INFORME_TECNICO_DESARROLLO.txt'
}
catch {
    Write-DiagnosticError ("No se pudo preparar la publicación protegida: " + $_.Exception.Message)
    throw
}

# UTF-8 con BOM para que Bloc de notas de Windows muestre bien acentos.
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$swReports = [System.Diagnostics.Stopwatch]::StartNew()
try {
    [System.IO.File]::WriteAllLines($BasicReportPath, $basic, $utf8Bom)
    [System.IO.File]::WriteAllLines($DetailedReportPath, $report, $utf8Bom)
}
catch {
    $reportBuildError = $_.Exception.Message
    $reportRecoveryError = $null
    try { $reportRecoveryPath = Save-ReportRecovery -Transaction $reportTransaction -Reason $reportBuildError } catch { $reportRecoveryError = $_.Exception.Message }
    Close-ReportTransaction -Transaction $reportTransaction -RemoveLock ($null -ne $reportRecoveryPath)
    $retainedTxtPath = @(Get-RetainedReportTxtLocations $reportTransaction $reportRecoveryPath) -join '; '
    Write-DiagnosticError ("No se pudieron preparar los TXT de informes: " + $reportBuildError + ". Ubicaciones de TXT: " + $retainedTxtPath + $(if ($reportRecoveryError) { ". Falló la copia a recuperación: $reportRecoveryError" } else { '' }))
    throw
}
$swReports.Stop()
$Perf.ReportMs = $swReports.Elapsed.TotalMilliseconds

Update-ProgressWindow -Percent 99 -EtaPercent 99 -Stage "Generando diagnóstico técnico..." -Item "INFORME_TECNICO_DESARROLLO.txt"

# El tiempo de referencia se congela después de producir los informes de usuario.
# La escritura del propio informe técnico queda fuera para no crear una dependencia circular.
if ($PerfTotal.IsRunning) { $PerfTotal.Stop() }
$actualTotalSec = $PerfTotal.Elapsed.TotalSeconds
$totalAudioSec = ($infos | Measure-Object DurationSec -Sum).Sum
$totalAudioMin = [math]::Max(($totalAudioSec / 60.0), 0.001)

# ------------------------------------------------------------
# INFORME TÉCNICO DE DESARROLLO — NO DESTINADO A USUARIO FINAL
# ------------------------------------------------------------
$tech = New-Object System.Collections.Generic.List[string]
$tech.Add("========================================")
$tech.Add("ANALIZADOR DE MULTITRACKS V2.24.23 - INFORME TÉCNICO DE DESARROLLO - WINDOWS")
$tech.Add("ESTUDIO PG")
$tech.Add("========================================")
$tech.Add("VERSIÓN / CONFIGURACIÓN ACTUAL")
$tech.Add("========================================")
$tech.Add("- Versión: V2.24.23 Windows.")
$tech.Add("- Peak/RMS global y RMS L/R: lectura directa WAV/C# con validación automática y fallback FFmpeg.")
$tech.Add("- Residual estéreo: FFmpeg, método estable validado. Residual de duplicados no ejecutado.")
$tech.Add("- Profundidad efectiva: análisis PCM24/PCM32 con early-exit.")
$tech.Add("- Silencio digital detectado antes del análisis LSB.")
$tech.Add("- Comparación de duplicados: DESACTIVADA temporalmente para priorizar rendimiento.")
$tech.Add("- Hash completo omitido por costo/beneficio.")
$tech.Add("- No se ejecutan filtros, fingerprints, hashes ni comparaciones de señal entre archivos para detectar duplicados.")
$tech.Add("- ETA con reloj monotónico y diagnóstico técnico.")
$tech.Add("- Salida segura: nunca borra [PROCESADO]; crea [PROCESADO 2], [PROCESADO 3], etc.")
$tech.Add("- Profundidad predominante calculada con profundidades confirmadas PCM entero y FLOAT.")
$tech.Add("- POSIBLE MONO / ESTÉREO ALTAMENTE CORRELACIONADO se envía a REVISAR, sin conversión automática.")
$tech.Add("- Informes de usuario omiten diagnósticos de duplicados; el informe técnico conserva ese diagnóstico interno.")
$tech.Add("- Ventana final al frente con autocierre a los 60 s.")
$tech.Add("- V2.24.23: candidata de integración de informes; se mantiene FFmpeg para residuales.")
$tech.Add("")

$tech.Add("========================================")
$tech.Add("ENTORNO")
$tech.Add("========================================")
$osCaption = "No disponible"; $osVersion = [Environment]::OSVersion.VersionString
$cpuName = "No disponible"; $ramGB = "No disponible"
try {
    $osObj = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $osCaption = $osObj.Caption
    $osVersion = $osObj.Version + " build " + $osObj.BuildNumber
    $ramGB = ("{0:0.00}" -f ($osObj.TotalVisibleMemorySize * 1KB / 1GB))
} catch {}
try { $cpuName = (Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Name) } catch {}
$ffmpegVersion = "No disponible"; $ffprobeVersion = "No disponible"
try { $ffmpegVersion = [string]((& $FFMPEG -version 2>$null | Select-Object -First 1)) } catch {}
try { $ffprobeVersion = [string]((& $FFPROBE -version 2>$null | Select-Object -First 1)) } catch {}
$tech.Add("Sistema: $osCaption")
$tech.Add("Versión Windows: $osVersion")
$tech.Add("PowerShell: $($PSVersionTable.PSVersion)")
$tech.Add("Arquitectura proceso: " + $(if ([Environment]::Is64BitProcess) {"64 bits"} else {"32 bits"}))
$tech.Add("CPU: $cpuName")
$tech.Add("RAM visible: $ramGB GB")
$tech.Add("FFmpeg: $ffmpegVersion")
$tech.Add("FFprobe: $ffprobeVersion")
$tech.Add("")

$tech.Add("========================================")
$tech.Add("CARGA DE TRABAJO")
$tech.Add("========================================")
$tech.Add("WAV analizados: $($infos.Count)")
$tech.Add(("Tamaño total WAV: {0:0.00} GB ({1:N0} bytes)" -f ($totalInputBytes/1GB), $totalInputBytes))
$tech.Add(("Audio acumulado: {0:0.00} min" -f $totalAudioMin))
$tech.Add(("Duración media por WAV: {0:0.00} s" -f (($infos | Measure-Object DurationSec -Average).Average)))
$tech.Add("Mono: $(@($infos | Where-Object {$_.Channels -eq 1}).Count)")
$tech.Add("Estéreo: $(@($infos | Where-Object {$_.Channels -eq 2}).Count)")
$tech.Add("Otros canales: $(@($infos | Where-Object {$_.Channels -ne 1 -and $_.Channels -ne 2}).Count)")
$tech.Add("PCM16: $(@($infos | Where-Object {-not $_.IsFloat -and $_.BitDepth -eq 16}).Count)")
$tech.Add("PCM24: $(@($infos | Where-Object {-not $_.IsFloat -and $_.BitDepth -eq 24}).Count)")
$tech.Add("PCM32 entero: $(@($infos | Where-Object {-not $_.IsFloat -and $_.BitDepth -eq 32}).Count)")
$tech.Add("FLOAT: $(@($infos | Where-Object {$_.IsFloat}).Count)")
$tech.Add("")

$tech.Add("========================================")
$tech.Add("RESULTADOS FUNCIONALES")
$tech.Add("========================================")
$tech.Add("Mono originales: $countMono")
$tech.Add("Estéreo reales: $countStereo")
$tech.Add("Conversiones previstas: $plannedConversionCount")
$tech.Add("Conversiones completadas: $($completedConversionResults.Count)")
$tech.Add("Conversiones fallidas: $($failedConversionResults.Count)")
foreach ($row in $conversionCategoryBreakdown) {
    $tech.Add(("{0}: previstas {1} | completadas {2} | fallidas {3}" -f $row.Category,$row.Planned,$row.Completed,$row.Failed))
}
$tech.Add("Para revisar: $countReview")
$tech.Add("  Posible mono / estéreo altamente correlacionado: $countHighCorr")
$tech.Add("Sin audio: $($silentFiles.Count)")
$tech.Add("Nivel bajo: $($lowFiles.Count)")
$tech.Add("Nivel extremadamente bajo: $($veryLowFiles.Count)")
$tech.Add("FLOAT > 0 dBFS: $($floatOverFiles.Count)")
$tech.Add("Errores de conversión: $($conversionErrors.Count)")
$tech.Add("Errores al conservar copia de respaldo: $($backupErrors.Count)")
foreach ($e in $backupErrors) { $tech.Add("RESPALDO FALLIDO: $e") }
$tech.Add("")
$tech.Add("Umbrales de clasificación vigentes:")
$tech.Add("  DUAL MONO EXACTO: diferencia < $DUAL_MONO_MAX_LEVEL_DIFF dB | residual relativo <= $DUAL_MONO_MAX_RESIDUAL dB")
$tech.Add("  MONO PANEADO: diferencia >= $DUAL_MONO_MAX_LEVEL_DIFF dB | residual relativo <= $MONO_PAN_MAX_RESIDUAL dB")
$tech.Add("  DUAL MONO PRÁCTICO: corr >= $PRACTICAL_DUAL_MIN_CORRELATION | diferencia <= $PRACTICAL_DUAL_MAX_LEVEL_DIFF dB | residual relativo <= $PRACTICAL_DUAL_MAX_RESIDUAL dB")
$tech.Add("  DUAL MONO PRÁCTICO PROBABLE (hipótesis métrica): residual <= $PROBABLE_DUAL_MAX_RESIDUAL dB | correlación estimada >= $PROBABLE_DUAL_MIN_CORRELATION | diferencia L/R <= $PROBABLE_DUAL_MAX_LEVEL_DIFF dB | estabilidad temporal SD <= $PROBABLE_DUAL_MAX_TEMPORAL_STD dB y rango <= $PROBABLE_DUAL_MAX_TEMPORAL_RANGE dB | mínimo $PROBABLE_DUAL_MIN_ACTIVE_WINDOWS ventanas activas de 1 s")
$tech.Add("  La correlación de la regla probable se estima desde el residual compensado; no equivale a confirmación auditiva de dual mono.")
$tech.Add("  ALTA CORRELACIÓN / REVISAR: corr >= $HIGH_CORR_MIN_CORRELATION | diferencia <= $HIGH_CORR_MAX_LEVEL_DIFF dB | residual relativo <= $HIGH_CORR_MAX_RESIDUAL dB")
$tech.Add("  REVISAR residual: <= $REVIEW_MAX_RESIDUAL dB relativo")
$tech.Add("")
$tech.Add("Evaluaciones DUAL MONO PRÁCTICO PROBABLE que cumplen residual/correlación/nivel:")
if ($probableDualEvaluations.Count -eq 0) { $tech.Add("  Ninguna.") }
else {
    foreach ($evaluation in $probableDualEvaluations) {
        $temporalStd = if ($null -eq $evaluation.TemporalStd) { 'ND' } else { ([double]$evaluation.TemporalStd).ToString('0.000', $Invariant) }
        $temporalRange = if ($null -eq $evaluation.TemporalRange) { 'ND' } else { ([double]$evaluation.TemporalRange).ToString('0.000', $Invariant) }
        $tech.Add(("  {0} -> {1} | correlación {2} | diferencia L/R {3} dB | residual {4} dB | temporal SD {5} dB | rango {6} dB | ventanas activas {7}/{8} | {9}" -f $evaluation.Name,$evaluation.Decision,$evaluation.Correlation.ToString('0.000000',$Invariant),$evaluation.LevelDiff.ToString('0.000',$Invariant),(Format-Db $evaluation.Residual),$temporalStd,$temporalRange,$evaluation.ActiveWindows,$evaluation.TotalWindows,$evaluation.Reason))
    }
}
$tech.Add("")

$tech.Add("========================================")
$tech.Add("TIEMPO TOTAL Y ETAPAS")
$tech.Add("========================================")
$tech.Add(("Tiempo de referencia total: {0:0.000} s" -f $actualTotalSec))
$tech.Add(("Tiempo por minuto de audio acumulado: {0:0.000} s/min" -f ($actualTotalSec/$totalAudioMin)))
$tech.Add("Nota: el total termina al finalizar los informes de usuario; excluye únicamente la escritura de este informe técnico.")
$tech.Add("")
$tech.Add(("Metadatos / FFprobe: {0} llamada(s) | {1:0.000} s" -f $Perf.FFprobeCalls, ($Perf.FFprobeMs/1000.0)))
$tech.Add(("Nivel + RMS global/L/R: {0} archivo(s) | {1:0.000} s" -f $Perf.FileStatsCalls, ($Perf.FileStatsMs/1000.0)))
$tech.Add("  Directo WAV/C#: $($Optimization.DirectLevelStatsFiles) | fallback FFmpeg/astats: $($Optimization.LevelStatsFallbackFiles)")
$tech.Add(("Profundidad efectiva: {0} llamada(s) | {1:0.000} s" -f $Perf.EffectiveDepthCalls, ($Perf.EffectiveDepthMs/1000.0)))
$tech.Add(("Análisis estéreo L/R + residual: {0} archivo(s) | {1:0.000} s" -f $Perf.StereoCalls, ($Perf.StereoMs/1000.0)))
$tech.Add("Hash completo de audio: OMITIDO (no rentable en esta rama)")
$tech.Add(("Fingerprint directo WAV (C#): {0} archivo(s), {1} ventanas | {2:0.000} s" -f $Perf.FingerprintFiles, $Perf.FingerprintCalls, ($Perf.FingerprintMs/1000.0)))
$tech.Add(("Comparación completa duplicados: {0} par(es) | {1:0.000} s" -f $Perf.DuplicatePairCalls, ($Perf.DuplicatePairMs/1000.0)))
$tech.Add(("Conversiones: {0} archivo(s) | {1:0.000} s" -f $Perf.ConversionCalls, ($Perf.ConversionMs/1000.0)))
$tech.Add(("Copias de salida: {0} archivo(s) | {1:0.000} s" -f $Perf.CopyCalls, ($Perf.CopyMs/1000.0)))
$tech.Add(("Escritura informes básico/detallado: {0:0.000} s" -f ($Perf.ReportMs/1000.0)))
$tech.Add("")
$tech.Add("Etapas ordenadas por costo:")
$techStages = @(
    [pscustomobject]@{N='Análisis estéreo';M=$Perf.StereoMs},
    [pscustomobject]@{N='Nivel/RMS';M=$Perf.FileStatsMs},
    [pscustomobject]@{N='Profundidad efectiva';M=$Perf.EffectiveDepthMs},
    [pscustomobject]@{N='Hash directo WAV';M=$Perf.DuplicateHashMs},
    [pscustomobject]@{N='Fingerprint directo WAV';M=$Perf.FingerprintMs},
    [pscustomobject]@{N='Comparación duplicados (desactivada)';M=$Perf.DuplicatePairMs},
    [pscustomobject]@{N='FFprobe';M=$Perf.FFprobeMs},
    [pscustomobject]@{N='Conversiones';M=$Perf.ConversionMs},
    [pscustomobject]@{N='Copias salida';M=$Perf.CopyMs},
    [pscustomobject]@{N='Informes';M=$Perf.ReportMs}
) | Sort-Object M -Descending
foreach ($x in $techStages) {
    $pct = if ($actualTotalSec -gt 0) { 100.0*($x.M/1000.0)/$actualTotalSec } else { 0.0 }
    $tech.Add(("  {0}: {1:0.000} s | {2:0.0}%" -f $x.N, ($x.M/1000.0), $pct))
}
$tech.Add("")

$tech.Add("========================================")
$tech.Add("COBERTURA DE OPTIMIZACIONES")
$tech.Add("========================================")
$tech.Add("WAV con FFprobe consolidado en una llamada: $($Optimization.MetadataSinglePassFiles) / $($infos.Count)")
$tech.Add("WAV estéreo que reutilizaron RMS L/R global: $($Optimization.StereoRmsReusedFiles)")
$tech.Add("Fallback de RMS L/R con decodificación adicional: $($Optimization.StereoRmsFallbackFiles)")
$tech.Add("Llamadas axcorrelate: $($Optimization.AxcorrelateCalls) (objetivo: 0)")
$tech.Add("Pasadas RMS L/R adicionales evitadas por reutilización: $($Optimization.StereoRmsReusedFiles * 2)")
$tech.Add("Pasadas axcorrelate evitadas respecto del esquema Windows anterior: $($Perf.StereoCalls)")
$tech.Add("Detección de duplicados: desactivada; no se ejecutan hashes, fingerprints ni comparaciones entre archivos")
$tech.Add("Llamadas FFmpeg para fingerprint de duplicados: 0 (etapa desactivada)")
$tech.Add("Procesos FFmpeg evitados por fingerprint directo: $($Perf.FingerprintCalls)")
$tech.Add(("Escrituras de estado de progreso: {0} | costo acumulado {1:0.000} s" -f $ProgressPerf.StateWrites, ($ProgressPerf.StateWriteMs/1000.0)))
$tech.Add("Nivel/RMS directo WAV/C#: $($Optimization.DirectLevelStatsFiles) / $($infos.Count)")
$tech.Add("Fallback nivel/RMS mediante FFmpeg astats: $($Optimization.LevelStatsFallbackFiles)")
$tech.Add("Validación lector directo: $($script:DirectLevelValidation.Checked) archivo(s) cotejados con FFmpeg")
$tech.Add(("Máxima diferencia validación Peak: {0:0.0000} dB | RMS: {1:0.0000} dB" -f $script:DirectLevelValidation.MaxPeakDiffDb, $script:DirectLevelValidation.MaxRmsDiffDb))
$tech.Add("Modo directo deshabilitado por validación: $($script:DirectLevelValidation.Disabled)")
$tech.Add("astats: reservado a fallback de nivel/RMS y residuales que aún requieren FFmpeg")
$tech.Add("Silencios que omitieron análisis LSB: $($Perf.EffectiveDepthSkippedSilence)")
$tech.Add("Early-exit PCM24: $($Optimization.DepthEarlyExit24)")
$tech.Add("PCM24 recorridos completos: $($Optimization.DepthFullScan24)")
$tech.Add("Early-exit PCM32: $($Optimization.DepthEarlyExit32)")
$tech.Add("PCM32 recorridos completos: $($Optimization.DepthFullScan32)")
$tech.Add("Errores profundidad efectiva: $($Optimization.DepthErrors)")
if ($Optimization.DepthSamplesTotal -gt 0) {
    $scanPct = 100.0*$Optimization.DepthSamplesScanned/$Optimization.DepthSamplesTotal
    $tech.Add(("Muestras inspeccionadas / potenciales: {0:N0} / {1:N0} ({2:0.00}%)" -f $Optimization.DepthSamplesScanned,$Optimization.DepthSamplesTotal,$scanPct))
}
if ($Optimization.DepthBytesTotal -gt 0) {
    $scanBytesPct = 100.0*$Optimization.DepthBytesScanned/$Optimization.DepthBytesTotal
    $tech.Add(("Bytes PCM leídos / datos PCM potenciales: {0:N0} / {1:N0} ({2:0.00}%)" -f $Optimization.DepthBytesScanned,$Optimization.DepthBytesTotal,$scanBytesPct))
}
$tech.Add("Nota: los porcentajes de escaneo corresponden a PCM24/PCM32 enviados al helper; PCM16 y silencios omitidos se contabilizan aparte.")
$tech.Add("")

$tech.Add("========================================")
$tech.Add("PROFUNDIDAD EFECTIVA — DETALLE DE RENDIMIENTO")
$tech.Add("========================================")
$infoMap = @{}; foreach ($iInfo in $infos) { $infoMap[$iInfo.RelativePath]=$iInfo }
$depthRows = @($PerfRows | Where-Object {$_.EffectiveDepthMs -gt 0} | Sort-Object EffectiveDepthMs -Descending)
$n=1
foreach ($row in $depthRows) {
    $ii=$infoMap[$row.RelativePath]; $dd=$ii.EffectiveDepth
    $pctSamples = if ($dd.TotalSamples -gt 0) {100.0*$dd.SamplesScanned/$dd.TotalSamples} else {0.0}
    $tech.Add(("{0}. {1}" -f $n,$row.RelativePath))
    $tech.Add(("   Tiempo externo: {0:0.0} ms | interno C#: {1:0.0} ms" -f $row.EffectiveDepthMs,$dd.AnalysisMs))
    $tech.Add("   Resultado: $($ii.EffectiveDepthSummary)")
    $tech.Add(("   Escaneo: {0:N0}/{1:N0} muestras ({2:0.00}%) | early-exit: {3}" -f $dd.SamplesScanned,$dd.TotalSamples,$pctSamples,$dd.EarlyExit))
    if ($dd.EarlyExitReason) { $tech.Add("   Motivo early-exit: $($dd.EarlyExitReason)") }
    if (-not $dd.Valid) { $tech.Add("   ERROR: $($dd.Error)") }
    $tech.Add("")
    $n++
}

$tech.Add("DUPLICADOS — DIAGNÓSTICO")
$tech.Add("========================================")
$tech.Add("Estado: COMPARACIÓN DESACTIVADA TEMPORALMENTE EN V2.24.23.")
$tech.Add("No se ejecutaron análisis de elegibilidad, fingerprints, hashes ni comparaciones de señal.")
$tech.Add("Grupos detectados: 0 (no evaluados; no equivale a ausencia de duplicados).")
$tech.Add("Tiempo de comparación de duplicados: 0 s porque la etapa no se ejecutó.")
$tech.Add("")

$tech.Add("========================================")
$tech.Add("ARCHIVOS MÁS COSTOSOS")
$tech.Add("========================================")
$n=1
foreach ($row in @($PerfRows | Sort-Object TotalMainMs -Descending | Select-Object -First 30)) {
    $tech.Add(("{0}. {1}" -f $n,$row.RelativePath))
    $tech.Add(("   total principal {0:0.0} ms | ffprobe {1:0.0} | nivel/RMS {2:0.0} | profundidad {3:0.0} | stereo {4:0.0} | hash omitido {5:0.0} | {6:0.00} MB" -f $row.TotalMainMs,$row.FFprobeMs,$row.FileStatsMs,$row.EffectiveDepthMs,$row.StereoMs,$row.HashMs,$row.SizeMB))
    $n++
}
$tech.Add("")

$tech.Add("========================================")
$tech.Add("DIAGNÓSTICO ETA / TIEMPO RESTANTE")
$tech.Add("========================================")
$tech.Add(("Tiempo real de referencia: {0:0.000} s" -f $actualTotalSec))
$tech.Add("Algoritmo: no estima antes de 8 s ni 20% ETA; análisis principal ponderado de 5% a 95% (60% archivos + 40% bytes); comparación de duplicados desactivada; cierre 96-100%; corrige rápido al alza y suavemente a la baja.")
$etaArray=@($script:EtaSamples)
$tech.Add("Llamadas de progreso evaluadas por ETA: $($script:EtaDiag.Calls)")
$tech.Add("Llamadas antes de 8 s: $($script:EtaDiag.BelowTime)")
$tech.Add("Llamadas con base ETA < 20%: $($script:EtaDiag.BelowPercent)")
$tech.Add("Llamadas elegibles para estimación: $($script:EtaDiag.Eligible)")
$tech.Add("Contador interno de muestras ETA: $($script:EtaDiag.Samples)")
$tech.Add("Muestras ETA almacenadas: $($etaArray.Count)")
$tech.Add(("Último EtaPercent registrado: {0:0.00}" -f $script:EtaLastLoggedBasePercent))
if ($null -eq $script:EtaEstimatedTotalSec) {
    $tech.Add("Estimación total final interna: NO GENERADA")
}
else {
    $tech.Add(("Estimación total final interna: {0:0.000} s" -f $script:EtaEstimatedTotalSec))
$tech.Add("Ponderación global V2.24.23: preanálisis 0-5% | análisis 5-95% | comparación duplicados desactivada | cierre 96-100%")
}
if ($etaArray.Count -gt 0) {
    $sumAbs=0.0; $sumPct=0.0; $validPct=0
    $segEarly=New-Object System.Collections.Generic.List[double]
    $segMid=New-Object System.Collections.Generic.List[double]
    $segLate=New-Object System.Collections.Generic.List[double]
    foreach ($es in $etaArray) {
        $err=[math]::Abs($es.EstimatedTotalSec-$actualTotalSec); $sumAbs+=$err
        if ($actualTotalSec -gt 0) { $sumPct += 100.0*$err/$actualTotalSec; $validPct++ }
        if ($es.EtaPercent -lt 50) {$segEarly.Add($err)} elseif ($es.EtaPercent -lt 80) {$segMid.Add($err)} else {$segLate.Add($err)}
    }
    $tech.Add(("Error absoluto medio del total estimado: {0:0.000} s" -f ($sumAbs/$etaArray.Count)))
    if ($validPct -gt 0) {$tech.Add(("Error porcentual medio sobre tiempo total: {0:0.00}%" -f ($sumPct/$validPct)))}
    foreach ($seg in @([pscustomobject]@{N='20-49%';L=$segEarly},[pscustomobject]@{N='50-79%';L=$segMid},[pscustomobject]@{N='80-99%';L=$segLate})) {
        if ($seg.L.Count -gt 0) {$tech.Add(("Error medio tramo {0}: {1:0.000} s ({2} muestras)" -f $seg.N,(($seg.L|Measure-Object -Average).Average),$seg.L.Count))}
    }
    $tech.Add("")
    $tech.Add("MUESTRAS ETA")
    $tech.Add("Transcurrido | Barra | Base ETA | Restante estimado | Total estimado | Error total | Etapa")
    foreach ($es in $etaArray) {
        $err=[math]::Abs($es.EstimatedTotalSec-$actualTotalSec)
        $tech.Add(("{0,8:0.0} s | {1,3}% | {2,6:0.0}% | {3,8:0.0} s | {4,8:0.0} s | {5,7:0.0} s | {6}" -f $es.ElapsedSec,$es.VisiblePercent,$es.EtaPercent,$es.RemainingSec,$es.EstimatedTotalSec,$err,$es.Stage))
    }
} else {
    $tech.Add("No se almacenaron muestras ETA válidas. Revisar contadores internos anteriores.")
}
$tech.Add("")

$tech.Add("========================================")
$tech.Add("ERRORES / INCIDENCIAS")
$tech.Add("========================================")
if ($conversionErrors.Count -eq 0 -and $backupErrors.Count -eq 0 -and $Optimization.DepthErrors -eq 0) {
    $tech.Add("Sin errores registrados en conversión ni profundidad efectiva.")
} else {
    foreach ($e in $conversionErrors) { $tech.Add("CONVERSIÓN: $e") }
    foreach ($ii in @($infos | Where-Object {$null -ne $_.EffectiveDepth -and -not $_.EffectiveDepth.Valid})) { $tech.Add("PROFUNDIDAD: $($ii.RelativePath) -> $($ii.EffectiveDepth.Error)") }
}
$tech.Add("")
$tech.Add("FIN DEL INFORME TÉCNICO")

try {
    [System.IO.File]::WriteAllLines($TechnicalReportPath, $tech, $utf8Bom)
    Register-PreparedReportHashes -Transaction $reportTransaction
}
catch {
    $reportBuildError = $_.Exception.Message
    $reportRecoveryError = $null
    try { $reportRecoveryPath = Save-ReportRecovery -Transaction $reportTransaction -Reason $reportBuildError } catch { $reportRecoveryError = $_.Exception.Message }
    Close-ReportTransaction -Transaction $reportTransaction -RemoveLock ($null -ne $reportRecoveryPath)
    $retainedTxtPath = @(Get-RetainedReportTxtLocations $reportTransaction $reportRecoveryPath) -join '; '
    Write-DiagnosticError ("No se pudo preparar el informe técnico: " + $reportBuildError + ". Ubicaciones de TXT: " + $retainedTxtPath + $(if ($reportRecoveryError) { ". Falló la copia a recuperación: $reportRecoveryError" } else { '' }))
    throw
}

# Los PDF se generan automáticamente al final del análisis. Si falla el
# generador, los TXT originales se conservan para evitar perder resultados.
$pdfGenerador = Join-Path $ScriptDir 'GenerarInformesPDF.ps1'
$pdfError = $null
if (-not (Test-Path -LiteralPath $pdfGenerador -PathType Leaf)) {
    $pdfError = "Falta GenerarInformesPDF.ps1 en la carpeta del programa."
}
else {
    try {
        $pdfSalida = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $pdfGenerador -Basico $BasicReportPath -Detallado $DetailedReportPath -ConservarTxt 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            $pdfError = "El generador PDF devolvió código $LASTEXITCODE. $pdfSalida"
        }
    }
    catch {
        $pdfError = $_.Exception.Message
    }
}

if ($null -eq $pdfError) {
    try {
        Publish-ReportTransaction -Transaction $reportTransaction | Out-Null
        try { Complete-ReportTransaction -Transaction $reportTransaction }
        catch {
            # La publicación ya fue validada. Si la limpieza falla, conservar
            # respaldo/manifiesto y dejar registro sin invalidar los resultados.
            Write-DiagnosticError ("Publicación confirmada; quedó limpieza pendiente: " + $_.Exception.Message)
            Close-ReportTransaction -Transaction $reportTransaction -RemoveLock $true
        }
    }
    catch {
        $pdfError = $_.Exception.Message
    }
}

if ($null -ne $pdfError) {
    $reportRecoveryError = $null
    if ($null -ne $reportTransaction) {
        try {
            if (-not $reportTransaction.Recovery -or -not (Test-Path -LiteralPath $reportTransaction.Recovery -PathType Container)) {
                $reportRecoveryPath = Save-ReportRecovery -Transaction $reportTransaction -Reason $pdfError
            }
            else { $reportRecoveryPath = $reportTransaction.Recovery }
            $recoveryAvailable = $reportRecoveryPath -and (Test-Path -LiteralPath $reportRecoveryPath -PathType Container)
            Close-ReportTransaction -Transaction $reportTransaction -RemoveLock ([bool]$recoveryAvailable -and $reportTransaction.Manifest.Phase -ne 'rollback_failed')
        }
        catch {
            $reportRecoveryError = $_.Exception.Message
        }
    }
    $retainedTxtPath = @(Get-RetainedReportTxtLocations $reportTransaction $reportRecoveryPath) -join '; '
    Write-DiagnosticError ("Generación de PDF: " + $pdfError + ". Ubicaciones de TXT: " + $retainedTxtPath + $(if ($reportRecoveryError) { ". No se completó la copia a recuperación: $reportRecoveryError" } else { '' }))
    [System.Windows.Forms.MessageBox]::Show(
        "No se pudieron generar los PDF. Los informes TXT quedaron conservados. Revisá el archivo de diagnóstico del programa.`r`n`r`n$pdfError",
        "Analizador de Multitracks - PDF de prueba") | Out-Null
}

# Los mensajes y la ventana final siguen apuntando a las rutas habituales.
$BasicReportPath = $FinalBasicReportPath
$DetailedReportPath = $FinalDetailedReportPath
$TechnicalReportPath = if ($null -ne $pdfError -and $reportRecoveryPath) {
    Join-Path $reportRecoveryPath 'INFORME_TECNICO_DESARROLLO.txt'
} else { $FinalTechnicalReportPath }


Update-ProgressWindow -Percent 100 -EtaPercent 100 -Stage "Proceso terminado" -Item "Análisis completado."
Start-Sleep -Milliseconds 450
Close-ProgressWindow

Write-Host ""
Write-Host "========================================"
Write-Host "PROCESO TERMINADO"
Write-Host "========================================"
Write-Host ""
Write-Host "Total WAV: $($infos.Count)"
Write-Host "Mono originales: $countMono"
Write-Host "Stereo reales: $countStereo"
Write-Host "Conversiones previstas: $plannedConversionCount"
Write-Host "Conversiones completadas: $($completedConversionResults.Count)"
Write-Host "Conversiones fallidas: $($failedConversionResults.Count)"
Write-Host "Para revisar: $countReview"
Write-Host ""
Write-Host "Informe técnico:"
Write-Host $TechnicalReportPath

$resultFolder = if ($needsProcessedFolder) { $OutputDir } else { $SourceDir }

# Ventana final Dark Minimal; la lógica de análisis y los informes permanecen independientes.
function Get-UiFont {
    try {
        $installed = New-Object System.Drawing.Text.InstalledFontCollection
        $names = @($installed.Families | ForEach-Object { $_.Name })
        if ($names -contains 'Segoe UI Variable Text') { return 'Segoe UI Variable Text' }
        if ($names -contains 'Segoe UI Variable') { return 'Segoe UI Variable' }
    } catch {}
    return 'Segoe UI'
}
function Set-DarkTitleBar([System.Windows.Forms.Form]$Form) {
    try {
        if (-not ('DarkTitleBarNative' -as [type])) {
            Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class DarkTitleBarNative {
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
}
"@
        }
        $enabled = 1
        [DarkTitleBarNative]::DwmSetWindowAttribute($Form.Handle,20,[ref]$enabled,4) | Out-Null
        [DarkTitleBarNative]::DwmSetWindowAttribute($Form.Handle,19,[ref]$enabled,4) | Out-Null
    } catch {}
}
$uiFont = Get-UiFont
$uiBg = [System.Drawing.Color]::FromArgb(24,24,24)
$uiSurface = [System.Drawing.Color]::FromArgb(38,38,38)
$uiBorder = [System.Drawing.Color]::FromArgb(58,58,58)
$uiText = [System.Drawing.Color]::FromArgb(240,240,240)
$uiMuted = [System.Drawing.Color]::FromArgb(164,164,164)
$uiAccent = [System.Drawing.Color]::FromArgb(72,164,255)
$uiWarning = [System.Drawing.Color]::FromArgb(224,157,72)

$finalForm = New-Object System.Windows.Forms.Form
$finalForm.Text = 'Analizador de Multitracks Estudio PG V2.24.23'
$finalForm.StartPosition = 'CenterScreen'
$finalForm.Size = New-Object System.Drawing.Size(700,490)
$finalForm.FormBorderStyle = 'FixedSingle'
$finalForm.MaximizeBox = $false
$finalForm.TopMost = $true
$finalForm.ShowInTaskbar = $true
$finalForm.BackColor = $uiBg
$finalForm.Font = New-Object System.Drawing.Font($uiFont,9)

$finalMarker = New-Object System.Windows.Forms.Panel
$finalMarker.Location = New-Object System.Drawing.Point(28,28)
$finalMarker.Size = New-Object System.Drawing.Size(4,54)
$finalMarker.BackColor = if ($null -ne $pdfError -or $conversionErrors.Count -gt 0) { $uiWarning } else { $uiAccent }
$finalForm.Controls.Add($finalMarker)

$finalTitle = New-Object System.Windows.Forms.Label
$finalTitle.Location = New-Object System.Drawing.Point(46,23)
$finalTitle.Size = New-Object System.Drawing.Size(610,35)
$finalTitle.Font = New-Object System.Drawing.Font($uiFont,18,[System.Drawing.FontStyle]::Bold)
$finalTitle.ForeColor = $uiText
$finalTitle.Text = if ($null -ne $pdfError -or $conversionErrors.Count -gt 0) { 'Análisis con observaciones' } else { 'Análisis finalizado' }
$finalForm.Controls.Add($finalTitle)

$finalSubtitle = New-Object System.Windows.Forms.Label
$finalSubtitle.Location = New-Object System.Drawing.Point(48,62)
$finalSubtitle.Size = New-Object System.Drawing.Size(605,25)
$finalSubtitle.Font = New-Object System.Drawing.Font($uiFont,9.5)
$finalSubtitle.ForeColor = $uiMuted
$finalSubtitle.Text = 'Analizador de Multitracks · Estudio PG'
$finalForm.Controls.Add($finalSubtitle)

$finalRule = New-Object System.Windows.Forms.Panel
$finalRule.Location = New-Object System.Drawing.Point(28,111)
$finalRule.Size = New-Object System.Drawing.Size(630,1)
$finalRule.BackColor = $uiBorder
$finalForm.Controls.Add($finalRule)

$metrics = @(
    [pscustomobject]@{ Value = [string]$infos.Count; Label = 'WAV analizados' },
    [pscustomobject]@{ Value = [string]$completedConversionResults.Count; Label = 'Conversiones completadas' },
    [pscustomobject]@{ Value = [string]$countReview; Label = 'Para revisar' }
)
for ($j=0; $j -lt 3; $j++) {
    $xx=28 + $j*210
    $metricValue=New-Object System.Windows.Forms.Label
    $metricValue.Location=New-Object System.Drawing.Point($xx,134)
    $metricValue.Size=New-Object System.Drawing.Size(188,39)
    $metricValue.Text=$metrics[$j].Value
    $metricValue.Font=New-Object System.Drawing.Font($uiFont,20,[System.Drawing.FontStyle]::Bold)
    $metricValue.ForeColor=$uiText
    $finalForm.Controls.Add($metricValue)
    $metricName=New-Object System.Windows.Forms.Label
    $metricName.Location=New-Object System.Drawing.Point($xx,175)
    $metricName.Size=New-Object System.Drawing.Size(188,25)
    $metricName.Text=$metrics[$j].Label
    $metricName.Font=New-Object System.Drawing.Font($uiFont,9)
    $metricName.ForeColor=$uiMuted
    $finalForm.Controls.Add($metricName)
}

$finalRule2=New-Object System.Windows.Forms.Panel
$finalRule2.Location=New-Object System.Drawing.Point(28,222)
$finalRule2.Size=New-Object System.Drawing.Size(630,1)
$finalRule2.BackColor=$uiBorder
$finalForm.Controls.Add($finalRule2)

$reportTitle=New-Object System.Windows.Forms.Label
$reportTitle.Location=New-Object System.Drawing.Point(28,241)
$reportTitle.Size=New-Object System.Drawing.Size(630,20)
$reportTitle.Font=New-Object System.Drawing.Font($uiFont,8.5)
$reportTitle.ForeColor=$uiMuted
$reportTitle.Text='INFORMES'
$finalForm.Controls.Add($reportTitle)
$reportStatus=New-Object System.Windows.Forms.Label
$reportStatus.Location=New-Object System.Drawing.Point(28,264)
$reportStatus.Size=New-Object System.Drawing.Size(630,43)
$reportStatus.Font=New-Object System.Drawing.Font($uiFont,10,[System.Drawing.FontStyle]::Bold)
$reportStatus.ForeColor=if ($null -eq $pdfError) { $uiText } else { $uiWarning }
$reportStatus.Text=if ($null -eq $pdfError) { 'Informe básico y detallado en PDF' } else { 'No se pudieron crear los PDF. Se conservaron los TXT.' }
$finalForm.Controls.Add($reportStatus)

$pathTitle=New-Object System.Windows.Forms.Label
$pathTitle.Location=New-Object System.Drawing.Point(28,318)
$pathTitle.Size=New-Object System.Drawing.Size(630,20)
$pathTitle.Font=New-Object System.Drawing.Font($uiFont,8.5)
$pathTitle.ForeColor=$uiMuted
$pathTitle.Text='CARPETA DE RESULTADOS'
$finalForm.Controls.Add($pathTitle)
$pathValue=New-Object System.Windows.Forms.Label
$pathValue.Location=New-Object System.Drawing.Point(28,342)
$pathValue.Size=New-Object System.Drawing.Size(630,44)
$pathValue.Font=New-Object System.Drawing.Font($uiFont,9)
$pathValue.ForeColor=$uiText
$pathValue.Text=$resultFolder
$pathValue.AutoEllipsis=$true
$finalForm.Controls.Add($pathValue)

$countdownLabel=New-Object System.Windows.Forms.Label
$countdownLabel.Location=New-Object System.Drawing.Point(28,410)
$countdownLabel.Size=New-Object System.Drawing.Size(350,24)
$countdownLabel.Font=New-Object System.Drawing.Font($uiFont,8.5)
$countdownLabel.ForeColor=$uiMuted
$finalForm.Controls.Add($countdownLabel)

function New-DarkButton([string]$Caption,[int]$X,[int]$Width,[bool]$Primary) {
    $button=New-Object System.Windows.Forms.Button
    $button.Text=$Caption
    $button.Location=New-Object System.Drawing.Point($X,400)
    $button.Size=New-Object System.Drawing.Size($Width,38)
    $button.FlatStyle=[System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize=1
    $button.FlatAppearance.BorderColor=if($Primary){$uiAccent}else{$uiBorder}
    $button.BackColor=if($Primary){$uiAccent}else{$uiSurface}
    $button.ForeColor=$uiText
    $button.Font=New-Object System.Drawing.Font($uiFont,9.5)
    $button.Cursor=[System.Windows.Forms.Cursors]::Hand
    return $button
}
$openButton=New-DarkButton 'Abrir carpeta' 405 120 $false
$openButton.Add_Click({
    try { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $resultFolder) } catch {}
    $finalForm.Close()
})
$finalForm.Controls.Add($openButton)
$closeButton=New-DarkButton 'Cerrar' 538 110 $true
$closeButton.Add_Click({$finalForm.Close()})
$finalForm.Controls.Add($closeButton)
$finalForm.AcceptButton=$closeButton

$script:FinalSecondsRemaining=60
$countdownLabel.Text="Cierre automático en 60 s"
$finalTimer=New-Object System.Windows.Forms.Timer
$finalTimer.Interval=1000
$finalTimer.Add_Tick({
    $script:FinalSecondsRemaining--
    if($script:FinalSecondsRemaining -le 0){$finalTimer.Stop();$finalForm.Close()}
    else{$countdownLabel.Text="Cierre automático en $($script:FinalSecondsRemaining) s"}
})
$finalForm.Add_Shown({
    Set-DarkTitleBar $finalForm
    $finalForm.TopMost=$true
    $finalForm.BringToFront()
    $finalForm.Activate()
    $closeButton.Focus()
    $finalTimer.Start()
})
$finalForm.Add_FormClosed({
    try{$finalTimer.Stop();$finalTimer.Dispose()}catch{}
})
[void]$finalForm.ShowDialog()
exit 0
