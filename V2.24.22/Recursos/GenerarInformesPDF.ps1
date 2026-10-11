param(
    [Parameter(Mandatory=$true)][string]$Basico,
    [Parameter(Mandatory=$true)][string]$Detallado,
    [switch]$ConservarTxt
)

$ErrorActionPreference = 'Stop'
$carpeta = Split-Path -Parent $MyInvocation.MyCommand.Path
$fuente = Join-Path $carpeta 'DejaVuSans.ttf'
$negrita = Join-Path $carpeta 'DejaVuSans-Bold.ttf'
$codigo = Join-Path $carpeta 'GeneradorPDF.cs'

foreach ($archivo in @($fuente, $negrita, $codigo, $Basico, $Detallado)) {
    if (-not (Test-Path -LiteralPath $archivo -PathType Leaf)) {
        throw "Falta un componente para crear los PDF: $archivo"
    }
}

# Se compila dentro de Windows PowerShell usando .NET Framework, sin descargar nada.
Add-Type -Path $codigo -ErrorAction Stop
$destino = Split-Path -Parent $Basico
$basicoPdf = Join-Path $destino 'Informe de análisis básico.pdf'
$detalladoPdf = Join-Path $destino 'Informe de análisis detallado.pdf'

# El analizador invoca este generador en una carpeta de preparación nueva. En
# invocaciones independientes se rechazan destinos existentes para evitar
# reemplazar informes finales sin pasar por la publicación transaccional.
foreach ($salida in @($basicoPdf, $detalladoPdf)) {
    if (Test-Path -LiteralPath $salida -PathType Leaf) {
        throw "Ya existe el PDF de destino; no se sobrescribe fuera de la publicación protegida: $salida"
    }
}

[EstudioPG.PdfReport]::Generate($Basico, $basicoPdf, $fuente, $negrita, $true)
[EstudioPG.PdfReport]::Generate($Detallado, $detalladoPdf, $fuente, $negrita, $false)

foreach ($archivo in @($basicoPdf, $detalladoPdf)) {
    if (-not (Test-Path -LiteralPath $archivo -PathType Leaf) -or (Get-Item -LiteralPath $archivo).Length -lt 1000) {
        throw "El PDF no se generó correctamente: $archivo"
    }
}

if (-not $ConservarTxt) {
    # Compatibilidad con la invocación habitual. La publicación protegida conserva
    # los TXT hasta confirmar el conjunto final.
    Remove-Item -LiteralPath $Basico, $Detallado -Force
}
