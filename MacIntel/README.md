# Mac Intel V2.12.19 - etapa 1

Fuentes recuperadas del paquete estable Mac Intel V2.12.18 y cambios acotados a informes, documentación y publicación de PDF. La lógica de audio y conversión se conserva.

## Estructura

- `app/Contents/`: scripts Mac, wrapper, recursos y el generador PDF binario de referencia.
- `docs/source/`: fuentes editables Markdown de las dos guías.
- `docs/`: PDF finales de las guías.
- `packaging/`: construcción y verificación del paquete autónomo.
- `tests/`: pruebas estáticas y de publicación con generador simulado.

FFmpeg y FFprobe se mantienen dentro del ZIP de distribución, pero sus binarios grandes no se agregan al repositorio. El empaquetador exige el ZIP V2.12.18 original, verifica su SHA-256 y copia esas dependencias desde esa base. No descarga ni sustituye binarios.

`GeneradorPDFMacIntel` se conserva sin cambios como dependencia x86_64 porque no se dispone de su código fuente. La fuente de las guías se reconstruyó desde los PDFs aprobados V2.12.18, con cambios mínimos de versión y precisión para V2.12.19.

## Empaquetado

En un entorno con Python 3, usar el ZIP de referencia como entrada explícita:

```powershell
python MacIntel/packaging/build_package.py --base-package "RUTA\Analizador de Multitracks Estudio PG V2.12.18 (Mac Intel).zip"
```

El empaquetador regenera primero los PDF desde las fuentes Markdown. El artefacto se genera bajo `MacIntel/dist/`. El ZIP resultante incluye la aplicación autónoma Intel, sus herramientas, fuentes y documentación PDF.

La construcción del ZIP puede hacerse en Windows. El lanzamiento de la aplicación, la compilación de AppleScript y la prueba integral con sesiones requieren macOS Intel.
