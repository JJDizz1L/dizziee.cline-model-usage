# dizziee.cline-model-usage

Cline token usage stats in the Omarchy bar. Displays today, weekly, and all-time token counts per model.

## Requirements

- Python 3
- Cline with existing session data in `~/.cline/data/db/sessions.db`

## Installation

```sh
git clone https://github.com/JJDizz1L/dizziee.cline-model-usage.git ~/.config/omarchy/plugins/dizziee.cline-model-usage
```

Then enable **Cline Usage** in the Omarchy bar widget settings.

## Configuration

| Key | Type | Default | Description |
|---|---|---|---|
| `refreshIntervalSec` | integer (30–3600) | 300 | How often to re-query the Cline database (seconds) |

## License

MIT
