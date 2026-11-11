--!strict
-- Server entry: the OpenFront port (OpenFrontServer). The earlier engine
-- (MatchRunner, MatchSim, Bots) was removed 2026-11-10 (audit F17); git
-- history keeps it.

require(script.Parent.OpenFrontServer).start()
