extends RefCounted
class_name HPProf

## Section timers for the world server's status line. OWNER: server repository
## (synced to the client like the rest of the simulation package).
##
## A section is timed with `var t := HPProf.start()` ... `HPProf.stop("snap", t)`;
## the status line prints, per section, its total cost per second of wall time
## and its slowest single call since the last line ("snap=1.8/4.2" = 1.8 ms of
## every second, worst call 4.2 ms). That tells which part of the world a
## hitch or a slow tick came from. Off unless `enabled` (the world server turns
## it on), so clients and offline play pay one bool test per call.

static var enabled := false
static var _total_us: Dictionary = {}
static var _max_us: Dictionary = {}
static var _since_us := 0


static func start() -> int:
	return Time.get_ticks_usec() if enabled else 0


static func stop(section: String, started_us: int) -> void:
	if not enabled or started_us == 0:
		return
	var spent := Time.get_ticks_usec() - started_us
	_total_us[section] = int(_total_us.get(section, 0)) + spent
	if spent > int(_max_us.get(section, 0)):
		_max_us[section] = spent


## "snap=1.8/4.2 step=0.9/2.0 ..." for the window since the last call, then
## starts a new window.
static func report() -> String:
	var now := Time.get_ticks_usec()
	var window_s := maxf(0.001, float(now - _since_us) / 1000000.0) if _since_us != 0 else 1.0
	_since_us = now
	var parts: Array = []
	var sections := _total_us.keys()
	sections.sort()
	for section in sections:
		parts.append("%s=%.1f/%.1f" % [section, float(_total_us[section]) / 1000.0 / window_s,
			float(_max_us.get(section, 0)) / 1000.0])
	_total_us.clear()
	_max_us.clear()
	return " ".join(parts)
