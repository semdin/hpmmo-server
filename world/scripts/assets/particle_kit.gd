extends RefCounted

## Soft, camera-facing textured particles, with no opaque primitive debris.
static func configure(particles: CPUParticles3D, fire: bool = false) -> void:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.vertex_color_use_as_albedo = true
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.albedo_texture = load("res://assets/vfx/flame_01.png" if fire else "res://assets/vfx/spark_01.png")
	var quad := QuadMesh.new()
	quad.size = Vector2(0.32, 0.55) if fire else Vector2(0.16, 0.16)
	quad.material = material
	particles.mesh = quad
	particles.local_coords = false
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 0.95, 0.7, 0.9))
	gradient.add_point(0.35, Color(1, 0.5, 0.12, 0.75) if fire else Color(0.45, 0.8, 1, 0.7))
	gradient.set_color(1, Color(0.7, 0.16, 0.02, 0))
	particles.color_ramp = gradient
	var curve := Curve.new()
	curve.add_point(Vector2(0, 0.3))
	curve.add_point(Vector2(0.2, 1))
	curve.add_point(Vector2(1, 0))
	particles.scale_amount_curve = curve
