extends Node2D
## Floor.gd - Environment / digitization layer for one building floor.
## Attach to: the root "Floor" node (via Floor.tscn) instanced by each
## CASS_0..CASS_3.tscn.
##
## Thesis ref: Chapter 3.4.2 "The Environment (Digitization Layer)".

@export var floor_index: int = 0
@export var base_occupancy: int = 30  # Agents spawned here under the Baseline Scenario (3.5).

const AgentScene: PackedScene = preload("res://scenes/Agent.tscn")

@onready var nav_region: NavigationRegion2D = $NavigationRegion2D
@onready var exits_container: Node2D = $Exits
@onready var stairs_container: Node2D = $StairConnectors
@onready var wander_points_container: Node2D = $WanderPoints
@onready var agents_container: Node2D = $Agents

# Cached at _ready() instead of rebuilt via get_children()+filtering on every
# call. These were getting rebuilt every time any agent picked a new wander
# target / panic target - with 100+ agents per floor doing that frequently,
# the repeated node-walk + array allocation added unnecessary overhead.
# Static for the lifetime of a run (set_blocked() only flips a flag on the
# existing nodes, it doesn't add/remove children), so caching is safe.
var _wander_points_cache: Array = []
var _exits_cache: Array = []
var _stairs_cache: Array = []


func _ready() -> void:
	Manager.register_floor(floor_index, self)
	_wander_points_cache = _collect_wander_points()
	_exits_cache = _collect_exits()
	_stairs_cache = _collect_stairs()


# ---------------------------------------------------------------------------
# Wander points
# ---------------------------------------------------------------------------

func _collect_wander_points() -> Array:
	var points: Array = []
	for child in wander_points_container.get_children():
		if child is Marker2D:
			points.append(child)
	return points


func get_wander_points() -> Array:
	return _wander_points_cache


func get_wander_point_by_name(point_name: String) -> Marker2D:
	return wander_points_container.get_node_or_null(point_name) as Marker2D


func get_random_wander_point() -> Marker2D:
	if _wander_points_cache.is_empty():
		return null
	return _wander_points_cache[randi() % _wander_points_cache.size()]


# ---------------------------------------------------------------------------
# Exits / Stairs
# ---------------------------------------------------------------------------

func _collect_exits() -> Array:
	var result: Array = []
	for child in exits_container.get_children():
		if child.is_in_group("exits"):
			result.append(child)
	return result


func _collect_stairs() -> Array:
	var result: Array = []
	for child in stairs_container.get_children():
		if child.is_in_group("stairs"):
			result.append(child)
	return result


func get_exits() -> Array:
	return _exits_cache


func get_stairs() -> Array:
	return _stairs_cache


func get_nearest_exit(from_pos: Vector2) -> Node:
	var best: Node = null
	var best_dist := INF
	for exit_node in get_exits():
		if exit_node.is_blocked:
			continue
		var d := from_pos.distance_squared_to(exit_node.get_target_position())
		if d < best_dist:
			best_dist = d
			best = exit_node
	return best


func get_nearest_stair_toward_ground(from_pos: Vector2) -> Node:
	var best: Node = null
	var best_dist := INF
	for stair_node in get_stairs():
		if stair_node.is_blocked:
			continue
		if stair_node.destination_floor >= floor_index:
			continue  # Only consider stairs that move the agent downward.
		var d := from_pos.distance_squared_to(stair_node.get_target_position())
		if d < best_dist:
			best_dist = d
			best = stair_node
	return best


# ---------------------------------------------------------------------------
# Agent spawning
# ---------------------------------------------------------------------------

func spawn_agents(count: int) -> void:
	for i in count:
		var agent = AgentScene.instantiate()
		agent.current_floor = self          # Must be set before add_child() triggers _ready().
		agents_container.add_child(agent)

		var wp := get_random_wander_point()
		if wp:
			agent.global_position = wp.global_position
