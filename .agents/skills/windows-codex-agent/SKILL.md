---
name: windows-codex-agent
description: Launch, supervise, and verify a Codex CLI agent on a user-designated Windows host over SSH. Use when UniSpace or Macifier work must be analyzed or implemented inside the real Windows checkout or runtime; do not use for direct Windows operations that do not need an agent.
---

# Windows Codex Agent

Run the remote agent with the narrowest authority that satisfies the user's request. An agent inherits the user's scope; spawning it does not authorize edits, restarts, deployments, pushes, or system changes.

## Preflight

1. Verify the exact SSH host key, hostname, Windows user, PowerShell version, and SSH session. Never disable host-key checking or guess the account.
2. Verify Codex without exposing credentials:
   - `Get-Command codex`
   - `codex --version`
   - `codex login status`
3. Resolve the exact checkout from the user's path or `git worktree list --porcelain`. A linked worktree may contain a `.git` file rather than a directory. Do not silently clone, select a similarly named checkout, or replace dirty source.
4. Record `git status --short --branch`, branch, HEAD, worktrees, and any installed process path/version/hash relevant to the task.

Treat the Windows source checkout, built artifact, and running process as separate state.

## Launch

Windows OpenSSH commonly invokes commands through `cmd.exe`. For prompts or commands containing quotes, pipelines, or variables, copy a collision-free temporary prompt or PowerShell script and invoke it with `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ...`.

For analysis, default to a non-persistent read-only run:

```powershell
Get-Content -Raw $promptPath |
    & (Get-Command codex).Source exec `
        --ephemeral `
        --sandbox read-only `
        -c 'approval_policy="never"' `
        -C $repository `
        -
```

- Use `--skip-git-repo-check` only when the target intentionally has no repository.
- Use `--json` when a caller needs machine-readable progress; otherwise preserve streamed diagnostics and the final response.
- Omit `--ephemeral` only when resuming the session is useful, then record the session ID. Resume with `codex exec resume <SESSION_ID> "<follow-up>"`.
- Use `--sandbox workspace-write` only when the user requested implementation. Keep writes inside a clean task worktree when the checkout is dirty.
- Never add `--dangerously-bypass-approvals-and-sandbox` merely to make automation succeed.

Native Windows sandbox startup can fail before the requested command runs, including status `0xC0000142`. Treat that as a sandbox failure, not an application failure. Retry with the official Windows sandbox configuration (`-c 'windows.sandbox="elevated"'`, or `unelevated` when elevated setup is unavailable); do not broaden filesystem authority. If both modes fail, report the block rather than silently running unrestricted.

## Supervise and verify

- Keep the SSH/Codex process attached and poll long-running output without leaving the user silent for more than a minute.
- Capture the Codex header: version, working directory, model, approval policy, sandbox, and session ID.
- Give the remote agent exact evidence and explicit non-actions. Ask it to separate verified facts from inference and cite Windows paths and line numbers.
- Independently verify its claims afterward: Git status/diff, HEAD, process/socket state, test exit codes, and requested business flow. An agent's final message is not proof by itself.
- Confirm the original checkout and live process remain unchanged unless the user authorized mutation.

## Cleanup and report

Remove only task-owned prompt files, scripts, bundles, worktrees, and temporary refs after verification. Preserve persistent session data when follow-up is expected.

Report the exact host/user, checkout/HEAD/dirty state, Codex version/session/sandbox, result, independent verification, residual gaps, and cleanup. For GUI apps, do not claim a visible restart from SSH session 0; use the project's Windows deployment workflow when restart or installation is explicitly requested.
