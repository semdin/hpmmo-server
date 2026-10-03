extends Node

## HPMMO Dedicated Server Entry Point
## Runs authoritatively in headless mode on Linux VPS (Ubuntu 22.04)

var world_scene = preload("res://scenes/world/game_world.tscn")
var world_instance: Node3D = null

func _ready() -> void:
	print("=========================================================")
	print(">>> [HPMMO DEDICATED SERVER] Booting up... <<<")
	print("=========================================================")
	
	# Start ENet server on port 7777
	var err := NetworkManager.start_dedicated_server(7777)
	if err != OK:
		print("FAILED to start server! Exiting...")
		get_tree().quit(1)
		return
	
	# Instantiate authoritative game world
	world_instance = world_scene.instantiate()
	add_child(world_instance)
	print("[Dedicated Server] Game World successfully loaded!")
	print("[Dedicated Server] Server is READY at 213.250.145.75:7777")
	print("=========================================================")

func _process(_delta: float) -> void:
	pass
