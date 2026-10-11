param(
    [Parameter(Mandatory=$true)][string]$Basico,
    [Parameter(Mandatory=$true)][string]$Detallado
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

[EstudioPG.PdfReport]::Generate($Basico, $basicoPdf, $fuente, $negrita, $true)
[EstudioPG.PdfReport]::Generate($Detallado, $detalladoPdf, $fuente, $negrita, $false)

foreach ($archivo in @($basicoPdf, $detalladoPdf)) {
    if (-not (Test-Path -LiteralPath $archivo -PathType Leaf) -or (Get-Item -LiteralPath $archivo).Length -lt 1000) {
        throw "El PDF no se generó correctamente: $archivo"
    }
}

# Solo después de verificar ambos PDF, se retiran los TXT de usuario.
# El informe técnico de desarrollo permanece en TXT.
Remove-Item -LiteralPath $Basico, $Detallado -Force
