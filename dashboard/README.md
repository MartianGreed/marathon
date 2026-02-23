# Marathon Dashboard

Web dashboard for the Marathon distributed Claude Code orchestrator.

## Stack

- **Vite** + **React 19** + **TypeScript**
- **Tailwind CSS v4** (dark theme)
- **react-router-dom** for routing

## Quick Start

```bash
cd dashboard
npm install
npm run dev     # http://localhost:3000
```

## Build

```bash
npm run build   # outputs to dist/
npm run preview # preview production build
```

## Pages

| Route | Description |
|---|---|
| `/` | Overview – node count, active tasks, queue depth, total cost |
| `/nodes` | Node list with status, VM slots, CPU/memory, uptime |
| `/tasks` | Task table with state, duration, cost, Claude turns, PR links |
| `/tasks/:id` | Task detail – logs, conversation, cost breakdown, cancel |
| `/settings` | Cost controls – per-task budget, org cap, kill switch, API key |

## Configuration

| Env Var | Default | Description |
|---|---|---|
| `VITE_API_URL` | `/api` | Orchestrator API base URL |
| `VITE_USE_MOCK` | `true` | Set to `false` to use real API |

## Mock Mode

Runs with realistic mock data by default so you can demo without a running orchestrator. Set `VITE_USE_MOCK=false` in `.env` to connect to the real API.

## API Key Auth

Enter your API key in Settings → Authentication. It's stored in `localStorage` and sent as `X-API-Key` header on every request.

## Real-time

Polls the orchestrator API every 5 seconds. WebSocket stub is in `src/lib/api.ts` (`connectTaskStream`) for future upgrade.
