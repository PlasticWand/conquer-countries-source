--!strict
-- Client entry. Thin by rule (AGENTS.md): it starts the OpenFront client,
-- which wires the map (Codex) and the HUD (Claude) together. The earlier
-- engine's client was removed 2026-11-10 (audit F17); git history keeps it.

require(script.Parent.OpenFrontClient).start()
