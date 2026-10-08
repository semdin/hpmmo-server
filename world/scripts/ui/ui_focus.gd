extends RefCounted
class_name UIFocus

## Interface input focus ("Make menus and interaction prompts
## respect input focus so clicks/keys in UI do not unexpectedly cast or mount").
##
## A panel that takes keyboard focus announces itself here while it is open.
## The player controller consults this group before it reads the keyboard, so
## typing in a panel can never also cast a spell or mount the broom - which
## matters because hotkeys are read by polling Input, so a consumed event alone
## would not stop them.
##
## Mouse clicks are a separate path: a Control with MOUSE_FILTER_STOP (the
## default for Panel/Button) consumes the click before `_unhandled_input`, so a
## click on a panel never reaches the world. The group below covers keys; both
## paths are asserted in the interface checks.

const GROUP := "ui_input_blocker"

## True while any registered panel is visible in the tree.
static func is_blocking(tree: SceneTree) -> bool:
	if tree == null:
		return false
	for node in tree.get_nodes_in_group(GROUP):
		if node is CanvasItem:
			if (node as CanvasItem).is_visible_in_tree():
				return true
		elif node is Node and node.is_inside_tree():
			return true
	return false

static func block(panel: Node) -> void:
	if panel != null and is_instance_valid(panel) and not panel.is_in_group(GROUP):
		panel.add_to_group(GROUP)

static func unblock(panel: Node) -> void:
	if panel != null and is_instance_valid(panel) and panel.is_in_group(GROUP):
		panel.remove_from_group(GROUP)

## Count for the checks: how many registered blockers are live right now.
static func blocker_count(tree: SceneTree) -> int:
	if tree == null:
		return 0
	return tree.get_nodes_in_group(GROUP).size()
