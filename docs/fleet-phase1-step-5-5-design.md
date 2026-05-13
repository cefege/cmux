# Fleet Phase 1 — Step 5.5: cmux owns the local PTY via Ghostty manual-IO

**Status:** design pass complete (2026-05-12). No code yet.
**Branch:** `fleet-phase1` on `cefege/cmux`.
**Blocks:** step 6 (POST `/v1/workspaces/:id/attach`) and step 7 (create workspace on a peer).
**Unblocks (side benefits):** session recording, AI summaries, terminal search-as-you-type.

## Why this step exists

Earlier in Phase 1 we assumed step 6 (fleet attach) could reuse "the cloud-VM PTY transport." A 2026-05-12 recon showed that framing is wrong:

- **Local Swift has zero PTY code.** Every `forkpty` / `openpty` / `TIOC*` reference lives in `ghostty/src/pty.zig`. The local Ghostty surface is created at `Sources/GhosttyTerminalView.swift:5115` with `io_mode = EXEC` (the default); Ghostty owns the fd, the spawn, the read thread, the write stream, TIOCSWINSZ, and the termios polling.
- **Cloud-VM workspaces use the same EXEC backend.** `ssh user@vm` is just the startup command Ghostty runs inside its local PTY (`Sources/Workspace.swift:9886-9899`). There is no second PTY transport on the local side that we can reuse.

If we want to fan PTY bytes out to remote viewers (step 6) — or have a peer create a workspace and stream it back (step 7) — cmux has to own the PTY. The Ghostty fork already exposes the API (`GHOSTTY_SURFACE_IO_MANUAL`, `ghostty_surface_process_output`, `io_write_cb` — fork PR #53, commit `22fa801f8`). cmux just doesn't use it yet.

## Alternative considered and rejected: ssh-into-tmux + saved creds

Per-peer SSH credentials in Keychain; "attach" = open a new local workspace that SSHs to the peer; tmux on the owner for shared sessions. Ships fleet attach in ~1 session vs. ~3–5 for manual-IO. Rejected because:

1. Every local workspace would have to live inside tmux (prefix key, status bar, scrollback model change) — UX regression.
2. Step 7 (create workspace on peer) is much harder: a cmux workspace is more than a PTY (panel layout, browser panes, env injection at `Sources/GhosttyTerminalView.swift:5135-5267`).
3. Unlocks none of the recording / summary / search side benefits.

Keeping this alternative on file for future re-evaluation — see "Open product question" at bottom.

## Manual-IO API surface (Ghostty fork)

From `ghostty/include/ghostty.h:469-492` and `ghostty/src/termio/Manual.zig`:

```c
typedef enum {
  GHOSTTY_SURFACE_IO_EXEC   = 0,  // Ghostty owns PTY (current)
  GHOSTTY_SURFACE_IO_MANUAL = 1,  // embedder owns PTY
} ghostty_surface_io_mode_e;

typedef void (*ghostty_io_write_cb)(void* userdata, const char* ptr, uintptr_t len);

// In ghostty_surface_config_s:
ghostty_surface_io_mode_e io_mode;
ghostty_io_write_cb       io_write_cb;
void*                     io_write_userdata;

// Embedder pushes PTY-read bytes into the renderer:
GHOSTTY_API void ghostty_surface_process_output(ghostty_surface_t, const char*, uintptr_t);
```

Behaviour:

- Ghostty calls `io_write_cb(userdata, ptr, len)` on its IO thread whenever keystrokes/text/paste need to go to the PTY. CR→CRLF expansion is already done by `Manual.zig` before the callback fires.
- The embedder calls `ghostty_surface_process_output` to feed PTY-read bytes into the renderer. **Thread-safe** — `Termio.processOutput` takes the renderer mutex itself (`ghostty/src/termio/Termio.zig:731`).
- The `Manual` backend's `resize`, `threadEnter`, and `childExitedAbnormally` are no-ops. cmux owns spawn, read loop, TIOCSWINSZ, SIGCHLD, and the wait-after-command UX.

## Architecture

```
┌────────── cmux (Swift, per surface) ──────────┐
│ CmuxPTY actor                                  │
│   master fd  (posix_openpt + grantpt + unlockpt)
│   child pid  (fork + execve, pre-exec hook)    │
│   DispatchSource.read on master ──►  ghostty_surface_process_output
│   ring + DispatchSource.write ◄──   io_write_cb (Ghostty IO thread)
│   NSView resize → TIOCSWINSZ                   │
│   DispatchSource.signal(SIGCHLD)               │
│     → ghostty_surface_request_close            │
│     or "[process exited]" banner if            │
│        waitAfterCommand is set                 │
└────────────────────────────────────────────────┘
```

Two thread interactions to design carefully:

1. **`io_write_cb` runs on Ghostty's IO thread.** It must not block. Plan: non-blocking `write(2)` to the master fd; on `EAGAIN`, push into a small SPSC ring and arm a writability `DispatchSource` to drain. No mutex held across the syscall.
2. **`ghostty_surface_process_output` takes the renderer mutex internally.** Bursts of output (e.g., `find /`) shouldn't pin the renderer. Plan: cap each call at 64 KiB and chunk between yields, mirroring `Exec.zig:1338`.

## Sub-steps (one commit each)

| Step | Scope | Effort |
|------|-------|--------|
| **5.5A** | New `Packages/CMUXPty` package. API: `CmuxPTY(command, args, env, cwd, winsize)` opens master+slave and forks+execs; `.read { handler }` starts a `DispatchSource.read`; `.write(bytes)` enqueues to master; `.resize(cols, rows, w, h)` issues TIOCSWINSZ; `.wait()` is a `DispatchSource.signal(SIGCHLD)` with `waitpid(-1, _, WNOHANG)` loop. Real-fork unit tests against `sh -c`. No Ghostty involvement. | 2–4h |
| **5.5B** | Behind a debug-menu toggle (default off), `TerminalSurface.createSurface` sets `io_mode = MANUAL`, plants `io_write_cb` + userdata, spawns `CmuxPTY` *before* `ghostty_surface_new`, wires read→`process_output`, NSView size→`.resize`, SIGCHLD→close or banner. | ~1 session |
| **5.5C** | Parity: `wait_after_command` "ssh exited" banner, OSC 7 cwd reporting (no work needed — still flows through `process_output`), remote-terminal startup-command path. | ~0.5 session |
| **5.5D** | Latency burn-in. 60s typing storm under busy output. Compare keystroke→pixel p50/p95/p99 vs EXEC on same Mac. **Gate: p99 within 10% of EXEC.** | variable |
| **5.5E** | Flip default, delete the EXEC config path from cmux surface creation (leave Ghostty's EXEC backend intact). | ~0.5 session |

Total: ~3–5 focused sessions before step 6 (attach) is unblocked.

## Latency risks (ordered by likelihood)

1. **`io_write_cb` blocking Ghostty's IO thread.** Mitigation above (non-blocking write + writability source). **OK.**
2. **`process_output` holding renderer mutex during a burst.** Mitigation above (chunk + yield, mirror `Exec.zig:1338`). **OK with care.**
3. **TIOCSWINSZ thrash during sidebar drag.** Already a known concern (`Sources/TerminalWindowPortal.swift:772` — "doesn't resize the PTY at stale intermediate widths"). Keep the same debouncer; just move the ioctl from Ghostty to Swift. **Neutral.**
4. **SIGCHLD reaping race** (second child exits before we record the first). Standard fix: signal source + `waitpid(-1, _, WNOHANG)` loop. **Standard.**
5. **`wait_after_command` UX gap.** Ghostty's exec path holds the surface open with the dead PTY visible. We have to synthesize the same behaviour. **Behavioural parity — needs an explicit test, not a perf risk.**

## Test / verification plan

- **CmuxPTY unit tests** (5.5A): echo round-trip, kill-and-collect-exit, resize-after-write, cwd inheritance, env passthrough, ENOENT command, fork failure. Real fork — no mocks. Per `CLAUDE.md` "Test quality policy", these are behavioural, not text-shape, tests.
- **Surface-level integration test** (after 5.5B): spawn shell with manual IO, drive `ghostty_surface_text("echo hi\r")`, observe `process_output` was called with bytes containing `"hi"`. Headless via `xcodebuild -scheme cmux-unit`.
- **Dogfood loop** (5.5D): typing latency at p50/p95/p99 captured via existing telemetry hooks. Compare EXEC vs manual on the same Mac. Run for at least one week before 5.5E.
- **Crash matrix** (5.5C): child SIGSEGV, `kill -9` master, fork failure, ENOENT command. Verify no leaks (`leaks` after each).
- **CI**: 5.5A unit tests run on every PR; 5.5D latency burn-in is manual / scheduled.

## Open questions to resolve before 5.5B

1. **Special-key encoding.** Do arrows / Fn keys / mouse SGR sequences still get encoded by Ghostty before hitting `queueWrite` under manual IO? A skim of `apprt/embedded.zig` says yes — `surface.io.queueWrite` is invoked from inside the input encoder — but confirm with a tracer run during 5.5A before committing the surface wiring.
2. **Termios password-input rendering.** Ghostty's `termiosTimer` polls `tcgetattr` to detect echo-off and renders password input differently. Under manual IO, that polling has to happen on the embedder side or be skipped. **Recommendation: skip in 5.5, file follow-up.**
3. **`getProcessInfo` (foreground PID, tty name) is `null` in Manual backend.** Anything in cmux depends on it? Shell-integration reports its own PID via OSC, so probably nothing — confirm before 5.5E flip.
4. **`posix_spawn` vs `fork+execve`.** Ghostty uses `fork+execve`. Stay consistent for setsid / controlling-tty correctness; `posix_spawn` has subtle differences that aren't worth the speed-up for an interactive shell.

## Open product question (post-5.5)

Once manual-IO is in place, fleet attach (step 6) can be either:

- **(a) Live mirror** — owner tees PTY bytes to attached viewers; viewers' input is fanned back into the same PTY. One terminal, many keyboards. This is what 5.5 enables.
- **(b) Independent shells** — viewer asks the owner's HTTP API to spawn a new `cmux`-managed PTY on the owner's box, then attaches to *that* (still teed, but a separate session). Solves the "I want my own shell on your Mac, with cmux semantics" use case the ssh-into-tmux alternative was reaching for, without giving up the recording/summary benefits.

Both are buildable on top of 5.5. Defer the choice until 5.5E lands.

## Pointers

- Surface creation: `Sources/GhosttyTerminalView.swift:5115`
- Env injection: `Sources/GhosttyTerminalView.swift:5135-5267`
- Cloud-VM SSH startup command: `Sources/Workspace.swift:9886-9899`
- Header: `ghostty/include/ghostty.h:469-492, 1119, 1150`
- Manual backend: `ghostty/src/termio/Manual.zig`
- Backend dispatcher: `ghostty/src/termio/backend.zig`
- Thread-safe entry point: `ghostty/src/termio/Termio.zig:731`
- Exec reference (what we're replacing for local surfaces): `ghostty/src/termio/Exec.zig:85` (threadEnter), `1338` (read thread)
- Phase 1 status: `memory/cmux_fleet_phase1.md`
