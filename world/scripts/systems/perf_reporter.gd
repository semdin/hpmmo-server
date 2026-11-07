extends Node
class_name PerfReporter

## How this client's frames and connection held up, every REPORT_S seconds:
## sent to the world server (v31 `sim_client_perf`, which only logs it) and
## printed in this client's own log. A player's "it stutters" can then be read
## next to the server's status lines instead of guessed at.
##
## A single frame over HITCH_LOG_MS is also printed when it happens, with the
## frame's process/physics time and the pipelines compiled in it, so a log
## sent in by a player says what the freeze was.

const QualityPresetScript = preload("res://scripts/world/quality_preset.gd")
const REPORT_S := 30.0
const HITCH_MS := 50.0
const HITCH_LOG_MS := 100.0
const PIPELINE_INFOS := [
	RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS,
	RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH,
	RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE,
	RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW,
	RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION,
]

var _last_us := 0
var _frames := PackedFloat32Array()
var _pings := PackedInt32Array()
var _ping_wait := 0.0
var _window := 0.0
var _pipelines := 0
var _hitches := 0
## The local body's reconcile_stats at the last report (corrections per window).
var _reconcile_last := {}

static func create(world: Node) -> PerfReporter:
	var reporter := PerfReporter.new()
	reporter.name = "PerfReporter"
	world.add_child(reporter)
	return reporter

func _ready() -> void:
	_pipelines = _pipeline_count()

func _process(_delta: float) -> void:
	# Real wall time between frames: `delta` is smoothed and hides a spike.
	var now := Time.get_ticks_usec()
	if _last_us == 0:
		_last_us = now
		return
	var frame_ms := float(now - _last_us) / 1000.0
	_last_us = now
	_frames.append(frame_ms)
	_window += frame_ms / 1000.0
	var pipelines := _pipeline_count()
	if frame_ms > HITCH_MS:
		_hitches += 1
	if frame_ms > HITCH_LOG_MS:
		print("[Perf] hitch %.0f ms (process %.1f ms, physics %.1f ms, %d pipelines compiled, %d nodes)" % [
			frame_ms, Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
			pipelines - _pipelines, int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))])
	_pipelines = pipelines
	_ping_wait -= frame_ms / 1000.0
	if _ping_wait <= 0.0:
		_ping_wait = 1.0
		var ping := SimNet.ping_ms()
		if ping >= 0:
			_pings.append(ping)
	if _window >= REPORT_S:
		_report()

## The machine behind the numbers, for the server log: OS, renderer, GPU, and
## the window and 3D frame in pixels (a Retina or 4K screen renders far more
## than the 1080p the presets were tuned on; see QualityPreset.render_scale).
func _machine() -> Dictionary:
	var viewport := get_viewport()
	var screen := QualityPresetScript.viewport_pixels(viewport)
	var scale := viewport.scaling_3d_scale if viewport != null else 1.0
	return {
		"os": OS.get_name(),
		"renderer": RenderingServer.get_current_rendering_method(),
		"adapter": RenderingServer.get_video_adapter_name(),
		"screen": "%dx%d" % [screen.x, screen.y],
		"render": "%dx%d" % [roundi(screen.x * scale), roundi(screen.y * scale)],
	}

func _report() -> void:
	var frames := _frames.duplicate()
	frames.sort()
	var pings := _pings.duplicate()
	pings.sort()
	var ping_sum := 0
	for p in pings:
		ping_sum += p
	var report := {
		"window_s": _window,
		"fps": float(frames.size()) / _window,
		"frame_p50_ms": frames[frames.size() / 2],
		"frame_p99_ms": frames[mini(frames.size() - 1, int(frames.size() * 0.99))],
		"worst_ms": frames[frames.size() - 1],
		"hitches": _hitches,
		"ping_avg": float(ping_sum) / float(pings.size()) if not pings.is_empty() else -1.0,
		"ping_p95": pings[mini(pings.size() - 1, int(pings.size() * 0.95))] if not pings.is_empty() else -1,
		"loss_pct": SimNet.packet_loss_pct(),
		"preset": QualityPresetScript.current(),
	}
	# How often the server's snapshots moved this body (snaps > 1 m, pulls).
	var player = SimAuthority.local_player_node()
	if player != null and is_instance_valid(player) and player.get("reconcile_stats") is Dictionary:
		var now: Dictionary = player.get("reconcile_stats")
		report["snaps"] = int(now["snaps"]) - int(_reconcile_last.get("snaps", 0))
		report["snap_m"] = float(now["snap_m"]) - float(_reconcile_last.get("snap_m", 0.0))
		report["pulls"] = int(now["pulls"]) - int(_reconcile_last.get("pulls", 0))
		report["pull_m"] = float(now["pull_m"]) - float(_reconcile_last.get("pull_m", 0.0))
		_reconcile_last = now.duplicate()
	report.merge(_machine())
	print("[Perf] %.0f s: fps %.1f, frame p50 %.1f / p99 %.1f / worst %.0f ms, %d hitches, ping %.0f (p95 %d) ms, loss %.1f %%, corrections %d snaps (%.1f m) %d pulls (%.1f m)" % [
		_window, report["fps"], report["frame_p50_ms"], report["frame_p99_ms"], report["worst_ms"],
		_hitches, report["ping_avg"], report["ping_p95"], report["loss_pct"],
		int(report.get("snaps", 0)), float(report.get("snap_m", 0.0)), int(report.get("pulls", 0)), float(report.get("pull_m", 0.0))])
	SimNet.submit_perf_report(report)
	_frames.clear()
	_pings.clear()
	_window = 0.0
	_hitches = 0

static func _pipeline_count() -> int:
	var total := 0
	for info in PIPELINE_INFOS:
		total += int(RenderingServer.get_rendering_info(info))
	return total
