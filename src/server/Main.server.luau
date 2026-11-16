--!strict
-- Server entry: the OpenFront port (OpenFrontServer). The earlier engine
-- (MatchRunner, MatchSim, Bots) was removed 2026-11-10 (audit F17); git
-- history keeps it.

require(script.Parent.OpenFrontServer).start()
-- "Come back" notifications (off until their setup is done; see the module).
require(script.Parent.Notifications).start()
