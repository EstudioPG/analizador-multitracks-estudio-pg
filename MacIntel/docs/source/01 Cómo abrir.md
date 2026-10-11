# Analizador de Multitracks Estudio PG V2.12.19 - Mac Intel

## CÓMO ABRIR

1. Abrí “Analizador de Multitracks Estudio PG V2.12.19 (Mac Intel).app”.
2. Si macOS lo bloquea la primera vez: Configuración del Sistema > Privacidad y seguridad > Abrir igualmente.
3. Elegí la carpeta que contiene los archivos WAV.
4. Recién después de elegirla se abre la ventana de progreso.
5. Al finalizar, la ventana de progreso se cierra y aparece el resultado con la opción de abrir la carpeta correspondiente.

## INFORMES GENERADOS

- **01 Informe de análisis básico.pdf:** resumen operativo para preparar la sesión.
- **02 Informe de análisis detallado.pdf:** evidencia técnica por archivo.
- **INFORME_TECNICO_DESARROLLO.txt:** diagnóstico interno de rendimiento de esta versión; no está pensado para usuarios finales.

Los PDF se generan dentro de la aplicación. No hace falta instalar Python, Swift, fuentes ni herramientas adicionales.

La aplicación genera los dos PDF en una carpeta temporal y los valida antes de publicarlos. Si la generación o publicación falla, conserva los informes básico y detallado en TXT y mantiene los PDF anteriores válidos. También muestra un mensaje de error.

## SALIDA

La carpeta [PROCESADO] se crea solamente si hay archivos que convertir.

Si ya existe, se crea [PROCESADO 2], [PROCESADO 3], etc. Nunca se borra ni se sobrescribe una salida anterior.

Los archivos originales nunca se modifican.
