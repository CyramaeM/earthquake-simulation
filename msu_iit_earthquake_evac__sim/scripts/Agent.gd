extends Node2D
## Agent.gd - Behavioral layer for a single evacuee.
## Attach to: Agent.tscn (root Node2D, already in group "agents").
##
## Thesis ref: Chapter 3.4.3 "The Agent (Behavioral Layer)", Listing 3.2.
##
## Movement uses NavigationAgent2D's built-in avoidance (RVO) instead of
## physics bodies, since Agent.tscn has no CharacterBody2D - just an Area2D
## used purely for exit/stair *detection*.

enum State { NORMAL, PANIC, IN_TRANSIT, ESCAPED }

@onready var nav_agent: NavigationAgent2D = $NavigationAgent2D
@onready var sprite: Sprite2D = $Sprite2D
@onready var detection_area: Area2D = $Area2D

var state: int = State.NORMAL

# Randomized per-agent attributes (3.4.3 "Attributes" + 2.4 "Speed variability").
var walk_speed: float = 40.0
var run_speed: float = 90.0
var reaction_time: float = 0.0
var collision_radius: float = 3.0

# Set by Floor.gd before this node enters the tree.
var current_floor: Node = null

var _reaction_timer: float = 0.0
var _reaction_complete: bool = false
var _wander_target: Node2D = null
var _panic_target_node: Node = null  # Exit or StairConnector currently being pathed to.


func _ready() -> void:
	add_to_group("agents")

	walk_speed = randf_range(30.0, 50.0)
	run_speed = randf_range(70.0, 110.0)
	reaction_time = randf_range(0.0, 3.0)

	var shape_node := detection_area.get_node_or_null("CollisionShape2D")
	if shape_node and shape_node.shape is CircleShape2D:
		collision_radius = shape_node.shape.radius

	nav_agent.radius = collision_radius
	nav_agent.max_speed = walk_speed
	nav_agent.avoidance_enabled = true
	nav_agent.velocity_computed.connect(_on_velocity_computed)

	Manager.register_agent(self)
	Manager.earthquake_started.connect(_on_earthquake_started)
	if Manager.earthquake_triggered:
		_on_earthquake_started()
	else:
		_pick_new_wander_target()
		sprite.modulate = Color.BLACK


func _physics_process(delta: float) -> void:
	match state:
		State.NORMAL:
			_process_normal(delta)
		State.PANIC:
			_process_panic(delta)
		State.IN_TRANSIT, State.ESCAPED:
			return  # Hidden / off the navmesh right now (mid-stair or already safe).

	# Feed the heat map / congestion log (3.6 Data Analysis).
	Manager.log_position(global_position)


func _process_normal(delta: float) -> void:
	if _wander_target == null or nav_agent.is_navigation_finished():
		_pick_new_wander_target()
		return
	_move_with_avoidance(walk_speed)


func _process_panic(delta: float) -> void:
	# Reaction delay before the agent actually starts moving (2.4 "Panic response").
	if _reaction_timer < reaction_time:
		_reaction_timer += delta
		return

	# Turn red after reaction delay completes (only once).
	if not _reaction_complete:
		_reaction_complete = true
		sprite.modulate = Color.RED

	if _panic_target_node == null or not is_instance_valid(_panic_target_node):
		_acquire_panic_target()
		if _panic_target_node == null:
			return  # No reachable exit/stair right now (e.g. everything is blocked).

	_move_with_avoidance(run_speed)


func _move_with_avoidance(speed: float) -> void:
	if nav_agent.is_navigation_finished():
		return

	# Density-dependent velocity, Fundamental Diagram of Pedestrian Flow (3.4.6.3):
	#   v = v_free * (1 - rho / rho_max)
	var rho: float = float(Manager.get_local_agent_count(global_position, 16.0, self))
	var rho_max: float = 8.0
	var density_factor: float = clamp(1.0 - (rho / rho_max), 0.15, 1.0)

	nav_agent.max_speed = speed
	var next_pos: Vector2 = nav_agent.get_next_path_position()
	var desired_velocity: Vector2 = global_position.direction_to(next_pos) * speed * density_factor
	nav_agent.set_velocity(desired_velocity)


func _on_velocity_computed(safe_velocity: Vector2) -> void:
	if state == State.IN_TRANSIT or state == State.ESCAPED:
		return
	global_position += safe_velocity * get_physics_process_delta_time()


func _pick_new_wander_target() -> void:
	if current_floor == null or not current_floor.has_method("get_random_wander_point"):
		return
	_wander_target = current_floor.get_random_wander_point()
	if _wander_target:
		nav_agent.target_position = _wander_target.global_position


func _on_earthquake_started() -> void:
	state = State.PANIC
	_reaction_timer = 0.0
	_reaction_complete = false
	_panic_target_node = null


func _acquire_panic_target() -> void:
	if current_floor == null:
		return

	# Ground floor: head straight for the nearest open exit.
	if current_floor.floor_index == 0:
		var exit_node = current_floor.get_nearest_exit(global_position)
		if exit_node:
			_panic_target_node = exit_node
			nav_agent.target_position = exit_node.get_target_position()
			return

	# Upper floors: head for the nearest stairwell that leads down (3.4.6).
	var stair_node = current_floor.get_nearest_stair_toward_ground(global_position)
	if stair_node:
		_panic_target_node = stair_node
		nav_agent.target_position = stair_node.get_target_position()


## --- Called by Exit.gd / StairConnector.gd before claiming this agent ---
## Guards against the same agent being captured twice in one physics step by
## two overlapping detection zones (e.g. two StairConnectors stacked at the
## same physical stairwell - one going up, one going down).
func is_active() -> bool:
	return state == State.NORMAL or state == State.PANIC


## --- Called by Exit.gd when this agent reaches a safe exit ---
func on_escaped() -> void:
	state = State.ESCAPED
	visible = false
	set_physics_process(false)
	detection_area.set_deferred("monitoring", false)
	detection_area.set_deferred("monitorable", false)
	queue_free()


## --- Called by StairConnector.gd ---
func enter_stair_transit() -> void:
	state = State.IN_TRANSIT
	visible = false
	detection_area.set_deferred("monitoring", false)
	detection_area.set_deferred("monitorable", false)


func exit_stair_transit(new_floor: Node) -> void:
	current_floor = new_floor
	visible = true
	detection_area.set_deferred("monitoring", true)
	detection_area.set_deferred("monitorable", true)
	_panic_target_node = null
	_wander_target = null

	state = State.PANIC if Manager.earthquake_triggered else State.NORMAL
	if state == State.NORMAL:
		sprite.modulate = Color.BLACK
		_pick_new_wander_target()
	else:
		sprite.modulate = Color.RED
