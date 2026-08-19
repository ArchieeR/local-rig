# Local Rigs & Firebase Emulators: How It Works

If you develop full-stack apps with **Firebase Emulators** (Firestore, Auth, Functions, Storage) and a web frontend (Next.js, Vite, React), you know the pain:

Running multiple local git worktrees or feature branches simultaneously usually means **port conflicts**, **duplicate emulator instances eating RAM**, or **database state getting stomped on**.

**Local Rig** solves this by introducing **Rigs** and **Shared vs. Isolated Emulator Topology**.

---

## 1. What is a "Rig"?

A **Rig** is a lightweight developer slot that couples:
1. **A Frontend Dev Server** (e.g. Next.js on `:3000`, `:3001`, `:3002`) bound to a specific git worktree / feature branch.
2. **An Emulator Strategy** (Shared or Isolated Firebase Emulators).
3. **Session Ownership** (Claimed by a specific developer, agent, or terminal task).

```text
  ┌─────────────────────────────────────────────────────────┐
  │                      LOCAL MACBOOK                      │
  │                                                         │
  │  ┌──────────────────────┐     ┌──────────────────────┐  │
  │  │ Rig 1 (wt-qa-rig)    │     │ Rig 2 (wt-rig2)      │  │
  │  │ Next.js on :3000     │     │ Next.js on :3002     │  │
  │  └──────────┬───────────┘     └──────────┬───────────┘  │
  │             │                            │              │
  │             │   ┌────────────────────────┘              │
  │             ▼   ▼                                       │
  │  ┌───────────────────────────────────────────────────┐  │
  │  │ SHARED FIREBASE EMULATOR SUITE (Rig 1)            │  │
  │  │ Firestore: :8080 · Auth: :9099 · Hub: :4000        │  │
  │  └───────────────────────────────────────────────────┘  │
  └─────────────────────────────────────────────────────────┘
```

---

## 2. Shared vs. Isolated Emulators

Starting a full set of Firebase Emulators (Java process + Node functions runtime) takes **~1.5 GB to 3 GB of RAM** and 10–20 seconds of boot time.

Local Rig gives you two modes:

### Mode A: Shared Emulator (Default & Fast)
* **How it works:** **Rig 1** boots the primary Firebase Emulator suite (Firestore `:8080`, Auth `:9099`, Emulator UI `:4000`). Rigs 2 through 5 point their frontend environment variables (`NEXT_PUBLIC_FIRESTORE_EMULATOR_HOST=127.0.0.1:8080`) to **Rig 1's emulator**.
* **Why use it:** Instant startup for Rigs 2–5. Saves 6–10 GB of RAM across multiple concurrent feature branches. Great for UI work, frontend QA, and rapid iteration against a single shared test dataset.

### Mode B: Isolated Emulator
* **How it works:** Rig 2 (or 3, 4, 5) boots its **own independent Firebase Emulator stack** on isolated port offsets (e.g. Firestore `:8082`, Auth `:9092`).
* **Why use it:** Perfect for destructive migration testing, Cloud Function schema refactorings, or automated test runs where you don't want to dirty the shared test data.

---

## 3. Port & Process Protection

Firebase Emulators are notorious for leaving orphan Java or Node processes running in the background when standard `Ctrl+C` fails or a terminal crashes.

Local Rig provides safety guarantees:
* **Liveness Truth:** Checks physical listening ports (`netstat`/`lsof`), not stale `.pid` files.
* **Safe Termination:** When you click **Stop**, Local Rig verifies the root PID and process signature before sending `SIGTERM`. It will **never force-kill** or stop an emulator that another active rig depends on.
* **No Stale Conflicts:** Discovers orphan helper processes and frees blocked ports cleanly.
