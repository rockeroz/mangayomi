# Mihon Sync en Mangayomi

Esta rama (`mihon-sync`) añade a Mangayomi la sincronización compatible con **Mihon Sync 0.7.2** (Android). Los dos usan la misma carpeta WebDAV y el mismo formato: documento esquema 4 e índice incremental `mihon-sync-v2-manifest.json`.

## Qué se sincroniza

- Mangas en la biblioteca (añadir y quitar).
- Capítulos leídos, página exacta y marcadores.
- Categorías: nombre, orden, borrado y pertenencia, con el mismo identificador compartido que usa Mihon.
- Historial: última lectura de cada manga.

Solo participan mangas de **extensiones de Mihon** usadas desde Mangayomi (servidor de extensiones). Un manga de una extensión propia de Mangayomi (JS/Dart) no tiene equivalente en Mihon y no se comparte.

Mangayomi conserva sin cambios lo que solo Mihon usa: tiendas y extensiones instaladas, migraciones, ajustes del lector por manga y trackers. Esos datos siguen viajando entre tus dispositivos Android.

## Cómo se usa

1. En Mangayomi, añade los mismos repositorios de extensiones de Mihon que tienes en el celular (por ejemplo Keiyoushi) e instala las extensiones.
2. Abre **Más → Ajustes → Mihon Sync (WebDAV)**.
3. Escribe la misma URL de carpeta, usuario y contraseña de aplicación que en Mihon Sync. Pulsa **Probar conexión** y después **Guardar**.
4. Activa **Sincronización activada** y pulsa **Sincronizar ahora**.

La sincronización se ejecuta al abrir la app, al cerrar el lector y cada 15 minutos mientras Mangayomi está abierto (configurable). Mientras el lector está abierto se envía tu progreso, pero los cambios recibidos esperan a que lo cierres.

La primera vez Mangayomi descarga la biblioteca completa. Después solo descarga los cambios, y si nada cambió el servidor responde "sin cambios" (304).

## Cómo reconoce los mangas

Mihon identifica un manga por **ID de fuente + URL**. Mangayomi guarda las fuentes de Mihon con otro ID (`'mihon-<id>'.hashCode`), así que esta versión recuerda el ID original de Mihon cada vez que Mangayomi lee la lista de un repositorio. Si un manga de tu biblioteca usa una fuente cuyo ID todavía no se conoce, la sincronización consulta la lista de ese repositorio. Si aun así no se identifica, ese manga se omite y el estado lo indica.

Un manga recibido del celular cuya fuente no aparece en ningún repositorio añadido en Mangayomi se deja pendiente. Se aplica cuando añadas ese repositorio.

## Diferencias entre las dos apps

- Mangayomi guarda las páginas empezando en 1 y Mihon en 0; la conversión es automática. Al terminar un capítulo, Mangayomi vuelve a la página 1; si el capítulo está leído en ambos lados, se conserva la página que guardó Mihon.
- Mangayomi guarda un solo registro de historial por manga (el último capítulo leído). Mihon guarda una fecha por capítulo. Al recibir, se toma el capítulo con la fecha más reciente.
- Un manga recibido que no existía se crea con título, portada y capítulos del documento compartido. Al abrirlo, Mangayomi completa los datos desde la fuente.

## Archivos locales

En la carpeta de soporte de la app (`…/mihon-sync/`): ajustes, journal y caché por cuenta, identificadores de categoría e IDs de fuentes de Mihon. La contraseña se guarda en el almacenamiento seguro del sistema.

## Compilación

El workflow `.github/workflows/mihon-sync.yml` analiza el código, ejecuta las pruebas de sincronización y compila la versión de Windows al subir cambios a la rama `mihon-sync`. El resultado queda como artefacto **Mangayomi-MihonSync-windows** en la ejecución de Actions.

## Pruebas

`test/services/mihon_sync_test.dart` comprueba:

- lectura de un documento escrito como lo escribe Mihon 0.7.2, con campos omitidos;
- ida y vuelta sin cambios;
- conservación de los datos solo de Mihon;
- convergencia de dos dispositivos contra un WebDAV simulado con ETags;
- respuestas 304, partes de cambios y compactación tras 32 cambios;
- lector abierto;
- lectura de un índice publicado por Mihon;
- rechazo de servidores que ignoran escrituras condicionales.

No se ha probado con la base de datos real de Mangayomi en un dispositivo, ni con el servidor del usuario junto a Mihon Sync en un teléfono.
