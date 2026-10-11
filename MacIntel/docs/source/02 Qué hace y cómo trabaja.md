# Analizador de Multitracks Estudio PG V2.12.19 - Mac Intel

## MOTOR DE ANÁLISIS

El Analizador utiliza FFmpeg y FFprobe como motor de análisis y procesamiento de audio.

FFmpeg es un conjunto de herramientas de código abierto ampliamente utilizado para leer, analizar, convertir y procesar audio y video. También forma parte de la infraestructura o de los componentes utilizados por software conocido como OBS y VLC.

Las versiones necesarias de FFmpeg y FFprobe están incluidas dentro de la aplicación: no hace falta instalarlas por separado.

Las clasificaciones y decisiones del Analizador se basan en reglas propias que combinan esos datos con criterios definidos para esta aplicación. FFmpeg y FFprobe no deciden por sí solos la clasificación.

## QUÉ HACE

Analiza automáticamente una carpeta de archivos WAV antes de crear una sesión de mezcla. Revisa formato, duración, nivel, estructura mono/estéreo y profundidad efectiva.

La comparación de pistas duplicadas está temporalmente desactivada en esta versión. No se generan resultados que indiquen si existen duplicados.

## CLASIFICACIÓN Y CONVERSIONES

- Mono original: sin cambios.
- Estéreo real: sin cambios.
- Dual Mono exacto: convierte a mono.
- Dual Mono práctico: convierte a mono cuando cumple criterios estrictos de similitud.
- Mono paneado: convierte a mono conservando el canal de mayor nivel.
- Casos dudosos: se informan para revisión manual.

Los archivos originales nunca se modifican.

Si hay conversiones, se crea una carpeta espejo [PROCESADO] y los archivos convertidos agregan [MONO] al nombre.

Si ya existe una salida anterior, se crea [PROCESADO 2], [PROCESADO 3], etc.; nunca se borra ni se sobrescribe una salida previa.

## CONTROLES PRINCIPALES

- Sample rate predominante y diferencias.
- Profundidad PCM predominante y diferencias.
- FLOAT 32 identificado por separado y excluido de comparaciones de profundidad PCM/LSB.
- Duración de referencia y archivos con duración diferente.
- Silencio digital, nivel bajo y nivel extremadamente bajo.
- Profundidad efectiva en PCM entero.

## INFORMES

**01 Informe de análisis básico.pdf** resume los datos necesarios para preparar la sesión y tomar decisiones operativas.

**02 Informe de análisis detallado.pdf** presenta evidencia técnica por archivo, distingue Dual Mono exacto y Dual Mono práctico, y numera los audios para facilitar la lectura de sesiones grandes.

Los dos PDF usan tipografía DejaVu y se generan localmente con un motor incluido dentro de la aplicación. La publicación ocurre únicamente después de generar y validar ambos archivos. Si falla, los TXT intermedios y los PDF anteriores válidos se conservan.

**INFORME_TECNICO_DESARROLLO.txt** es un informe interno de esta versión. Registra tiempos por etapa, rendimiento, ETA, el estado de la comparación de duplicados y otros datos de diagnóstico. No está pensado para entregarse a usuarios finales.

## PROGRESO

Después de seleccionar la carpeta se abre la ventana de progreso. Muestra etapa actual, porcentaje, archivo en proceso, tiempo transcurrido y tiempo restante aproximado.

Al finalizar, esa ventana se cierra automáticamente y se muestra el resultado final con la opción de abrir la carpeta correspondiente.
