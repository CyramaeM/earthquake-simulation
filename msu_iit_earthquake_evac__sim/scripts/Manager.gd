extends Node
## Manager.gd - Central simulation director / data analysis layer.
##
## SETUP (required): This script must be added as an AUTOLOAD singleton.
##   Project > Project Settings > Autoload
##   Path: res://scripts/Manager.gd   Node Name: Manager
## It is not attached to any node in Main.tscn on purpose - everything else
## (Agent, Exit, StairConnector, Floor, UI) talks to it as "Manager.xxx".
##
## Thesis ref: Chapter 3.4.4 "The Manager (Data Analysis Layer)", Listing 3.3,
## and Chapter 3.6 "Data Analysis".

signal earthquake_started
signal agent_escaped_updated(escaped_count: int, total_count: int)
signal simulation_started(scenario_name: String)
signal simulation_complete(stats: Dictionary)
signal metrics_updated(metrics: Dictionary)

enum Scenario { BASELINE, HIGH_DENSITY, CONSTRAINED }

# --- Scenario configuration (3.5 Simulation Scenarios) ---

# Multiplies each floor's base_occupancy to model peak-hour / time-of-day load.
var occupancy_multiplier: Dictionary = {
	Scenario.BASELINE: 1.0,
	Scenario.HIGH_DENSITY: 1.8,
	Scenario.CONSTRAINED: 1.0,
}

# Node names of Exit / StairConnector instances to disable for the
# "Constrained Scenario" (partial structural failure, 3.5). Fill these in
# with real node names (e.g. "Stair_0_2") once you've identified which
# routes you want to stress-test.
var blocked_exit_names: Dictionary = {
	Scenario.CONSTRAINED: [],
}
var blocked_stair_names: Dictionary = {
	Scenario.CONSTRAINED: [],
}


# Routes (exit/stair node names) the user closes at runtime from the dashboard's
# Constrained-Scenario picker. This is the UI-driven equivalent of hard-coding
# names into blocked_*_names above. Applied on top of the scenario lists and the
# editor flags in _apply_scenario_blocks(). Set via set_manual_blocks().
var manual_blocked_names: Array = []


# Snapshot of each node's is_blocked value as set in the Inspector (captured
# once, before any simulation run overwrites it). This lets Option B preserve
# editor-authored "always blocked" flags across restarts.
var _editor_blocked_exits: Dictionary = {}   # node instance_id -> bool
var _editor_blocked_stairs: Dictionary = {}  # node instance_id -> bool

var time_to_earthquake: float = 5.0  # Seconds of "Normal" wandering before the quake signal fires.

# Fraction of total_agents_spawned that must escape before the simulation
# is considered complete (the long tail of stragglers is treated as noise
# once the bulk of the crowd is out).
var evacuation_completion_threshold: float = 0.9

# --- Runtime state ---
var current_scenario: int = Scenario.BASELINE
var simulation_running: bool = false
var earthquake_triggered: bool = false
var elapsed_time: float = 0.0

var _metrics_accum: float = 0.0
const METRICS_INTERVAL: float = 0.25     # emit metrics 4x/second (cheap)
const FLOW_WINDOW: float = 2.0           # seconds, for instantaneous flow
var _peak_flow: float = 0.0
var auto_trigger_earthquake: bool = true # fire the quake automatically at time_to_earthquake

var floors: Dictionary = {}     # floor_index (int) -> Floor node
var agents: Array = []          # all currently-active Agent nodes

var total_agents_spawned: int = 0
var agents_escaped: int = 0
var escape_log: Array = []      # [{agent_id, time, floor}, ...]

# --- Heat map density grid (3.6 Data Analysis / "Red Zones") ---
var cell_size: float = 32.0
var live_density: Dictionary = {}   # Vector2i cell -> float (decaying live count)
var density_decay: float = 0.92

# --- Spatial hash grid for fast local-crowding queries ---
# Rebuilt lazily, at most once per physics frame, no matter how many agents
# call get_local_agent_count() that frame. Without this, get_local_agent_count
# was an O(n) scan over every agent in the simulation, called once per active
# agent per physics frame -> O(n^2) per frame. At 100 agents/floor across 4
# floors (400 agents) that's ~160,000 distance checks/tick, which is the
# main cause of simulation slowdown at higher agent counts.
#
# NOTE: radius passed into get_local_agent_count() (currently 16.0, see
# Agent.gd) must stay <= cell_size for the 3x3 neighborhood check below to
# be correct. If you ever raise that radius above cell_size, widen the
# neighborhood loop (or bump cell_size) accordingly.
var _agent_grid: Dictionary = {}        # Vector2i cell -> Array[Node] (this frame's agents)
var _agent_grid_built_frame: int = -1


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	# Snapshot every exit/stair's is_blocked value exactly as authored in the
	# Inspector, before start_simulation() ever calls _apply_scenario_blocks().
	# We wait one frame so all Floor nodes (and their children) have finished
	# their own _ready() calls and registered with Manager.
	await get_tree().process_frame
	_snapshot_editor_blocked_flags()


# ---------------------------------------------------------------------------
# Registration (called by Floor.gd and Agent.gd)
# ---------------------------------------------------------------------------

func register_floor(floor_index: int, floor_node: Node) -> void:
	floors[floor_index] = floor_node


func get_floor(floor_index: int) -> Node:
	return floors.get(floor_index, null)


func register_agent(agent: Node) -> void:
	agents.append(agent)
	total_agents_spawned += 1


func agent_escaped(agent: Node) -> void:
	if not simulation_running:
		return  # Already wrapped up (e.g. a same-frame straggler reaching an exit
				# right as the 90% threshold was hit) - don't double-count or re-finish.

	agents_escaped += 1
	var floor_idx: int = agent.current_floor.floor_index if agent.current_floor else -1
	escape_log.append({"agent_id": agent.get_instance_id(), "time": elapsed_time, "floor": floor_idx})
	agents.erase(agent)
	agent_escaped_updated.emit(agents_escaped, total_agents_spawned)

	if agents_escaped >= _required_escapes_for_completion():
		_finish_simulation()


func _required_escapes_for_completion() -> int:
	# At least 1 agent, and rounded up so e.g. 10 agents @ 90% requires 9, not 8.
	return int(max(1, ceil(total_agents_spawned * evacuation_completion_threshold)))


# ---------------------------------------------------------------------------
# Density tracking (used by Agent.gd for crowd slowdown, and HeatMap.gd)
# ---------------------------------------------------------------------------

func log_position(world_pos: Vector2) -> void:
	var cell := Vector2i(int(floor(world_pos.x / cell_size)), int(floor(world_pos.y / cell_size)))
	live_density[cell] = live_density.get(cell, 0.0) + 1.0


func get_local_agent_count(world_pos: Vector2, radius: float, exclude: Node = null) -> int:
	_ensure_agent_grid_current()

	var count := 0
	var center_cell := _grid_cell(world_pos)
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var cell := center_cell + Vector2i(dx, dy)
			var bucket = _agent_grid.get(cell)
			if bucket == null:
				continue
			for a in bucket:
				if a == exclude or not is_instance_valid(a):
					continue
				if a.global_position.distance_to(world_pos) <= radius:
					count += 1
	return count


func _grid_cell(world_pos: Vector2) -> Vector2i:
	return Vector2i(int(floor(world_pos.x / cell_size)), int(floor(world_pos.y / cell_size)))


## Rebuilds the agent spatial hash at most once per physics frame. Cheap to
## call redundantly - every agent calls this every physics frame via
## get_local_agent_count(), but only the first call in a given frame does
## any work (subsequent calls in the same frame are a no-op check).
func _ensure_agent_grid_current() -> void:
	var current_frame := Engine.get_physics_frames()
	if _agent_grid_built_frame == current_frame:
		return
	_agent_grid_built_frame = current_frame

	_agent_grid.clear()
	for a in agents:
		if not is_instance_valid(a):
			continue
		var cell := _grid_cell(a.global_position)
		if _agent_grid.has(cell):
			_agent_grid[cell].append(a)
		else:
			_agent_grid[cell] = [a]


# ---------------------------------------------------------------------------
# Simulation control
# ---------------------------------------------------------------------------

func start_simulation(scenario: int = Scenario.BASELINE) -> void:
	current_scenario = scenario
	simulation_running = true
	earthquake_triggered = false
	elapsed_time = 0.0
	agents_escaped = 0
	total_agents_spawned = 0
	_peak_flow = 0.0
	escape_log.clear()
	agents.clear()
	live_density.clear()

	_apply_scenario_blocks(scenario)
	_spawn_all_agents(scenario)

	simulation_started.emit(Scenario.keys()[scenario])


func _apply_scenario_blocks(scenario: int) -> void:
	# Option B: respect the editor-set is_blocked flag on each node.
	# Priority order for each node, CONSTRAINED ONLY:
	#   1. Scenario list says block it     -> blocked (true)
	#   2. Editor Inspector had it blocked -> blocked (true, preserved across restarts)
	#   3. Dashboard manual-block picker    -> blocked (true)
	#   4. Neither                          -> unblocked (false)
	# Baseline / High Density always run fully open - editor-authored
	# is_blocked flags and manual picks are Constrained-only stressors and
	# must never leak into other scenarios.
	var is_constrained := (scenario == Scenario.CONSTRAINED)
	print("=== _apply_scenario_blocks: scenario=%s is_constrained=%s ===" % [Scenario.keys()[scenario], is_constrained])

	var blocked_exits: Array = blocked_exit_names.get(scenario, []) if is_constrained else []
	for exit_node in get_tree().get_nodes_in_group("exits"):
		if exit_node.has_method("set_blocked"):
			var editor_blocked: bool = is_constrained and _editor_blocked_exits.get(exit_node.get_instance_id(), false)
			var manual_blocked: bool = is_constrained and (exit_node.name in manual_blocked_names)
			var final_blocked: bool = (exit_node.name in blocked_exits) or editor_blocked or manual_blocked
			print("  exit %s -> blocked=%s (editor_snapshot=%s, manual=%s)" % [exit_node.name, final_blocked, editor_blocked, manual_blocked])
			exit_node.set_blocked(final_blocked)

	var blocked_stairs: Array = blocked_stair_names.get(scenario, []) if is_constrained else []
	for stair_node in get_tree().get_nodes_in_group("stairs"):
		if stair_node.has_method("set_blocked"):
			var editor_blocked: bool = is_constrained and _editor_blocked_stairs.get(stair_node.get_instance_id(), false)
			var manual_blocked: bool = is_constrained and (stair_node.name in manual_blocked_names)
			var final_blocked: bool = (stair_node.name in blocked_stairs) or editor_blocked or manual_blocked
			print("  stair %s -> blocked=%s (editor_snapshot=%s, manual=%s)" % [stair_node.name, final_blocked, editor_blocked, manual_blocked])
			stair_node.set_blocked(final_blocked)

## Called by the dashboard's Constrained-Scenario picker. `names` is the list of
## exit/stair node names the user has checked to close. Takes effect on the next
## start_simulation() (and the picker also marks them live in the world).
func set_manual_blocks(names: Array) -> void:
	manual_blocked_names = names.duplicate()
	

func _snapshot_editor_blocked_flags() -> void:
	# Called once from _ready() (after one deferred frame) so all nodes exist.
	# Records whatever is_blocked value is baked into the scene/Inspector for
	# every exit and stair, so _apply_scenario_blocks() can honour it later.
	_editor_blocked_exits.clear()
	for exit_node in get_tree().get_nodes_in_group("exits"):
		if "is_blocked" in exit_node:
			_editor_blocked_exits[exit_node.get_instance_id()] = exit_node.is_blocked

	_editor_blocked_stairs.clear()
	for stair_node in get_tree().get_nodes_in_group("stairs"):
		if "is_blocked" in stair_node:
			_editor_blocked_stairs[stair_node.get_instance_id()] = stair_node.is_blocked


func _spawn_all_agents(scenario: int) -> void:
	var mult: float = occupancy_multiplier.get(scenario, 1.0)
	for idx in floors.keys():
		var f = floors[idx]
		var count: int = int(round(f.base_occupancy * mult))
		f.spawn_agents(count)

## Called live while simulation_running, whenever the UI slider changes.
## Adjusts each floor's current agent count up or down to match the new
## occupancy_multiplier, without resetting elapsed_time, escape counts, or
## agents already in transit. Only agents ON THIS scenario's floors are
## affected - already-escaped agents are untouched.
func update_occupancy_live(scenario: int, new_multiplier: float) -> void:
	if not simulation_running:
		return
	if scenario != current_scenario:
		return  # Don't touch a scenario that isn't the one currently running.

	occupancy_multiplier[scenario] = new_multiplier

	for idx in floors.keys():
		var f = floors[idx]
		var target_count: int = int(round(f.base_occupancy * new_multiplier))
		var current_count: int = _count_agents_on_floor(idx)
		var diff: int = target_count - current_count

		if diff > 0:
			# Need more agents on this floor - spawn the shortfall.
			f.spawn_agents(diff)
		elif diff < 0:
			# Too many agents on this floor - remove the excess (not escapes).
			_despawn_agents_on_floor(idx, -diff)


func _count_agents_on_floor(floor_index: int) -> int:
	var count := 0
	for a in agents:
		if not is_instance_valid(a):
			continue
		if a.current_floor and a.current_floor.floor_index == floor_index:
			count += 1
	return count


## Removes up to `amount` agents from the given floor. These agents are
## silently retired - not logged as escapes, and total_agents_spawned is
## decremented so the evacuation percentage stays accurate.
func _despawn_agents_on_floor(floor_index: int, amount: int) -> void:
	var removed := 0
	for a in agents.duplicate():
		if removed >= amount:
			break
		if not is_instance_valid(a):
			continue
		if a.current_floor and a.current_floor.floor_index == floor_index:
			if a.has_method("set_physics_process"):
				a.set_physics_process(false)
			var detection: Node = a.get_node_or_null("Area2D")
			if detection:
				detection.set_deferred("monitoring", false)
				detection.set_deferred("monitorable", false)
			agents.erase(a)
			a.queue_free()
			total_agents_spawned -= 1
			removed += 1


func _process(delta: float) -> void:
	if not simulation_running:
		return

	elapsed_time += delta

	# Decay the live density grid so the heat map reflects *current* congestion.
	for k in live_density.keys():
		live_density[k] *= density_decay
		if live_density[k] < 0.05:
			live_density.erase(k)
	_update_metrics(delta) 


func trigger_earthquake() -> void:
	if not earthquake_triggered:
		earthquake_triggered = true
		earthquake_started.emit()

func _update_metrics(_delta: float) -> void:
	# Optional auto-earthquake (manual Panic button still works and can fire earlier).
	if auto_trigger_earthquake and not earthquake_triggered and elapsed_time >= time_to_earthquake:
		trigger_earthquake()

	_metrics_accum += _delta
	if _metrics_accum < METRICS_INTERVAL:
		return
	_metrics_accum = 0.0

	var flow := get_instantaneous_flow(FLOW_WINDOW)
	_peak_flow = max(_peak_flow, flow)
	var peak := get_peak_density_cell()   # { "cell": Vector2i, "value": float } or {}

	var m := {
		"time": elapsed_time,
		"escaped": agents_escaped,
		"total": total_agents_spawned,
		"remaining": agents.size(),
		"flow": flow,
		"floor_counts": get_live_floor_counts(),
		"peak_density": peak.get("value", 0.0),
		"peak_cell": peak.get("cell", null),
	}
	metrics_updated.emit(m)


## Instantaneous outflow rate: escapes within the last `window` seconds / window.
func get_instantaneous_flow(window: float) -> float:
	if window <= 0.0:
		return 0.0
	var cutoff := elapsed_time - window
	var count := 0
	# escape_log is append-ordered by time, so scan from the back and stop early.
	for i in range(escape_log.size() - 1, -1, -1):
		if escape_log[i]["time"] < cutoff:
			break
		count += 1
	return float(count) / window


## Live count of active (not-yet-escaped) agents on each floor.
func get_live_floor_counts() -> Dictionary:
	var counts: Dictionary = {}
	for idx in floors.keys():
		counts[idx] = 0
	for a in agents:
		if not is_instance_valid(a):
			continue
		if a.current_floor and a.current_floor.floor_index in counts:
			counts[a.current_floor.floor_index] += 1
	return counts


## The single hottest congestion cell (the current worst bottleneck).
func get_peak_density_cell() -> Dictionary:
	var best_cell = null
	var best_val := 0.0
	for cell in live_density.keys():
		var v: float = live_density[cell]
		if v > best_val:
			best_val = v
			best_cell = cell
	if best_cell == null:
		return {}
	return { "cell": best_cell, "value": best_val }


## Top-K congestion cells above `threshold`, hottest first (for the world overlay).
func get_top_density_cells(k: int, threshold: float = 3.0) -> Array:
	var arr: Array = []
	for cell in live_density.keys():
		var v: float = live_density[cell]
		if v >= threshold:
			arr.append({ "cell": cell, "value": v })
	arr.sort_custom(func(a, b): return a["value"] > b["value"])
	if arr.size() > k:
		arr.resize(k)
	return arr

func _finish_simulation() -> void:
	simulation_running = false
	var stats := {
		"scenario": Scenario.keys()[current_scenario],
		"total_evacuation_time": elapsed_time,
		"total_agents": total_agents_spawned,
		"escaped": agents_escaped,
		"evacuated_percentage": (float(agents_escaped) / float(total_agents_spawned)) * 100.0 if total_agents_spawned > 0 else 0.0,
		"avg_flow": (float(agents_escaped) / elapsed_time) if elapsed_time > 0.0 else 0.0,
		"peak_flow": _peak_flow,
	}
	_retire_remaining_agents()
	_export_logs_to_csv()
	simulation_complete.emit(stats)


## Anyone still mid-evacuation once the completion threshold is hit is outside
## the scope of this run. Stop them in place and free them so they can't keep
## moving in the background, escape late, and corrupt the *next* run's count.
func _retire_remaining_agents() -> void:
	for a in agents.duplicate():
		if not is_instance_valid(a):
			continue
		if a.has_method("set_physics_process"):
			a.set_physics_process(false)
		var detection: Node = a.get_node_or_null("Area2D")
		if detection:
			detection.set_deferred("monitoring", false)
			detection.set_deferred("monitorable", false)
		a.queue_free()
	agents.clear()


## Writes three CSV files per run to user://logs/:
##   evac_log_<ts>.csv        - one row per escaped agent (full per-agent data)
##   evac_summary_<ts>.csv    - one row of scalar summary metrics
##   evac_stairs_<ts>.csv     - one row per StairConnector
func _export_logs_to_csv(stats: Dictionary) -> void:
	var dir_path := "user://logs"
	DirAccess.make_dir_recursive_absolute(dir_path)
	var ts: int = Time.get_unix_time_from_system()

	# --- 1. Per-agent escape log ---
	var log_path := "%s/evac_log_%d.csv" % [dir_path, ts]
	var log_file := FileAccess.open(log_path, FileAccess.WRITE)
	if log_file == null:
		push_warning("Manager: could not open log file: %s" % log_path)
	else:
		log_file.store_line("agent_id,time_seconds,floor,exit_id,distance,congestion_time_s")
		for e in escape_log:
			log_file.store_line("%s,%.3f,%d,%s,%.2f,%.3f" % [
				e.agent_id, e.time, e.floor,
				e.get("exit_id", ""),
				e.get("distance", 0.0),
				e.get("congestion_time", 0.0),
			])
		log_file.close()
		print("Manager: escape log -> ", log_path)

	# --- 2. Scalar summary ---
	var summary_path := "%s/evac_summary_%d.csv" % [dir_path, ts]
	var summary_file := FileAccess.open(summary_path, FileAccess.WRITE)
	if summary_file == null:
		push_warning("Manager: could not open summary file: %s" % summary_path)
	else:
		summary_file.store_line(
			"scenario,load,escaped_90pct,clearance_time_s," +
			"avg_flow_per_s,core_flow_per_s,peak_flow_per_s,peak_mean_ratio," +
			"first_escape_s,last_escape_s,median_escape_s,escape_stddev_s," +
			"reaction_mean_s,reaction_stddev_s," +
			"dist_mean,dist_max,congestion_mean_s"
		)
		summary_file.store_line("%.s,%d,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.2f,%.2f,%.3f" % [
			stats["scenario"],
			stats["load"],
			stats["escaped_90pct"],
			stats["clearance_time"],
			stats["avg_flow"],
			stats["core_flow"],
			stats["peak_flow"],
			stats["peak_mean_ratio"],
			stats["first_escape_time"],
			stats["last_escape_time"],
			stats["median_escape_time"],
			stats["escape_time_stddev"],
			stats["reaction_time_mean"],
			stats["reaction_time_stddev"],
			stats["distance_mean"],
			stats["distance_max"],
			stats["congestion_time_mean"],
		])
		summary_file.close()
		print("Manager: summary -> ", summary_path)

	# --- 3. Per-stair summary ---
	var stair_path := "%s/evac_stairs_%d.csv" % [dir_path, ts]
	var stair_file := FileAccess.open(stair_path, FileAccess.WRITE)
	if stair_file == null:
		push_warning("Manager: could not open stair file: %s" % stair_path)
	else:
		stair_file.store_line(
			"stair_name,transit_count,peak_queue_length," +
			"mean_wait_s,max_wait_s,mean_transit_s,base_transit_s,slowdown_factor"
		)
		for sname in stair_stats:
			var s: Dictionary = stair_stats[sname]
			stair_file.store_line("%s,%d,%d,%.3f,%.3f,%.3f,%.3f,%.3f" % [
				sname,
				s.get("transit_count", 0),
				s.get("peak_queue_length", 0),
				s.get("mean_wait_time", 0.0),
				s.get("max_wait_time", 0.0),
				s.get("mean_transit_time", 0.0),
				s.get("base_transit_time", 0.0),
				s.get("slowdown_factor", 1.0),
			])

		# Also write per-floor and exit-distribution data as trailing sections.
		stair_file.store_line("")
		stair_file.store_line("floor,escape_count,clearance_time_s")
		var ecp: Dictionary = stats.get("escape_count_per_floor", {})
		var ctp: Dictionary = stats.get("clearance_time_per_floor", {})
		for fi in ecp:
			stair_file.store_line("%d,%d,%.3f" % [fi, ecp[fi], ctp.get(fi, 0.0)])

		stair_file.store_line("")
		stair_file.store_line("exit_id,agent_count")
		var euc: Dictionary = stats.get("exit_use_counts", {})
		for eid in euc:
			stair_file.store_line("%s,%d" % [eid, euc[eid]])

		stair_file.close()
		print("Manager: stair/floor/exit log -> ", stair_path)
