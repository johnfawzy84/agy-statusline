# agy-statusline

Status line para **Antigravity CLI** (`agy`) — muestra modelo activo, contexto de sesión, directorio/rama git y cuotas de uso en tiempo real.

## Qué muestra

```text
Claude Sonnet 4.6 (Thinking) │ ✍️  27% │ mi-proyecto (main*) │ Google AI Pro

claude 5h ●●○○○○○○○○  21% ⟳ 20:40
claude 7d ●○○○○○○○○○  16% ⟳ jul 4, 20:57
```

| Campo | Descripción |
|-------|-------------|
| Modelo | Modelo activo en la sesión |
| `✍️ %` | Contexto de la sesión actual |
| Directorio (rama*) | Directorio de trabajo + rama git (`*` = cambios sin commit) |
| Plan | Tier de cuenta (Google AI Pro, etc.) |
| `claude/gemini 5h` | Cuota de la ventana de 5 horas del pool activo |
| `claude/gemini 7d` | Cuota semanal del pool activo |

> La cuota que se muestra (`claude` o `gemini`) se detecta automáticamente según el modelo activo en la sesión.

## Requisitos

- [`jq`](https://jqlang.github.io/jq/) — para parsear JSON
- `git` — para info de rama
- `agy` (Antigravity CLI) instalado y configurado

## Instalación

```bash
git clone https://github.com/tu-usuario/agy-statusline
cd agy-statusline
bash bin/install.sh
```

Reiniciá `agy` para ver el statusline.

## Desinstalación

```bash
bash bin/uninstall.sh
```

## Estructura

```
agy-statusline/
├── bin/
│   ├── statusline.sh   # Script principal (se copia a ~/.gemini/)
│   ├── install.sh      # Instalador
│   └── uninstall.sh    # Desinstalador
└── README.md
```

## Cómo funciona

`agy` ejecuta el comando configurado en `statusLine` de `settings.json` y le pasa un JSON por stdin con el estado actual de la sesión. El script lo parsea y devuelve el texto formateado con colores ANSI.

El archivo de configuración que se modifica es:

```
~/.gemini/antigravity-cli/settings.json
```

Con:

```json
"statusLine": {
  "type": "command",
  "command": "bash \"$HOME/.gemini/statusline.sh\"",
  "enabled": true
}
```
