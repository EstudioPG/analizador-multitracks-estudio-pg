param(
    [Parameter(Mandatory=$true)][string]$StateFile,
    [Parameter(Mandatory=$true)][string]$ReadyFile
)
$ErrorActionPreference='SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Get-ModernFontFamily {
    try {
        $installed=New-Object System.Drawing.Text.InstalledFontCollection
        $names=@($installed.Families|ForEach-Object{$_.Name})
        if($names -contains 'Segoe UI Variable Text'){return 'Segoe UI Variable Text'}
        if($names -contains 'Segoe UI Variable'){return 'Segoe UI Variable'}
    }catch{}
    return 'Segoe UI'
}


function Apply-DarkTitleBar([System.Windows.Forms.Form]$Form) {
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
        $enabled=1
        [DarkTitleBarNative]::DwmSetWindowAttribute($Form.Handle,20,[ref]$enabled,4)|Out-Null
        [DarkTitleBarNative]::DwmSetWindowAttribute($Form.Handle,19,[ref]$enabled,4)|Out-Null
    }catch{}
}

function Format-Time([double]$Seconds){
    if($Seconds -lt 0){$Seconds=0}
    $ts=[TimeSpan]::FromSeconds($Seconds)
    if($ts.TotalHours -ge 1){return ('{0:00}:{1:00}:{2:00}' -f [int]$ts.TotalHours,$ts.Minutes,$ts.Seconds)}
    return ('{0:00}:{1:00}' -f [int]$ts.TotalMinutes,$ts.Seconds)
}

$fontName=Get-ModernFontFamily
$accent=[System.Drawing.Color]::FromArgb(72,164,255)
$textMain=[System.Drawing.Color]::FromArgb(240,240,240)
$textMuted=[System.Drawing.Color]::FromArgb(164,164,164)
$surface=[System.Drawing.Color]::FromArgb(24,24,24)
$track=[System.Drawing.Color]::FromArgb(58,58,58)

$form=New-Object System.Windows.Forms.Form
$form.Text='Analizador de Multitracks Estudio PG V2.24.23'
$form.StartPosition='CenterScreen'
$form.Size=New-Object System.Drawing.Size(700,330)
$form.FormBorderStyle='FixedSingle'
$form.MaximizeBox=$false
$form.MinimizeBox=$true
$form.ControlBox=$true
$form.ShowInTaskbar=$true
$form.TopMost=$false
$form.BackColor=$surface
$form.Font=New-Object System.Drawing.Font($fontName,9)

$header=New-Object System.Windows.Forms.Panel
$header.Dock='Top'
$header.Height=82
$header.BackColor=[System.Drawing.Color]::FromArgb(24,24,24)
$form.Controls.Add($header)

$app=New-Object System.Windows.Forms.Label
$app.Location=New-Object System.Drawing.Point(24,18)
$app.Size=New-Object System.Drawing.Size(640,22)
$app.Font=New-Object System.Drawing.Font($fontName,9,[System.Drawing.FontStyle]::Bold)
$app.ForeColor=$textMuted
$app.Text='ANALIZADOR DE MULTITRACKS ESTUDIO PG'
$header.Controls.Add($app)

$title=New-Object System.Windows.Forms.Label
$title.Location=New-Object System.Drawing.Point(24,42)
$title.Size=New-Object System.Drawing.Size(640,28)
$title.Font=New-Object System.Drawing.Font($fontName,14,[System.Drawing.FontStyle]::Bold)
$title.ForeColor=$textMain
$title.Text='Preparando...'
$header.Controls.Add($title)

$fileLabel=New-Object System.Windows.Forms.Label
$fileLabel.Location=New-Object System.Drawing.Point(24,102)
$fileLabel.Size=New-Object System.Drawing.Size(640,25)
$fileLabel.Font=New-Object System.Drawing.Font($fontName,10,[System.Drawing.FontStyle]::Bold)
$fileLabel.ForeColor=$textMain
$fileLabel.Text=''
$fileLabel.AutoEllipsis=$true
$form.Controls.Add($fileLabel)

$stage=New-Object System.Windows.Forms.Label
$stage.Location=New-Object System.Drawing.Point(24,130)
$stage.Size=New-Object System.Drawing.Size(640,24)
$stage.Font=New-Object System.Drawing.Font($fontName,9)
$stage.ForeColor=$textMuted
$stage.Text=''
$form.Controls.Add($stage)

$trackPanel=New-Object System.Windows.Forms.Panel
$trackPanel.Location=New-Object System.Drawing.Point(24,170)
$trackPanel.Size=New-Object System.Drawing.Size(590,8)
$trackPanel.BackColor=$track
$form.Controls.Add($trackPanel)

$fillPanel=New-Object System.Windows.Forms.Panel
$fillPanel.Location=New-Object System.Drawing.Point(0,0)
$fillPanel.Size=New-Object System.Drawing.Size(0,8)
$fillPanel.BackColor=$accent
$trackPanel.Controls.Add($fillPanel)

$percent=New-Object System.Windows.Forms.Label
$percent.Location=New-Object System.Drawing.Point(620,160)
$percent.Size=New-Object System.Drawing.Size(50,28)
$percent.TextAlign='MiddleRight'
$percent.Font=New-Object System.Drawing.Font($fontName,9,[System.Drawing.FontStyle]::Bold)
$percent.ForeColor=$textMain
$percent.Text='0%'
$form.Controls.Add($percent)

$sep=New-Object System.Windows.Forms.Panel
$sep.Location=New-Object System.Drawing.Point(24,204)
$sep.Size=New-Object System.Drawing.Size(646,1)
$sep.BackColor=[System.Drawing.Color]::FromArgb(58,58,58)
$form.Controls.Add($sep)

$elapsedTitle=New-Object System.Windows.Forms.Label
$elapsedTitle.Location=New-Object System.Drawing.Point(24,222)
$elapsedTitle.Size=New-Object System.Drawing.Size(160,20)
$elapsedTitle.Font=New-Object System.Drawing.Font($fontName,8.5)
$elapsedTitle.ForeColor=$textMuted
$elapsedTitle.Text='TRANSCURRIDO'
$form.Controls.Add($elapsedTitle)

$elapsedValue=New-Object System.Windows.Forms.Label
$elapsedValue.Location=New-Object System.Drawing.Point(24,244)
$elapsedValue.Size=New-Object System.Drawing.Size(180,30)
$elapsedValue.Font=New-Object System.Drawing.Font($fontName,13,[System.Drawing.FontStyle]::Bold)
$elapsedValue.ForeColor=$textMain
$elapsedValue.Text='00:00'
$form.Controls.Add($elapsedValue)

$etaTitle=New-Object System.Windows.Forms.Label
$etaTitle.Location=New-Object System.Drawing.Point(250,222)
$etaTitle.Size=New-Object System.Drawing.Size(190,20)
$etaTitle.Font=New-Object System.Drawing.Font($fontName,8.5)
$etaTitle.ForeColor=$textMuted
$etaTitle.Text='RESTANTE APROX.'
$form.Controls.Add($etaTitle)

$etaValue=New-Object System.Windows.Forms.Label
$etaValue.Location=New-Object System.Drawing.Point(250,244)
$etaValue.Size=New-Object System.Drawing.Size(190,30)
$etaValue.Font=New-Object System.Drawing.Font($fontName,13,[System.Drawing.FontStyle]::Bold)
$etaValue.ForeColor=$textMain
$etaValue.Text='calculando...'
$form.Controls.Add($etaValue)

$note=New-Object System.Windows.Forms.Label
$note.Location=New-Object System.Drawing.Point(468,228)
$note.Size=New-Object System.Drawing.Size(200,48)
$note.Font=New-Object System.Drawing.Font($fontName,8.3)
$note.ForeColor=$textMuted
$note.Text='La estimación se ajusta durante el análisis.'
$note.TextAlign='MiddleRight'
$form.Controls.Add($note)

$script:LastState=$null
$script:LastStateAt=[DateTime]::UtcNow

$readTimer=New-Object System.Windows.Forms.Timer
$readTimer.Interval=250
$readTimer.Add_Tick({
    if(-not(Test-Path -LiteralPath $StateFile)){return}
    try{
        $raw=[IO.File]::ReadAllText($StateFile)
        if([string]::IsNullOrWhiteSpace($raw)){return}
        $s=$raw|ConvertFrom-Json
        $script:LastState=$s
        $script:LastStateAt=[DateTime]::Parse($s.UpdatedUtc).ToUniversalTime()

        $p=[math]::Max(0,[math]::Min(100,[int]$s.Percent))
        $percent.Text="$p%"
        $fillWidth=[int][math]::Round($trackPanel.ClientSize.Width*($p/100.0))
        $fillPanel.Width=[math]::Max(0,[math]::Min($trackPanel.ClientSize.Width,$fillWidth))

        $title.Text=[string]$s.Stage
        $fileLabel.Text=[string]$s.Item
        $stage.Text=if([string]::IsNullOrWhiteSpace([string]$s.Item)){'ANÁLISIS EN CURSO'}else{'PISTA / OPERACIÓN ACTUAL'}

        if($s.Completed){
            $elapsedValue.Text=Format-Time([double]$s.ElapsedMs/1000.0)
            $etaValue.Text='00:00'
            $note.Text='Proceso completado.'
            $readTimer.Stop()
            $t=New-Object System.Windows.Forms.Timer
            $t.Interval=650
            $t.Add_Tick({$t.Stop();$form.Close()})
            $t.Start()
        }
    }catch{}
})

$clockTimer=New-Object System.Windows.Forms.Timer
$clockTimer.Interval=250
$clockTimer.Add_Tick({
    if($null -eq $script:LastState){return}
    try{
        $delta=([DateTime]::UtcNow-$script:LastStateAt).TotalSeconds
        if($delta -lt 0){$delta=0}
        $elapsed=([double]$script:LastState.ElapsedMs/1000.0)+$delta
        $elapsedValue.Text=Format-Time $elapsed

        if($null -ne $script:LastState.RemainingSec){
            $remaining=[math]::Max(0.0,[double]$script:LastState.RemainingSec-$delta)
            $etaValue.Text='~'+(Format-Time $remaining)
        }else{
            $etaValue.Text='calculando...'
        }
    }catch{}
})

$form.Add_Shown({
    try{[IO.File]::WriteAllText($ReadyFile,'OK',[Text.Encoding]::ASCII)}catch{}
    Apply-DarkTitleBar $form
    $form.Activate()
    $form.BringToFront()
})
$form.Add_FormClosed({
    $readTimer.Stop()
    $clockTimer.Stop()
    Remove-Item -LiteralPath $ReadyFile -Force -ErrorAction SilentlyContinue
})

$readTimer.Start()
$clockTimer.Start()
[void]$form.ShowDialog()
