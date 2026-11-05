# Cuota IA

Panel nativo y widget de escritorio para ver cuotas de suscripciones de IA en dos Macs.

## Estado real

| Servicio | Fuente | Disponible |
|---|---|---|
| Codex | `codex app-server`, `account/rateLimits/read` | Porcentajes de las ventanas y próximos reinicios |
| Codex, actividad | `account/usage/read` | Tokens históricos de la cuenta; **no** representan saldo ni límite del plan |
| Claude | OAuth de Claude Code, endpoint de uso | Sesión y semana, más cuotas por modelo si las devuelve Claude |
| ChatGPT | Sesión propia y respuesta de inicio del chat normal | Cupos reales de investigaciones, archivos, texto a archivo e imágenes, con reinicios. No hay contador de preguntas normales |
| Gemini app | Sesión WebKit propia, consulta de la página de uso | Ventanas de cinco horas y semanal; lectura real y sincronización verificadas |

No hay llamadas de inferencia, compras, cambios de plan, ni reinicios de cuota automáticos.
No se estima una fecha de agotamiento: depende del uso futuro. Se muestra el reinicio real informado por el proveedor.

## Uso

La app se instala en `~/Applications/Cuota IA.app`. Abre una ventana y un icono de barra de menú.
La ventana inicial es un resumen translúcido de 300 × 112 puntos. Muestra el porcentaje disponible
en la primera ventana de cada servicio; un guion indica que no hay medición. Se mueve desde su
cabecera y al pulsar los porcentajes abre el panel completo. En la barra de menú están **Mostrar resumen**
y **Mostrar panel**. El botón de contraer del panel vuelve al resumen.
El resumen queda detrás de las ventanas normales para no tapar el trabajo; se ve al mostrar el escritorio.
El alfiler permite mantener la ventana sobre las otras aplicaciones.

En la Mac principal: clic derecho en el escritorio → **Editar widgets** → buscar **Cuota IA**.
Hay tamaños mediano y grande. El grande incluye la ventana semanal además de la sesión.
macOS decide el momento efectivo de actualización del widget; la app pide una nueva lectura cada minuto.
El recolector consulta los proveedores cada tres minutos.

En la Mac servidor con Ventura se instala la misma app universal, sin la extensión de escritorio (requiere macOS 14).
En Ventura el panel usa AppKit para evitar un fallo reproducido en SwiftUI sobre la Mac Intel.
El LaunchAgent supervisa el proceso real de la app y lo reinicia tras un fallo; **Salir** la cierra voluntariamente.
La tarjeta queda detrás de las ventanas normales y puede verse al mostrar el escritorio.

**Conectar ChatGPT** abre la página de uso de la cuenta familiar en una sesión propia de WebKit.
La página de esta cuenta indica que los chats normales no están incluidos en su contador: los límites publicados
son compartidos por Codex, Work, Workspace Agents y ChatGPT para Excel. Por eso se muestra el estado de conexión
y la limitación; no se inventa un porcentaje de consumo del chat familiar.
Se verificó una segunda fuente en la respuesta que solicita el chat normal al abrirse:
`limits_progress` devuelve cupos de herramientas y sus reinicios. Se muestran con su unidad real,
sin convertirlos en tokens ni en cantidad de preguntas restantes. El resumen muestra **Activa**
para la sesión de ChatGPT y el detalle muestra cada herramienta. La sesión se consulta cada tres minutos
mientras Cuota IA está abierta; no se recarga una conversación ni un borrador de consulta.

Para Gemini: **Conectar Gemini**, iniciar sesión en la ventana y pulsar **Leer consumo**.
La sesión queda en el almacén WebKit de la app en esa Mac, no en el servidor.
Mientras la app está abierta, vuelve a consultar cada tres minutos. Si Google rechaza el navegador integrado,
la integración queda pendiente; no se extraen cookies de otros navegadores para evitarlo.

Claude usa credenciales existentes de Claude Code y una caché propia en el Llavero.
El proceso de sondeo no puede abrir diálogos de autenticación. Si la sesión vence y macOS no permite
leer la credencial nueva, el panel conserva la medición anterior como desactualizada. Abrir Claude Code
y usar la flecha de Claude en el panel permite reconectar con una acción explícita.
No se rotan tokens de Claude por cuenta propia ni se modifica su entrada original del Llavero.

## Dos Macs

Las credenciales de los proveedores se mantienen en la Mac principal. El servicio consulta Codex y Claude allí.
Solo envía el snapshot validado (nombre, porcentajes, reinicios, plan y actividad histórica de Codex) al servidor,
mediante SSH y su clave existente. Ambos servicios HTTP escuchan exclusivamente en `127.0.0.1:8769`.
No se abre ningún puerto en la red local.

La sincronización usa una configuración SSH propia en `~/Library/Application Support/QuotaGarden/ssh.config`.
No modifica `~/.ssh/config`. Si cambia la IP del servidor, actualizar `HostName` en ese archivo.
La clave de host se contrasta con la identidad conocida del servidor bajo `192.168.86.246`.

Si la Mac principal está apagada, el servidor muestra la última lectura y la marca como anterior a partir de 10 minutos.
Una desconexión nunca se transforma en 0 % consumido. Una hora de reinicio pasada tampoco repone la barra:
hay que confirmar la nueva cuota con el proveedor.

## Compilar e instalar

Requiere Xcode y XcodeGen en la Mac de desarrollo. Python 3 estándar, sin paquetes externos.

```sh
zsh scripts/build.sh
python3 -m unittest discover -s tests -v
python3 scripts/install.py --app-source 'build/DerivedData/Build/Products/Release/Cuota IA.app' --server-ip 192.168.86.249
```

La app tiene compilaciones arm64 y x86_64 con destino macOS 13; la extensión requiere macOS 14.
Se firma localmente de forma ad hoc; no requiere ni publica en una cuenta de Apple Developer.

En el servidor se copian `collector/quota_service.py`, `scripts/install.py` y la app compilada a `~/QuotaGarden`:

```sh
python3 ~/QuotaGarden/scripts/install.py --receiver --app-source "$HOME/QuotaGarden/deploy/Cuota IA.app"
```

Instala dos LaunchAgents por usuario: `dev.bambam.QuotaGarden.service` y `dev.bambam.QuotaGarden.app`.
Los datos y registros propios están en `~/Library/Application Support/QuotaGarden`.
Las versiones previas de la app se conservan allí como `app-backup-*` al reinstalar.
No se guardan secretos de proveedores en logs, snapshots ni Git.

Para detener y quitar el inicio automático, conservando app y datos:

```sh
python3 scripts/uninstall.py
```

## Referencias verificadas

- [OpenAI Docs: Codex app-server](https://learn.chatgpt.com/docs/app-server).
- [Claude: límites de uso](https://support.claude.com/en/articles/11647753-how-do-usage-and-length-limits-work).
- [Apple: crear una extensión WidgetKit](https://developer.apple.com/documentation/widgetkit/creating-a-widget-extension).
- [CodexBar, documentación de fuentes de Claude](https://github.com/steipete/CodexBar/blob/main/docs/claude.md)
  y [Gemini](https://github.com/steipete/CodexBar/blob/main/docs/gemini.md): referencia de protocolos web;
  no se distribuye ese proyecto ni se depende de su ejecutable.
