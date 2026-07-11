extends Area2D
## StairConnector.gd - Models vertical evacuation through a stairwell using
## the "Connector Model" (teleport-queue) described in the thesis, rather
## than continuous 3D physics.
##
## Attach to: each "Stair_X_Y" Area2D node under a Floor's "StairConnectors"
## container (e.g. in CASS_0..CASS_3.tscn).
##
## Expected exported properties already set in your .tscn files:
##   destination_floor        (int)    - floor_index of the destination Floor.
##   destination_marker_name  (String) - name of the Marker2D under the
##                                        destination Floor's WanderPoints
##                                        node where the agent reappears.
##
## Thesis ref: Chapter 3.4.6 "Vertical Evacuation and Stairwell Dynamics"
## (3.4.6.1 Connector Model, 3.4.6.2 Funnel Simulation, 3.4.6.3
## Density-Dependent Velocity).
##
## LIMITATION (documented, not hidden): each StairConnector models a single
## floor-to-floor hop in isolation. The thesis's 3.4.6.4 "Merge Logic"
## (descending traffic vs. traffic entering from an intermediate floor)
## would require linking adjacent connectors into one shared queue across
## floors, which the current per-floor node layout doesn't represent. As a
## practical approximation, arrival order at *this* connector already gives
## first-come-first-served priority, and the capacity cap below reproduces
## the "queue backs up under high density" behavior from 3.4.6.3.

@export var destination_floor: int = 0
@export var destination_marker_name: String = ""
@export var base_transit_time: float = 1.0   # T_transit in seconds, uncongested.
@export var capacity: int = 20               # Max agents physically on the stairs at once.
@export var is_blocked: bool = false         # "Constrained Scenario" (3.5).

var _queue: Array = []
var _in_transit_count: int = 0
var _resolved: bool = false   # true only once Manager has applied real scenario logic

func _ready() -> void:
	add_to_group("stairs")
	area_entered.connect(_on_area_entered)
	# Draw the "blocked" marker above the floor plan / agents (critical-point
	# overlay lives at 100, so stay just under it). z_as_relative=false makes
	# this absolute within the world canvas, independent of the Floor's own z.
	z_index = 90
	z_as_relative = false
	queue_redraw()


## The StairConnector Area2D node itself always sits at local (0,0) under
## "StairConnectors" - the real-world location is entirely encoded in the
## child CollisionShape2D's position. Pathfinding targets must use this,
## not global_position directly.
func get_target_position() -> Vector2:
	for child in get_children():
		if child is CollisionShape2D or child is CollisionPolygon2D:
			return child.global_position
	return global_position


func _on_area_entered(area: Area2D) -> void:
	if is_blocked:
		return

	var agent := area.get_parent()
	if agent == null or not is_instance_valid(agent) or not agent.is_in_group("agents"):
		return
	if not agent.has_method("enter_stair_transit"):
		return
	if agent in _queue:
		return

	agent.enter_stair_transit()
	_queue.append(agent)
	_process_queue()


func _process_queue() -> void:
	# Drop any agents that were freed WHILE still waiting in this queue. That
	# happens when the Manager despawns them (live occupancy slider) or retires
	# them (90% completion threshold) - neither path knows this connector is
	# still holding a reference. Popping a freed object and passing it into the
	# typed `_transit_agent(agent: Node)` parameter is exactly what produced:
	#   "Invalid type in function '_transit_agent' ... argument 1 (previously
	#    freed) is not a subclass of the expected argument class."
	# It surfaced mainly in the Constrained Scenario because a blocked route
	# funnels the crowd onto fewer stairs, so queues routinely back up well past
	# `capacity` and agents sit here long enough to be freed underneath us.
	_prune_freed_from_queue()
	while _in_transit_count < capacity and not _queue.is_empty():
		var agent = _queue.pop_front()
		if not is_instance_valid(agent):
			continue  # already gone - skip WITHOUT charging it against capacity
		_in_transit_count += 1
		_transit_agent(agent)


## Remove any freed agents still sitting in the waiting queue.
func _prune_freed_from_queue() -> void:
	var i := _queue.size() - 1
	while i >= 0:
		if not is_instance_valid(_queue[i]):
			_queue.remove_at(i)
		i -= 1


func _transit_agent(agent: Node) -> void:
	# Density-dependent slowdown of the stairwell, mirroring the Fundamental
	# Diagram of Pedestrian Flow used for in-corridor movement (3.4.6.3):
	# the fuller the stairwell, the longer the effective transit time.
	var rho: float = float(_in_transit_count)
	var rho_max: float = float(capacity)
	var slowdown: float = 1.0 / clamp(1.0 - (rho / (rho_max + 1.0)), 0.15, 1.0)
	var transit_time: float = base_transit_time * slowdown

	await get_tree().create_timer(transit_time).timeout

	_in_transit_count -= 1

	if is_instance_valid(agent):
		_complete_transit(agent)

	_process_queue()


func _complete_transit(agent: Node) -> void:
	var dest_floor = Manager.get_floor(destination_floor)
	if dest_floor == null:
		push_warning("StairConnector '%s': destination floor %d not registered with Manager." % [name, destination_floor])
		return

	var marker = dest_floor.get_wander_point_by_name(destination_marker_name)
	if marker == null:
		push_warning("StairConnector '%s': marker '%s' not found on floor %d." % [name, destination_marker_name, destination_floor])
		return

	agent.global_position = marker.global_position
	agent.exit_stair_transit(dest_floor)


func set_blocked(value: bool) -> void:
	is_blocked = value
	_resolved = true
	queue_redraw()


## Visual marker for a route the user has closed (Constrained Scenario). The
## Area2D itself is invisible at runtime, so we draw the marker at the child
## CollisionShape's position (converted into this node's local space).
func _draw() -> void:
	if not _resolved or not is_blocked:
		return
	var p := to_local(get_target_position())
	var s := 22.0
	var box := Rect2(p - Vector2(s, s), Vector2(s * 2.0, s * 2.0))
	draw_rect(box, Color(0.90, 0.10, 0.10, 0.25), true)          # translucent red fill
	draw_rect(box, Color(1.00, 0.22, 0.22, 0.95), false, 2.0)     # solid border
	draw_line(p - Vector2(s, s), p + Vector2(s, s), Color(1.0, 0.28, 0.28, 0.95), 3.0)
	draw_line(p - Vector2(s, -s), p + Vector2(s, -s), Color(1.0, 0.28, 0.28, 0.95), 3.0)
	var font: Font = ThemeDB.fallback_font
	draw_string(font, p + Vector2(-s, -s - 6.0), "STAIR BLOCKED",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1.0, 0.55, 0.5))
