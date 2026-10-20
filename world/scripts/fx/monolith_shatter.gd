extends Node3D
class_name MonolithShatter

## A Metin stone breaking apart: stone shards thrown out and up from the body,
## tumbling and bouncing once on the ground before they sink away, with a
## burst of the stone's glow, a ground shockwave and settling dust. Presentation
## only (clients and the solo host); frees itself.
##
##   MonolithShatter.play(parent, at, glow, height)

const SHARDS := 26
const LIFE := 3.6

var _shards: Array = []   # [{node, vel, spin, floor}]
var _age := 0.0

static func play(parent: Node, at: Vector3, glow: Color, height: float = 7.0) -> MonolithShatter:
	if parent == null or not parent.is_inside_tree():
		return null
	var fx := MonolithShatter.new()
	fx.name = "MonolithShatter"
	parent.add_child(fx)
	fx.global_position = at
	fx._build(glow, height)
	FlipbookFX.play(parent, at, [
		{"atlas": "burst_green_8x8_2k", "size": height * 1.5, "height": height * 0.45, "fps": 30.0, "tint": glow.lightened(0.2)},
		{"atlas": "shockwave_8x8_1k", "size": height * 2.6, "flat": true, "height": 0.15, "fps": 26.0, "tint": glow},
		{"atlas": "smoke_puff_8x8_1k", "size": height * 1.2, "height": 1.6, "fps": 16.0, "delay": 0.15, "opacity": 0.6,
			"tint": Color(0.55, 0.55, 0.52)},
	], {"life": 3.0, "light": glow, "light_energy": 9.0, "light_range": 22.0, "light_height": height * 0.5,
		"sound": "spell_bombarda_impact"})
	return fx

func _build(glow: Color, height: float) -> void:
	var stone := StandardMaterial3D.new()
	stone.albedo_color = Color(0.13, 0.12, 0.14)
	stone.roughness = 0.85
	var lit := StandardMaterial3D.new()
	lit.albedo_color = Color(0.1, 0.12, 0.1)
	lit.emission_enabled = true
	lit.emission = glow
	lit.emission_energy_multiplier = 2.2
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for i in SHARDS:
		var mesh: PrimitiveMesh = PrismMesh.new() if i % 3 == 0 else BoxMesh.new()
		var s := rng.randf_range(0.25, 0.85) * (1.6 if i < 5 else 1.0)
		if mesh is BoxMesh:
			(mesh as BoxMesh).size = Vector3(s, s * rng.randf_range(0.8, 2.2), s * rng.randf_range(0.5, 1.0))
		else:
			(mesh as PrismMesh).size = Vector3(s, s * 1.6, s * 0.7)
		var node := MeshInstance3D.new()
		node.mesh = mesh
		node.material_override = lit if i % 4 == 0 else stone
		var h := rng.randf_range(0.4, height * 0.9)
		var ang := rng.randf() * TAU
		node.position = Vector3(cos(ang) * 0.7, h, sin(ang) * 0.7)
		node.rotation = Vector3(rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU)
		add_child(node)
		var out := Vector3(cos(ang), 0.0, sin(ang)) * rng.randf_range(3.0, 9.0)
		_shards.append({"node": node, "vel": out + Vector3.UP * rng.randf_range(3.0, 9.0),
			"spin": Vector3(rng.randf_range(-8, 8), rng.randf_range(-8, 8), rng.randf_range(-8, 8)),
			"floor": s * 0.3, "bounced": false})

func _process(delta: float) -> void:
	_age += delta
	for shard in _shards:
		var node: MeshInstance3D = shard["node"]
		var vel: Vector3 = shard["vel"]
		vel.y -= 22.0 * delta
		node.position += vel * delta
		var rest := float(shard["floor"])
		if node.position.y < rest:
			node.position.y = rest
			if not bool(shard["bounced"]):
				shard["bounced"] = true
				vel = Vector3(vel.x * 0.4, absf(vel.y) * 0.3, vel.z * 0.4)
				shard["spin"] = (shard["spin"] as Vector3) * 0.4
			else:
				vel = Vector3(vel.x * 0.85, 0.0, vel.z * 0.85)
				shard["spin"] = (shard["spin"] as Vector3) * 0.85
		shard["vel"] = vel
		node.rotation += (shard["spin"] as Vector3) * delta
		# the last second: the shards sink into the ground and shrink away
		if _age > LIFE - 1.0:
			var k := clampf((LIFE - _age) / 1.0, 0.0, 1.0)
			node.scale = Vector3.ONE * maxf(0.01, k)
	if _age >= LIFE:
		queue_free()
