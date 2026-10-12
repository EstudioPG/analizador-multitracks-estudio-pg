# Procedencia y dependencias Mac Intel

## Paquete base

- Archivo: `Analizador de Multitracks Estudio PG V2.12.18 (Mac Intel).zip` (suministrado por el usuario en Downloads; no versionado).
- SHA-256: `EE7F04167EF2BEC5BD2EEA15DB23D16E109ABE133AB32B7C79E2A33774286ACF`.
- El paquete base V2.12.18 declaraba macOS 10.15. V2.12.19 requiere macOS 11.0 por el mínimo de despliegue confirmado en el generador PDF.
- El archivo incluye ejecutables Mach-O x86_64 y conserva modos Unix de ejecución en las entradas ZIP.

## Componentes incorporados o conservados

| Componente | Procedencia | SHA-256 de la base | Tratamiento |
|---|---|---|---|
| `AnalizadorMultitracksV2.command` | ZIP V2.12.18 | `e60b0d20f83d9d7dc0e646d83e67237ce04cae54c020e960f8958dc18eee195c` | Fuente recuperada; cambios solo en informes y publicación PDF. |
| `Info.plist` | ZIP V2.12.18 | `b337b15771ba8c59d01e47341aedf5f35ee48385c6bf54dec3dc16755e53d403` | Versión de bundle actualizada a 2.12.19; mínimo elevado a macOS 11.0 tras verificar el generador PDF. |
| `EffectiveDepth.pl` | ZIP V2.12.18 | `ac4402c06fc1d2ad2c033522439096ae04608d78422f95625465d0b34759b320` | Conservado sin cambios. |
| `Progress.applescript` | ZIP V2.12.18 | `0f448b3d27fee8e7a995fde6a1d07b0bd837f12c470127e9e386880ccffe92ab` | Conservado; solo cambia el rótulo de versión. |
| `GeneradorPDFMacIntel` | ZIP V2.12.18 | `7cc720272d5749a77454d497d45a893ec93ed7284c6039690fb6d28faf01d0b7` | Binario x86_64, sin cambios; no se encontró su fuente. |
| `ffmpeg` | ZIP V2.12.18 | `e27de05e3a9f9c758f9766d15d1a069fddeed5f725e35d9ab28683be4740dad7` | Binario x86_64; no se versiona por tamaño, el empaquetador lo toma de la base verificada. |
| `ffprobe` | ZIP V2.12.18 | `a1508faa028bfb8e20c9d182c3d41fcff29ee7584ae21b2d6c357472a3ecbc24` | Binario x86_64; no se versiona por tamaño, el empaquetador lo toma de la base verificada. |
| `DejaVuSans.ttf` | ZIP V2.12.18 | `ae7b7855e115a5966d8b1b3f80f254ccc117ec86f9965e202ee2940453837280` | Conservada; acompaña la licencia incluida. |
| `DejaVuSans-Bold.ttf` | ZIP V2.12.18 | `5c1247acef7f2b8522a31742c76d6adcb5569bacc0be7ceaa4dc39dd252ce895` | Conservada; acompaña la licencia incluida. |
| `AnalizadorMultitracks` | ZIP V2.12.18 | `41fc269df94e10b684c26663b92c71116e5a3cc5e1d3929b85bd4c2700754449` | Launcher recuperado; cambia el rótulo de versión y el texto del error PDF para incluir fallos de publicación. |
| `AppIcon.icns` | ZIP V2.12.18 | `fa1dd038f248388ad30c368c21e159e6461c054d00d7a380256a32eb966f0540` | Conservado sin cambios. |
| `LICENCIA_FUENTE_DEJAVU.txt` | ZIP V2.12.18 | `e180b3d65bf650dffffd71dd21b6180767b469a18dd87e1d8552be69bb9ecdf0` | Conservada junto a las fuentes DejaVu. |

Las guías PDF V2.12.18 se extrajeron del mismo ZIP: `01 Cómo abrir.pdf`, SHA-256 `b67b4045327c90f3d6cfc3788df77eba0af38c16fb88c4ac7ab660197daa6518`; `02 Qué hace y cómo trabaja.pdf`, SHA-256 `480292c4e8e0e10dd01e81cec265204704bb18cda16e9f31cfc952a6c8d3e04a`. Sus fuentes Markdown se reconstruyeron a partir del texto y el diseño aprobados; no se presentan como fuentes originales recuperadas.

## Compatibilidad mínima confirmada

Los load commands Mach-O de `GeneradorPDFMacIntel` declaran `LC_BUILD_VERSION` para macOS 11.0.0. FFmpeg y FFprobe declaran `LC_VERSION_MIN_MACOSX` 10.13.0. Por eso V2.12.19 fija el mínimo en macOS 11.0. Esta lectura de metadatos no sustituye una prueba real de ejecución en macOS.

La verificación de publicación runtime revisa la cabecera `%PDF-`, la presencia de `startxref` y el cierre `%%EOF`. El generador nativo no tiene código fuente ni se dispone de un parser PDF dentro del bundle; la prueba integral con su salida real queda pendiente en macOS Intel.
