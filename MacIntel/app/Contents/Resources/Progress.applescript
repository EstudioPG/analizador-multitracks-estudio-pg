use AppleScript version "2.4"
use scripting additions

on formatSeconds(totalSeconds)
    set t to totalSeconds as integer
    if t < 0 then set t to 0
    set h to t div 3600
    set m to (t mod 3600) div 60
    set s to t mod 60

    if h > 0 then
        return (h as text) & " h " & (m as text) & " min " & (s as text) & " s"
    else if m > 0 then
        return (m as text) & " min " & (s as text) & " s"
    else
        return (s as text) & " s"
    end if
end formatSeconds


on truncateText(theText, maxChars)
    set t to theText as text
    if (count characters of t) ≤ maxChars then return t
    if maxChars ≤ 3 then return "..."
    return (text 1 thru (maxChars - 3) of t) & "..."
end truncateText

on run
    set uidText to do shell script "/usr/bin/id -u"
    set statusFile to "/tmp/estudiopg_analizador_" & uidText & ".status"
    set cancelFile to "/tmp/estudiopg_analizador_" & uidText & ".cancel"
    set readyFile to "/tmp/estudiopg_analizador_" & uidText & ".ready"
    set etaFile to "/tmp/estudiopg_analizador_" & uidText & ".eta.tsv"
    set closedFile to "/tmp/estudiopg_analizador_" & uidText & ".closed"

    set progress total steps to 100
    set progress completed steps to 0
    set progress description to "Analizador de Multitracks Estudio PG V2.12.19"
    set progress additional description to "Preparando..." & return & "Estimación: calculando..."

    set startDate to current date
    set elapsedSeconds to 0
    set currentPct to 0
    set currentEtaPct to 0
    set lastPctForEstimate to 0
    set estimatedTotal to missing value
    set currentPhase to "Analizador de Multitracks Estudio PG V2.12.19"
    set currentDetail to "Preparando..."
    set lastLoggedPct to -1

    do shell script "/usr/bin/touch " & quoted form of readyFile

    try
        repeat
            try
                set rawStatus to do shell script "/bin/cat " & quoted form of statusFile

                set oldTID to AppleScript's text item delimiters
                set AppleScript's text item delimiters to tab
                set parts to text items of rawStatus
                set AppleScript's text item delimiters to oldTID

                if (count of parts) ≥ 1 then
                    set firstPart to item 1 of parts

                    if firstPart is "DONE" then
                        set progress completed steps to 100
                        set progress description to "Análisis finalizado"
                        set progress additional description to "Completado."
                        delay 0.15
                        exit repeat

                    else if firstPart is "ERROR" then
                        exit repeat

                    else if firstPart is "CANCEL" then
                        exit repeat

                    else if (count of parts) ≥ 3 then
                        try
                            set newPct to (item 1 of parts) as integer
                            set currentPct to newPct
                            set progress completed steps to currentPct
                        end try
                        set currentPhase to my truncateText(item 2 of parts, 58)
                        set currentDetail to my truncateText(item 3 of parts, 58)
                        set progress description to currentPhase
                        if (count of parts) ≥ 4 then
                            try
                                -- El proceso principal envía milisegundos ENTEROS.
                                set elapsedMilliseconds to (item 4 of parts) as integer
                                set elapsedSeconds to elapsedMilliseconds / 1000.0
                            end try
                        end if
                        if (count of parts) ≥ 5 then
                            try
                                -- V2.12.18: porcentaje específico para el ETA. Puede ser más
                                -- conservador que la barra visible durante el análisis por archivos.
                                set currentEtaPct to (item 5 of parts) as integer
                            on error
                                set currentEtaPct to currentPct
                            end try
                        else
                            set currentEtaPct to currentPct
                        end if
                    end if
                end if

                -- V2.12.18: el tiempo transcurrido llega desde el proceso principal
                -- como milisegundos enteros y se convierte localmente a segundos.
                -- La ventana no depende del separador decimal regional.
                -- V2.12.18: no se publica un ETA demasiado pronto. Las primeras muestras
                -- estaban sistemáticamente sesgadas porque todavía no había suficiente trabajo
                -- terminado para medir el rendimiento real de la carpeta.
                if currentEtaPct ≥ 20 and elapsedSeconds ≥ 8 then
                    if currentEtaPct > lastPctForEstimate then
                        set rawTotal to (elapsedSeconds * 100) / currentEtaPct

                        if estimatedTotal is missing value then
                            set estimatedTotal to rawTotal
                        else
                            -- Corrección asimétrica: si el cálculo nuevo indica que falta más
                            -- tiempo, corregimos rápido; si indica menos, bajamos con suavidad.
                            -- Evita mantener durante mucho tiempo una primera estimación optimista.
                            if rawTotal > estimatedTotal then
                                set estimatedTotal to (estimatedTotal * 0.25) + (rawTotal * 0.75)
                            else
                                set estimatedTotal to (estimatedTotal * 0.75) + (rawTotal * 0.25)
                            end if
                        end if

                        set lastPctForEstimate to currentEtaPct
                    end if

                    if estimatedTotal is not missing value then
                        set remainingSeconds to estimatedTotal - elapsedSeconds
                        if remainingSeconds < 0 then set remainingSeconds to 0
                        set timeText to "Transcurrido: " & my formatSeconds(elapsedSeconds) & "   ·   Restante aprox.: " & my formatSeconds(remainingSeconds)
                    else
                        set timeText to "Transcurrido: " & my formatSeconds(elapsedSeconds) & "   ·   Estimación: calculando..."
                    end if
                else
                    set timeText to "Transcurrido: " & my formatSeconds(elapsedSeconds) & "   ·   Estimación: calculando..."
                end if

                if currentEtaPct ≥ 20 and currentPct is not lastLoggedPct and estimatedTotal is not missing value then
                    try
                        set remainingForLog to estimatedTotal - elapsedSeconds
                        if remainingForLog < 0 then set remainingForLog to 0
                        -- El log usa enteros para que no dependa de coma/punto decimal
                        -- de la configuración regional de macOS.
                        set elapsedForLog to (round elapsedSeconds)
                        set remainingForLogInt to (round remainingForLog)
                        set estimatedTotalForLog to (round estimatedTotal)
                        set safePhase to do shell script "/usr/bin/printf %s " & quoted form of currentPhase & " | /usr/bin/tr '\t\r\n' '   '"
                        set logLine to (elapsedForLog as text) & tab & (currentPct as text) & tab & (remainingForLogInt as text) & tab & (estimatedTotalForLog as text) & tab & safePhase & tab & (currentEtaPct as text)
                        do shell script "/usr/bin/printf '%s\n' " & quoted form of logLine & " >> " & quoted form of etaFile
                        set lastLoggedPct to currentPct
                    end try
                end if

                set progress additional description to currentDetail & return & timeText

            end try

            delay 0.2
        end repeat

    on error number -128
        do shell script "/usr/bin/touch " & quoted form of cancelFile
    end try

    try
        do shell script "/usr/bin/touch " & quoted form of closedFile
    end try
end run
