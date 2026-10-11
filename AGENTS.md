# Analizador de Multitracks Estudio PG



## Objetivo

Mantener y desarrollar el Analizador de Multitracks Estudio PG, una aplicación para Windows que analiza sesiones multitrack y genera informes en PDF.



## Estado de referencia

La versión de referencia funcional es V2.24.17 para Windows. Fue probada manualmente y debe conservarse como referencia de comportamiento.



## Reglas obligatorias

- No modificar archivos originales de audio.

- No cambiar criterios de clasificación sin autorización.

- No cambiar el comportamiento existente sin explicar previamente el motivo, los riesgos y el impacto.

- No reemplazar componentes ni dependencias sin autorización.

- No eliminar funciones existentes para simplificar el código.

- No modificar la versión estable ni la copia de seguridad.

- No generar una versión de distribución sin autorización.

- No ejecutar pruebas sobre sesiones reales sin autorización.



## Procedimiento de trabajo

1. Leer la documentación y analizar el código existente.

2. Explicar el problema y proponer una solución antes de modificar.

3. Identificar los archivos que se modificarían.

4. Esperar autorización antes de realizar cambios.

5. Ejecutar las pruebas disponibles después de modificar.

6. Informar los cambios, resultados y limitaciones.

7. No afirmar que una prueba funcionó si no se ejecutó.



## Entorno Windows

El proyecto utiliza PowerShell, C# y FFmpeg/FFprobe.



Los ejecutables `Recursos/ffmpeg.exe` y `Recursos/ffprobe.exe` corresponden a FFmpeg 9.0.1 de gyan.dev. Están excluidos del repositorio mediante `.gitignore` y deben permanecer disponibles en el entorno local.



No descargar ni sustituir estos ejecutables automáticamente.



## Criterios de calidad

Priorizar la exactitud del análisis y la preservación de los archivos por encima de la velocidad de procesamiento.



Mantener los informes PDF y la estructura de salida existentes, salvo autorización expresa para modificarlos.



## Primera tarea

Inspeccionar el repositorio y documentar la arquitectura actual. No modificar código ni ejecutar cambios.

