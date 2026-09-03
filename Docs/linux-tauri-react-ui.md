# Linux Tauri UI → production React app

Status: **implemented on `feat/linux-tauri-react-ui`**. Track A live gates stay OPEN. Live dellom window walk still depends on deploying this branch to the host.
Date: 2026-09-03.
Branch when implementing: `feat/linux-tauri-react-ui` from current `feat/linux-receiver` (HEAD at plan save: `ebf6975`). Do not mix this into PR #39 pointer validation. Do not push, merge, or mark Track A complete without explicit authority.

## Current state

The Linux UI is not a React app. It is a single vanilla file, `Linux/ui/index.html`, loaded as a static `frontendDist` by `Linux/tauri.conf.json` (`withGlobalTauri: true`, `csp: null`). The window binary is `Linux/src/bin/ui.rs`.

Commits after the original Track A handover (`b5a2198`) include WebKit/Omarchy usability work (`1ab5632`, `0f33e1d`, `ebf6975`). The React refactor must preserve those IPC and click-reliability constraints.

Screens today (preserve copy, window size, and flows; restyle with shadcn tokens, not a new product identity):

- unpaired **Connect**
- **Confirm pairing** (6-digit tiles)
- paired **Home / Transfers / Clipboard** plus unpair dialog

Live state is `ReceiverSnapshot` from `Linux/src/observe.rs` (`rename_all = "camelCase"`). Updates arrive three ways, all required:

1. `on_page_load` `webview.eval` sets `window.__unispaceBoot` (webkit2gtk invoke is unreliable)
2. Tauri event `receiver-status` plus a JSON-equality `eval` of `window.__unispaceApply`
3. Frontend `local_state` then `state`, polled every 2s

A previous DOM-rebuild-on-every-snapshot bug ate clicks. React must apply snapshots immutably and keep transfer list identity stable (`transfer.id`).

Rust command surface stays unchanged: `ping`, `local_state`, `state`, `begin_pairing`, `confirm_pairing`, `cancel_pairing`, `unpair`, `start_service`, `stop_service`, `restart_receiver`, `choose_files`, `send_files`, `open_folder`.

Do **not** touch pointer/uinput/watchdog/keepalive, Wayland chrome heal, or single-instance `ui.sock`. Check `git status` before every mutation.

## Stack from gitui

Reference: `/Users/tai/projects/gitui` (Cairn desktop). Copy **choices**, not **pins**. Resolve current latest of each package at implement time (`pnpm add` / `npx shadcn@latest`). Do **not** copy Cairn product code (xterm, docking, cmdk, markdown, Inter CDN, Playwright visual, src-tauri layout, extra Tauri plugins) and do **not** freeze gitui’s React 18.3 / Vite 6 / pnpm 10.33 / per-package Radix. Keep UniSpace’s existing Rust crate (`Linux/src/bin/ui.rs`, nFPM two binaries).

| Layer | Choice (from gitui) | Versions |
|---|---|---|
| Package manager | pnpm; commit `pnpm-lock.yaml` | latest pnpm; set `packageManager` to that version |
| UI | React + `react-dom` | current React (19 if that is latest) |
| Bundler | Vite + `@vitejs/plugin-react` + `@tailwindcss/vite`; port 1420, `strictPort`, `clearScreen: false`, `TAURI_DEV_HOST` | current Vite |
| CSS | Tailwind 4 + `tw-animate-css`; `@import "tailwindcss"` + layer split (`theme, base, app, components, utilities`) | current Tailwind 4.x |
| shadcn | `new-york`, `rsc: false`, `baseColor: slate`, `cssVariables`, lucide | `npx shadcn@latest init` / `add` |
| Radix | whatever **latest shadcn** emits (unified `radix-ui` is fine) | do not pin gitui’s `@radix-ui/react-*` split |
| Utils | `class-variance-authority`, `clsx`, `tailwind-merge`, `cn()` | latest |
| Icons | `lucide-react` | latest |
| State | zustand store for `ReceiverSnapshot` + pairing phase | latest zustand |
| Tauri JS | `@tauri-apps/api` v2, `withGlobalTauri: true`, `__TAURI__` fallback | latest 2.x |
| Tests | Vitest + **happy-dom**, `src/**/*.test.ts(x)`, mock `@tauri-apps/api/core` | current Vitest |
| Types | `strict`, `@/*` → `./src/*` | current TypeScript |

Primitives: latest shadcn `button`, `input`, `label`, `badge`, `dialog`, `tooltip`, plus `card`, `tabs`, `alert`, `alert-dialog`, `progress`, `separator`. Do not `add --all`. Unpair uses **AlertDialog**. Pairing code tiles stay a small custom component.

Theme mechanism from gitui (`index.css` `@theme inline` bridging `--bg/--ink/--accent` → shadcn `--color-*`; dark via `[data-theme="dark"]`, not `next-themes`). Palette stays UniSpace: accent `#0a84ff` as `--accent` / `--color-primary`. Fonts: `--font-ui` with **system fallbacks only** (no Inter/Geist network load in WebKitGTK). `prefers-color-scheme` sets `data-theme`. Respect `prefers-reduced-motion`. No nested cards, no extra accent colors.

```
Linux/ui/
  package.json              # packageManager: latest pnpm
  pnpm-lock.yaml
  components.json           # new-york / slate / lucide (latest CLI schema)
  vite.config.ts
  vitest.config.ts          # happy-dom, separate from app build
  tsconfig.json
  tsconfig.node.json
  index.html
  src/
    main.tsx
    app.tsx
    index.css               # tailwind + tw-animate + token bridge
    theme.css               # UniSpace --bg/--ink/--accent + data-theme
    test/setup.ts           # vi.mock @tauri-apps/api/*
    lib/utils.ts
    lib/tauri.ts
    lib/types.ts
    lib/format.ts
    state/receiver-store.ts # zustand; window.__unispaceApply
    screens/…
    panels/…
    components/ui/          # latest shadcn primitives
    components/pairing-code.tsx
```

## Screen composition

- Welcome: centered `Card` + `Label`/`Input` + primary `Button` + `Alert` for errors
- Confirm: `Card` + pairing-code tiles + `Button` row
- Shell: header + status `Badge`s + `Tabs` (Home / Transfers / Clipboard)
- Home: one `Card` status list (controller, service, uinput) + ghost Unpair
- Transfers: toolbar `Button`s + `Card`+`Progress` per transfer; empty `Card`
- Clipboard: `Card` + `Badge`; `Alert` if reconnecting
- Unpair: `AlertDialog`

No React Router: route from `snapshot.paired` + pairing phase + `Tabs` value.

## IPC and WebKit fallbacks

IPC wrapper caches `@tauri-apps/api` but falls back to `window.__TAURI__.core.invoke` / `.event.listen` so a broken webview IPC still works.

Boot stub in `index.html` (before React):

```js
window.__unispaceApply = window.__unispaceApply || function (s) { window.__unispaceBoot = s; };
```

`main.tsx` installs the store’s `apply`, then applies `window.__unispaceBoot`. That lets Rust keep a **short** `on_page_load` eval (boot JSON + `__unispaceApply`) and drop the current DOM-mutating script in `Linux/src/bin/ui.rs`. `push_snapshot` eval stays, still gated on JSON equality.

Keep `withGlobalTauri: true`. Set a tight production CSP in `tauri.conf.json` (`default-src 'self'`; allow bundled CSS). Confirm `webview.eval` still injects after CSP (WebKit evaluateJavaScript typically bypasses page CSP). Tailwind output is bundled; Radix portals stay in-document.

## Build / CI (cargo must keep working)

Today `cargo build --bin unispace-linux-ui` embeds `./ui` with no Node toolchain. Tauri `beforeBuildCommand` is **not** enough: this repo builds via Cargo, and `bundle.active` is false.

- Point `frontendDist` at `./ui/dist`. Add `devUrl` + `beforeDevCommand` for `tauri dev` only.
- Enable Tauri’s `custom-protocol` feature in `Linux/Cargo.toml`. This repo ships with `cargo build --release`, not `tauri build`; without that feature every cargo binary is treated as `tauri dev` and opens `http://localhost:1420`.
- `Linux/build.rs`: if `UNISPACE_SKIP_UI_BUILD` is unset, run `pnpm install --frozen-lockfile` when `ui/node_modules` is missing, then `pnpm build`, then `tauri_build::build()`. Fail with a clear “install Node LTS and pnpm” message.
- `.github/workflows/linux-receiver-ci.yml`: current Node LTS + latest pnpm, then `pnpm install --frozen-lockfile` + `pnpm test` + `pnpm build` in `Linux/ui` **before** cargo fmt/test/clippy.
- Gitignore `Linux/ui/node_modules` and `Linux/ui/dist`; commit `pnpm-lock.yaml`.

## Tests

Vitest + happy-dom, gitui-style `src/test/setup.ts` mocks for `@tauri-apps/api/core` and `event`:

- `formatBytes` / transfer percent
- zustand store: unpaired → paired, notice routing (pair form vs Home), idempotent apply
- Welcome validation (“Enter the controller…”)
- pairing confirm tiles from `Offer.code`
- mock `invoke` for begin/confirm/unpair/start/stop

Do not weaken Rust or macOS QoS/coverage thresholds.

## Implementation checklist

1. `git status` before any mutation; create `feat/linux-tauri-react-ui` from `feat/linux-receiver`.
2. Scaffold `Linux/ui` with gitui choices at current latest versions.
3. Zustand receiver store + `__TAURI__` fallback; `window.__unispaceApply` / `__unispaceBoot`.
4. Compose Welcome / Confirm / Shell from shadcn primitives; keep copy and 760×640; stable transfer keys.
5. Slim `on_page_load` eval; `frontendDist` `./ui/dist`; `build.rs` pnpm build; optional CSP.
6. Vitest + happy-dom; Node LTS + pnpm in Linux CI.
7. Local: `pnpm test` in `Linux/ui`; `cargo test --manifest-path Linux/Cargo.toml`; `cargo clippy --all-targets -- -D warnings`.
8. Live dellom: build `unispace-linux-ui`, launch from the graphical session, walk Connect → (skip live pair if already paired) Home / Transfers / Clipboard / unpair dialog cancel. Confirm tray still opens the window and clicks are not eaten.
9. No push, no Track A “complete”, no PR unless asked.

## Out of scope

Cairn/gitui product features (terminal, docking, cmdk, Playwright visual). New UniSpace product identity. Extra settings pages. Next.js, React Router. `shadcn add --all`. Generating specta types. Changing invoke names. systemd/uinput permission changes. Track A physical/QA hosts. Do not freeze gitui’s package versions.
