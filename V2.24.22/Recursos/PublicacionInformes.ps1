# Publicación transaccional de informes. No realiza operaciones sobre audio.

$script:ReportNames = @(
    'INFORME_ANALISIS_BASICO.txt',
    'INFORME_ANALISIS_DETALLADO.txt',
    'INFORME_TECNICO_DESARROLLO.txt',
    'Informe de análisis básico.pdf',
    'Informe de análisis detallado.pdf'
)
$script:ReportPublishNames = @(
    'INFORME_TECNICO_DESARROLLO.txt',
    'Informe de análisis básico.pdf',
    'Informe de análisis detallado.pdf'
)

function Get-ReportHash {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction Stop)) { return $null }
    $stream = $null
    $sha256 = $null
    try {
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $hashBytes = $sha256.ComputeHash($stream)
        return ([System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant())
    }
    finally {
        try { if ($null -ne $stream) { $stream.Dispose() } }
        finally { if ($null -ne $sha256) { $sha256.Dispose() } }
    }
}

function Write-ReportManifest {
    param([Parameter(Mandatory=$true)]$Transaction)
    $path = Join-Path $Transaction.Root 'manifest.json'
    $temp = "$path.tmp"
    $json = $Transaction.Manifest | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($temp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $path -Force -ErrorAction Stop
}

function ConvertTo-ReportHashtable {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) { $result[$property.Name] = ConvertTo-ReportHashtable $property.Value }
        return $result
    }
    if ($Value -is [System.Array]) {
        $items = @()
        foreach ($item in $Value) { $items += ,(ConvertTo-ReportHashtable $item) }
        return ,$items
    }
    return $Value
}

function Invoke-ReportMove {
    param([string]$Source, [string]$Destination)
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }
    Move-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop
}

function Test-GeneratedPdf {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "No existe el PDF: $Path" }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 1000) { throw "El PDF tiene menos de 1000 bytes: $Path" }
    $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
    if (-not $ascii.StartsWith('%PDF-1.4')) { throw "Cabecera PDF inválida: $Path" }
    if (-not $ascii.TrimEnd().EndsWith('%%EOF')) { throw "Falta %%EOF al final del PDF: $Path" }

    $sx = [regex]::Match($ascii, 'startxref\s+(\d+)\s+%%EOF\s*$')
    if (-not $sx.Success) { throw "No se encontró startxref inmediatamente antes de %%EOF: $Path" }
    $xrefOffset = 0L
    if (-not [long]::TryParse($sx.Groups[1].Value, [ref]$xrefOffset) -or $xrefOffset -lt 0 -or $xrefOffset -ge $bytes.Length) {
        throw "Offset startxref inválido: $Path"
    }
    $xrefTail = [System.Text.Encoding]::ASCII.GetString($bytes, [int]$xrefOffset, [math]::Min(16, $bytes.Length - [int]$xrefOffset))
    if (-not $xrefTail.StartsWith('xref')) { throw "startxref no apunta a una tabla xref: $Path" }

    $xrefMatch = [regex]::Match($ascii.Substring([int]$xrefOffset), '^xref\s+0\s+(\d+)\s*\r?\n')
    if (-not $xrefMatch.Success) { throw "Tabla xref con formato inesperado: $Path" }
    $objectCount = 0
    if (-not [int]::TryParse($xrefMatch.Groups[1].Value, [ref]$objectCount) -or $objectCount -lt 2) {
        throw "Conteo de objetos xref inválido: $Path"
    }
    $sectionStart = [int]$xrefOffset + $xrefMatch.Length
    $entryPattern = '(?m)^\d{10} \d{5} n\s*$'
    $entries = [regex]::Matches($ascii.Substring($sectionStart), $entryPattern)
    if ($entries.Count -lt ($objectCount - 1)) { throw "La tabla xref no contiene todas las entradas activas: $Path" }

    $trailer = [regex]::Match($ascii.Substring([int]$xrefOffset), '(?s)^xref.*?trailer\s*<<(?<dict>.*?)>>')
    if (-not $trailer.Success) { throw "No se encontró trailer PDF: $Path" }
    $sizeMatch = [regex]::Match($trailer.Groups['dict'].Value, '/Size\s+(\d+)')
    $rootMatch = [regex]::Match($trailer.Groups['dict'].Value, '/Root\s+(\d+)\s+0\s+R')
    if (-not $sizeMatch.Success -or [int]$sizeMatch.Groups[1].Value -ne $objectCount -or -not $rootMatch.Success) {
        throw "Size o Root del trailer no coincide con xref: $Path"
    }
    $rootId = [int]$rootMatch.Groups[1].Value
    if ($rootId -le 0 -or $rootId -ge $objectCount -or
        $ascii -notmatch ("(?s)(?<!\d)" + $rootId + ' 0 obj\s*<<\s*/Type /Catalog')) {
        throw "El objeto Root no es un catálogo localizado: $Path"
    }

    $activeEntries = [regex]::Matches($ascii.Substring($sectionStart), '(?m)^(\d{10}) \d{5} n\s*$')
    for ($i = 0; $i -lt $activeEntries.Count -and $i -lt ($objectCount - 1); $i++) {
        $offset = [int]$activeEntries[$i].Groups[1].Value
        if ($offset -lt 0 -or $offset -ge $bytes.Length -or
            $ascii.Substring($offset) -notmatch ("^" + ($i + 1) + ' 0 obj\b')) {
            throw "Un offset xref no apunta al objeto esperado: $Path"
        }
    }
    return $true
}

function New-ReportTransaction {
    param([Parameter(Mandatory=$true)][string]$TargetDirectory)
    if (-not (Test-Path -LiteralPath $TargetDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $TargetDirectory -Force -ErrorAction Stop | Out-Null
    }
    $target = [System.IO.Path]::GetFullPath($TargetDirectory)
    $lockPath = Join-Path $target '.AnalizadorMultitracks.publicacion.lock'
    $lock = $null
    try {
        $lock = New-Object System.IO.FileStream($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $runId = [guid]::NewGuid().ToString('N')
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $root = Join-Path $target ('.AnalizadorMultitracks_txn_' + $stamp + '_' + $runId)
        New-Item -ItemType Directory -Path $root -ErrorAction Stop | Out-Null
        $stage = Join-Path $root 'preparacion'
        $backup = Join-Path $root 'respaldo'
        New-Item -ItemType Directory -Path $stage,$backup -ErrorAction Stop | Out-Null
        $originals = [ordered]@{}
        foreach ($name in $script:ReportNames) {
            $final = Join-Path $target $name
            $hash = Get-ReportHash $final
            $originals[$name] = [ordered]@{ Exists=($null -ne $hash); Hash=$hash; BackedUp=$false; Published=$false }
        }
        $tx = [pscustomobject]@{
            Target=$target; Root=$root; Stage=$stage; Backup=$backup; Recovery=$null; LockPath=$lockPath; Lock=$lock
            Manifest=[ordered]@{ Schema=1; Id=$runId; Created=(Get-Date).ToString('o'); Target=$target; Phase='preparing'; Originals=$originals; Prepared=[ordered]@{} }
        }
        Write-ReportManifest $tx
        return $tx
    }
    catch {
        if ($null -ne $lock) { $lock.Dispose() }
        # Si el archivo de bloqueo se creó pero no se pudo establecer una transacción verificable, se conserva para inspección.
        throw
    }
}

function Save-ReportRecovery {
    param([Parameter(Mandatory=$true)]$Transaction, [string]$Reason)
    if ($Transaction.Recovery -and $Transaction.Manifest.RecoveryVerified -and (Test-Path -LiteralPath $Transaction.Recovery -PathType Container)) {
        $existingIsVerified = $true
        foreach ($name in @('INFORME_ANALISIS_BASICO.txt','INFORME_ANALISIS_DETALLADO.txt','INFORME_TECNICO_DESARROLLO.txt')) {
            $expected = $Transaction.Manifest.RecoveryHashes[$name]
            try {
                if (-not $expected -or (Get-ReportHash (Join-Path $Transaction.Recovery $name)) -ne $expected) { $existingIsVerified = $false }
            }
            catch { $existingIsVerified = $false }
        }
        if ($existingIsVerified) { return $Transaction.Recovery }
    }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $recoveryBaseName = "RECUPERACION_ANALISIS_{0}_{1}" -f $stamp,$Transaction.Manifest.Id
    $dest = Join-Path $Transaction.Target $recoveryBaseName
    $suffix = 0
    while (Test-Path -LiteralPath $dest) {
        $suffix++
        $dest = Join-Path $Transaction.Target ("{0}_{1}" -f $recoveryBaseName,$suffix)
    }

    $names = @('INFORME_ANALISIS_BASICO.txt','INFORME_ANALISIS_DETALLADO.txt','INFORME_TECNICO_DESARROLLO.txt')
    $sources = [ordered]@{}
    $results = [ordered]@{}
    foreach ($name in $names) {
        $src = Join-Path $Transaction.Stage $name
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
            $partial = Join-Path $Transaction.Root ('publicado_parcial_' + $name)
            if (Test-Path -LiteralPath $partial -PathType Leaf) { $src = $partial }
        }
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            $sources[$name] = $src
            $results[$name] = [ordered]@{ Source=$src; Destination=(Join-Path $dest $name); Status='pending'; SourceHash=$null; DestinationHash=$null; Error=$null }
        }
        else {
            $sources[$name] = $null
            $results[$name] = [ordered]@{ Source=$src; Destination=(Join-Path $dest $name); Status='missing'; SourceHash=$null; DestinationHash=$null; Error="No se encontró en preparación ni publicación parcial: $src ; $partial" }
        }
    }
    New-Item -ItemType Directory -Path $dest -ErrorAction Stop | Out-Null
    if ($null -eq $Transaction.Manifest.Prepared) { $Transaction.Manifest.Prepared = [ordered]@{} }
    $recoveryHashes = [ordered]@{}
    $Transaction.Manifest.Recovery = $dest
    $Transaction.Manifest.RecoveryVerified = $false
    $Transaction.Manifest.RecoveryHashes = $recoveryHashes
    $Transaction.Manifest.RecoveryResults = $results
    $Transaction.Manifest.Error = $Reason
    if ($Transaction.Manifest.Phase -ne 'rollback_failed') { $Transaction.Manifest.Phase = 'recovery' }
    Write-ReportManifest $Transaction

    foreach ($name in $names) {
        $src = $sources[$name]
        $result = $results[$name]
        if (-not $src) { continue }
        $expectedHash = $Transaction.Manifest.Prepared[$name]
        $sourceHash = $null
        $sourceHashError = $null
        try { $sourceHash = Get-ReportHash $src }
        catch { $sourceHashError = $_.Exception.Message }
        $result.SourceHash = $sourceHash
        if (-not $expectedHash -and $sourceHash) {
            $expectedHash = $sourceHash
            $Transaction.Manifest.Prepared[$name] = $sourceHash
        }
        elseif ($expectedHash -and $sourceHash -and $sourceHash -ne $expectedHash) {
            $result.Error = "El hash de la fuente no coincide con el registrado."
        }

        try {
            Copy-Item -LiteralPath $src -Destination $result.Destination -ErrorAction Stop
        }
        catch {
            $result.Status = 'copy_failed'
            $copyErrors = @()
            if ($result.Error) { $copyErrors += $result.Error }
            $copyErrors += $_.Exception.Message
            $result.Error = $copyErrors -join ' '
            Write-ReportManifest $Transaction
            continue
        }

        $destinationHash = $null
        $destinationHashError = $null
        try { $destinationHash = Get-ReportHash $result.Destination }
        catch { $destinationHashError = $_.Exception.Message }
        $result.DestinationHash = $destinationHash
        $hashesMatch = $false
        if ($destinationHash) {
            if ($expectedHash) {
                $hashesMatch = ($destinationHash -eq $expectedHash) -and ($null -eq $sourceHash -or $sourceHash -eq $expectedHash)
            }
            elseif ($sourceHash) { $hashesMatch = ($destinationHash -eq $sourceHash) }
        }
        if ($hashesMatch) {
            $result.Status = 'verified'
            $result.Error = $null
            $recoveryHashes[$name] = $destinationHash
        }
        else {
            $result.Status = 'copied_unverified'
            $details = @()
            if ($result.Error) { $details += $result.Error }
            if ($sourceHashError) { $details += "No se pudo calcular el hash de origen: $sourceHashError" }
            if ($destinationHashError) { $details += "No se pudo calcular el hash de recuperación: $destinationHashError" }
            if (-not $destinationHash -and -not $destinationHashError) { $details += 'El archivo copiado no tiene un hash verificable.' }
            if ($destinationHash -and $expectedHash -and $destinationHash -ne $expectedHash) { $details += 'El hash copiado no coincide con el registrado.' }
            if ($destinationHash -and -not $expectedHash -and -not $sourceHash) { $details += 'No hay hash registrado ni hash de origen verificable para comparar.' }
            $result.Error = $details -join ' '
        }
        Write-ReportManifest $Transaction
    }

    $stageHashes = [ordered]@{}
    foreach ($name in $script:ReportNames) {
        $stagePath = Join-Path $Transaction.Stage $name
        if (Test-Path -LiteralPath $stagePath -PathType Leaf) {
            try { $stageHashes[$name] = Get-ReportHash $stagePath } catch { }
        }
    }
    $Transaction.Manifest.StageHashes = $stageHashes
    $Transaction.Manifest.RecoveryVerified = ($results.Count -eq $names.Count -and @($names | Where-Object { $results[$_].Status -ne 'verified' }).Count -eq 0)
    Write-ReportManifest $Transaction
    $Transaction.Recovery = $dest
    try { Copy-Item -LiteralPath (Join-Path $Transaction.Root 'manifest.json') -Destination (Join-Path $dest 'manifest.json') -Force -ErrorAction Stop }
    catch {
        $Transaction.Manifest.RecoveryVerified = $false
        $Transaction.Manifest.RecoveryManifestError = $_.Exception.Message
        Write-ReportManifest $Transaction
    }
    return $dest
}

function Register-PreparedReportHashes {
    param([Parameter(Mandatory=$true)]$Transaction)
    foreach ($name in @('INFORME_ANALISIS_BASICO.txt','INFORME_ANALISIS_DETALLADO.txt','INFORME_TECNICO_DESARROLLO.txt')) {
        $path = Join-Path $Transaction.Stage $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Falta el TXT preparado: $path" }
        $Transaction.Manifest.Prepared[$name] = Get-ReportHash $path
    }
    Write-ReportManifest $Transaction
}

function Assert-ResolvedReportState {
    param([Parameter(Mandatory=$true)]$Transaction)
    foreach ($name in $script:ReportNames) {
        $final = Join-Path $Transaction.Target $name
        $backup = Join-Path $Transaction.Backup $name
        $stage = Join-Path $Transaction.Stage $name
        $original = $Transaction.Manifest.Originals[$name]
        $finalHash = Get-ReportHash $final
        if ($original.Exists) {
            if ($finalHash -ne $original.Hash) { throw "Estado final distinto del original; se conserva todo: $name" }
        } elseif ($null -ne $finalHash) { throw "Apareció un informe final no registrado; se conserva todo: $name" }

        $backupHash = Get-ReportHash $backup
        if ($null -ne $backupHash -and (-not $original.Exists -or $backupHash -ne $original.Hash)) {
            throw "Respaldo ambiguo; se conserva todo: $backup"
        }
        $stageHash = Get-ReportHash $stage
        if ($null -ne $stageHash) {
            $expectedStageHash = $null
            if ($null -ne $Transaction.Manifest.StageHashes) { $expectedStageHash = $Transaction.Manifest.StageHashes[$name] }
            if (-not $expectedStageHash) { $expectedStageHash = $Transaction.Manifest.Prepared[$name] }
            if (-not $expectedStageHash -or $stageHash -ne $expectedStageHash) { throw "Preparación ambigua; se conserva todo: $stage" }
        }
        $partial = Join-Path $Transaction.Root ('publicado_parcial_' + $name)
        $partialHash = Get-ReportHash $partial
        if ($null -ne $partialHash -and $partialHash -ne $Transaction.Manifest.Prepared[$name]) {
            throw "Publicación parcial ambigua; se conserva todo: $partial"
        }
    }

    $recoveryPath = $Transaction.Manifest.Recovery
    if ($recoveryPath) {
        if (-not (Test-Path -LiteralPath $recoveryPath -PathType Container)) { throw "No se encuentra la carpeta de recuperación; se conserva todo: $recoveryPath" }
        foreach ($name in @('INFORME_ANALISIS_BASICO.txt','INFORME_ANALISIS_DETALLADO.txt','INFORME_TECNICO_DESARROLLO.txt')) {
            $path = Join-Path $recoveryPath $name
            $expected = $null
            if ($null -ne $Transaction.Manifest.RecoveryHashes) { $expected = $Transaction.Manifest.RecoveryHashes[$name] }
            if (-not $expected -or (Get-ReportHash $path) -ne $expected) { throw "TXT de recuperación ambiguo; se conserva todo: $path" }
        }
    }
}

function Restore-ReportTransaction {
    param([Parameter(Mandatory=$true)]$Transaction)
    $items = @()
    foreach ($name in $script:ReportNames) {
        $final = Join-Path $Transaction.Target $name
        $backup = Join-Path $Transaction.Backup $name
        $original = $Transaction.Manifest.Originals[$name]
        $currentHash = Get-ReportHash $final
        $backupHash = Get-ReportHash $backup
        $newHash = $Transaction.Manifest.Prepared[$name]
        if ($original.Exists) {
            if ($currentHash -eq $original.Hash) { $action='none' }
            elseif ($backupHash -eq $original.Hash -and ($null -eq $currentHash -or $currentHash -eq $newHash)) { $action='restore' }
            else { throw "Estado ambiguo; se conserva todo: $name" }
        }
        else {
            if ($null -eq $currentHash) { $action='none' }
            elseif ($null -ne $newHash -and $currentHash -eq $newHash) { $action='remove-new' }
            else { throw "Estado ambiguo; se conserva todo: $name" }
        }
        $items += [pscustomobject]@{ Name=$name; Final=$final; Backup=$backup; Action=$action }
    }

    # Preflight completo anterior a cualquier mutación.
    foreach ($item in $items) {
        if ($item.Action -eq 'restore' -and (Test-Path -LiteralPath $item.Final)) {
            $preparedPath = Join-Path $Transaction.Stage $item.Name
            if (-not (Test-Path -LiteralPath $preparedPath)) { $preparedPath = Join-Path $Transaction.Root ('publicado_parcial_' + $item.Name) }
            Invoke-ReportMove $item.Final $preparedPath
        }
        if ($item.Action -eq 'restore') { Invoke-ReportMove $item.Backup $item.Final }
        elseif ($item.Action -eq 'remove-new') {
            $preparedPath = Join-Path $Transaction.Stage $item.Name
            if (-not (Test-Path -LiteralPath $preparedPath)) { $preparedPath = Join-Path $Transaction.Root ('publicado_parcial_' + $item.Name) }
            Invoke-ReportMove $item.Final $preparedPath
        }
    }
    foreach ($item in $items) {
        $original = $Transaction.Manifest.Originals[$item.Name]
        $hash = Get-ReportHash $item.Final
        if ($original.Exists -and $hash -ne $original.Hash) { throw "No se pudo verificar la restauración: $($item.Name)" }
        if (-not $original.Exists -and $null -ne $hash) { throw "Quedó un archivo parcial tras restaurar: $($item.Name)" }
    }
    $Transaction.Manifest.Phase = 'rolledback'
    Write-ReportManifest $Transaction
}

function Resolve-PendingReportTransactions {
    param([Parameter(Mandatory=$true)][string]$TargetDirectory)
    $target = [System.IO.Path]::GetFullPath($TargetDirectory)
    $lockPath = Join-Path $target '.AnalizadorMultitracks.publicacion.lock'
    $roots = @(Get-ChildItem -LiteralPath $target -Directory -Filter '.AnalizadorMultitracks_txn_*' -ErrorAction SilentlyContinue)
    if ($roots.Count -eq 0) {
        if (Test-Path -LiteralPath $lockPath) { throw "Hay un bloqueo sin transacción verificable; no se modifica: $lockPath" }
        return
    }

    $recoveryLock = $null
    try {
        if (Test-Path -LiteralPath $lockPath) {
            $recoveryLock = New-Object System.IO.FileStream($lockPath,[System.IO.FileMode]::Open,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
        }
        else {
            $recoveryLock = New-Object System.IO.FileStream($lockPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
        }
    }
    catch { throw "No se puede adquirir el bloqueo para recuperación; no se modifica ningún informe: $lockPath" }

    $allResolved = $true
    try {
        foreach ($rootItem in $roots) {
            $manifestPath = Join-Path $rootItem.FullName 'manifest.json'
            if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { $allResolved=$false; throw "Transacción sin manifiesto; requiere revisión manual: $($rootItem.FullName)" }
            try {
                $manifestJson = [System.IO.File]::ReadAllText($manifestPath,[System.Text.Encoding]::UTF8)
                $manifest = ConvertTo-ReportHashtable ($manifestJson | ConvertFrom-Json -ErrorAction Stop)
            }
            catch { $allResolved=$false; throw "Manifiesto ilegible; no se altera: $manifestPath" }
            if ($manifest.Target -ne $target -or $manifest.Schema -ne 1) { $allResolved=$false; throw "Manifiesto no reconocido o destino distinto; no se altera: $manifestPath" }

            $stage = Join-Path $rootItem.FullName 'preparacion'
            $backup = Join-Path $rootItem.FullName 'respaldo'
            $tx = [pscustomobject]@{ Target=$target; Root=$rootItem.FullName; Stage=$stage; Backup=$backup; Recovery=$manifest.Recovery; LockPath=$lockPath; Lock=$null; Manifest=$manifest }
            if ($manifest.Phase -eq 'committed') {
                $complete = $true
                foreach ($name in $script:ReportPublishNames) {
                    if ((Get-ReportHash (Join-Path $target $name)) -ne $manifest.Prepared[$name]) { $complete=$false }
                }
                foreach ($name in @('INFORME_ANALISIS_BASICO.txt','INFORME_ANALISIS_DETALLADO.txt')) {
                    if (Test-Path -LiteralPath (Join-Path $target $name)) { $complete=$false }
                }
                if (-not $complete) { $allResolved=$false; throw "Transacción marcada completa pero las rutas finales no coinciden; se conserva todo: $($rootItem.FullName)" }
                # La publicación ya fue verificada y el manifiesto marca commit; solo queda limpieza confirmada.
                Remove-Item -LiteralPath $rootItem.FullName -Recurse -Force -ErrorAction Stop
            }
            elseif ($manifest.Phase -in @('preparing','backing_up','publishing','rollback_failed')) {
                Restore-ReportTransaction $tx
                $recoveryPath = Save-ReportRecovery $tx 'Recuperación de una ejecución interrumpida.'
                if (-not $manifest.LockWasMissing) { $tx.Manifest.Recovery=$recoveryPath }
                Assert-ResolvedReportState $tx
                # Los respaldos se conservan en una recuperación tras interrupción.
            }
            elseif ($manifest.Phase -in @('recovery','rolledback')) {
                # Revalidar la realidad antes de retirar un bloqueo dejado por una interrupción.
                Assert-ResolvedReportState $tx
                if (-not $manifest.Recovery) {
                    Save-ReportRecovery $tx 'Recuperación de una ejecución interrumpida tras la reversión.' | Out-Null
                    Assert-ResolvedReportState $tx
                }
                continue
            }
            else { $allResolved=$false; throw "Fase desconocida; no se altera: $($manifest.Phase)" }
        }
    }
    catch {
        $recoveryLock.Dispose()
        if (-not $allResolved) { throw }
        throw
    }
    $recoveryLock.Dispose()
    # Solo se retira el bloqueo si todas las transacciones se resolvieron sin ambigüedad.
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction Stop
}

function Publish-ReportTransaction {
    param([Parameter(Mandatory=$true)]$Transaction)
    foreach ($name in $script:ReportNames) {
        $staged = Join-Path $Transaction.Stage $name
        if (-not (Test-Path -LiteralPath $staged -PathType Leaf)) { throw "Falta el informe preparado: $name" }
        $Transaction.Manifest.Prepared[$name] = Get-ReportHash $staged
    }
    Test-GeneratedPdf (Join-Path $Transaction.Stage 'Informe de análisis básico.pdf') | Out-Null
    Test-GeneratedPdf (Join-Path $Transaction.Stage 'Informe de análisis detallado.pdf') | Out-Null
    Write-ReportManifest $Transaction

    try {
        $Transaction.Manifest.Phase = 'backing_up'
        Write-ReportManifest $Transaction
        foreach ($name in $script:ReportNames) {
            $final = Join-Path $Transaction.Target $name
            if ($Transaction.Manifest.Originals[$name].Exists) {
                Invoke-ReportMove $final (Join-Path $Transaction.Backup $name)
                if ((Get-ReportHash (Join-Path $Transaction.Backup $name)) -ne $Transaction.Manifest.Originals[$name].Hash) { throw "Respaldo no coincide: $name" }
                $Transaction.Manifest.Originals[$name].BackedUp = $true
                Write-ReportManifest $Transaction
            }
        }
        $Transaction.Manifest.Phase = 'publishing'
        Write-ReportManifest $Transaction
        foreach ($name in $script:ReportPublishNames) {
            Invoke-ReportMove (Join-Path $Transaction.Stage $name) (Join-Path $Transaction.Target $name)
            $Transaction.Manifest.Originals[$name].Published = $true
            Write-ReportManifest $Transaction
        }

        foreach ($name in $script:ReportPublishNames) {
            if ((Get-ReportHash (Join-Path $Transaction.Target $name)) -ne $Transaction.Manifest.Prepared[$name]) { throw "Verificación final falló: $name" }
        }
        foreach ($name in @('INFORME_ANALISIS_BASICO.txt','INFORME_ANALISIS_DETALLADO.txt')) {
            if (Test-Path -LiteralPath (Join-Path $Transaction.Target $name)) { throw "TXT de usuario inesperado en salida final: $name" }
        }
        Test-GeneratedPdf (Join-Path $Transaction.Target 'Informe de análisis básico.pdf') | Out-Null
        Test-GeneratedPdf (Join-Path $Transaction.Target 'Informe de análisis detallado.pdf') | Out-Null

        $Transaction.Manifest.Phase = 'committed'
        $Transaction.Manifest.Committed = (Get-Date).ToString('o')
        Write-ReportManifest $Transaction
        return $true
    }
    catch {
        $publishError = $_.Exception.Message
        $rollbackError = $null
        try {
            Restore-ReportTransaction $Transaction
        }
        catch {
            $rollbackError = $_.Exception.Message
        }
        if ($null -eq $rollbackError) {
            $recovery = $null
            $recoveryError = $null
            try { $recovery = Save-ReportRecovery $Transaction $publishError }
            catch { $recoveryError = $_.Exception.Message }
            if ($recovery) {
                $verification = if ($Transaction.Manifest.RecoveryVerified) { 'TXT recuperados y verificados' } else { 'TXT copiados parcialmente o sin verificación; consultar RecoveryResults en el manifiesto' }
                throw "Publicación revertida; $verification en $recovery. Error original: $publishError$(if ($recoveryError) { '. Error adicional de recuperación: ' + $recoveryError } else { '' })"
            }
            throw "Publicación revertida. Error original: $publishError$(if ($recoveryError) { '. No se completó la preparación de recuperación: ' + $recoveryError } else { '' })"
        }
        else {
            $Transaction.Manifest.Phase = 'rollback_failed'
            $Transaction.Manifest.Error = $publishError
            $Transaction.Manifest.RollbackError = $rollbackError
            try { Write-ReportManifest $Transaction } catch {}
            try { Save-ReportRecovery $Transaction $rollbackError | Out-Null } catch {}
            throw "No se pudo confirmar la reversión. Se conservaron respaldo y transacción para recuperación manual: $($Transaction.Root). $rollbackError"
        }
    }
}

function Complete-ReportTransaction {
    param([Parameter(Mandatory=$true)]$Transaction)
    if ($Transaction.Manifest.Phase -ne 'committed') { throw 'No se pueden limpiar respaldos antes de confirmar la publicación.' }
    foreach ($name in $script:ReportPublishNames) {
        if ((Get-ReportHash (Join-Path $Transaction.Target $name)) -ne $Transaction.Manifest.Prepared[$name]) { throw "El informe final cambió antes de limpiar respaldos: $name" }
    }
    foreach ($name in @('INFORME_ANALISIS_BASICO.txt','INFORME_ANALISIS_DETALLADO.txt')) {
        if (Test-Path -LiteralPath (Join-Path $Transaction.Target $name)) { throw "TXT básico/detallado inesperado antes de limpiar respaldos: $name" }
    }
    Test-GeneratedPdf (Join-Path $Transaction.Target 'Informe de análisis básico.pdf') | Out-Null
    Test-GeneratedPdf (Join-Path $Transaction.Target 'Informe de análisis detallado.pdf') | Out-Null
    foreach ($name in $script:ReportNames) {
        if ($Transaction.Manifest.Originals[$name].Exists) {
            $old = Join-Path $Transaction.Backup $name
            if ((Get-ReportHash $old) -ne $Transaction.Manifest.Originals[$name].Hash) { throw "Respaldo previo no verificable; se conserva: $old" }
        }
    }
    foreach ($name in @('INFORME_ANALISIS_BASICO.txt','INFORME_ANALISIS_DETALLADO.txt')) {
        $staged = Join-Path $Transaction.Stage $name
        if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged -Force -ErrorAction Stop }
    }
    $Transaction.Lock.Dispose()
    $Transaction.Lock = $null
    Remove-Item -LiteralPath $Transaction.LockPath -Force -ErrorAction Stop
    Remove-Item -LiteralPath $Transaction.Root -Recurse -Force -ErrorAction Stop
}

function Close-ReportTransaction {
    param([Parameter(Mandatory=$true)]$Transaction, [bool]$RemoveLock=$true)
    if ($null -ne $Transaction.Lock) { $Transaction.Lock.Dispose(); $Transaction.Lock=$null }
    $resolvedPhase = $Transaction.Manifest.Phase -in @('rolledback','committed')
    $verifiedRecovery = ($Transaction.Manifest.Phase -eq 'recovery' -and $Transaction.Manifest.RecoveryVerified -eq $true)
    if ($RemoveLock -and ($resolvedPhase -or $verifiedRecovery)) {
        Remove-Item -LiteralPath $Transaction.LockPath -Force -ErrorAction SilentlyContinue
    }
}

