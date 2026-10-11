#!/bin/bash
# Safe publication of the two analysis reports. All temporary and backup files
# stay inside the destination folder so every final rename is on one filesystem.

pdf_is_valid() {
    local path="$1"
    [ -f "$path" ] && [ -s "$path" ] || return 1
    [ "$(LC_ALL=C /usr/bin/head -c 5 "$path" 2>/dev/null)" = "%PDF-" ] || return 1
    LC_ALL=C /usr/bin/grep -a -q 'startxref' "$path" 2>/dev/null || return 1
    LC_ALL=C /usr/bin/tail -c 4096 "$path" 2>/dev/null | /usr/bin/grep -a -q '%%EOF' || return 1
    return 0
}

_pdf_rollback_publication() {
    local rollback_ok=1 index
    if [ "$PUBLISHED_BASIC" -eq 1 ] && [ "${SAVED[0]:-0}" -eq 0 ]; then
        rm -f "$FINAL_BASIC_PDF" || rollback_ok=0
    fi
    if [ "$PUBLISHED_DETAIL" -eq 1 ] && [ "${SAVED[1]:-0}" -eq 0 ]; then
        rm -f "$FINAL_DETAIL_PDF" || rollback_ok=0
    fi
    for index in 3 2 1 0; do
        if [ "${SAVED[$index]:-0}" -eq 1 ]; then
            rm -f "${PUBLISH_PATHS[$index]}" || rollback_ok=0
            mv -f "$BACKUP_DIR/$index.pdf" "${PUBLISH_PATHS[$index]}" || rollback_ok=0
        fi
    done
    return "$((rollback_ok ? 0 : 1))"
}

publish_pdf_reports() {
    local generator="$1" basic_txt="$2" detail_txt="$3"
    local font_regular="$4" font_bold="$5" output_dir="$6"
    local generated_basic_name="$7" generated_detail_name="$8"
    local final_basic="$9" final_detail="${10}"
    local staged_basic staged_detail run_error publish_error
    local index target backup_path
    local -a PUBLISH_PATHS SAVED
    local PUBLISHED_BASIC=0 PUBLISHED_DETAIL=0
    local BACKUP_DIR PDF_STAGE_DIR

    PDF_STATUS="ERROR"
    PDF_ERROR_MSG=""
    FINAL_BASIC_PDF="$final_basic"
    FINAL_DETAIL_PDF="$final_detail"

    if [ ! -x "$generator" ]; then
        PDF_ERROR_MSG="Generador PDF no disponible dentro de la aplicación."
        return 1
    elif [ ! -f "$font_regular" ] || [ ! -f "$font_bold" ]; then
        PDF_ERROR_MSG="Faltan las fuentes DejaVu incluidas para generar los PDF."
        return 1
    elif [ ! -s "$basic_txt" ] || [ ! -s "$detail_txt" ]; then
        PDF_ERROR_MSG="Faltan los informes TXT intermedios necesarios para crear los PDF."
        return 1
    elif [ ! -d "$output_dir" ]; then
        PDF_ERROR_MSG="No existe la carpeta de destino de los informes."
        return 1
    fi

    PDF_STAGE_DIR=$(/usr/bin/mktemp -d "$output_dir/.pdf-stage.XXXXXXXX" 2>/dev/null) || {
        PDF_ERROR_MSG="No se pudo preparar una carpeta temporal para los PDF."
        return 1
    }
    BACKUP_DIR="$PDF_STAGE_DIR/previous"
    mkdir -p "$BACKUP_DIR" || {
        PDF_ERROR_MSG="No se pudo preparar el respaldo de los PDF anteriores."
        rm -rf "$PDF_STAGE_DIR"
        return 1
    }
    staged_basic="$PDF_STAGE_DIR/$generated_basic_name"
    staged_detail="$PDF_STAGE_DIR/$generated_detail_name"
    run_error="$PDF_STAGE_DIR/generator.stderr"
    publish_error=""

    if ! "$generator" "$basic_txt" "$detail_txt" "$font_regular" "$font_bold" "$PDF_STAGE_DIR" >"$PDF_STAGE_DIR/generator.stdout" 2>"$run_error"; then
        PDF_ERROR_MSG="$(/usr/bin/head -n 1 "$run_error" 2>/dev/null)"
        [ -n "$PDF_ERROR_MSG" ] || PDF_ERROR_MSG="El generador de PDF terminó con error."
        rm -rf "$PDF_STAGE_DIR"
        return 1
    fi
    if ! pdf_is_valid "$staged_basic" || ! pdf_is_valid "$staged_detail"; then
        PDF_ERROR_MSG="El generador no produjo los dos PDF con contenido válido; se conservaron los informes TXT y los PDF anteriores."
        rm -rf "$PDF_STAGE_DIR"
        return 1
    fi

    PUBLISH_PATHS=("$final_basic" "$final_detail" "$output_dir/$generated_basic_name" "$output_dir/$generated_detail_name")
    for index in 0 1 2 3; do
        target="${PUBLISH_PATHS[$index]}"
        SAVED[$index]=0
        if [ -e "$target" ] || [ -L "$target" ]; then
            if [ ! -f "$target" ]; then
                publish_error="El destino PDF existe y no es un archivo regular: $target"
                break
            fi
            backup_path="$BACKUP_DIR/$index.pdf"
            if ! mv -f "$target" "$backup_path"; then
                publish_error="No se pudo respaldar el PDF anterior: $target"
                break
            fi
            SAVED[$index]=1
        fi
    done

    if [ -z "$publish_error" ]; then
        if mv -f "$staged_basic" "$final_basic"; then
            PUBLISHED_BASIC=1
        else
            publish_error="No se pudo publicar el informe básico."
        fi
    fi
    if [ -z "$publish_error" ]; then
        if mv -f "$staged_detail" "$final_detail"; then
            PUBLISHED_DETAIL=1
        else
            publish_error="No se pudo publicar el informe detallado."
        fi
    fi
    if [ -z "$publish_error" ]; then
        if ! pdf_is_valid "$final_basic" || ! pdf_is_valid "$final_detail"; then
            publish_error="La validación de los PDF publicados no fue satisfactoria."
        fi
    fi

    if [ -n "$publish_error" ]; then
        if _pdf_rollback_publication; then
            PDF_ERROR_MSG="$publish_error Se restauraron los PDF anteriores; se conservaron los informes TXT."
            rm -rf "$PDF_STAGE_DIR"
        else
            PDF_ERROR_MSG="$publish_error No se pudo completar la restauración automática; los respaldos siguen en $BACKUP_DIR. Se conservaron los informes TXT."
        fi
        return 1
    fi

    PDF_STATUS="OK"
    rm -f "$basic_txt" "$detail_txt"
    rm -rf "$PDF_STAGE_DIR"
    return 0
}
