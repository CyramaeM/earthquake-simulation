extends Area2D
## Exit.gd - Detects evacuated agents reaching a safe exit.
## Attach to: each "Exit" Area2D node under a Floor's "Exits" container.
##
## NOTE: Agent.tscn has no PhysicsBody, only an Area2D (for precise, cheap
## overlap detection), so this listens for area_entered (Area<->Area),
## not body_entered.
##
## Thesis ref: Chapter 3.4.2 "The Environment (Digitization Layer)", Listing 3.1.

@export var is_blocked: bool = false  # Used by the "Constrained Scenario" (3.5).


func _ready() -> void:
	add_to_group("exits")
	area_entered.connect(_on_area_entered)
	Manager.earthquake_started.connect(_on_earthquake_started)
	z_index = 90
	z_as_relative = false
	queue_redraw()

## The Exit Area2D node itself always sits at local (0,0) under "Exits" - the
## real-world location is entirely encoded in the child CollisionShape2D's
## position. Pathfinding targets must use this, not global_position directly.
func get_target_position() -> Vector2:
	for child in get_children():
		if child is CollisionShape2D or child is CollisionPolygon2D:
			return child.global_position
	return global_position


func _on_area_entered(area: Area2D) -> void:
	if not Manager.earthquake_triggered:
		return  # Pre-quake wandering agents pass through exits freely - an exit
				# only "counts" once the evacuation has actually begun. Without
				# this, an agent in State.NORMAL that happens to wander across
				# the exit zone gets despawned and counted as escaped before
				# anything has even happened.
	_try_evacuate(area)


## area_entered only fires on a *new* overlap. An agent that wandered into
## this exit's zone before the quake (and is just standing there, since the
## check above was blocking it) won't generate a fresh signal once the quake
## fires - it's already "entered". Without this sweep that agent would be
## physically standing in the exit but never get counted as escaped until it
## happened to wander back out and back in again. So the instant the quake
## triggers, check everyone already overlapping this exit right now.
func _on_earthquake_started() -> void:
	for area in get_overlapping_areas():
		_try_evacuate(area)


func _try_evacuate(area: Area2D) -> void:
	if is_blocked:
		return

	var agent := area.get_parent()
	if agent == null or not is_instance_valid(agent):
		return
	if not agent.is_in_group("agents"):
		return
	if not agent.has_method("on_escaped"):
		return
	if agent.has_method("is_active") and not agent.is_active():
		return  # Already claimed by an overlapping Exit/StairConnector this frame.

	Manager.agent_escaped(agent)
	agent.on_escaped()


func set_blocked(value: bool) -> void:
	is_blocked = value
	# Visual feedback if this exit gets disabled for a Constrained Scenario run.
	#modulate = Color(0.5, 0.5, 0.5, 0.6) if value else Color(1, 1, 1, 1)
	queue_redraw()


## Visual marker for an exit closed for a Constrained Scenario run.
func _draw() -> void:
	if not is_blocked:
		return
	var p := to_local(get_target_position())
	var s := 20.0
	var box := Rect2(p - Vector2(s, s), Vector2(s * 2.0, s * 2.0))
	draw_rect(box, Color(0.90, 0.10, 0.10, 0.25), true)
	draw_rect(box, Color(1.00, 0.22, 0.22, 0.95), false, 2.0)
	draw_line(p - Vector2(s, s), p + Vector2(s, s), Color(1.0, 0.28, 0.28, 0.95), 3.0)
	draw_line(p - Vector2(s, -s), p + Vector2(s, -s), Color(1.0, 0.28, 0.28, 0.95), 3.0)
	var font: Font = ThemeDB.fallback_font
	draw_string(font, p + Vector2(-s, -s - 6.0), "EXIT BLOCKED",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1.0, 0.55, 0.5))
