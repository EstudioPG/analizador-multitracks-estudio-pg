# Resultados de validación V2.12.19 - etapa 1

Fecha: 2026-10-11. Entorno disponible: Windows; no hay un Mac Intel en esta sesión.

## Ejecutado y aprobado

- El ZIP base V2.12.18 coincide con SHA-256 `EE7F04167EF2BEC5BD2EEA15DB23D16E109ABE133AB32B7C79E2A33774286ACF`; los hashes de componentes registrados también coinciden.
- `bash -n` pasó para el script principal, `PublishPDFReports.sh` y la prueba del publicador.
- `tests/test_publish_reports.sh` pasó cuatro escenarios con informes de texto y PDFs simulados: publicación correcta, error del generador, segundo PDF inválido y fallo al renombrar el segundo PDF. En los fallos se conservaron TXT y PDF previos; el fallo de publicación restauró los dos PDF anteriores.
- `py_compile` pasó para el empaquetador, generador de guías y prueba estática.
- `tests/test_static_integrity.py` pasó contra la base V2.12.18 y el paquete V2.12.19. Confirmó que el script de análisis/conversión es idéntico fuera de las secciones autorizadas de informes y PDF; que los duplicados siguen desactivados; y que el informe técnico conserva su estado y contadores.
- Las guías PDF se verificaron con Poppler: A4, una página para “Cómo abrir” y dos para “Qué hace y cómo trabaja”. Rendericé y revisé visualmente todas las páginas; no observé recortes ni caracteres sustituidos.
- `build_package.py` creó el paquete autónomo y pasó `ZipFile.testzip`, los hashes del manifiesto, la versión del bundle, los permisos de ejecución y la identificación Mach-O x86_64 para `GeneradorPDFMacIntel`, `ffmpeg` y `ffprobe`.

## Pendiente por falta de macOS Intel

- Abrir la aplicación, compilar `Progress.applescript` con `osacompile` y probar la interfaz de progreso.
- Ejecutar el generador PDF Mach-O con informes reales de prueba y confirmar su comportamiento al recibir una carpeta temporal como destino.
- Generar los dos PDF de análisis con datos sintéticos y revisar sus nombres, texto y paginación.
- Ejecutar la prueba de extremo a extremo de la aplicación y confirmar su funcionamiento en macOS 10.15 o posterior.
- No se ejecutó `perl -c` porque Perl no está disponible en este Windows. `EffectiveDepth.pl` quedó byte por byte igual que en el ZIP base.

No se abrieron sesiones originales ni se leyeron, copiaron o modificaron WAV de sesiones. El test del publicador usa únicamente archivos temporales de texto y PDFs simulados. Las pruebas de PDFs de análisis reales quedan pendientes; no se consideran aprobadas por el test simulado.
