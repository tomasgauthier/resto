# resto

App de barra de menú para macOS que muestra **cuánta cuota te queda** en los CLIs de IA
que tengas instalados, más la RAM que están consumiendo.

Dos superficies:

- **Menu bar** — el detalle completo: cada CLI, su cuota real cuando el proveedor la expone,
  su sesión local, su RSS, y la RAM del sistema. Acá también eliges con el alfiler qué filas
  van en la pebble.
- **Pebble** — una píldora flotante y arrastrable con sólo lo alfilerado. No se expande: para
  el detalle está el menu bar.

## Qué sabe de cada CLI

| CLI | Cuota real | De dónde |
|---|---|---|
| Claude Code | sí | `api.anthropic.com/api/oauth/usage` con el token OAuth del Llavero |
| Codex | sí | JSON-RPC contra el `codex app-server` local |
| Kimi Code | sí | `api.kimi.com/coding/v1/usages` |
| Antigravity (`agy`) | no | el CLI no la expone |
| Gemini CLI, OpenCode, GitHub Copilot | no | sólo historial local |

Los que no entregan cuota muestran su sesión reciente (historial local en `jsonl`, o SQLite
en el caso de OpenCode) y la RAM de sus procesos.

La app no lee, guarda ni imprime tokens: el de Claude viaja por un pipe desde `security` y se
usa una sola vez por consulta.

## Compilar

Requiere macOS 14+ y Swift 6.

```sh
make app     # compila en release y arma resto.app
make run     # lo anterior, y la abre
make test    # self-test de la ventana de 5 h y del parseo de RAM
```

`resto.app` es una app accesoria (`LSUIElement`): vive en la barra de menú, no en el Dock.
Para que arranque sola, agrégala en Ajustes → General → Ítems de inicio.

## Ícono

`Icon/resto.svg` sigue el sistema de glifos de gauthier.cl: caja 64×64 sobre navy `#05012F`,
polilínea lima `#c0f600` con eco azul `#2222ff` desfasado `(-1.2, +1.2)`, sólo rectas.
El `.icns` se rasteriza con sharp a `density: 600` — ImageMagick descarta los `stroke`
heredados del `<g>` y devuelve un cuadrado navy.
