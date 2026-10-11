#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$ROOT/app/Contents/Resources/PublishPDFReports.sh"
TMP_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/pg-pdf-test.XXXXXXXX") || exit 1
trap 'rm -rf "$TMP_ROOT"' EXIT
source "$HELPER"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }
write_valid_pdf() {
    printf '%%PDF-1.7\n1 0 obj << /Type /Catalog >> endobj\nstartxref\n0\n%%%%EOF\n' > "$1"
}
write_marked_pdf() {
    printf '%%PDF-1.7\n1 0 obj << /Type /Catalog /Marker (%s) >> endobj\nstartxref\n0\n%%%%EOF\n' "$2" > "$1"
}
write_old_files() {
    local dir="$1"
    write_marked_pdf "$dir/01 Informe de análisis básico.pdf" OLD_BASIC
    write_marked_pdf "$dir/02 Informe de análisis detallado.pdf" OLD_DETAIL
    write_marked_pdf "$dir/Informe de análisis básico.pdf" OLD_LEGACY_BASIC
    write_marked_pdf "$dir/Informe de análisis detallado.pdf" OLD_LEGACY_DETAIL
}
write_txts() {
    printf 'texto básico\n' > "$1/INFORME_ANALISIS_BASICO.txt"
    printf 'texto detallado\n' > "$1/INFORME_ANALISIS_DETALLADO.txt"
}
assert_old_files() {
    local dir="$1"
    for item in '01 Informe de análisis básico.pdf|OLD_BASIC' '02 Informe de análisis detallado.pdf|OLD_DETAIL' 'Informe de análisis básico.pdf|OLD_LEGACY_BASIC' 'Informe de análisis detallado.pdf|OLD_LEGACY_DETAIL'; do
        local name="${item%%|*}" text="${item#*|}"
        /usr/bin/grep -a -q "$text" "$dir/$name" || fail "previous PDF was not preserved: $name"
    done
}
assert_txts_exist() {
    [ -s "$1/INFORME_ANALISIS_BASICO.txt" ] || fail 'basic TXT backup missing'
    [ -s "$1/INFORME_ANALISIS_DETALLADO.txt" ] || fail 'detailed TXT backup missing'
}
assert_no_staging() {
    local dir="$1"
    for path in "$dir"/.pdf-stage.*; do [ -e "$path" ] && fail 'temporary PDF directory left behind'; done
}

cat > "$TMP_ROOT/fake-generator" <<'FAKE'
#!/bin/bash
basic_txt="$1"; detail_txt="$2"; font_regular="$3"; font_bold="$4"; output_dir="$5"
write_pdf() { printf '%%PDF-1.7\n1 0 obj << /Type /Catalog /Marker (NEW_%s) >> endobj\nstartxref\n0\n%%%%EOF\n' "$2" > "$1"; }
write_pdf "$output_dir/Informe de análisis básico.pdf" BASIC
if [ "${FAKE_PDF_MODE:-success}" = "generation-failure" ]; then exit 23; fi
if [ "${FAKE_PDF_MODE:-success}" = "invalid-detail" ]; then printf 'not a PDF\n' > "$output_dir/Informe de análisis detallado.pdf"; exit 0; fi
write_pdf "$output_dir/Informe de análisis detallado.pdf" DETAIL
FAKE
chmod +x "$TMP_ROOT/fake-generator"
: > "$TMP_ROOT/font-regular"; : > "$TMP_ROOT/font-bold"

setup_case() {
    local name="$1"
    CASE_DIR="$TMP_ROOT/$name/sesión de prueba"
    mkdir -p "$CASE_DIR"
    write_old_files "$CASE_DIR"
    write_txts "$CASE_DIR"
    BASIC="$CASE_DIR/01 Informe de análisis básico.pdf"
    DETAIL="$CASE_DIR/02 Informe de análisis detallado.pdf"
}
run_publish() {
    publish_pdf_reports "$TMP_ROOT/fake-generator" \
      "$CASE_DIR/INFORME_ANALISIS_BASICO.txt" "$CASE_DIR/INFORME_ANALISIS_DETALLADO.txt" \
      "$TMP_ROOT/font-regular" "$TMP_ROOT/font-bold" "$CASE_DIR" \
      'Informe de análisis básico.pdf' 'Informe de análisis detallado.pdf' "$BASIC" "$DETAIL"
}

setup_case success
FAKE_PDF_MODE=success; export FAKE_PDF_MODE
run_publish || fail "success case returned error: $PDF_ERROR_MSG"
[ "$PDF_STATUS" = OK ] || fail 'success case did not set PDF_STATUS=OK'
/usr/bin/grep -a -q 'NEW_BASIC' "$BASIC" || fail 'new basic PDF was not published'
/usr/bin/grep -a -q 'NEW_DETAIL' "$DETAIL" || fail 'new detailed PDF was not published'
[ ! -e "$CASE_DIR/INFORME_ANALISIS_BASICO.txt" ] || fail 'basic TXT was not retired after success'
[ ! -e "$CASE_DIR/INFORME_ANALISIS_DETALLADO.txt" ] || fail 'detailed TXT was not retired after success'
[ ! -e "$CASE_DIR/Informe de análisis básico.pdf" ] || fail 'legacy basic PDF remained after success'
[ ! -e "$CASE_DIR/Informe de análisis detallado.pdf" ] || fail 'legacy detailed PDF remained after success'
assert_no_staging "$CASE_DIR"
pass 'publishes both validated PDFs, then retires TXT and old report names'

setup_case generation_failure
FAKE_PDF_MODE=generation-failure; export FAKE_PDF_MODE
if run_publish; then fail 'generator failure unexpectedly succeeded'; fi
[ "$PDF_STATUS" = ERROR ] || fail 'generator failure status missing'
assert_old_files "$CASE_DIR"; assert_txts_exist "$CASE_DIR"; assert_no_staging "$CASE_DIR"
pass 'generator failure preserves prior PDFs and both TXT backups'

setup_case invalid_detail
FAKE_PDF_MODE=invalid-detail; export FAKE_PDF_MODE
if run_publish; then fail 'invalid detailed PDF unexpectedly succeeded'; fi
assert_old_files "$CASE_DIR"; assert_txts_exist "$CASE_DIR"; assert_no_staging "$CASE_DIR"
pass 'invalid second PDF prevents publication and preserves prior outputs'

setup_case publish_failure
FAKE_PDF_MODE=success; export FAKE_PDF_MODE
FAIL_PUBLISH_TO="$DETAIL"
mv() {
    if [ "${1:-}" = '-f' ] && [[ "${2:-}" == *'/.pdf-stage.'* ]] && [[ "${2:-}" != *'/previous/'* ]] && [ "${3:-}" = "$FAIL_PUBLISH_TO" ]; then return 71; fi
    command mv "$@"
}
if run_publish; then fail 'injected second rename failure unexpectedly succeeded'; fi
[ "$PDF_STATUS" = ERROR ] || fail 'publish failure status missing'
assert_old_files "$CASE_DIR"; assert_txts_exist "$CASE_DIR"; assert_no_staging "$CASE_DIR"
pass 'second rename failure rolls back both old PDFs and keeps TXT'

printf 'All PDF publication tests passed.\n'
