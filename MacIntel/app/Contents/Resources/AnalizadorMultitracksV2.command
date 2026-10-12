#!/bin/bash

# ============================================================
# ANALIZADOR DE MULTITRACKS ESTUDIO PG V2.12.19 - macOS INTEL
# Revisión: paridad con optimizaciones Apple Silicon
# - salida [PROCESADO] solo si hay conversiones
# - código de duplicados conservado, pero desactivado temporalmente en V2.12.18
# - residual L/R con resta explícita
# - progreso con tiempo transcurrido y restante aproximado
# - detección automática de DUAL MONO PRÁCTICO
# - detección preventiva de estéreo extremadamente correlacionado / posible mono
# Estudio PG
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FFMPEG="$SCRIPT_DIR/ffmpeg"
FFPROBE="$SCRIPT_DIR/ffprobe"
EFFECTIVE_DEPTH_HELPER="$SCRIPT_DIR/EffectiveDepth.pl"
PERL_BIN="/usr/bin/perl"
PDF_GENERATOR="$SCRIPT_DIR/GeneradorPDFMacIntel"
PDF_FONT_REGULAR="$SCRIPT_DIR/DejaVuSans.ttf"
PDF_FONT_BOLD="$SCRIPT_DIR/DejaVuSans-Bold.ttf"
PDF_PUBLISH_HELPER="$SCRIPT_DIR/PublishPDFReports.sh"
PDF_STATUS="PENDIENTE"
PDF_ERROR_MSG=""

# ------------------------------------------------------------
# Umbrales
# ------------------------------------------------------------

DUAL_MONO_MAX_LEVEL_DIFF="0.01"
DUAL_MONO_MAX_RESIDUAL="-70"
MONO_PAN_MAX_RESIDUAL="-100"

# Dual mono práctico: canales virtualmente iguales desde el punto de vista de mezcla,
# aunque no sean copias matemáticamente idénticas. Se convierte automáticamente
# solo cuando coinciden simultáneamente correlación, nivel y residual.
PRACTICAL_DUAL_MAX_LEVEL_DIFF="0.10"
PRACTICAL_DUAL_MAX_RESIDUAL="-50"
PRACTICAL_DUAL_MIN_CORRELATION="0.99999"

REVIEW_MAX_RESIDUAL="-50"

# Posible mono práctico dentro de un archivo estéreo:
# no se convierte automáticamente; se marca para revisión.
HIGH_CORR_MAX_LEVEL_DIFF="1.0"
HIGH_CORR_MAX_RESIDUAL="-30"
HIGH_CORR_MIN_CORRELATION="0.9995"

# Control de nivel por pico máximo:
# > -20 dBFS        = sin advertencia
# <= -20 y > -60   = NIVEL BAJO
# <= -60 dBFS      = NIVEL EXTREMADAMENTE BAJO
LOW_WARNING_THRESHOLD="-20"
LOW_LEVEL_THRESHOLD="-60"

# Detección de pistas duplicadas.
DUPLICATE_MAX_RESIDUAL="-100"
DUPLICATE_SAME_LEVEL_DIFF="0.01"
DUP_FP_TOLERANCE="1.5"
DUP_FP_WINDOW="0.30"
DUP_FP_MIN_NONHASH_PAIRS="25"

# V2.12.18: comparación de duplicados desactivada temporalmente para medir rendimiento.
# El código de detección se conserva, pero ninguna etapa se ejecuta mientras el valor sea 0.
DUPLICATE_ANALYSIS_ENABLED=0




# ============================================================
# PROFUNDIDAD EFECTIVA
# ============================================================
# El análisis se realiza leyendo directamente las muestras PCM del WAV.
# PCM16 se identifica sin recorrer las muestras. PCM24/PCM32 entero se
# inspeccionan para detectar almacenamiento a mayor profundidad y, en PCM24,
# patrones estadísticos compatibles con una grilla previa de 16 bits.
# FLOAT se mantiene separado de la lógica de LSB.

get_effective_depth() {
    local FILE="$1"

    if [ ! -x "$PERL_BIN" ] || [ ! -f "$EFFECTIVE_DEPTH_HELPER" ]; then
        printf "0\tDESCONOCIDO\t\t\tPROFUNDIDAD EFECTIVA NO DETERMINADA\tNO APLICA\t\t\t\t\t\t\t\tMotor de profundidad efectiva no disponible\n"
        return
    fi

    "$PERL_BIN" "$EFFECTIVE_DEPTH_HELPER" "$FILE" 2>/dev/null || \
        printf "0\tDESCONOCIDO\t\t\tPROFUNDIDAD EFECTIVA NO DETERMINADA\tNO APLICA\t\t\t\t\t\t\t\tError de análisis\n"
}

# ============================================================
# PERFIL TÉCNICO INTERNO (V2.12.18)
# ============================================================
# Este perfil existe solo para diagnóstico/desarrollo. Usa Time::HiRes de
# Perl para obtener milisegundos en macOS Intel sin depender de Homebrew.
# La instrumentación agrega una pequeña sobrecarga, por lo que los tiempos
# sirven principalmente para comparar etapas y detectar cuellos de botella.

now_ms() {
    # Reloj monotónico del sistema: no cambia si se ajusta la hora del Mac.
    # Se usa para profiler y para la referencia compartida del ETA.
    "$PERL_BIN" -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e 'printf "%.0f\n", clock_gettime(CLOCK_MONOTONIC)*1000' 2>/dev/null
}

ms_add() {
    # Uso: VAR=$(ms_add "$VAR" "$DELTA")
    awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { printf "%.0f", a+b }'
}

PROFILE_TOTAL_START_MS=0
PROFILE_METADATA_MS=0
PROFILE_DEPTH_MS=0
PROFILE_LEVEL_MS=0
PROFILE_DUP_PREP_MS=0
PROFILE_DUP_HASH_MS=0
PROFILE_DUP_FP_MS=0
PROFILE_STEREO_MS=0
PROFILE_CONVERT_MS=0
PROFILE_FORMAT_MS=0
PROFILE_DUPLICATES_MS=0
PROFILE_REPORT_MS=0
PROFILE_PDF_MS=0
PROFILE_OUTPUT_MS=0
PROFILE_DISCOVERY_MS=0
PROFILE_INSTRUMENTED_CALLS=0
AUDIO_DURATION_SUM=0
CONVERSION_ERRORS=0
DUP_EXACT_HASH_MATCHES=0
DUP_SIGNAL_MATCHES=0

# ============================================================
# PROGRESO GRÁFICO DE LA APP
# ============================================================

PROGRESS_FILE="${PG_PROGRESS_FILE:-}"
CANCEL_FILE="${PG_CANCEL_FILE:-}"
ETA_LOG_FILE="${PG_ETA_FILE:-/tmp/estudiopg_analizador_$(/usr/bin/id -u).eta.tsv}"

progress_update() {

    local PERCENT="$1"
    local PHASE="$2"
    local DETAIL="$3"
    # Por defecto el ETA usa el mismo porcentaje visible. Durante el análisis
    # por archivo puede recibir un porcentaje de trabajo más conservador,
    # basado solo en trabajo ya completado.
    local ETA_PERCENT="${4:-$PERCENT}"

    if [ -n "$CANCEL_FILE" ] && [ -e "$CANCEL_FILE" ]; then
        exit 130
    fi

    if [ -n "$PROGRESS_FILE" ]; then
        # V2.12.18: el cuarto campo se envía como MILISEGUNDOS ENTEROS.
        # AppleScript interpreta números decimales según la configuración regional;
        # en macOS en español, por ejemplo, "13.386" puede leerse como 13386.
        # Los enteros evitan por completo esa ambigüedad de separador decimal.
        local ELAPSED_STATUS_MS="0"
        if [ "${PROFILE_TOTAL_START_MS:-0}" -gt 0 ] 2>/dev/null; then
            local NOW_STATUS_MS
            NOW_STATUS_MS=$(now_ms)
            PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
            if [ "$NOW_STATUS_MS" -ge "$PROFILE_TOTAL_START_MS" ] 2>/dev/null; then
                ELAPSED_STATUS_MS=$((NOW_STATUS_MS - PROFILE_TOTAL_START_MS))
            fi
        fi
        printf "%s\t%s\t%s\t%s\t%s\n" \
            "$PERCENT" \
            "$PHASE" \
            "$DETAIL" \
            "$ELAPSED_STATUS_MS" \
            "$ETA_PERCENT" > "$PROGRESS_FILE"
    fi
}


progress_finish() {

    local DESTINATION="$1"
    local OUTPUT_TYPE="$2"
    local PDF_MSG="${PDF_ERROR_MSG:-}"
    PDF_MSG="${PDF_MSG//$'\t'/ }"
    PDF_MSG="${PDF_MSG//$'\n'/ }"

    if [ -n "$PROGRESS_FILE" ]; then
        printf "DONE\t100\tProceso terminado\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            "$DESTINATION" \
            "$OUTPUT_TYPE" \
            "${TOTAL:-0}" \
            "${CONVERSION_TOTAL:-0}" \
            "${PDF_STATUS:-NO_EVALUADO}" \
            "$PDF_MSG" > "$PROGRESS_FILE"
    fi
}



# Nombre compacto para la ventana de progreso.
# La ventana estándar de macOS puede ensancharse si recibe una cadena larga;
# por eso el nombre visible se limita y termina en tres puntos.
progress_short_filename() {
    local NAME="$1"
    /usr/bin/awk -v s="$NAME" 'BEGIN {
        max=36;
        if (length(s) <= max) { print s; exit }
        print substr(s,1,max-3) "..."
    }'
}

# ============================================================
# FUNCIONES DE PRESENTACIÓN
# ============================================================

format_level_diff() {
    awk -v x="$1" 'BEGIN {
        printf "%.2f dB", x
    }'
}


format_residual() {
    awk -v x="$1" 'BEGIN {
        if (x <= -150) {
            printf "prácticamente nulo"
        } else {
            printf "%.1f dB", x
        }
    }'
}


estimate_correlation_from_residual() {
    # Tras compensar la diferencia de nivel entre L/R, la energía residual
    # permite estimar la correlación lineal entre ambos canales.
    awk -v r="$1" 'BEGIN {
        c = 1 - (exp(log(10) * r / 10) / 2)
        if (c > 1) c = 1
        if (c < -1) c = -1
        printf "%.5f", c
    }'
}


format_peak() {
    local PEAK="$1"

    if [ "$PEAK" = "-inf" ]; then
        echo "silencio digital"
    else
        awk -v x="$PEAK" 'BEGIN {
            printf "%.1f dBFS", x
        }'
    fi
}


format_sample_rate() {
    local SR="$1"

    if [ "$SR" = "DESCONOCIDO" ]; then
        echo "DESCONOCIDO"
        return
    fi

    awk -v sr="$SR" 'BEGIN {
        khz=sr/1000

        if (khz == int(khz)) {
            printf "%d kHz", khz
        } else {
            printf "%.1f kHz", khz
        }
    }'
}


format_duration() {
    local SEC="$1"

    if [ "$SEC" = "DESCONOCIDO" ]; then
        echo "DESCONOCIDO"
        return
    fi

    awk -v x="$SEC" 'BEGIN {

        sign=""

        if (x < 0) {
            sign="-"
            x=-x
        }

        h=int(x/3600)
        rem=x-(h*3600)
        m=int(rem/60)
        s=rem-(m*60)

        if (h > 0) {
            printf "%s%d h %02d min %06.3f s", sign, h, m, s
        }
        else if (m > 0) {
            printf "%s%d min %06.3f s", sign, m, s
        }
        else {
            printf "%s%.3f s", sign, s
        }
    }'
}


format_time_difference() {
    local MS="$1"

    if [ "$MS" = "DESCONOCIDO" ]; then
        echo "DESCONOCIDO"
        return
    fi

    awk -v ms="$MS" 'BEGIN {
        sign=""
        if (ms < 0) { sign="-"; ms=-ms }
        sec=ms/1000
        if (sec < 60) {
            printf "%s%.3f s", sign, sec
        } else {
            min=int(sec/60)
            s=sec-(min*60)
            printf "%s%d min %.3f s", sign, min, s
        }
    }'
}


# ============================================================
# VERIFICAR FFMPEG / FFPROBE
# ============================================================

if [ ! -x "$FFMPEG" ]; then
    echo "ERROR: No se encontró ffmpeg ejecutable en:"
    echo "$FFMPEG"
    exit 1
fi

if [ ! -x "$FFPROBE" ]; then
    echo "ERROR: No se encontró ffprobe ejecutable en:"
    echo "$FFPROBE"
    exit 1
fi


# ============================================================
# CARPETA A ANALIZAR
# ============================================================
# La app principal selecciona la carpeta ANTES de abrir el progreso.
# Se conserva un selector de respaldo para ejecutar el script directamente.
SOURCE_DIR="${PG_SOURCE_DIR:-}"

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR=$(osascript <<'APPLESCRIPT'
try
    set selectedFolder to choose folder with prompt "Elegí la carpeta de multitracks que querés analizar:"
    return POSIX path of selectedFolder
on error number -128
    return ""
end try
APPLESCRIPT
    )
fi

if [ -z "$SOURCE_DIR" ]; then
    echo "Proceso cancelado."
    exit 0
fi

SOURCE_DIR="${SOURCE_DIR%/}"

SOURCE_NAME="$(basename "$SOURCE_DIR")"
PARENT_DIR="$(dirname "$SOURCE_DIR")"
DEST_BASE="$PARENT_DIR/$SOURCE_NAME [PROCESADO]"
DEST_DIR="$DEST_BASE"

resolve_destination_dir() {
    local candidate="$DEST_BASE"
    local n=1

    while [ -e "$candidate" ]; do
        n=$((n+1))
        candidate="$PARENT_DIR/$SOURCE_NAME [PROCESADO $n]"
    done

    DEST_DIR="$candidate"
}

progress_update 4 "Preparando análisis" "$SOURCE_NAME"
PROFILE_TOTAL_START_MS=$(now_ms)
PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))

# Trabajo temporal: no se crea [PROCESADO] hasta saber que realmente
# hay al menos una conversión automática.
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/estudiopg_clasificador.XXXXXX")"
if [ -z "$WORK_DIR" ] || [ ! -d "$WORK_DIR" ]; then
    echo "ERROR: No se pudo crear el directorio temporal."
    exit 1
fi
trap 'rm -rf "$WORK_DIR"' EXIT

CONVERT_DIR="$WORK_DIR/convertidos"
mkdir -p "$CONVERT_DIR"

REPORT="$WORK_DIR/INFORME_ANALISIS.txt"
REVIEW_TEMP="$WORK_DIR/.archivos_para_revisar.tmp"
META_TEMP="$WORK_DIR/.metadata_archivos.tmp"
SILENT_TEMP="$WORK_DIR/.sin_audio.tmp"
LOW_WARNING_TEMP="$WORK_DIR/.nivel_bajo.tmp"
LOW_TEMP="$WORK_DIR/.nivel_extremadamente_bajo.tmp"
DUP_META_TEMP="$WORK_DIR/.duplicados_metadata.tmp"
DUP_PAIR_TEMP="$WORK_DIR/.duplicados_pares.tmp"
CONVERSION_MAP="$WORK_DIR/.conversiones.tmp"
CHANGES_TEMP="$WORK_DIR/.cambios_realizados.tmp"
DEPTH_TEMP="$WORK_DIR/.profundidad_efectiva.tmp"
INT_BITS_TEMP="$WORK_DIR/.profundidad_pcm_entero.tmp"
FLOAT_TEMP="$WORK_DIR/.archivos_float.tmp"
CLASS_TEMP="$WORK_DIR/.clasificacion.tmp"
PROFILE_FILE_TEMP="$WORK_DIR/.perfil_archivos.tmp"
REPORT_TECH="$WORK_DIR/INFORME_TECNICO_DESARROLLO.txt"

: > "$REVIEW_TEMP"
: > "$META_TEMP"
: > "$SILENT_TEMP"
: > "$LOW_WARNING_TEMP"
: > "$LOW_TEMP"
if [ "$DUPLICATE_ANALYSIS_ENABLED" -eq 1 ]; then
    : > "$DUP_META_TEMP"
    : > "$DUP_PAIR_TEMP"
fi
: > "$CONVERSION_MAP"
: > "$CHANGES_TEMP"
: > "$DEPTH_TEMP"
: > "$INT_BITS_TEMP"
: > "$FLOAT_TEMP"
: > "$CLASS_TEMP"
: > "$PROFILE_FILE_TEMP"


# ============================================================
# CONTADORES
# ============================================================

TOTAL=0

MONO_ORIGINAL=0
STEREO_REAL=0
DUAL_MONO=0
DUAL_MONO_PRACTICO=0
MONO_PANEADO=0
HIGH_CORR_REVIEW=0
REVISAR=0

SIN_AUDIO=0
NIVEL_BAJO=0
NIVEL_EXTREMO=0

SAMPLE_RATE_ERRORS=0
BITS_ERRORS=0
DURATION_ERRORS=0

DEPTH_EXACT_24_TO_16=0
DEPTH_EXACT_32_TO_24=0
DEPTH_EXACT_32_TO_16=0
DEPTH_STRONG=0
DEPTH_PARTIAL=0
DEPTH_ANALYSIS_ERRORS=0
DEPTH_FLOAT=0
DEPTH_SILENCE_SKIPPED=0

DUP_GROUPS=0
DUP_EXTRA_FILES=0
DUP_PREFILTER_RUN=0
DUP_PREFILTER_DISCARDED=0
DUP_FULL_COMPARISONS=0
DUP_COUNT=0
DUP_THEORETICAL_TOTAL=0
DUP_EFFECTIVE_TOTAL=0
DUP_NONHASH_CANDIDATE_PAIRS=0
DUP_FP_MODE="DESACTIVADO TEMPORALMENTE"
DUP_FP_FILES=0
DUP_EXACT_HASH_MATCHES=0
DUP_SIGNAL_MATCHES=0

# V2.12.18 — reutilización de análisis / reducción de procesos externos
METADATA_SINGLE_PASS_FILES=0
STEREO_RMS_REUSED_FILES=0
ASTATS_LIMITED_CALLS=0


# ============================================================
# INFORME INICIAL
# ============================================================

{
    echo "============================================================"
    echo "ANALIZADOR DE MULTITRACKS ESTUDIO PG — V2.12.19 (Mac Intel)"
    echo "============================================================"
    echo
    echo "Carpeta analizada:"
    echo "$SOURCE_DIR"
    echo
} > "$REPORT"


# ============================================================
# OBTENER RMS DE UN CANAL
# ============================================================

get_rms_channel() {

    local FILE="$1"
    local CHANNEL="$2"
    local VALUE

    VALUE=$(
        "$FFMPEG" \
        -nostdin \
        -hide_banner \
        -nostats \
        -i "$FILE" \
        -af "pan=mono|c0=c${CHANNEL},astats=metadata=1:reset=0:measure_perchannel=none:measure_overall=RMS_level" \
        -f null - 2>&1 |
        grep "RMS level dB" |
        tail -1 |
        sed -E 's/.*RMS level dB:[[:space:]]*//'
    )

    if [ -z "$VALUE" ]; then
        echo "-999"
    elif [[ "$VALUE" == *"-inf"* ]]; then
        echo "-999"
    else
        echo "$VALUE"
    fi
}


# ============================================================
# ESTADÍSTICAS GENERALES EN UNA SOLA PASADA — V2.12.18
# Devuelve: pico máximo, RMS general (sólo si la comparación de duplicados
# está activa) y RMS de los canales 1 y 2.
#
# El RMS por canal se reutiliza después en la clasificación estéreo.
# El RMS global se omite cuando los duplicados están desactivados porque
# sólo se utilizaba para esa función. No se omite el Peak global ni el RMS L/R.
# ============================================================

get_file_stats() {

    local FILE="$1"
    local OVERALL_MEASURES="Peak_level"
    if [ "$DUPLICATE_ANALYSIS_ENABLED" -eq 1 ]; then
        OVERALL_MEASURES="Peak_level+RMS_level"
    fi

    "$FFMPEG" \
        -nostdin \
        -hide_banner \
        -nostats \
        -i "$FILE" \
        -af "astats=metadata=1:reset=0:measure_perchannel=RMS_level:measure_overall=${OVERALL_MEASURES}" \
        -f null - 2>&1 |
        awk '
        /Channel:/ {
            section="channel"
            channel=$NF+0
        }

        /Overall/ {
            section="overall"
            channel=0
        }

        /Peak level dB:/ {
            if ($NF != "-inf") {
                value=$NF+0
                if (!peak_found || value > peak) {
                    peak=value
                    peak_found=1
                }
            }
        }

        /RMS level dB:/ {
            value=$NF
            if (section == "channel" && channel == 1) ch1=value
            else if (section == "channel" && channel == 2) ch2=value
            else if (section == "overall") rms=value
        }

        END {
            if (!peak_found) peak_text="-inf"
            else peak_text=sprintf("%.10f", peak)

            if (rms == "") rms="-inf"
            if (ch1 == "") ch1="-inf"
            if (ch2 == "") ch2="-inf"

            printf "%s\t%s\t%s\t%s\n", peak_text, rms, ch1, ch2
        }'
}


# ============================================================
# FINGERPRINT RÁPIDO PARA DUPLICADOS
# Tres ventanas cortas (~20%, 50%, 80% de la duración).
# Se normalizan respecto del promedio para que una diferencia
# global de ganancia no cambie la forma del fingerprint.
# ============================================================

get_quick_fingerprint() {

    local FILE="$1"
    local DURATION="$2"

    if [ -z "$DURATION" ] || [ "$DURATION" = "DESCONOCIDO" ]; then
        echo "SIN_FP"
        return
    fi

    local VALUES=()
    local FRACTION START VALUE

    for FRACTION in 0.20 0.50 0.80
    do
        START=$(awk -v d="$DURATION" -v f="$FRACTION" -v w="$DUP_FP_WINDOW" 'BEGIN {
            s=(d*f)-(w/2)
            if (s < 0) s=0
            printf "%.6f", s
        }')

        VALUE=$(
            "$FFMPEG" \
                -nostdin \
                -hide_banner \
                -nostats \
                -ss "$START" \
                -t "$DUP_FP_WINDOW" \
                -i "$FILE" \
                -af "astats=metadata=1:reset=0:measure_perchannel=none:measure_overall=RMS_level" \
                -f null - 2>&1 |
                grep "RMS level dB" |
                tail -1 |
                sed -E 's/.*RMS level dB:[[:space:]]*//'
        )

        if [ -z "$VALUE" ] || [[ "$VALUE" == *"-inf"* ]]; then
            VALUES+=("S")
        else
            VALUES+=("$VALUE")
        fi
    done

    awk \
        -v a="${VALUES[0]}" \
        -v b="${VALUES[1]}" \
        -v c="${VALUES[2]}" '
        BEGIN {
            vals[1]=a; vals[2]=b; vals[3]=c
            sum=0; n=0

            for (i=1; i<=3; i++) {
                if (vals[i] != "S") {
                    sum += vals[i]+0
                    n++
                }
            }

            if (n < 2) {
                print "SIN_FP"
                exit
            }

            avg=sum/n
            out=""

            for (i=1; i<=3; i++) {
                if (i>1) out=out ","
                if (vals[i] == "S") out=out "S"
                else out=out sprintf("%.3f", (vals[i]+0)-avg)
            }

            print out
        }'
}


fingerprint_compare() {

    local FP_A="$1"
    local FP_B="$2"

    if [ "$FP_A" = "SIN_FP" ] || [ "$FP_B" = "SIN_FP" ]; then
        echo "2"
        return
    fi

    awk -v a="$FP_A" -v b="$FP_B" -v tol="$DUP_FP_TOLERANCE" '
    BEGIN {
        split(a,A,",")
        split(b,B,",")

        for (i=1; i<=3; i++) {
            if (A[i] == "S" || B[i] == "S") {
                if (A[i] != B[i]) {
                    print 0
                    exit
                }
            }
            else {
                d=(A[i]+0)-(B[i]+0)
                if (d<0) d=-d
                if (d > tol) {
                    print 0
                    exit
                }
            }
        }

        print 1
    }'
}


# ============================================================
# RESIDUAL L/R COMPENSADO
# ============================================================

get_residual() {

    local FILE="$1"
    local GAIN="$2"
    local VALUE

    VALUE=$(
        "$FFMPEG" \
        -nostdin \
        -hide_banner \
        -nostats \
        -i "$FILE" \
        -filter_complex \
        "[0:a]channelsplit=channel_layout=stereo[L][R];[L]volume=${GAIN}dB[L2];[L2][R]amerge=inputs=2[M];[M]pan=mono|c0=c0-c1,astats=metadata=1:reset=0:measure_perchannel=none:measure_overall=RMS_level" \
        -f null - 2>&1 |
        grep "RMS level dB" |
        tail -1 |
        sed -E 's/.*RMS level dB:[[:space:]]*//'
    )

    if [ -z "$VALUE" ]; then
        echo "-999"
    elif [[ "$VALUE" == *"-inf"* ]]; then
        echo "-999"
    else
        echo "$VALUE"
    fi
}


# ============================================================
# RMS GENERAL DEL ARCHIVO
# Se calcula una sola vez por archivo para la búsqueda de duplicados.
# ============================================================

get_file_rms() {

    local FILE="$1"
    local VALUE

    VALUE=$(
        "$FFMPEG" \
        -nostdin \
        -hide_banner \
        -nostats \
        -i "$FILE" \
        -af "astats=metadata=1:reset=0:measure_perchannel=none:measure_overall=RMS_level" \
        -f null - 2>&1 |
        grep "RMS level dB" |
        tail -1 |
        sed -E 's/.*RMS level dB:[[:space:]]*//'
    )

    if [ -z "$VALUE" ] || [[ "$VALUE" == *"-inf"* ]]; then
        echo "-999"
    else
        echo "$VALUE"
    fi
}


# ============================================================
# HASH DEL AUDIO
# Detecta copias con audio exactamente igual sin depender
# de los metadatos RIFF/BWF del archivo.
# ============================================================

get_audio_hash() {

    local FILE="$1"
    local VALUE

    VALUE=$(
        "$FFMPEG" \
        -nostdin \
        -hide_banner \
        -loglevel error \
        -i "$FILE" \
        -map 0:a:0 \
        -c:a copy \
        -f hash \
        -hash md5 \
        - 2>/dev/null |
        sed -E 's/^MD5=//'
    )

    if [ -z "$VALUE" ]; then
        echo "SIN_HASH"
    else
        echo "$VALUE"
    fi
}


# ============================================================
# RESIDUAL ENTRE DOS ARCHIVOS
# A se ajusta al nivel de B y luego se hace una resta explícita.
# Compatible con mono y stereo.
# ============================================================

get_duplicate_residual() {

    local FILE_A="$1"
    local FILE_B="$2"
    local CHANNELS="$3"
    local GAIN="$4"
    local VALUE

    if [ "$CHANNELS" -eq 1 ]; then

        VALUE=$(
            "$FFMPEG" \
            -nostdin \
            -hide_banner \
            -nostats \
            -i "$FILE_A" \
            -i "$FILE_B" \
            -filter_complex \
            "[0:a]volume=${GAIN}dB[A];[A][1:a]amerge=inputs=2[M];[M]pan=mono|c0=c0-c1,astats=metadata=1:reset=0:measure_perchannel=none:measure_overall=RMS_level" \
            -f null - 2>&1 |
            grep "RMS level dB" |
            tail -1 |
            sed -E 's/.*RMS level dB:[[:space:]]*//'
        )

    elif [ "$CHANNELS" -eq 2 ]; then

        VALUE=$(
            "$FFMPEG" \
            -nostdin \
            -hide_banner \
            -nostats \
            -i "$FILE_A" \
            -i "$FILE_B" \
            -filter_complex \
            "[0:a]volume=${GAIN}dB[A];[A][1:a]amerge=inputs=2[M];[M]pan=stereo|c0=c0-c2|c1=c1-c3,astats=metadata=1:reset=0:measure_perchannel=none:measure_overall=RMS_level" \
            -f null - 2>&1 |
            grep "RMS level dB" |
            tail -1 |
            sed -E 's/.*RMS level dB:[[:space:]]*//'
        )

    else
        echo "-999"
        return
    fi

    if [ -z "$VALUE" ] || [[ "$VALUE" == *"-inf"* ]]; then
        echo "-999"
    else
        echo "$VALUE"
    fi
}


# ============================================================
# CONVERTIR A MONO
# ============================================================

convert_to_mono() {

    local FILE="$1"
    local KEEP_CHANNEL="$2"
    local CODEC="$3"
    local OUTPUT="$4"

    "$FFMPEG" \
        -nostdin \
        -hide_banner \
        -loglevel error \
        -i "$FILE" \
        -map_metadata 0 \
        -af "pan=mono|c0=c${KEEP_CHANNEL}" \
        -c:a "$CODEC" \
        -write_bext 1 \
        "$OUTPUT"
}


# ============================================================
# RECORRER ARCHIVOS WAV
# ============================================================

PROFILE_T0=$(now_ms)
WAV_LIST_FILE="$WORK_DIR/.wav_list.bin"
find "$SOURCE_DIR" -type f \
    \( -iname "*.wav" -o -iname "*.wave" \) \
    -print0 > "$WAV_LIST_FILE"

TOTAL_WAV_COUNT=$(tr -cd '\0' < "$WAV_LIST_FILE" | wc -c | tr -d ' ')
TOTAL_WAV_BYTES=0
while IFS= read -r -d '' SIZE_FILE; do
    FILE_BYTES=$(/usr/bin/stat -f '%z' "$SIZE_FILE" 2>/dev/null || /usr/bin/stat -c '%s' "$SIZE_FILE" 2>/dev/null || echo 0)
    TOTAL_WAV_BYTES=$((TOTAL_WAV_BYTES + FILE_BYTES))
done < "$WAV_LIST_FILE"
PROFILE_T1=$(now_ms)
PROFILE_DISCOVERY_MS=$((PROFILE_T1-PROFILE_T0))
PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+2))

[ -z "$TOTAL_WAV_COUNT" ] && TOTAL_WAV_COUNT=0
ANALYSIS_BYTES_COMPLETED=0

progress_update 5 "Analizando archivos" "0 de $TOTAL_WAV_COUNT"
PROFILE_ANALYSIS_T0=$(now_ms)
PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))

while IFS= read -r -d '' FILE
do

    TOTAL=$((TOTAL + 1))

    RELATIVE="${FILE#$SOURCE_DIR/}"

    CURRENT_FILE_BYTES=$(/usr/bin/stat -f '%z' "$FILE" 2>/dev/null || /usr/bin/stat -c '%s' "$FILE" 2>/dev/null || echo 0)
    if [ "$TOTAL_WAV_BYTES" -gt 0 ] && [ "$TOTAL_WAV_COUNT" -gt 0 ]; then
        # Barra visible: conserva una lectura fluida usando el punto medio del archivo.
        FILE_PROGRESS=$(awk -v done="$ANALYSIS_BYTES_COMPLETED" -v cur="$CURRENT_FILE_BYTES" -v total="$TOTAL_WAV_BYTES" 'BEGIN {
            p=5 + (((done + cur/2)/total)*85);
            if (p < 5) p=5; if (p > 89) p=89;
            printf "%d", p
        }')

        # ETA V2.12.18: no usa el punto medio del archivo actual ni 100% bytes.
        # Profundidad efectiva tiene un coste importante por archivo y además puede
        # salir antes según el contenido; por eso una mezcla 60% cantidad de archivos
        # ya terminados + 40% bytes ya terminados representa mejor el trabajo real.
        COMPLETED_FILES=$((TOTAL - 1))
        ETA_FILE_PROGRESS=$(awk \
            -v filesDone="$COMPLETED_FILES" \
            -v filesTotal="$TOTAL_WAV_COUNT" \
            -v bytesDone="$ANALYSIS_BYTES_COMPLETED" \
            -v bytesTotal="$TOTAL_WAV_BYTES" \
            'BEGIN {
                ff=(filesTotal>0 ? filesDone/filesTotal : 0);
                bf=(bytesTotal>0 ? bytesDone/bytesTotal : 0);
                work=(0.60*ff)+(0.40*bf);
                p=5+(work*85);
                if(p<5)p=5; if(p>89)p=89;
                printf "%d", p
            }')
    elif [ "$TOTAL_WAV_COUNT" -gt 0 ]; then
        FILE_PROGRESS=$(awk -v current="$TOTAL" -v total="$TOTAL_WAV_COUNT" 'BEGIN { p=5+((current/total)*85); if(p>89)p=89; printf "%d", p }')
        COMPLETED_FILES=$((TOTAL - 1))
        ETA_FILE_PROGRESS=$(awk -v done="$COMPLETED_FILES" -v total="$TOTAL_WAV_COUNT" 'BEGIN { p=5+((done/total)*85); if(p>89)p=89; printf "%d", p }')
    else
        FILE_PROGRESS=89
        ETA_FILE_PROGRESS=89
    fi

    FILE_NAME="$(basename "$FILE")"
    PROGRESS_FILE_NAME="$(progress_short_filename "$FILE_NAME")"

    progress_update \
        "$FILE_PROGRESS" \
        "Analizando archivos" \
        "Archivo $TOTAL de $TOTAL_WAV_COUNT — $PROGRESS_FILE_NAME" \
        "$ETA_FILE_PROGRESS"

    ANALYSIS_BYTES_COMPLETED=$((ANALYSIS_BYTES_COMPLETED + CURRENT_FILE_BYTES))

    REL_DIR="$(dirname "$RELATIVE")"

    echo
    echo "Analizando: $RELATIVE"


    # --------------------------------------------------------
    # Información técnica
    # --------------------------------------------------------

    PROFILE_T0=$(now_ms)
    PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))

    # V2.12.18: una sola ejecución de FFprobe obtiene todos los metadatos
    # necesarios del stream y la duración del contenedor. En versiones previas
    # se lanzaban varias instancias de FFprobe por cada WAV.
    FFPROBE_RAW=$(
        "$FFPROBE" \
        -v error \
        -select_streams a:0 \
        -show_entries stream=codec_name,channels,sample_rate,bits_per_sample,bits_per_raw_sample,duration_ts:format=duration \
        -of flat=s=_ \
        "$FILE" 2>/dev/null
    )

    ffprobe_flat_value() {
        local KEY="$1"
        printf '%s\n' "$FFPROBE_RAW" |
            sed -n "s/^${KEY}=//p" |
            head -1 |
            sed -E 's/^"(.*)"$/\1/'
    }

    CODEC=$(ffprobe_flat_value 'streams_stream_0_codec_name')
    CHANNELS=$(ffprobe_flat_value 'streams_stream_0_channels')
    SAMPLE_RATE=$(ffprobe_flat_value 'streams_stream_0_sample_rate')
    BITS_SAMPLE=$(ffprobe_flat_value 'streams_stream_0_bits_per_sample')
    BITS_RAW=$(ffprobe_flat_value 'streams_stream_0_bits_per_raw_sample')
    DURATION_TS=$(ffprobe_flat_value 'streams_stream_0_duration_ts')
    DURATION_SEC=$(ffprobe_flat_value 'format_duration')

    BITS="$BITS_SAMPLE"
    if [ -z "$BITS" ] || [ "$BITS" = "0" ]; then
        BITS="$BITS_RAW"
    fi

    METADATA_SINGLE_PASS_FILES=$((METADATA_SINGLE_PASS_FILES + 1))

    [ -z "$SAMPLE_RATE" ] && SAMPLE_RATE="DESCONOCIDO"
    [ -z "$BITS" ] && BITS="DESCONOCIDO"
    [ -z "$DURATION_TS" ] && DURATION_TS="DESCONOCIDO"
    [ -z "$DURATION_SEC" ] && DURATION_SEC="DESCONOCIDO"

    PROFILE_T1=$(now_ms)
    PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
    PROFILE_METADATA_MS=$((PROFILE_METADATA_MS + PROFILE_T1 - PROFILE_T0))

    if [ "$DURATION_SEC" != "DESCONOCIDO" ]; then
        AUDIO_DURATION_SUM=$(awk -v a="$AUDIO_DURATION_SUM" -v b="$DURATION_SEC" 'BEGIN { printf "%.6f", a+b }')
    fi

    printf "%s\t%s\t%s\t%s\t%s\n" \
        "$RELATIVE" \
        "$SAMPLE_RATE" \
        "$BITS" \
        "$DURATION_TS" \
        "$DURATION_SEC" >> "$META_TEMP"


    # --------------------------------------------------------
    # Error de lectura
    # --------------------------------------------------------

    if [ -z "$CHANNELS" ]; then

        echo "NO SE PUDO ANALIZAR -> PARA REVISAR"

        REVISAR=$((REVISAR + 1))
        echo "$RELATIVE|Error de lectura" >> "$REVIEW_TEMP"

        continue
    fi


    # --------------------------------------------------------
    # CONTROL DE NIVEL / SILENCIO — ANTES DE PROFUNDIDAD EFECTIVA
    # --------------------------------------------------------
    # V2.12.18: el análisis global de nivel ya era obligatorio para todos los
    # archivos. Se ejecuta antes de Profundidad Efectiva para detectar silencio
    # digital y evitar recorrer millones de muestras inútilmente con el helper
    # de LSB. El resultado funcional de formato/profundidad se conserva.

    PROFILE_T0=$(now_ms)
    PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
    IFS=$'\t' read -r PEAK_LEVEL FILE_RMS STAT_L_RMS STAT_R_RMS <<< "$(get_file_stats "$FILE")"
    PROFILE_T1=$(now_ms)
    PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
    PROFILE_LEVEL_MS=$((PROFILE_LEVEL_MS + PROFILE_T1 - PROFILE_T0))

    if [ "$DUPLICATE_ANALYSIS_ENABLED" -eq 1 ]; then
        if [ -z "$FILE_RMS" ] || [[ "$FILE_RMS" == *"-inf"* ]]; then
            DUP_RMS="-999"
        else
            DUP_RMS="$FILE_RMS"
        fi
    fi


    # --------------------------------------------------------
    # SILENCIO DIGITAL — SALIDA TEMPRANA DE PROFUNDIDAD EFECTIVA
    # --------------------------------------------------------

    if [ "$PEAK_LEVEL" = "-inf" ]; then

        SIN_AUDIO=$((SIN_AUDIO + 1))
        DEPTH_SILENCE_SKIPPED=$((DEPTH_SILENCE_SKIPPED + 1))

        echo "SIN AUDIO -> SILENCIO DIGITAL"
        echo "Archivo original sin cambios"
        echo "$RELATIVE" >> "$SILENT_TEMP"

        # El codec ya fue obtenido en la lectura única de metadatos.
        SILENT_CODEC="$CODEC"

        DEPTH_VALID=1
        DEPTH_CONTAINER="$BITS"
        DEPTH_GRID_EXACT=""
        DEPTH_GRID_WITHIN2=""
        DEPTH_GRID_RMS=""
        DEPTH_ERROR=""
        DEPTH_PATTERN="NO APLICA"

        case "$SILENT_CODEC" in
            pcm_f32le|pcm_f32be|pcm_f64le|pcm_f64be)
                DEPTH_ENCODING="PCM FLOAT"
                DEPTH_STRICT="FLOAT 32 - PROFUNDIDAD EFECTIVA NO DETERMINADA"
                DEPTH_FLOAT=$((DEPTH_FLOAT + 1))
                printf "%s\t%s\n" "$RELATIVE" "$DEPTH_CONTAINER" >> "$FLOAT_TEMP"
                ;;
            pcm_*)
                DEPTH_ENCODING="PCM ENTERO"
                if [ "$BITS" = "16" ]; then
                    DEPTH_STRICT="PCM ENTERO 16"
                else
                    DEPTH_STRICT="PROFUNDIDAD EFECTIVA NO DETERMINABLE - SILENCIO DIGITAL"
                fi
                printf "%s\t%s\n" "$RELATIVE" "$DEPTH_CONTAINER" >> "$INT_BITS_TEMP"
                ;;
            *)
                DEPTH_ENCODING="OTRO / NO PCM"
                DEPTH_STRICT="PROFUNDIDAD EFECTIVA NO DETERMINADA"
                ;;
        esac

        printf "%s\t0\t%s\t%s\t%s\n" "$RELATIVE" "$DURATION_SEC" "$DEPTH_ENCODING" "$DEPTH_CONTAINER" >> "$PROFILE_FILE_TEMP"
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            "$RELATIVE" "$DEPTH_ENCODING" "$DEPTH_CONTAINER" "$DEPTH_STRICT" \
            "$DEPTH_PATTERN" "$DEPTH_GRID_EXACT" "$DEPTH_GRID_WITHIN2" \
            "$DEPTH_GRID_RMS" "$DEPTH_VALID" "$DEPTH_ERROR" >> "$DEPTH_TEMP"

        # No tiene sentido clasificar un archivo silencioso como dual mono,
        # estéreo real ni compararlo como duplicado.
        continue
    fi


    # --------------------------------------------------------
    # PROFUNDIDAD EFECTIVA
    # --------------------------------------------------------

    # Sólo llega aquí audio con al menos una muestra distinta de cero.
    # Se mide externamente la llamada completa al helper.
    PROFILE_DEPTH_T0=$(now_ms)
    PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
    DEPTH_RAW="$(get_effective_depth "$FILE")"
    PROFILE_DEPTH_T1=$(now_ms)
    PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
    DEPTH_EXTERNAL_MS=$((PROFILE_DEPTH_T1-PROFILE_DEPTH_T0))
    [ "$DEPTH_EXTERNAL_MS" -lt 0 ] && DEPTH_EXTERNAL_MS=0
    PROFILE_DEPTH_MS=$((PROFILE_DEPTH_MS + DEPTH_EXTERNAL_MS))

    IFS=$'\t' read -r \
        DEPTH_VALID DEPTH_ENCODING DEPTH_CONTAINER DEPTH_VALID_BITS \
        DEPTH_STRICT DEPTH_PATTERN DEPTH_NONZERO DEPTH_COMMON_ZERO \
        DEPTH_GRID_EXACT DEPTH_GRID_WITHIN2 DEPTH_GRID_RMS \
        DEPTH_GRID_ENTROPY DEPTH_GRID_DISTINCT DEPTH_ERROR DEPTH_PROFILE_MS \
        <<< "$DEPTH_RAW"

    [ -z "$DEPTH_VALID" ] && DEPTH_VALID=0
    [ -z "$DEPTH_PROFILE_MS" ] && DEPTH_PROFILE_MS="NO_CONFIABLE"
    printf "%s\t%s\t%s\t%s\t%s\n" "$RELATIVE" "$DEPTH_EXTERNAL_MS" "$DURATION_SEC" "$DEPTH_ENCODING" "$DEPTH_CONTAINER" >> "$PROFILE_FILE_TEMP"

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$RELATIVE" "$DEPTH_ENCODING" "$DEPTH_CONTAINER" "$DEPTH_STRICT" \
        "$DEPTH_PATTERN" "$DEPTH_GRID_EXACT" "$DEPTH_GRID_WITHIN2" \
        "$DEPTH_GRID_RMS" "$DEPTH_VALID" "$DEPTH_ERROR" >> "$DEPTH_TEMP"

    if [ "$DEPTH_VALID" = "1" ] && [ "$DEPTH_ENCODING" = "PCM FLOAT" ]; then
        DEPTH_FLOAT=$((DEPTH_FLOAT + 1))
        printf "%s\t%s\n" "$RELATIVE" "$DEPTH_CONTAINER" >> "$FLOAT_TEMP"
    elif [ "$DEPTH_VALID" = "1" ] && [ "$DEPTH_ENCODING" = "PCM ENTERO" ]; then
        printf "%s\t%s\n" "$RELATIVE" "$DEPTH_CONTAINER" >> "$INT_BITS_TEMP"
    fi

    if [ "$DEPTH_VALID" != "1" ]; then
        DEPTH_ANALYSIS_ERRORS=$((DEPTH_ANALYSIS_ERRORS + 1))
    elif [ "$DEPTH_ENCODING" = "PCM FLOAT" ]; then
        :
    elif [ "$DEPTH_STRICT" = "16 BITS EFECTIVOS EN CONTENEDOR PCM DE 24" ]; then
        DEPTH_EXACT_24_TO_16=$((DEPTH_EXACT_24_TO_16 + 1))
    elif [ "$DEPTH_STRICT" = "24 BITS EFECTIVOS EN CONTENEDOR PCM ENTERO DE 32" ]; then
        DEPTH_EXACT_32_TO_24=$((DEPTH_EXACT_32_TO_24 + 1))
    elif [ "$DEPTH_STRICT" = "16 BITS EFECTIVOS EN CONTENEDOR PCM ENTERO DE 32" ]; then
        DEPTH_EXACT_32_TO_16=$((DEPTH_EXACT_32_TO_16 + 1))
    elif [ "$DEPTH_PATTERN" = "PATRON FUERTEMENTE COMPATIBLE CON CUANTIZACION PREVIA DE 16 BITS" ]; then
        DEPTH_STRONG=$((DEPTH_STRONG + 1))
    elif [ "$DEPTH_PATTERN" = "PATRON PARCIAL COMPATIBLE CON GRILLA DE 16 BITS" ]; then
        DEPTH_PARTIAL=$((DEPTH_PARTIAL + 1))
    fi


    if [ "$DUPLICATE_ANALYSIS_ENABLED" -eq 1 ]; then
    # --------------------------------------------------------
    # DATOS PARA DETECCIÓN DE DUPLICADOS
    #
    # Los archivos completamente silenciosos quedan fuera:
    # ya tienen su propio control y no aportan una comparación útil.
    # --------------------------------------------------------

    PROFILE_T0=$(now_ms)
    PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
    DUP_HASH=$(get_audio_hash "$FILE")
    PROFILE_T1=$(now_ms)
    PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
    DUP_HASH_DELTA=$((PROFILE_T1-PROFILE_T0))
    PROFILE_DUP_HASH_MS=$((PROFILE_DUP_HASH_MS + DUP_HASH_DELTA))
    PROFILE_DUP_PREP_MS=$((PROFILE_DUP_PREP_MS + DUP_HASH_DELTA))
    DUP_FP="SIN_FP"

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$FILE" \
        "$RELATIVE" \
        "$SAMPLE_RATE" \
        "$CHANNELS" \
        "$BITS" \
        "$DURATION_TS" \
        "$DURATION_SEC" \
        "$DUP_RMS" \
        "$DUP_HASH" \
        "$DUP_FP" >> "$DUP_META_TEMP"


    fi

    # --------------------------------------------------------
    # CONTROL DE NIVEL BAJO
    #
    # <= -60 dBFS:
    #     NIVEL EXTREMADAMENTE BAJO
    #
    # <= -20 dBFS y > -60 dBFS:
    #     NIVEL BAJO
    #
    # Ambos son avisos informativos. El archivo continúa con
    # la clasificación normal y no se modifica por este motivo.
    # --------------------------------------------------------

    IS_EXTREME_LOW=$(awk \
        -v peak="$PEAK_LEVEL" \
        -v threshold="$LOW_LEVEL_THRESHOLD" \
        'BEGIN {
            if (peak <= threshold) print 1;
            else print 0
        }'
    )

    if [ "$IS_EXTREME_LOW" -eq 1 ]; then

        NIVEL_EXTREMO=$((NIVEL_EXTREMO + 1))

        PEAK_DISPLAY=$(format_peak "$PEAK_LEVEL")

        echo "ADVERTENCIA: NIVEL EXTREMADAMENTE BAJO"
        echo "Pico máximo: $PEAK_DISPLAY"

        printf "%s\t%s\n" \
            "$RELATIVE" \
            "$PEAK_LEVEL" >> "$LOW_TEMP"

    else

        IS_LOW_WARNING=$(awk \
            -v peak="$PEAK_LEVEL" \
            -v threshold="$LOW_WARNING_THRESHOLD" \
            'BEGIN {
                if (peak <= threshold) print 1;
                else print 0
            }'
        )

        if [ "$IS_LOW_WARNING" -eq 1 ]; then

            NIVEL_BAJO=$((NIVEL_BAJO + 1))

            PEAK_DISPLAY=$(format_peak "$PEAK_LEVEL")

            echo "ADVERTENCIA: NIVEL BAJO"
            echo "Pico máximo: $PEAK_DISPLAY"

            printf "%s\t%s\n" \
                "$RELATIVE" \
                "$PEAK_LEVEL" >> "$LOW_WARNING_TEMP"
        fi
    fi


    # --------------------------------------------------------
    # Mono original
    # --------------------------------------------------------

    if [ "$CHANNELS" -eq 1 ]; then

        echo "MONO ORIGINAL -> SIN CAMBIOS"

        MONO_ORIGINAL=$((MONO_ORIGINAL + 1))
        printf "%s|MONO ORIGINAL|||\n" "$RELATIVE" >> "$CLASS_TEMP"

        continue
    fi


    # --------------------------------------------------------
    # Más de dos canales
    # --------------------------------------------------------

    if [ "$CHANNELS" -ne 2 ]; then

        echo "$CHANNELS CANALES -> PARA REVISAR"

        REVISAR=$((REVISAR + 1))
        echo "$RELATIVE|Archivo de $CHANNELS canales" >> "$REVIEW_TEMP"
        printf "%s|REVISAR|||Archivo de %s canales\n" "$RELATIVE" "$CHANNELS" >> "$CLASS_TEMP"

        continue
    fi


    # --------------------------------------------------------
    # RMS L / R
    # --------------------------------------------------------

    PROFILE_T0=$(now_ms)
    PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))

    # V2.12.18: reutilizar RMS L/R ya calculados por get_file_stats.
    # Sólo se vuelve al método anterior como salvaguarda si FFmpeg no entregó
    # alguna estadística de canal por una condición inesperada.
    if [ -n "$STAT_L_RMS" ] && [ "$STAT_L_RMS" != "-inf" ] && \
       [ -n "$STAT_R_RMS" ] && [ "$STAT_R_RMS" != "-inf" ]; then
        L_RMS="$STAT_L_RMS"
        R_RMS="$STAT_R_RMS"
        STEREO_RMS_REUSED_FILES=$((STEREO_RMS_REUSED_FILES + 1))
    else
        L_RMS=$(get_rms_channel "$FILE" 0)
        R_RMS=$(get_rms_channel "$FILE" 1)
    fi

    GAIN_COMP=$(awk -v l="$L_RMS" -v r="$R_RMS" 'BEGIN {
        printf "%.10f", r-l
    }')

    LEVEL_DIFF=$(awk -v l="$L_RMS" -v r="$R_RMS" 'BEGIN {
        d=l-r;
        if (d<0) d=-d;
        printf "%.10f", d
    }')


    # --------------------------------------------------------
    # Residual
    # --------------------------------------------------------

    RESIDUAL=$(get_residual "$FILE" "$GAIN_COMP")

    MAX_RMS=$(awk -v l="$L_RMS" -v r="$R_RMS" 'BEGIN {
        if (l > r) print l;
        else print r
    }')

    RELATIVE_RESIDUAL=$(awk \
        -v residual="$RESIDUAL" \
        -v max="$MAX_RMS" \
        'BEGIN {
            printf "%.10f", residual-max
        }'
    )

    LEVEL_DIFF_DISPLAY=$(format_level_diff "$LEVEL_DIFF")
    RESIDUAL_DISPLAY=$(format_residual "$RELATIVE_RESIDUAL")
    CORRELATION_EST=$(estimate_correlation_from_residual "$RELATIVE_RESIDUAL")


    # --------------------------------------------------------
    # Canal de mayor nivel
    # --------------------------------------------------------

    KEEP_CHANNEL=$(awk -v l="$L_RMS" -v r="$R_RMS" 'BEGIN {
        if (l >= r) print 0;
        else print 1
    }')

    if [ "$KEEP_CHANNEL" -eq 0 ]; then
        CHANNEL_NAME="L"
    else
        CHANNEL_NAME="R"
    fi


    BASE="${FILE_NAME%.*}"
    EXT="${FILE_NAME##*.}"

    NEW_NAME="$BASE [MONO].$EXT"

    # CODEC ya proviene de la lectura única de FFprobe al inicio del archivo.

    PROFILE_T1=$(now_ms)
    PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
    PROFILE_STEREO_MS=$((PROFILE_STEREO_MS + PROFILE_T1 - PROFILE_T0))


    if [ "$REL_DIR" = "." ]; then
        CONVERT_OUT_DIR="$CONVERT_DIR"
        NEW_RELATIVE="$NEW_NAME"
    else
        CONVERT_OUT_DIR="$CONVERT_DIR/$REL_DIR"
        NEW_RELATIVE="$REL_DIR/$NEW_NAME"
    fi

    mkdir -p "$CONVERT_OUT_DIR"


    # --------------------------------------------------------
    # DUAL MONO
    # --------------------------------------------------------

    IS_DUAL_MONO=$(awk \
        -v diff="$LEVEL_DIFF" \
        -v residual="$RELATIVE_RESIDUAL" \
        -v maxdiff="$DUAL_MONO_MAX_LEVEL_DIFF" \
        -v maxres="$DUAL_MONO_MAX_RESIDUAL" \
        'BEGIN {
            if (diff < maxdiff && residual <= maxres) print 1;
            else print 0
        }'
    )

    if [ "$IS_DUAL_MONO" -eq 1 ]; then

        PROFILE_T0=$(now_ms)
PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
convert_to_mono \
            "$FILE" \
            "$KEEP_CHANNEL" \
            "$CODEC" \
            "$CONVERT_OUT_DIR/$NEW_NAME"



        CONVERT_STATUS=$?


        PROFILE_T1=$(now_ms)
PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
PROFILE_CONVERT_MS=$((PROFILE_CONVERT_MS + PROFILE_T1 - PROFILE_T0))

if [ "$CONVERT_STATUS" -ne 0 ]; then

            echo "ERROR AL CONVERTIR -> PARA REVISAR"

            rm -f "$CONVERT_OUT_DIR/$NEW_NAME"

            REVISAR=$((REVISAR + 1))
            CONVERSION_ERRORS=$((CONVERSION_ERRORS + 1))
            echo "$RELATIVE|Error de conversión" >> "$REVIEW_TEMP"
            printf "%s|REVISAR|||Error de conversión\n" "$RELATIVE" >> "$CLASS_TEMP"

            continue
        fi

        printf "%s\t%s\n" "$RELATIVE" "$NEW_RELATIVE" >> "$CONVERSION_MAP"

        echo "DUAL MONO -> CONVERTIDO A MONO"
        echo "Canal conservado: $CHANNEL_NAME"
        echo "Diferencia L/R: $LEVEL_DIFF_DISPLAY"
        echo "Residual relativo: $RESIDUAL_DISPLAY"
        echo "Nuevo archivo: $NEW_NAME"

        DUAL_MONO=$((DUAL_MONO + 1))

        printf "%s\t%s\t%s\t%s\t%s\n" \
            "DUAL MONO" "$RELATIVE" "$NEW_RELATIVE" "$CHANNEL_NAME" "$LEVEL_DIFF_DISPLAY" >> "$CHANGES_TEMP"
        printf "%s|DUAL MONO EXACTO|%s|%s|\n" "$RELATIVE" "$CHANNEL_NAME" "$NEW_RELATIVE" >> "$CLASS_TEMP"

        continue
    fi


    # --------------------------------------------------------
    # MONO PANEADO
    # --------------------------------------------------------

    IS_MONO_PAN=$(awk \
        -v diff="$LEVEL_DIFF" \
        -v residual="$RELATIVE_RESIDUAL" \
        -v mindiff="$DUAL_MONO_MAX_LEVEL_DIFF" \
        -v maxres="$MONO_PAN_MAX_RESIDUAL" \
        'BEGIN {
            if (diff >= mindiff && residual <= maxres) print 1;
            else print 0
        }'
    )

    if [ "$IS_MONO_PAN" -eq 1 ]; then

        PROFILE_T0=$(now_ms)
PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
convert_to_mono \
            "$FILE" \
            "$KEEP_CHANNEL" \
            "$CODEC" \
            "$CONVERT_OUT_DIR/$NEW_NAME"



        CONVERT_STATUS=$?


        PROFILE_T1=$(now_ms)
PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
PROFILE_CONVERT_MS=$((PROFILE_CONVERT_MS + PROFILE_T1 - PROFILE_T0))

if [ "$CONVERT_STATUS" -ne 0 ]; then

            echo "ERROR AL CONVERTIR -> PARA REVISAR"

            rm -f "$CONVERT_OUT_DIR/$NEW_NAME"

            REVISAR=$((REVISAR + 1))
            CONVERSION_ERRORS=$((CONVERSION_ERRORS + 1))
            echo "$RELATIVE|Error de conversión" >> "$REVIEW_TEMP"
            printf "%s|REVISAR|||Error de conversión\n" "$RELATIVE" >> "$CLASS_TEMP"

            continue
        fi

        printf "%s\t%s\n" "$RELATIVE" "$NEW_RELATIVE" >> "$CONVERSION_MAP"

        echo "MONO PANEADO -> CONVERTIDO A MONO"
        echo "Canal conservado: $CHANNEL_NAME"
        echo "Diferencia L/R: $LEVEL_DIFF_DISPLAY"
        echo "Residual relativo: $RESIDUAL_DISPLAY"
        echo "Nuevo archivo: $NEW_NAME"

        MONO_PANEADO=$((MONO_PANEADO + 1))

        printf "%s\t%s\t%s\t%s\t%s\n" \
            "MONO PANEADO" "$RELATIVE" "$NEW_RELATIVE" "$CHANNEL_NAME" "$LEVEL_DIFF_DISPLAY" >> "$CHANGES_TEMP"
        printf "%s|MONO PANEADO|%s|%s|\n" "$RELATIVE" "$CHANNEL_NAME" "$NEW_RELATIVE" >> "$CLASS_TEMP"

        continue
    fi


    # --------------------------------------------------------
    # DUAL MONO PRÁCTICO
    # --------------------------------------------------------
    # L y R no son copias matemáticamente idénticas, pero la diferencia
    # queda suficientemente por debajo de la señal como para considerarlos
    # mono a efectos prácticos. Para evitar falsos positivos se exige que
    # se cumplan simultáneamente: correlación extrema, diferencia de nivel
    # mínima y residual relativo bajo.

    IS_PRACTICAL_DUAL=$(awk \
        -v diff="$LEVEL_DIFF" \
        -v residual="$RELATIVE_RESIDUAL" \
        -v corr="$CORRELATION_EST" \
        -v maxdiff="$PRACTICAL_DUAL_MAX_LEVEL_DIFF" \
        -v maxres="$PRACTICAL_DUAL_MAX_RESIDUAL" \
        -v mincorr="$PRACTICAL_DUAL_MIN_CORRELATION" \
        'BEGIN {
            if (diff <= maxdiff && residual <= maxres && corr >= mincorr) print 1;
            else print 0
        }'
    )

    if [ "$IS_PRACTICAL_DUAL" -eq 1 ]; then

        PROFILE_T0=$(now_ms)
PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
convert_to_mono \
            "$FILE" \
            "$KEEP_CHANNEL" \
            "$CODEC" \
            "$CONVERT_OUT_DIR/$NEW_NAME"



        CONVERT_STATUS=$?


        PROFILE_T1=$(now_ms)
PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
PROFILE_CONVERT_MS=$((PROFILE_CONVERT_MS + PROFILE_T1 - PROFILE_T0))

if [ "$CONVERT_STATUS" -ne 0 ]; then

            echo "ERROR AL CONVERTIR -> PARA REVISAR"

            rm -f "$CONVERT_OUT_DIR/$NEW_NAME"

            REVISAR=$((REVISAR + 1))
            CONVERSION_ERRORS=$((CONVERSION_ERRORS + 1))
            echo "$RELATIVE|Error de conversión" >> "$REVIEW_TEMP"
            printf "%s|REVISAR|||Error de conversión\n" "$RELATIVE" >> "$CLASS_TEMP"

            continue
        fi

        printf "%s\t%s\n" "$RELATIVE" "$NEW_RELATIVE" >> "$CONVERSION_MAP"

        echo "DUAL MONO PRÁCTICO -> CONVERTIDO A MONO"
        echo "Canal conservado: $CHANNEL_NAME"
        echo "Correlación L/R aprox.: $CORRELATION_EST"
        echo "Diferencia L/R: $LEVEL_DIFF_DISPLAY"
        echo "Residual relativo: $RESIDUAL_DISPLAY"
        echo "Nuevo archivo: $NEW_NAME"

        DUAL_MONO_PRACTICO=$((DUAL_MONO_PRACTICO + 1))

        printf "%s\t%s\t%s\t%s\t%s\n" \
            "DUAL MONO PRÁCTICO" "$RELATIVE" "$NEW_RELATIVE" "$CHANNEL_NAME" "$LEVEL_DIFF_DISPLAY" >> "$CHANGES_TEMP"
        printf "%s|DUAL MONO PRÁCTICO|%s|%s|\n" "$RELATIVE" "$CHANNEL_NAME" "$NEW_RELATIVE" >> "$CLASS_TEMP"

        continue
    fi


    # --------------------------------------------------------
    # POSIBLE MONO / ESTÉREO ALTAMENTE CORRELACIONADO
    # --------------------------------------------------------
    # Caso preventivo: canales extremadamente similares, pero no lo
    # suficiente para una conversión automática segura. Se conserva
    # el estéreo y se informa para escucha/revisión manual.

    IS_HIGH_CORR=$(awk \
        -v diff="$LEVEL_DIFF" \
        -v residual="$RELATIVE_RESIDUAL" \
        -v corr="$CORRELATION_EST" \
        -v maxdiff="$HIGH_CORR_MAX_LEVEL_DIFF" \
        -v maxres="$HIGH_CORR_MAX_RESIDUAL" \
        -v mincorr="$HIGH_CORR_MIN_CORRELATION" \
        'BEGIN {
            if (diff <= maxdiff && residual <= maxres && corr >= mincorr) print 1;
            else print 0
        }'
    )

    if [ "$IS_HIGH_CORR" -eq 1 ]; then

        echo "POSIBLE MONO / ESTÉREO ALTAMENTE CORRELACIONADO -> PARA REVISAR"
        echo "Correlación L/R aprox.: $CORRELATION_EST"
        echo "Diferencia L/R: $LEVEL_DIFF_DISPLAY"
        echo "Residual relativo: $RESIDUAL_DISPLAY"

        HIGH_CORR_REVIEW=$((HIGH_CORR_REVIEW + 1))
        REVISAR=$((REVISAR + 1))

        REASON="Posible mono / estéreo altamente correlacionado | correlación L/R ≈ $CORRELATION_EST | diferencia L-R: $LEVEL_DIFF_DISPLAY"
        echo "$RELATIVE|$REASON" >> "$REVIEW_TEMP"
        printf "%s|REVISAR|||%s\n" "$RELATIVE" "$REASON" >> "$CLASS_TEMP"

        continue
    fi


    # --------------------------------------------------------
    # PARA REVISAR
    # --------------------------------------------------------

    IS_REVIEW=$(awk \
        -v residual="$RELATIVE_RESIDUAL" \
        -v maxres="$REVIEW_MAX_RESIDUAL" \
        'BEGIN {
            if (residual <= maxres) print 1;
            else print 0
        }'
    )

    if [ "$IS_REVIEW" -eq 1 ]; then

        echo "PARA REVISAR -> SIN CAMBIOS"

        REVISAR=$((REVISAR + 1))

        REASON="Residual: $RESIDUAL_DISPLAY / Diferencia L-R: $LEVEL_DIFF_DISPLAY"
        echo "$RELATIVE|$REASON" >> "$REVIEW_TEMP"
        printf "%s|REVISAR|||%s\n" "$RELATIVE" "$REASON" >> "$CLASS_TEMP"

        continue
    fi


    # --------------------------------------------------------
    # STEREO REAL
    # --------------------------------------------------------

    echo "STEREO REAL -> SIN CAMBIOS"

    STEREO_REAL=$((STEREO_REAL + 1))
    printf "%s|ESTÉREO REAL|||\n" "$RELATIVE" >> "$CLASS_TEMP"


done < "$WAV_LIST_FILE"

PROFILE_ANALYSIS_T1=$(now_ms)
PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
PROFILE_ANALYSIS_MS=$((PROFILE_ANALYSIS_T1-PROFILE_ANALYSIS_T0))

progress_update 90 "Control de sesión" "Revisando formato, duración y consistencia."
PROFILE_FORMAT_T0=$(now_ms)
PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))

# ============================================================
# CONTROL GLOBAL DE FORMATO Y DURACIÓN
# ============================================================

if [ "$TOTAL" -gt 0 ]; then

    REF_SAMPLE_RATE=$(
        cut -f2 "$META_TEMP" |
        grep -v '^DESCONOCIDO$' |
        sort |
        uniq -c |
        sort -nr |
        head -1 |
        awk '{print $2}'
    )

    REF_BITS=$(
        cut -f2 "$INT_BITS_TEMP" |
        grep -v '^DESCONOCIDO$' |
        sort |
        uniq -c |
        sort -nr |
        head -1 |
        awk '{print $2}'
    )

    # La duración de referencia se toma dentro del sample rate
    # predominante. Así duration_ts siempre representa muestras
    # sobre una misma frecuencia de muestreo.
    REF_DURATION_TS=$(
        awk -F '\t' -v sr="$REF_SAMPLE_RATE" '
        $2 == sr && $4 != "DESCONOCIDO" { print $4 }
        ' "$META_TEMP" |
        sort |
        uniq -c |
        sort -nr |
        head -1 |
        awk '{print $2}'
    )

    if [ -n "$REF_DURATION_TS" ] &&
       [ "$REF_DURATION_TS" != "DESCONOCIDO" ] &&
       [ "$REF_SAMPLE_RATE" != "DESCONOCIDO" ]; then

        REF_DURATION_SEC=$(awk \
            -v ts="$REF_DURATION_TS" \
            -v sr="$REF_SAMPLE_RATE" \
            'BEGIN {
                printf "%.12f", ts/sr
            }'
        )

    else
        REF_DURATION_SEC="DESCONOCIDO"
    fi

    [ -z "$REF_SAMPLE_RATE" ] && REF_SAMPLE_RATE="DESCONOCIDO"
    [ -z "$REF_BITS" ] && REF_BITS="DESCONOCIDO"
    [ -z "$REF_DURATION_TS" ] && REF_DURATION_TS="DESCONOCIDO"
    [ -z "$REF_DURATION_SEC" ] && REF_DURATION_SEC="DESCONOCIDO"

    REF_SR_DISPLAY=$(format_sample_rate "$REF_SAMPLE_RATE")
    REF_DURATION_DISPLAY=$(format_duration "$REF_DURATION_SEC")



    # --------------------------------------------------------
    # SAMPLE RATE
    # --------------------------------------------------------

    SR_TEMP="$WORK_DIR/.sample_rate_errors.tmp"
    : > "$SR_TEMP"

    while IFS=$'\t' read -r META_FILE META_SR META_BITS META_TS META_SEC
    do

        if [ "$META_SR" != "$REF_SAMPLE_RATE" ]; then

            SAMPLE_RATE_ERRORS=$((SAMPLE_RATE_ERRORS + 1))

            printf "%s\t%s\n" \
                "$META_FILE" \
                "$META_SR" >> "$SR_TEMP"
        fi

    done < "$META_TEMP"


    # --------------------------------------------------------
    # PROFUNDIDAD DE BITS
    # --------------------------------------------------------

    BITS_TEMP="$WORK_DIR/.bits_errors.tmp"
    : > "$BITS_TEMP"

    while IFS=$'\t' read -r META_FILE META_BITS
    do

        [ -z "$META_FILE" ] && continue
        [ -z "$REF_BITS" ] && continue

        if [ "$META_BITS" != "$REF_BITS" ]; then

            BITS_ERRORS=$((BITS_ERRORS + 1))

            printf "%s\t%s\n" \
                "$META_FILE" \
                "$META_BITS" >> "$BITS_TEMP"
        fi

    done < "$INT_BITS_TEMP"


    # --------------------------------------------------------
    # LONGITUD
    # --------------------------------------------------------

    DURATION_TEMP="$WORK_DIR/.duration_errors.tmp"
    : > "$DURATION_TEMP"

    while IFS=$'\t' read -r META_FILE META_SR META_BITS META_TS META_SEC
    do

        DURATION_IS_DIFFERENT=0
        SAMPLE_DIFF="DESCONOCIDO"
        MS_DIFF="DESCONOCIDO"

        if [ "$META_TS" = "DESCONOCIDO" ] ||
           [ "$META_SR" = "DESCONOCIDO" ] ||
           [ "$REF_DURATION_TS" = "DESCONOCIDO" ] ||
           [ "$REF_SAMPLE_RATE" = "DESCONOCIDO" ]; then

            if [ "$META_SEC" != "DESCONOCIDO" ] &&
               [ "$REF_DURATION_SEC" != "DESCONOCIDO" ]; then

                MS_DIFF=$(awk \
                    -v a="$META_SEC" \
                    -v b="$REF_DURATION_SEC" \
                    'BEGIN {
                        printf "%.10f", (a-b)*1000
                    }'
                )

                DURATION_IS_DIFFERENT=$(awk \
                    -v ms="$MS_DIFF" \
                    'BEGIN {
                        if (ms < 0) ms=-ms
                        if (ms > 0.001) print 1
                        else print 0
                    }'
                )
            fi

        elif [ "$META_SR" = "$REF_SAMPLE_RATE" ]; then

            # Con el mismo sample rate conservamos el criterio
            # exacto: una sola muestra de diferencia se informa.
            if [ "$META_TS" != "$REF_DURATION_TS" ]; then

                DURATION_IS_DIFFERENT=1
                SAMPLE_DIFF=$((META_TS - REF_DURATION_TS))

                MS_DIFF=$(awk \
                    -v samples="$SAMPLE_DIFF" \
                    -v sr="$META_SR" \
                    'BEGIN {
                        printf "%.10f", (samples/sr)*1000
                    }'
                )
            fi

        else

            # Con sample rates distintos no se comparan duration_ts
            # directamente. Se compara tiempo real:
            #
            # duración = muestras / sample rate
            #
            # Se admite la mínima diferencia inevitable al cuantizar
            # el mismo instante sobre dos grillas distintas.
            TIME_DIFF_SEC=$(awk \
                -v ts="$META_TS" \
                -v sr="$META_SR" \
                -v rts="$REF_DURATION_TS" \
                -v rsr="$REF_SAMPLE_RATE" \
                'BEGIN {
                    printf "%.15f", (ts/sr)-(rts/rsr)
                }'
            )

            TOLERANCE_SEC=$(awk \
                -v sr="$META_SR" \
                -v rsr="$REF_SAMPLE_RATE" \
                'BEGIN {
                    printf "%.15f", (0.5/sr)+(0.5/rsr)
                }'
            )

            DURATION_IS_DIFFERENT=$(awk \
                -v d="$TIME_DIFF_SEC" \
                -v t="$TOLERANCE_SEC" \
                'BEGIN {
                    if (d < 0) d=-d
                    if (d > t) print 1
                    else print 0
                }'
            )

            MS_DIFF=$(awk \
                -v d="$TIME_DIFF_SEC" \
                'BEGIN {
                    printf "%.10f", d*1000
                }'
            )
        fi


        if [ "$DURATION_IS_DIFFERENT" -eq 1 ]; then

            DURATION_ERRORS=$((DURATION_ERRORS + 1))

            printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
                "$META_FILE" \
                "$META_SR" \
                "$META_TS" \
                "$META_SEC" \
                "$SAMPLE_DIFF" \
                "$MS_DIFF" >> "$DURATION_TEMP"
        fi

    done < "$META_TEMP"


fi


PROFILE_FORMAT_T1=$(now_ms)
PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
PROFILE_FORMAT_MS=$((PROFILE_FORMAT_T1-PROFILE_FORMAT_T0))
if [ "$DUPLICATE_ANALYSIS_ENABLED" -eq 1 ]; then
PROFILE_DUP_T0=$(now_ms)
PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))

# ============================================================
# DETECCIÓN OPTIMIZADA DE PISTAS DUPLICADAS
#
# Etapa 1: solo compara archivos técnicamente compatibles.
# Etapa 2: usa hash para duplicados exactos.
# Etapa 3: solo cuando el hash difiere, compara señal compensando
#          la diferencia de nivel.
#
# No modifica ni elimina ningún archivo.
# ============================================================

DUP_FULL=()
DUP_REL=()
DUP_SR=()
DUP_CH=()
DUP_BITS=()
DUP_DUR=()
DUP_DUR_SEC=()
DUP_RMS=()
DUP_HASH=()
DUP_FP=()
DUP_PARENT=()

DUP_INDEX=0

while IFS=$'\t' read -r D_FULL D_REL D_SR D_CH D_BITS D_DUR D_DUR_SEC D_RMS D_HASH D_FP
do
    DUP_FULL[$DUP_INDEX]="$D_FULL"
    DUP_REL[$DUP_INDEX]="$D_REL"
    DUP_SR[$DUP_INDEX]="$D_SR"
    DUP_CH[$DUP_INDEX]="$D_CH"
    DUP_BITS[$DUP_INDEX]="$D_BITS"
    DUP_DUR[$DUP_INDEX]="$D_DUR"
    DUP_DUR_SEC[$DUP_INDEX]="$D_DUR_SEC"
    DUP_RMS[$DUP_INDEX]="$D_RMS"
    DUP_HASH[$DUP_INDEX]="$D_HASH"
    DUP_FP[$DUP_INDEX]="$D_FP"
    DUP_PARENT[$DUP_INDEX]="$DUP_INDEX"

    DUP_INDEX=$((DUP_INDEX + 1))

done < "$DUP_META_TEMP"

DUP_COUNT=${#DUP_FULL[@]}

# Cantidad REAL de pares que superan el filtro técnico previo.
# Se usa en la ventana de progreso en lugar de mostrar todas las
# combinaciones teóricas posibles.
DUP_EFFECTIVE_TOTAL=0
if [ "$DUP_COUNT" -gt 1 ]; then
    for ((pi=0; pi<DUP_COUNT; pi++)); do
        for ((pj=pi+1; pj<DUP_COUNT; pj++)); do
            if [ "${DUP_SR[$pi]}" = "${DUP_SR[$pj]}" ] &&
               [ "${DUP_CH[$pi]}" = "${DUP_CH[$pj]}" ] &&
               [ "${DUP_BITS[$pi]}" = "${DUP_BITS[$pj]}" ] &&
               [ "${DUP_DUR[$pi]}" = "${DUP_DUR[$pj]}" ] &&
               [ "${DUP_SR[$pi]}" != "DESCONOCIDO" ] &&
               [ "${DUP_BITS[$pi]}" != "DESCONOCIDO" ] &&
               [ "${DUP_DUR[$pi]}" != "DESCONOCIDO" ]; then
                DUP_EFFECTIVE_TOTAL=$((DUP_EFFECTIVE_TOTAL + 1))
            fi
        done
    done
fi

DUP_NONHASH_CANDIDATE_PAIRS=0
DUP_FP_MODE="OMITIDO"
DUP_FP_FILES=0
DUP_FP_NEEDED=()
for ((pi=0; pi<DUP_COUNT; pi++)); do DUP_FP_NEEDED[$pi]=0; done

if [ "$DUP_COUNT" -gt 1 ]; then
    for ((pi=0; pi<DUP_COUNT; pi++)); do
        for ((pj=pi+1; pj<DUP_COUNT; pj++)); do
            if [ "${DUP_SR[$pi]}" = "${DUP_SR[$pj]}" ] &&
               [ "${DUP_CH[$pi]}" = "${DUP_CH[$pj]}" ] &&
               [ "${DUP_BITS[$pi]}" = "${DUP_BITS[$pj]}" ] &&
               [ "${DUP_DUR[$pi]}" = "${DUP_DUR[$pj]}" ] &&
               [ "${DUP_SR[$pi]}" != "DESCONOCIDO" ] &&
               [ "${DUP_BITS[$pi]}" != "DESCONOCIDO" ] &&
               [ "${DUP_DUR[$pi]}" != "DESCONOCIDO" ]; then
                if [ "${DUP_HASH[$pi]}" = "SIN_HASH" ] ||
                   [ "${DUP_HASH[$pj]}" = "SIN_HASH" ] ||
                   [ "${DUP_HASH[$pi]}" != "${DUP_HASH[$pj]}" ]; then
                    DUP_NONHASH_CANDIDATE_PAIRS=$((DUP_NONHASH_CANDIDATE_PAIRS + 1))
                    DUP_FP_NEEDED[$pi]=1
                    DUP_FP_NEEDED[$pj]=1
                fi
            fi
        done
    done
fi

if [ "$DUP_NONHASH_CANDIDATE_PAIRS" -ge "$DUP_FP_MIN_NONHASH_PAIRS" ]; then
    DUP_FP_MODE="ACTIVO"
    for ((pi=0; pi<DUP_COUNT; pi++)); do
        if [ "${DUP_FP_NEEDED[$pi]}" -eq 1 ]; then
            PROFILE_T0=$(now_ms)
            PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
            DUP_FP[$pi]=$(get_quick_fingerprint "${DUP_FULL[$pi]}" "${DUP_DUR_SEC[$pi]}")
            PROFILE_T1=$(now_ms)
            PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
            DUP_FP_DELTA=$((PROFILE_T1-PROFILE_T0))
            PROFILE_DUP_FP_MS=$((PROFILE_DUP_FP_MS + DUP_FP_DELTA))
            PROFILE_DUP_PREP_MS=$((PROFILE_DUP_PREP_MS + DUP_FP_DELTA))
            DUP_FP_FILES=$((DUP_FP_FILES + 1))
        fi
    done
fi

DUP_EFFECTIVE_INDEX=0
DUP_LAST_PROGRESS=-1

progress_update 80 "Buscando pistas duplicadas" "Comparaciones efectivas: 0 de $DUP_EFFECTIVE_TOTAL"


dup_find_root() {

    local X="$1"

    while [ "${DUP_PARENT[$X]}" -ne "$X" ]
    do
        X="${DUP_PARENT[$X]}"
    done

    echo "$X"
}


dup_union() {

    local A="$1"
    local B="$2"

    local ROOT_A
    local ROOT_B

    ROOT_A=$(dup_find_root "$A")
    ROOT_B=$(dup_find_root "$B")

    if [ "$ROOT_A" -ne "$ROOT_B" ]; then
        DUP_PARENT[$ROOT_B]="$ROOT_A"
    fi
}


if [ "$DUP_COUNT" -gt 1 ]; then

    for ((i=0; i<DUP_COUNT; i++))
    do
        for ((j=i+1; j<DUP_COUNT; j++))
        do

            # ------------------------------------------------
            # Filtro previo: si estos datos no coinciden,
            # no se hace ninguna comparación de señal.
            # ------------------------------------------------

            if [ "${DUP_SR[$i]}" != "${DUP_SR[$j]}" ] ||
               [ "${DUP_CH[$i]}" != "${DUP_CH[$j]}" ] ||
               [ "${DUP_BITS[$i]}" != "${DUP_BITS[$j]}" ] ||
               [ "${DUP_DUR[$i]}" != "${DUP_DUR[$j]}" ]; then
                continue
            fi

            if [ "${DUP_SR[$i]}" = "DESCONOCIDO" ] ||
               [ "${DUP_BITS[$i]}" = "DESCONOCIDO" ] ||
               [ "${DUP_DUR[$i]}" = "DESCONOCIDO" ]; then
                continue
            fi

            DUP_EFFECTIVE_INDEX=$((DUP_EFFECTIVE_INDEX + 1))
            if [ "$DUP_EFFECTIVE_TOTAL" -gt 0 ]; then
                DUP_PROGRESS=$((80 + (DUP_EFFECTIVE_INDEX * 17 / DUP_EFFECTIVE_TOTAL)))
                if [ "$DUP_PROGRESS" -ne "$DUP_LAST_PROGRESS" ]; then
                    progress_update "$DUP_PROGRESS" "Buscando pistas duplicadas" "Comparaciones efectivas: $DUP_EFFECTIVE_INDEX de $DUP_EFFECTIVE_TOTAL"
                    DUP_LAST_PROGRESS="$DUP_PROGRESS"
                fi
            fi

            # ------------------------------------------------
            # Duplicado exacto de audio:
            # mismo hash con mismo formato técnico.
            # ------------------------------------------------

            if [ "${DUP_HASH[$i]}" != "SIN_HASH" ] &&
               [ "${DUP_HASH[$i]}" = "${DUP_HASH[$j]}" ]; then

                dup_union "$i" "$j"
                DUP_EXACT_HASH_MATCHES=$((DUP_EXACT_HASH_MATCHES + 1))

                printf "%s\t%s\tEXACTO\t0\t-999\n" \
                    "$i" "$j" >> "$DUP_PAIR_TEMP"

                continue
            fi

            # ------------------------------------------------
            # Prefiltro rápido por fingerprint (~20/50/80%).
            # Si la forma dinámica no coincide, descartamos el par
            # sin hacer la comparación completa de señal.
            # ------------------------------------------------

            if [ "$DUP_FP_MODE" = "ACTIVO" ]; then
                DUP_PREFILTER_RUN=$((DUP_PREFILTER_RUN + 1))
                FP_RESULT=$(fingerprint_compare "${DUP_FP[$i]}" "${DUP_FP[$j]}")
                if [ "$FP_RESULT" = "0" ]; then
                    DUP_PREFILTER_DISCARDED=$((DUP_PREFILTER_DISCARDED + 1))
                    continue
                fi
            fi

            # ------------------------------------------------
            # Para diferencias de nivel hacemos comparación
            # de señal solo en mono o stereo.
            # ------------------------------------------------

            if [ "${DUP_CH[$i]}" -ne 1 ] &&
               [ "${DUP_CH[$i]}" -ne 2 ]; then
                continue
            fi

            if [ "${DUP_RMS[$i]}" = "-999" ] ||
               [ "${DUP_RMS[$j]}" = "-999" ]; then
                continue
            fi

            DUP_GAIN=$(awk \
                -v a="${DUP_RMS[$i]}" \
                -v b="${DUP_RMS[$j]}" \
                'BEGIN {
                    printf "%.10f", b-a
                }'
            )

            DUP_LEVEL_DIFF=$(awk \
                -v a="${DUP_RMS[$i]}" \
                -v b="${DUP_RMS[$j]}" \
                'BEGIN {
                    d=a-b
                    if (d<0) d=-d
                    printf "%.10f", d
                }'
            )

            DUP_FULL_COMPARISONS=$((DUP_FULL_COMPARISONS + 1))

            DUP_RESIDUAL=$(get_duplicate_residual \
                "${DUP_FULL[$i]}" \
                "${DUP_FULL[$j]}" \
                "${DUP_CH[$i]}" \
                "$DUP_GAIN"
            )

            DUP_REL_RES=$(awk \
                -v residual="$DUP_RESIDUAL" \
                -v ref="${DUP_RMS[$j]}" \
                'BEGIN {
                    printf "%.10f", residual-ref
                }'
            )

            DUP_IS_MATCH=$(awk \
                -v residual="$DUP_REL_RES" \
                -v threshold="$DUPLICATE_MAX_RESIDUAL" \
                'BEGIN {
                    if (residual <= threshold) print 1
                    else print 0
                }'
            )

            if [ "$DUP_IS_MATCH" -eq 1 ]; then

                dup_union "$i" "$j"
                DUP_SIGNAL_MATCHES=$((DUP_SIGNAL_MATCHES + 1))

                DUP_SAME_LEVEL=$(awk \
                    -v diff="$DUP_LEVEL_DIFF" \
                    -v threshold="$DUPLICATE_SAME_LEVEL_DIFF" \
                    'BEGIN {
                        if (diff < threshold) print 1
                        else print 0
                    }'
                )

                if [ "$DUP_SAME_LEVEL" -eq 1 ]; then
                    DUP_TYPE="EXACTO"
                else
                    DUP_TYPE="NIVEL"
                fi

                printf "%s\t%s\t%s\t%s\t%s\n" \
                    "$i" \
                    "$j" \
                    "$DUP_TYPE" \
                    "$DUP_GAIN" \
                    "$DUP_REL_RES" >> "$DUP_PAIR_TEMP"
            fi

        done
    done

fi


# ------------------------------------------------------------
# Consolidar raíces luego de las uniones
# ------------------------------------------------------------

for ((i=0; i<DUP_COUNT; i++))
do
    DUP_PARENT[$i]=$(dup_find_root "$i")
done


# ------------------------------------------------------------
# Contar grupos y archivos adicionales
# ------------------------------------------------------------

for ((i=0; i<DUP_COUNT; i++))
do

    ROOT="${DUP_PARENT[$i]}"

    # Solo la primera aparición de cada raíz calcula el grupo.
    ALREADY_COUNTED=0

    for ((k=0; k<i; k++))
    do
        if [ "${DUP_PARENT[$k]}" -eq "$ROOT" ]; then
            ALREADY_COUNTED=1
            break
        fi
    done

    if [ "$ALREADY_COUNTED" -eq 1 ]; then
        continue
    fi

    MEMBERS=0

    for ((j=0; j<DUP_COUNT; j++))
    do
        if [ "${DUP_PARENT[$j]}" -eq "$ROOT" ]; then
            MEMBERS=$((MEMBERS + 1))
        fi
    done

    if [ "$MEMBERS" -gt 1 ]; then
        DUP_GROUPS=$((DUP_GROUPS + 1))
        DUP_EXTRA_FILES=$((DUP_EXTRA_FILES + MEMBERS - 1))
    fi

done



PROFILE_DUP_T1=$(now_ms)
PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
PROFILE_DUPLICATES_MS=$((PROFILE_DUP_T1-PROFILE_DUP_T0))
else
    # V2.12.18: se omite por completo la detección de duplicados.
    # No se leen metadatos de candidatos, no se calculan pares elegibles,
    # no se ejecutan hashes/fingerprints y no se comparan señales entre archivos.
    DUP_FULL=(); DUP_REL=(); DUP_SR=(); DUP_CH=(); DUP_BITS=(); DUP_DUR=()
    DUP_DUR_SEC=(); DUP_RMS=(); DUP_HASH=(); DUP_FP=(); DUP_PARENT=()
    DUP_COUNT=0
    DUP_THEORETICAL_TOTAL=0
    DUP_EFFECTIVE_TOTAL=0
    DUP_NONHASH_CANDIDATE_PAIRS=0
    DUP_FP_MODE="DESACTIVADO TEMPORALMENTE"
    DUP_FP_FILES=0
    DUP_PREFILTER_RUN=0
    DUP_PREFILTER_DISCARDED=0
    DUP_FULL_COMPARISONS=0
    DUP_GROUPS=0
    DUP_EXTRA_FILES=0
    DUP_EXACT_HASH_MATCHES=0
    DUP_SIGNAL_MATCHES=0
    PROFILE_DUP_PREP_MS=0
    PROFILE_DUP_HASH_MS=0
    PROFILE_DUP_FP_MS=0
    PROFILE_DUPLICATES_MS=0
fi

PROFILE_REPORT_T0=$(now_ms)
PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))

# ============================================================
# INFORMES BÁSICO, DETALLADO Y TÉCNICO DE DESARROLLO
# ============================================================

progress_update 91 "Preparando informes" "Organizando resultados del análisis"

CONVERSION_TOTAL=$((DUAL_MONO + DUAL_MONO_PRACTICO + MONO_PANEADO))
FORMAT_WARNINGS=$((SAMPLE_RATE_ERRORS + BITS_ERRORS + DURATION_ERRORS))
LEVEL_WARNINGS=$((SIN_AUDIO + NIVEL_BAJO + NIVEL_EXTREMO))
DEPTH_RELEVANT_TOTAL=$((DEPTH_EXACT_24_TO_16 + DEPTH_EXACT_32_TO_24 + DEPTH_EXACT_32_TO_16 + DEPTH_STRONG + DEPTH_PARTIAL))
UNCHANGED_TOTAL=$((MONO_ORIGINAL + STEREO_REAL))
TOTAL_WARNINGS=$((FORMAT_WARNINGS + LEVEL_WARNINGS))

REPORT_BASIC="$WORK_DIR/INFORME_ANALISIS_BASICO.txt"
REPORT_DETAIL="$WORK_DIR/INFORME_ANALISIS_DETALLADO.txt"

# -------------------- INFORME BÁSICO -------------------------
{
    echo "============================================================"
    echo "ANALIZADOR DE MULTITRACKS ESTUDIO PG — V2.12.19 (Mac Intel)"
    echo "INFORME BÁSICO"
    echo "============================================================"
    echo
    echo "Carpeta analizada:"
    echo "$SOURCE_DIR"

    echo
    echo "FORMATO PARA CREAR LA SESIÓN"
    echo "----------------------------"
    echo "Sample rate predominante: $REF_SR_DISPLAY"
    echo "Profundidad predominante PCM entero: $REF_BITS bits"
    echo "WAV analizados: $TOTAL"
    [ "$SAMPLE_RATE_ERRORS" -gt 0 ] && echo "Otros sample rates: $SAMPLE_RATE_ERRORS archivo(s)"
    [ "$BITS_ERRORS" -gt 0 ] && echo "Otras profundidades PCM: $BITS_ERRORS archivo(s)"
    [ "$DURATION_ERRORS" -gt 0 ] && echo "Duración diferente de la referencia: $DURATION_ERRORS archivo(s)"
    [ "$DEPTH_FLOAT" -gt 0 ] && echo "FLOAT 32 detectados: $DEPTH_FLOAT archivo(s) (informados por separado)"

    echo
    echo "CONVERSIONES Y DECISIONES"
    echo "-------------------------"
    echo "Dual Mono convertidos a mono: $((DUAL_MONO + DUAL_MONO_PRACTICO))"
    echo "Mono paneados convertidos a mono: $MONO_PANEADO"
    echo "Archivos sin cambios: $UNCHANGED_TOTAL"
    echo "Archivos para revisar: $REVISAR"

    echo
    echo "PROFUNDIDAD EFECTIVA"
    echo "---------------------"
    echo "16 bits efectivos en contenedor 24: $DEPTH_EXACT_24_TO_16"
    echo "24 bits efectivos en contenedor entero 32: $DEPTH_EXACT_32_TO_24"
    echo "16 bits efectivos en contenedor entero 32: $DEPTH_EXACT_32_TO_16"
    echo "Patrón FUERTE compatible con cuantización previa de 16 bits: $DEPTH_STRONG"
    echo "Patrón PARCIAL compatible con grilla de 16 bits: $DEPTH_PARTIAL"
    echo "FLOAT 32: $DEPTH_FLOAT (fuera del análisis de LSB)"
    echo "Detalle y evidencia: ver 02 Informe de análisis detallado.pdf"

    echo
    echo "ADVERTENCIAS"
    echo "------------"
    if [ "$LEVEL_WARNINGS" -eq 0 ]; then
        echo "Nivel: sin advertencias."
    else
        echo "Sin audio: $SIN_AUDIO"
        echo "Nivel bajo: $NIVEL_BAJO"
        echo "Nivel extremadamente bajo: $NIVEL_EXTREMO"
    fi

    echo
    echo "ARCHIVOS PARA REVISAR"
    echo "----------------------"
    if [ "$REVISAR" -eq 0 ]; then
        echo "Ninguno."
        echo
    else
        N=1
        while IFS='|' read -r REVIEW_FILE REVIEW_REASON; do
            [ -z "$REVIEW_FILE" ] && continue
            echo "   $N. $REVIEW_FILE"
            echo "      Motivo: $REVIEW_REASON"
            echo
            N=$((N + 1))
        done < "$REVIEW_TEMP"
    fi
} > "$REPORT_BASIC"

# ------------------- INFORME DETALLADO -----------------------
{
    echo "============================================================"
    echo "ANALIZADOR DE MULTITRACKS ESTUDIO PG — V2.12.19 (Mac Intel)"
    echo "INFORME DETALLADO"
    echo "============================================================"
    echo
    echo "Carpeta analizada:"
    echo "$SOURCE_DIR"

    echo
    echo "FORMATO Y DURACIÓN"
    echo "------------------"
    echo "Sample rate de referencia: $REF_SR_DISPLAY"
    echo "Profundidad PCM de referencia: $REF_BITS bits"
    echo "Duración de referencia: $REF_DURATION_DISPLAY"
    echo

    if [ "$FORMAT_WARNINGS" -eq 0 ]; then
        echo "Sin diferencias relevantes."
        echo
    else
        if [ "$SAMPLE_RATE_ERRORS" -gt 0 ]; then
            echo "SAMPLE RATE DIFERENTE"
            N=1
            while IFS=$'\t' read -r F V; do
                [ -z "$F" ] && continue
                echo "   $N. $F"
                echo "      Sample rate: $(format_sample_rate "$V")"
                echo
                N=$((N + 1))
            done < "$SR_TEMP"
        fi

        if [ "$BITS_ERRORS" -gt 0 ]; then
            echo "PROFUNDIDAD PCM DIFERENTE"
            N=1
            while IFS=$'\t' read -r F V; do
                [ -z "$F" ] && continue
                echo "   $N. $F"
                echo "      Profundidad: $V bits"
                echo
                N=$((N + 1))
            done < "$BITS_TEMP"
        fi

        if [ "$DURATION_ERRORS" -gt 0 ]; then
            echo "DURACIÓN DIFERENTE"
            N=1
            while IFS=$'\t' read -r F SR TS SEC SAMPLES MS; do
                [ -z "$F" ] && continue
                echo "   $N. $F"
                echo "      Duración: $(format_duration "$SEC")"
                echo "      Diferencia: $(format_time_difference "$MS")"
                echo
                N=$((N + 1))
            done < "$DURATION_TEMP"
        fi
    fi

    if [ "$DEPTH_FLOAT" -gt 0 ]; then
        echo "FLOAT 32"
        echo "Se informan por separado y no se comparan contra profundidad PCM ni se analizan por LSB."
        echo
        N=1
        while IFS=$'\t' read -r F B; do
            [ -z "$F" ] && continue
            echo "   $N. $F"
            echo "      Formato: FLOAT ${B:-32} bits"
            echo
            N=$((N + 1))
        done < "$FLOAT_TEMP"
    fi

    echo "CLASIFICACIÓN DE ARCHIVOS"
    echo "-------------------------"
    N=1
    while IFS='|' read -r F C KEEP NEW REASON; do
        [ -z "$F" ] && continue
        echo "   $N. $F"
        if [ "$C" = "DUAL MONO EXACTO" ] || [ "$C" = "DUAL MONO PRÁCTICO" ]; then
            echo "      Clasificación: $C"
            echo "      Canal conservado: $KEEP"
            echo "      Archivo generado: $NEW"
        elif [ "$C" = "MONO PANEADO" ]; then
            echo "      Clasificación: MONO PANEADO"
            echo "      Canal conservado: $KEEP"
            echo "      Archivo generado: $NEW"
        elif [ "$C" = "REVISAR" ]; then
            echo "      Clasificación: REVISAR"
            [ -n "$REASON" ] && echo "      Motivo: $REASON"
        else
            echo "      Clasificación: $C"
        fi
        echo
        N=$((N + 1))
    done < "$CLASS_TEMP"

    echo "NIVELES"
    echo "-------"
    if [ "$LEVEL_WARNINGS" -eq 0 ]; then
        echo "Sin advertencias."
        echo
    else
        N=1
        while IFS= read -r F; do
            [ -z "$F" ] && continue
            echo "   $N. $F"
            echo "      Resultado: SIN AUDIO — silencio digital"
            echo
            N=$((N+1))
        done < "$SILENT_TEMP"
        while IFS=$'\t' read -r F P; do
            [ -z "$F" ] && continue
            echo "   $N. $F"
            echo "      Resultado: NIVEL BAJO"
            echo "      Pico: $(format_peak "$P")"
            echo
            N=$((N+1))
        done < "$LOW_WARNING_TEMP"
        while IFS=$'\t' read -r F P; do
            [ -z "$F" ] && continue
            echo "   $N. $F"
            echo "      Resultado: NIVEL EXTREMADAMENTE BAJO"
            echo "      Pico: $(format_peak "$P")"
            echo
            N=$((N+1))
        done < "$LOW_TEMP"
    fi

    echo "PROFUNDIDAD EFECTIVA"
    echo "---------------------"
    if [ "$DEPTH_RELEVANT_TOTAL" -eq 0 ]; then
        echo "Sin hallazgos relevantes en PCM entero."
        echo
    else
        N=1
        while IFS=$'\t' read -r D_FILE D_ENCODING D_CONTAINER D_STRICT D_PATTERN D_EXACT D_WITHIN2 D_RMS D_VALID D_ERROR; do
            RESULT=""; EVIDENCE=""
            if [ "$D_STRICT" = "16 BITS EFECTIVOS EN CONTENEDOR PCM DE 24" ]; then RESULT="16 bits efectivos en contenedor 24"; EVIDENCE="8 LSB inferiores en cero"
            elif [ "$D_STRICT" = "24 BITS EFECTIVOS EN CONTENEDOR PCM ENTERO DE 32" ]; then RESULT="24 bits efectivos en contenedor 32"; EVIDENCE="8 LSB inferiores en cero"
            elif [ "$D_STRICT" = "16 BITS EFECTIVOS EN CONTENEDOR PCM ENTERO DE 32" ]; then RESULT="16 bits efectivos en contenedor 32"; EVIDENCE="16 LSB inferiores en cero"
            elif [ "$D_PATTERN" = "PATRON FUERTEMENTE COMPATIBLE CON CUANTIZACION PREVIA DE 16 BITS" ]; then RESULT="Patrón FUERTE compatible con cuantización previa de 16 bits"; EVIDENCE=$(awk -v p="$D_WITHIN2" -v r="$D_RMS" 'BEGIN { printf "%.1f%% dentro de ±2 LSB de la grilla de 16 bits | RMS residual %.2f LSB", p, r }')
            elif [ "$D_PATTERN" = "PATRON PARCIAL COMPATIBLE CON GRILLA DE 16 BITS" ]; then RESULT="Patrón PARCIAL compatible con grilla de 16 bits"; EVIDENCE=$(awk -v p="$D_EXACT" -v r="$D_RMS" 'BEGIN { printf "%.1f%% de coincidencia exacta con la grilla de 16 bits | RMS residual %.2f LSB", p, r }')
            fi
            if [ -n "$RESULT" ]; then
                echo "   $N. $D_FILE"
                echo "      Resultado: $RESULT"
                echo "      Formato: $D_ENCODING $D_CONTAINER bits"
                echo "      Evidencia: $EVIDENCE"
                echo
                N=$((N + 1))
            fi
        done < "$DEPTH_TEMP"
    fi
    if [ "$DEPTH_FLOAT" -gt 0 ]; then
        echo "FLOAT 32 detectados: $DEPTH_FLOAT archivo(s). Se excluyen del análisis de LSB."
        echo
    fi

} > "$REPORT_DETAIL"

PROFILE_REPORT_T1=$(now_ms)
PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
PROFILE_REPORT_MS=$((PROFILE_REPORT_T1-PROFILE_REPORT_T0))

# ---------------- INFORME TÉCNICO / DESARROLLO --------------
# No forma parte de los informes destinados al usuario final.
PROFILE_TECH_T0=$(now_ms)
PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))

if [ "$DUPLICATE_ANALYSIS_ENABLED" -eq 1 ]; then
    DUP_THEORETICAL_TOTAL=$((DUP_COUNT * (DUP_COUNT - 1) / 2))
else
    DUP_THEORETICAL_TOTAL=0
fi
UNKNOWN_SR=$(awk -F '\t' '$2=="DESCONOCIDO" {c++} END{print c+0}' "$META_TEMP")
UNKNOWN_BITS=$(awk -F '\t' '$3=="DESCONOCIDO" {c++} END{print c+0}' "$META_TEMP")
UNKNOWN_DURATION=$(awk -F '\t' '$5=="DESCONOCIDO" {c++} END{print c+0}' "$META_TEMP")
PCM16_COUNT=$(awk -F '\t' '$2=="PCM ENTERO" && $3==16 {c++} END{print c+0}' "$DEPTH_TEMP")
PCM24_COUNT=$(awk -F '\t' '$2=="PCM ENTERO" && $3==24 {c++} END{print c+0}' "$DEPTH_TEMP")
PCM32_COUNT=$(awk -F '\t' '$2=="PCM ENTERO" && $3==32 {c++} END{print c+0}' "$DEPTH_TEMP")
OTHER_DEPTH_COUNT=$(awk -F '\t' '$2!="PCM ENTERO" && $2!="PCM FLOAT" {c++} END{print c+0}' "$DEPTH_TEMP")

MACOS_VERSION=$(/usr/bin/sw_vers -productVersion 2>/dev/null || echo "DESCONOCIDO")
MACOS_BUILD=$(/usr/bin/sw_vers -buildVersion 2>/dev/null || echo "DESCONOCIDO")
ARCH=$(uname -m 2>/dev/null || echo "DESCONOCIDO")
CPU=$(/usr/sbin/sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "DESCONOCIDO")
LOGICAL_CPU=$(/usr/sbin/sysctl -n hw.logicalcpu 2>/dev/null || echo "DESCONOCIDO")
MEM_BYTES=$(/usr/sbin/sysctl -n hw.memsize 2>/dev/null || echo "0")
MEM_GB=$(awk -v b="$MEM_BYTES" 'BEGIN { if (b+0>0) printf "%.1f", b/1073741824; else print "DESCONOCIDO" }')
FFMPEG_VERSION=$("$FFMPEG" -version 2>/dev/null | head -1)
FFPROBE_VERSION=$("$FFPROBE" -version 2>/dev/null | head -1)

# El total parcial se calcula antes de la copia de salida; se completa al final.
PROFILE_PREOUTPUT_NOW=$(now_ms)
PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
PROFILE_PREOUTPUT_MS=$((PROFILE_PREOUTPUT_NOW-PROFILE_TOTAL_START_MS))

{
    echo "============================================================"
    echo "INFORME TÉCNICO DE DESARROLLO — V2.12.19 (Mac Intel)"
    echo "============================================================"
    echo "USO INTERNO: diagnóstico, rendimiento y optimización."
    echo "NO ENTREGAR A USUARIOS FINALES."
    echo "Comparación de duplicados: TEMPORALMENTE DESACTIVADA; no se evaluó la existencia de duplicados."
    echo
    echo "NOTA DE MEDICIÓN"
    echo "----------------"
    echo "Esta compilación incorpora instrumentación de tiempo y puede agregar una pequeña sobrecarga."
    echo "Los valores son especialmente útiles para comparar etapas entre sí y entre versiones."
    echo
    echo "ENTORNO"
    echo "-------"
    echo "macOS: $MACOS_VERSION ($MACOS_BUILD)"
    echo "Arquitectura: $ARCH"
    echo "CPU: $CPU"
    echo "CPU lógicas: $LOGICAL_CPU"
    echo "RAM: $MEM_GB GB"
    echo "FFmpeg: $FFMPEG_VERSION"
    echo "FFprobe: $FFPROBE_VERSION"
    echo "Carpeta analizada: $SOURCE_DIR"
    echo
    echo "CARGA DE TRABAJO"
    echo "----------------"
    echo "WAV encontrados: $TOTAL_WAV_COUNT"
    echo "WAV analizados: $TOTAL"
    echo "Bytes WAV acumulados: $TOTAL_WAV_BYTES"
    echo "Duración acumulada de audio: $(format_duration "$AUDIO_DURATION_SUM")"
    echo "Mono originales: $MONO_ORIGINAL"
    echo "Estéreo reales: $STEREO_REAL"
    echo "Dual mono exactos: $DUAL_MONO"
    echo "Dual mono prácticos: $DUAL_MONO_PRACTICO"
    echo "Mono paneados: $MONO_PANEADO"
    echo "Para revisar: $REVISAR"
    echo "Conversiones automáticas: $CONVERSION_TOTAL"
    echo
    echo "FORMATOS / PROFUNDIDAD"
    echo "----------------------"
    echo "PCM16: $PCM16_COUNT"
    echo "PCM24: $PCM24_COUNT"
    echo "PCM32 entero: $PCM32_COUNT"
    echo "FLOAT: $DEPTH_FLOAT"
    echo "Otros/no determinados: $OTHER_DEPTH_COUNT"
    echo "Sample rate desconocido: $UNKNOWN_SR"
    echo "Profundidad desconocida: $UNKNOWN_BITS"
    echo "Duración desconocida: $UNKNOWN_DURATION"
    echo "Errores del análisis de profundidad efectiva: $DEPTH_ANALYSIS_ERRORS"
    echo "Profundidad efectiva omitida por silencio ya detectado: $DEPTH_SILENCE_SKIPPED"
    echo
    echo "TIEMPOS ACUMULADOS — ANÁLISIS POR ARCHIVO"
    echo "-----------------------------------------"
    printf "Bucle completo de análisis de archivos: %.3f s\n" "$(awk -v x="$PROFILE_ANALYSIS_MS" 'BEGIN{print x/1000}')"
    printf "Metadatos / FFprobe: %.3f s\n" "$(awk -v x="$PROFILE_METADATA_MS" 'BEGIN{print x/1000}')"
    echo "  WAV con metadatos consolidados en una sola llamada: $METADATA_SINGLE_PASS_FILES"
    printf "Profundidad efectiva: %.3f s\n" "$(awk -v x="$PROFILE_DEPTH_MS" 'BEGIN{print x/1000}')"
    echo "Archivos silenciosos que evitaron recorrido LSB: $DEPTH_SILENCE_SKIPPED"
    printf "Nivel (Peak global + RMS por canal): %.3f s\n" "$(awk -v x="$PROFILE_LEVEL_MS" 'BEGIN{print x/1000}')"
    if [ "$DUPLICATE_ANALYSIS_ENABLED" -eq 1 ]; then
        printf "Preparación duplicados (hash + fingerprint): %.3f s\n" "$(awk -v x="$PROFILE_DUP_PREP_MS" 'BEGIN{print x/1000}')"
        printf "  Hash exacto: %.3f s\n" "$(awk -v x="$PROFILE_DUP_HASH_MS" 'BEGIN{print x/1000}')"
        printf "  Fingerprint adaptativo: %.3f s\n" "$(awk -v x="$PROFILE_DUP_FP_MS" 'BEGIN{print x/1000}')"
    else
        echo "Preparación duplicados: NO EJECUTADA (comparación temporalmente desactivada)."
        echo "Hashes calculados para duplicados: 0"
        echo "Fingerprints calculados: 0"
    fi
    printf "Análisis estéreo L/R + residual: %.3f s\n" "$(awk -v x="$PROFILE_STEREO_MS" 'BEGIN{print x/1000}')"
    echo "  WAV estéreo que reutilizaron RMS L/R del análisis global: $STEREO_RMS_REUSED_FILES"
    echo "  astats: Peak global + RMS por canal para clasificación estéreo"
    printf "Conversiones automáticas a mono: %.3f s\n" "$(awk -v x="$PROFILE_CONVERT_MS" 'BEGIN{print x/1000}')"
    PROFILE_MEASURED_FILE_MS=$((PROFILE_METADATA_MS + PROFILE_DEPTH_MS + PROFILE_LEVEL_MS + PROFILE_DUP_PREP_MS + PROFILE_STEREO_MS + PROFILE_CONVERT_MS))
    PROFILE_UNACCOUNTED_FILE_MS=$((PROFILE_ANALYSIS_MS - PROFILE_MEASURED_FILE_MS))
    [ "$PROFILE_UNACCOUNTED_FILE_MS" -lt 0 ] && PROFILE_UNACCOUNTED_FILE_MS=0
    printf "Resto del bucle no instrumentado: %.3f s\n" "$(awk -v x="$PROFILE_UNACCOUNTED_FILE_MS" 'BEGIN{print x/1000}')"
    if [ "$PROFILE_ANALYSIS_MS" -gt 0 ]; then
        awk -v u="$PROFILE_UNACCOUNTED_FILE_MS" -v t="$PROFILE_ANALYSIS_MS" 'BEGIN { printf "Porcentaje del bucle todavía no instrumentado: %.2f%%\n", 100*u/t }'
    fi
    echo
    echo "PROFUNDIDAD EFECTIVA — ARCHIVOS MÁS LENTOS"
    echo "------------------------------------------"
    if [ -s "$PROFILE_FILE_TEMP" ]; then
        sort -t $'\t' -k2,2nr "$PROFILE_FILE_TEMP" | head -10 | awk -F '\t' '{ printf "%2d. %s | %.3f s | duración %s s | %s %s bits\n", NR, $1, $2/1000, $3, $4, $5 }'
    else
        echo "Sin datos."
    fi
    echo
    echo "DIAGNÓSTICO DE COBERTURA DEL PROFILER"
    echo "------------------------------------"
    PROFILE_ACCOUNTED_PCT=$(awk -v m="$PROFILE_MEASURED_FILE_MS" -v t="$PROFILE_ANALYSIS_MS" 'BEGIN { if (t>0) printf "%.2f", 100*m/t; else print "0.00" }')
    echo "Tiempo del bucle explicado por etapas instrumentadas: $PROFILE_ACCOUNTED_PCT%"
    if [ "$PROFILE_UNACCOUNTED_FILE_MS" -gt 5000 ]; then
        echo "ATENCIÓN: quedan más de 5 s sin atribuir dentro del bucle; conviene instrumentar ese tramo antes de optimizar otras etapas."
    else
        echo "Cobertura temporal del bucle: suficiente para orientar optimizaciones."
    fi
    echo
    echo "TIEMPOS — ETAPAS GLOBALES"
    echo "-------------------------"
    printf "Descubrimiento/conteo de WAV: %.3f s\n" "$(awk -v x="$PROFILE_DISCOVERY_MS" 'BEGIN{print x/1000}')"
    printf "Control global de formato/duración: %.3f s\n" "$(awk -v x="$PROFILE_FORMAT_MS" 'BEGIN{print x/1000}')"
    if [ "$DUPLICATE_ANALYSIS_ENABLED" -eq 1 ]; then
        printf "Detección/consolidación de duplicados: %.3f s\n" "$(awk -v x="$PROFILE_DUPLICATES_MS" 'BEGIN{print x/1000}')"
    else
        echo "Detección/consolidación de duplicados: NO EJECUTADA (temporalmente desactivada)."
    fi
    printf "Generación de informes Básico + Detallado: %.3f s\n" "$(awk -v x="$PROFILE_REPORT_MS" 'BEGIN{print x/1000}')"
    printf "Tiempo transcurrido antes de materializar salida: %.3f s\n" "$(awk -v x="$PROFILE_PREOUTPUT_MS" 'BEGIN{print x/1000}')"
    echo
    if [ "$DUPLICATE_ANALYSIS_ENABLED" -eq 1 ]; then
        echo "DUPLICADOS — EFICIENCIA DEL FILTRO"
        echo "---------------------------------"
        echo "Archivos candidatos (no silenciosos): $DUP_COUNT"
        echo "Pares teóricos posibles: $DUP_THEORETICAL_TOTAL"
        echo "Pares técnicamente compatibles: $DUP_EFFECTIVE_TOTAL"
        echo "Pares compatibles no resueltos por hash: $DUP_NONHASH_CANDIDATE_PAIRS"
        echo "Coincidencias por hash exacto: $DUP_EXACT_HASH_MATCHES"
        echo "Modo fingerprint: $DUP_FP_MODE"
        echo "Umbral de activación fingerprint: $DUP_FP_MIN_NONHASH_PAIRS pares no exactos"
        echo "Archivos fingerprint analizados: $DUP_FP_FILES"
        echo "Prefiltros fingerprint ejecutados: $DUP_PREFILTER_RUN"
        echo "Pares descartados por fingerprint: $DUP_PREFILTER_DISCARDED"
        echo "Comparaciones completas de señal: $DUP_FULL_COMPARISONS"
        echo "Coincidencias confirmadas por señal: $DUP_SIGNAL_MATCHES"
        if [ "$DUP_THEORETICAL_TOTAL" -gt 0 ]; then
            awk -v e="$DUP_EFFECTIVE_TOTAL" -v t="$DUP_THEORETICAL_TOTAL" 'BEGIN { printf "Reducción por filtro técnico: %.2f%%\n", 100*(1-e/t) }'
        fi
        if [ "$DUP_PREFILTER_RUN" -gt 0 ]; then
            awk -v d="$DUP_PREFILTER_DISCARDED" -v r="$DUP_PREFILTER_RUN" 'BEGIN { printf "Descarte del fingerprint: %.2f%%\n", 100*(d/r) }'
        fi
        echo
    else
        echo "COMPARACIÓN DE DUPLICADOS"
        echo "-------------------------"
        echo "Estado: TEMPORALMENTE DESACTIVADA EN V2.12.19"
        echo "Hashes para duplicados: 0"
        echo "Fingerprints calculados: 0"
        echo "Filtros de elegibilidad ejecutados: 0"
        echo "Comparaciones de señal entre archivos: 0"
        echo "Grupos de duplicados: NO EVALUADO"
        echo "La ausencia de resultados no implica que no existan duplicados."
        echo "Código de detección conservado para reactivación futura."
        echo
    fi
    echo "CONTROL DE ERRORES / CASOS ESPECIALES"
    echo "------------------------------------"
    echo "Sin audio: $SIN_AUDIO"
    echo "Nivel bajo: $NIVEL_BAJO"
    echo "Nivel extremadamente bajo: $NIVEL_EXTREMO"
    echo "Errores de conversión: $CONVERSION_ERRORS"
    echo "Errores de profundidad efectiva: $DEPTH_ANALYSIS_ERRORS"
    echo "Archivos para revisión manual: $REVISAR"
    echo
    echo "INSTRUMENTACIÓN"
    echo "---------------"
    echo "Lecturas externas de reloj realizadas por el profiler: $PROFILE_INSTRUMENTED_CALLS"
    echo "Profundidad efectiva se mide externamente alrededor de cada llamada al helper; no depende del tiempo interno devuelto por Perl."
    echo "V2.12.19 mantiene FFprobe consolidado, RMS L/R reutilizado y astats limitado a las métricas necesarias.
Con duplicados desactivados, se omite también el RMS global del archivo porque sólo se utilizaba para comparar duplicados; se conservan Peak global y RMS por canal para clasificación estéreo.
El ETA visible recibe milisegundos monotónicos enteros directamente del proceso principal y los convierte a segundos dentro de la ventana; esto evita ambigüedad de separador decimal por configuración regional."
    echo "La sobrecarga de las lecturas de reloj está incluida en el tiempo total."
    echo
    echo "NOTA"
    echo "----"
    echo "Los tiempos de copia de [PROCESADO] y el tiempo total definitivo se agregan al finalizar la salida."
    echo
} > "$REPORT_TECH"

PROFILE_TECH_T1=$(now_ms)
PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
PROFILE_TECH_REPORT_MS=$((PROFILE_TECH_T1-PROFILE_TECH_T0))
PROFILE_OUTPUT_T0=$(now_ms)
PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))

# ============================================================
# SALIDA INTELIGENTE
# ============================================================

progress_update 92 "Preparando salida" "Guardando informes y conversiones necesarias"

if [ "$CONVERSION_TOTAL" -gt 0 ]; then

    # Nunca se borra ni se sobrescribe una salida anterior.
    # Si [PROCESADO] ya existe, se busca automáticamente [PROCESADO 2],
    # [PROCESADO 3], etc., y se usa la primera carpeta disponible.
    resolve_destination_dir
    DEST_LABEL="$(basename "$DEST_DIR")"

    progress_update 94 "Creando carpeta procesada" "Salida: $DEST_LABEL"

    mkdir -p "$DEST_DIR"
    /usr/bin/ditto "$SOURCE_DIR" "$DEST_DIR"
    rm -f "$DEST_DIR/INFORME_ANALISIS.txt"

    while IFS=$'\t' read -r ORIGINAL_REL NEW_REL
    do
        [ -z "$ORIGINAL_REL" ] && continue

        rm -f "$DEST_DIR/$ORIGINAL_REL"
        mkdir -p "$(dirname "$DEST_DIR/$NEW_REL")"
        cp -p "$CONVERT_DIR/$NEW_REL" "$DEST_DIR/$NEW_REL"

    done < "$CONVERSION_MAP"

    for R in "$REPORT_BASIC" "$REPORT_DETAIL"; do
        {
            echo
            echo "SALIDA"
            echo "------"
            echo "Se generó $DEST_LABEL con $CONVERSION_TOTAL conversión(es) automática(s)."
            echo
        } >> "$R"
    done

    cp -p "$REPORT_BASIC" "$DEST_DIR/INFORME_ANALISIS_BASICO.txt"
    cp -p "$REPORT_DETAIL" "$DEST_DIR/INFORME_ANALISIS_DETALLADO.txt"
    cp -p "$REPORT_TECH" "$DEST_DIR/INFORME_TECNICO_DESARROLLO.txt"
    FINAL_FOLDER="$DEST_DIR"
    OUTPUT_TYPE="PROCESADO"

else

    progress_update 94 "Guardando informes" "No se requieren conversiones automáticas"

    for R in "$REPORT_BASIC" "$REPORT_DETAIL"; do
        {
            echo
            echo "SALIDA"
            echo "------"
            echo "No se requirieron modificaciones automáticas; no se creó [PROCESADO]."
            echo
        } >> "$R"
    done

    cp -p "$REPORT_BASIC" "$SOURCE_DIR/INFORME_ANALISIS_BASICO.txt"
    cp -p "$REPORT_DETAIL" "$SOURCE_DIR/INFORME_ANALISIS_DETALLADO.txt"
    cp -p "$REPORT_TECH" "$SOURCE_DIR/INFORME_TECNICO_DESARROLLO.txt"
    FINAL_FOLDER="$SOURCE_DIR"
    OUTPUT_TYPE="SIN_CAMBIOS"
fi

# ============================================================
# INFORMES PDF PARA USUARIO
# ============================================================
# Los TXT básico y detallado se usan como fuente intermedia. Solo se retiran
# de la carpeta final cuando AMBOS PDF fueron creados y verificados. Si algo
# falla, los TXT se conservan como respaldo y la ventana final informa el error.

progress_update 97 "Generando informes PDF" "Informe básico + informe detallado"

FINAL_BASIC_TXT="$FINAL_FOLDER/INFORME_ANALISIS_BASICO.txt"
FINAL_DETAIL_TXT="$FINAL_FOLDER/INFORME_ANALISIS_DETALLADO.txt"
# El generador nativo todavía crea sus nombres internos históricos.
# V2.12.18 los renombra antes de entregar para usar nombres legibles y numerados.
GEN_BASIC_PDF="$FINAL_FOLDER/Informe de análisis básico.pdf"
GEN_DETAIL_PDF="$FINAL_FOLDER/Informe de análisis detallado.pdf"
FINAL_BASIC_PDF="$FINAL_FOLDER/01 Informe de análisis básico.pdf"
FINAL_DETAIL_PDF="$FINAL_FOLDER/02 Informe de análisis detallado.pdf"
PDF_ERROR_LOG="$WORK_DIR/pdf_generation_error.txt"
PDF_STDOUT_LOG="$WORK_DIR/pdf_generation_output.txt"
PDF_STATUS="ERROR"
PDF_ERROR_MSG=""

PROFILE_PDF_T0=$(now_ms)
PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))

if [ ! -r "$PDF_PUBLISH_HELPER" ]; then
    PDF_ERROR_MSG="No está disponible el módulo de publicación segura de PDF."
elif ! . "$PDF_PUBLISH_HELPER"; then
    PDF_ERROR_MSG="No se pudo cargar el módulo de publicación segura de PDF."
elif ! declare -F publish_pdf_reports >/dev/null 2>&1; then
    PDF_ERROR_MSG="El módulo de publicación segura de PDF no contiene la función necesaria."
else
    publish_pdf_reports \
        "$PDF_GENERATOR" \
        "$FINAL_BASIC_TXT" \
        "$FINAL_DETAIL_TXT" \
        "$PDF_FONT_REGULAR" \
        "$PDF_FONT_BOLD" \
        "$FINAL_FOLDER" \
        "Informe de análisis básico.pdf" \
        "Informe de análisis detallado.pdf" \
        "$FINAL_BASIC_PDF" \
        "$FINAL_DETAIL_PDF"
fi

PROFILE_PDF_T1=$(now_ms)
PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
PROFILE_PDF_MS=$((PROFILE_PDF_T1-PROFILE_PDF_T0))

PROFILE_OUTPUT_T1=$(now_ms)
PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
PROFILE_OUTPUT_MS=$((PROFILE_OUTPUT_T1-PROFILE_OUTPUT_T0))
PROFILE_TOTAL_END_MS=$(now_ms)
PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
PROFILE_TOTAL_MS=$((PROFILE_TOTAL_END_MS-PROFILE_TOTAL_START_MS))
PROFILE_SEC_PER_AUDIO_MIN=$(awk -v ms="$PROFILE_TOTAL_MS" -v audio="$AUDIO_DURATION_SUM" 'BEGIN { if (audio>0) printf "%.4f", (ms/1000)/(audio/60); else print "0" }')
{
    echo "TIEMPOS FINALES"
    echo "---------------"
    printf "Generación del informe técnico: %.3f s\n" "$(awk -v x="$PROFILE_TECH_REPORT_MS" 'BEGIN{print x/1000}')"
    printf "Generación de PDF básico + detallado: %.3f s\n" "$(awk -v x="$PROFILE_PDF_MS" 'BEGIN{print x/1000}')"
    echo "Estado de informes PDF: $PDF_STATUS"
    if [ "$PDF_STATUS" != "OK" ]; then
        echo "Error de informes PDF: $PDF_ERROR_MSG"
        echo "Respaldo conservado: INFORME_ANALISIS_BASICO.txt + INFORME_ANALISIS_DETALLADO.txt"
    fi
    printf "Materialización/copia de salida: %.3f s\n" "$(awk -v x="$PROFILE_OUTPUT_MS" 'BEGIN{print x/1000}')"
    printf "TIEMPO TOTAL: %.3f s\n" "$(awk -v x="$PROFILE_TOTAL_MS" 'BEGIN{print x/1000}')"
    echo "Segundos de proceso por minuto de audio acumulado: $PROFILE_SEC_PER_AUDIO_MIN"
    echo "Carpeta final: $FINAL_FOLDER"
    echo "Lecturas externas de reloj totales: $PROFILE_INSTRUMENTED_CALLS"
    echo
    echo "DIAGNÓSTICO DE ETA / TIEMPO RESTANTE"
    echo "-----------------------------------"
    if [ -s "$ETA_LOG_FILE" ]; then
        # Referencia ETA tomada con el MISMO reloj monotónico y el MISMO origen
        # temporal que usa la ventana. Incluye todo el trabajo hasta este punto,
        # no solo el núcleo del profiler.
        ETA_REFERENCE_NOW_MS=$(now_ms)
        PROFILE_INSTRUMENTED_CALLS=$((PROFILE_INSTRUMENTED_CALLS+1))
        ETA_REFERENCE_MS=$((ETA_REFERENCE_NOW_MS-PROFILE_TOTAL_START_MS))
        ETA_REFERENCE_SEC=$(awk -v ms="$ETA_REFERENCE_MS" 'BEGIN { printf "%.3f", ms/1000 }')
        INTERNAL_TOTAL_SEC=$(awk -v ms="$PROFILE_TOTAL_MS" 'BEGIN { printf "%.3f", ms/1000 }')
        ETA_SAMPLES=$(awk -F '\t' '{gsub(/,/,".",$1); gsub(/,/,".",$3); gsub(/,/,".",$4)} $1 ~ /^[0-9.]+$/ && $2 ~ /^[0-9]+$/ {c++} END{print c+0}' "$ETA_LOG_FILE")
        echo "Muestras registradas: $ETA_SAMPLES"
        echo "Tiempo de procesamiento interno: $INTERNAL_TOTAL_SEC s"
        echo "Tiempo visible de referencia para ETA: $ETA_REFERENCE_SEC s"
        echo "Referencia temporal ETA: tiempo transcurrido monotónico suministrado por el proceso principal en cada actualización de progreso."
        echo "Algoritmo ETA V2.12.19: conserva la fórmula validada; espera mínimo 8 s y 20% de trabajo ETA, pondera 60% archivos completados + 40% bytes completados y corrige rápido al alza y suave a la baja."
        echo "Progreso V2.12.19: análisis por archivos 5–89%; control de sesión 90%; preparación de informes 91%; preparación de salida 92%; copia/proceso de salida 94%; generación de PDF 97%; finalización 99%. No hay etapa de duplicados."
        awk -F '\t' -v actual="$ETA_REFERENCE_SEC" '
            {
                gsub(/,/,".",$1); gsub(/,/,".",$3); gsub(/,/,".",$4)
            }
            $1 ~ /^[0-9.]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9.]+$/ && $4 ~ /^[0-9.]+$/ {
                n++; elapsed=$1+0; pct=$2+0; rem=$3+0; esttotal=$4+0; phase=$5;
                err=esttotal-actual; abs=(err<0?-err:err); ape=(actual>0?100*abs/actual:0);
                remreal=actual-elapsed; if(remreal<0) remreal=0;
                remerr=rem-remreal; remabs=(remerr<0?-remerr:remerr);
                sumabs+=abs; sumape+=ape; sumremabs+=remabs;
                if(n==1){firstpct=pct; firsttotal=esttotal; firsterr=err}
                lastpct=pct; lasttotal=esttotal; lasterr=err;
                if(abs>maxabs){maxabs=abs; maxpct=pct; maxphase=phase; maxerr=err}
                if(pct<25){q1+=abs; n1++} else if(pct<50){q2+=abs; n2++} else if(pct<75){q3+=abs; n3++} else {q4+=abs; n4++}
            }
            END {
                if(n>0){
                    printf "Primera estimación: %.1f s totales al %d%% | error %+0.1f s\n", firsttotal, firstpct, firsterr;
                    printf "Última estimación antes del final: %.1f s totales al %d%% | error %+0.1f s\n", lasttotal, lastpct, lasterr;
                    printf "Error absoluto medio del total estimado: %.1f s\n", sumabs/n;
                    printf "Error porcentual absoluto medio: %.1f%%\n", sumape/n;
                    printf "Error absoluto medio del tiempo restante: %.1f s\n", sumremabs/n;
                    printf "Peor desvío: %+0.1f s al %d%% | etapa: %s\n", maxerr, maxpct, maxphase;
                    printf "Error medio por tramo: 5-24%% %.1f s | 25-49%% %.1f s | 50-74%% %.1f s | 75-99%% %.1f s\n", (n1?q1/n1:0), (n2?q2/n2:0), (n3?q3/n3:0), (n4?q4/n4:0);
                } else print "No hubo muestras ETA válidas.";
            }' "$ETA_LOG_FILE"
        echo
        echo "MUESTRAS ETA"
        echo "------------"
        echo "Transcurrido | Barra | Base ETA | Restante estimado | Total estimado | Etapa"
        awk -F '\t' '{gsub(/,/,".",$1); gsub(/,/,".",$3); gsub(/,/,".",$4)} $1 ~ /^[0-9.]+$/ && $2 ~ /^[0-9]+$/ { eta=($6 ~ /^[0-9]+$/ ? $6 : $2); printf "%8.1f s | %3d%% | %3d%% | %8.1f s | %8.1f s | %s\n", $1,$2,eta,$3,$4,$5 }' "$ETA_LOG_FILE"
    else
        echo "No se encontraron muestras del ETA mostrado por la ventana de progreso."
    fi
    echo
} >> "$REPORT_TECH"
cp -p "$REPORT_TECH" "$FINAL_FOLDER/INFORME_TECNICO_DESARROLLO.txt"

REPORT="$REPORT_DETAIL"

progress_update 99 "Finalizando" "Guardando informe y limpiando archivos temporales."


# ============================================================
# LIMPIAR TEMPORALES
# ============================================================

rm -rf "$WORK_DIR"
trap - EXIT


# ============================================================
# RESUMEN EN TERMINAL
# ============================================================

echo
echo "========================================"
echo "PROCESO TERMINADO"
echo "========================================"
echo
echo "Total WAV: $TOTAL"
echo
echo "Mono originales: $MONO_ORIGINAL"
echo "Stereo reales: $STEREO_REAL"
echo "Dual-mono convertidos: $DUAL_MONO"
echo "Dual-mono prácticos convertidos: $DUAL_MONO_PRACTICO"
echo "Mono paneados convertidos: $MONO_PANEADO"
echo "Posible mono / estéreo altamente correlacionado: $HIGH_CORR_REVIEW"
echo "Para revisar: $REVISAR"
echo
echo "CONTROL DE NIVEL:"
echo "Sin audio: $SIN_AUDIO"
echo "Nivel bajo: $NIVEL_BAJO"
echo "Nivel extremadamente bajo: $NIVEL_EXTREMO"
echo
echo "CONTROL DE SESIÓN:"
echo "Sample rate diferente: $SAMPLE_RATE_ERRORS"
echo "Profundidad diferente: $BITS_ERRORS"
echo "Longitud diferente: $DURATION_ERRORS"
echo
echo "PROFUNDIDAD EFECTIVA:"
echo "16 en 24: $DEPTH_EXACT_24_TO_16"
echo "24 en 32: $DEPTH_EXACT_32_TO_24"
echo "16 en 32: $DEPTH_EXACT_32_TO_16"
echo "Patrón FUERTE 16 bits: $DEPTH_STRONG"
echo "Patrón PARCIAL 16 bits: $DEPTH_PARTIAL"
echo "FLOAT (fuera de comparación PCM): $DEPTH_FLOAT"
echo
echo "COMPARACIÓN DE DUPLICADOS:"
if [ "$DUPLICATE_ANALYSIS_ENABLED" -eq 1 ]; then
    echo "Grupos de duplicados: $DUP_GROUPS"
    echo "Archivos duplicados adicionales: $DUP_EXTRA_FILES"
    echo "Comparaciones completas de señal: $DUP_FULL_COMPARISONS"
else
    echo "Temporalmente desactivada; existencia de duplicados no evaluada."
fi
echo
echo "Carpeta de salida:"
echo "$FINAL_FOLDER"
echo
echo "Informe:"
echo "$REPORT"
echo

progress_finish "$FINAL_FOLDER" "$OUTPUT_TYPE"
echo "========================================"
echo

echo
