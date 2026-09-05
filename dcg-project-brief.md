# Digital Card Game (MTG Arena-style) — Project Brief

## Goal
A digital card game similar to MTG Arena / MTGO, built primarily with Claude Code, with **real-time multiplayer from day one**.

## Core Architectural Principle
Separate the **rules engine** from the **presentation layer**. This is the single most important decision — it lets you test game logic independently of UI, and keeps the whole project buildable/refactorable by Claude Code without a GUI editor in the loop.

## Chosen Stack

| Layer | Tech | Purpose |
|---|---|---|
| Rules Engine | TypeScript (pure logic, no rendering) | Priority, stack, triggered/state-based actions, targeting, replacement effects. Fully unit-testable headlessly. |
| Server | Node.js + WebSockets | Runs the rules engine authoritatively. Validates every player action. Sends each player only the game state they're allowed to see (critical — hidden information like opponent's hand/deck order must never be exposed client-side). |
| Client | React | UI structure: hand, battlefield, stack, menus, deck builder. Pure renderer of server state — no independent game logic. |
| Animation/Physics | Pixi.js and/or Framer Motion | Card dragging, zoom-on-hover, tweened movement, stack resolution animations, glow/particle effects. |

## Why This Stack (vs. Unity/Godot)
- Every layer is plain text files — Claude Code can read, write, and refactor the entire project (engine, server, client, animations) without needing a visual editor.
- Card games are UI/state-machine heavy, not rendering-heavy — no need for a 3D/general-purpose game engine.
- Networking is natural to build for real-time multiplayer with hidden information (WebSocket server as source of truth).
- **Godot** remains a good fallback later if you want a native installable client (Steam, desktop/mobile) — the decoupled rules engine can be reused unchanged. Unity/Unreal were ruled out — too much GUI-editor-dependent workflow, which doesn't pair well with an AI coding agent.

## Recommended Build Order (multiplayer-first specific)
Don't build networking and rules correctness at the same time — that's the classic stall point for this kind of project.

1. **Rules engine + automated tests** — headless, no UI, no network. Get core interactions (casting spells, priority passing, stack resolution, state-based actions) fully correct and tested first.
2. **Bare-bones server** wrapping the engine — two minimal/dumb clients (even just console/JSON logs) to prove state sync and per-player information-hiding works correctly.
3. **Real UI layer** on top, once the state flow is trustworthy.
4. **Animation/polish layer** last (Pixi/Framer Motion, particle effects, juice).

## Key Risks to Watch
- **Cheating via client-trusted state** — always validate and resolve on the server; client only renders.
- **Per-player state filtering** — often underestimated; needs careful design early (step 2 above) rather than bolted on later.
- **Scope creep on visuals before rules are solid** — resist polishing animations before the engine + networking loop is proven.

## Status
Not yet started — this is the plan to pick up when the project begins.
