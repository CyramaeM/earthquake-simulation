extends CanvasLayer
class_name SimDashboard
## SimDashboard.gd - A NetLogo-style control + visualization layer for the
## earthquake evacuation simulation. Builds its ENTIRE interface in code, so you
## only add one node to the scene (no manual wiring of dozens of widgets).
##
## Layout (like NetLogo, but richer):
##   +----------------+---------------------------+------------------+
##   |  CONTROLS      |                           |   LIVE GRAPHS    |
##   |  - scenario    |                           |   - escaped      |
##   |  - agents      |     (your simulation      |   - flow rate    |
##   |  - speed       |      renders here)        |   - per-floor    |
##   |  - buttons     |                           |                  |
##   |  METRICS       |                           |   BOTTLENECK     |
##   |  LEGEND        |                           |   read-out       |
##   +----------------+---------------------------+------------------+
##
## SETUP:
##   1. Apply the additive patch in Manager_ADDITIONS.gd to your Manager.gd.
##   2. Add a CanvasLayer node to Main.tscn, attach this script (or instance
##      SimDashboard.tscn if you make one). Set its "layer" to 1 so it draws
##      over the world. Remove/disable your old UI CanvasLayer.
##   3. (Optional) Add CriticalPointsOverlay.gd to a Node2D under Main for the
##      live bottleneck markers in the world view.
##
## Requires the Manager additions: signal metrics_updated, get_live_floor_counts(),
## get_peak_density_cell(), get_instantaneous_flow(). See Manager_ADDITIONS.gd.

const PANEL_W := 300.0
const GRAPH_W := 360.0

# Controls
var _scenario_opt: OptionButton
var _occ_slider: HSlider
var _occ_label: Label
var _base_spin: SpinBox
var _quake_spin: SpinBox
var _speed_slider: HSlider
var _speed_label: Label
var _btn_start: Button
var _btn_panic: Button
var _btn_reset: Button

# Metrics labels
var _m_time: Label
var _m_escaped: Label
var _m_pct: Label
var _m_flow: Label
var _m_remaining: Label
var _m_bottleneck: Label

# Graphs
var _g_escaped: LiveGraph
var _s_escaped := -1
var _g_flow: LiveGraph
var _s_flow := -1
var _g_floors: LiveGraph
var _floor_series: Dictionary = {}   # floor_index -> series id

# Summary popup
var _summary_panel: PanelContainer
var _summary_label: RichTextLabel

# Constrained-scenario route picker
var _block_section: VBoxContainer
var _block_list_vb: VBoxContainer
var _block_checks: Array = []       # CheckBox nodes
var _manual_blocks: Array = []      # node names currently checked

var _current_scenario: int = Manager.Scenario.BASELINE
var _floor_palette := [
	Color(0.30, 0.69, 1.00 ), Color(0.98, 0.55, 0.20 ),
	Color(0.40, 0.80, 0.45 ), Color(0.80, 0.45, 0.95 ),
	Color(0.95, 0.80, 0.25 ), Color(0.55, 0.75, 0.95 ),
]

func _ready() -> void:
	layer = 5
	_hide_legacy_hud()
	_build_ui()
	# Hook Manager signals (additive; existing ones still work).
	Manager.simulation_started.connect(_on_sim_started)
	Manager.agent_escaped_updated.connect(_on_escaped_updated)
	Manager.simulation_complete.connect(_on_sim_complete)
	if Manager.has_signal("metrics_updated"):
		Manager.metrics_updated.connect(_on_metrics)
	# Seed Manager with initial control values.
	Manager.occupancy_multiplier[_current_scenario] = _occ_slider.value
	Manager.time_to_earthquake = _quake_spin.value
	_refresh_projection()
	# Floors register with the Manager a frame after us, so build the route
	# picker once they exist.
	call_deferred("_rebuild_block_list")


## The old UI.gd HUD (Label_Timer/Escaped/Scenario, Button_Start/Panic,
## slider_occupancy) is fully replaced by this dashboard. If it's still in the
## scene it stacks a SECOND heads-up display that fights this one for the same
## screen space. Hide its widgets - but do NOT free the CanvasLayer, because a
## Camera2D commonly lives under it and freeing that would blank the view.
func _hide_legacy_hud() -> void:
	var root := get_tree().current_scene
	if root == null:
		return
	for node in root.find_children("*", "CanvasLayer", true, false):
		if node == self:
			continue
		var looks_legacy: bool = node.has_node("Button_Start") \
			or node.has_node("Label_Timer") \
			or node.has_node("slider_occupancy")
		if looks_legacy:
			for child in node.get_children():
				if child is Control:
					child.hide()

func _process(_delta: float) -> void:
	if Manager.simulation_running:
		_m_time.text = "Elapsed:  %.1f s" % Manager.elapsed_time

# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------
func _build_ui() -> void:
	_build_control_panel()
	_build_graph_panel()
	_build_summary_popup()

func _panel(anchor_left: bool, width: float) -> PanelContainer:
	var p := PanelContainer.new()
	p.set_anchors_preset(Control.PRESET_LEFT_WIDE if anchor_left else Control.PRESET_RIGHT_WIDE)
	p.custom_minimum_size = Vector2(width, 0 )
	if anchor_left:
		p.offset_right = width
	else:
		p.offset_left = -width
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.08, 0.10, 1.0 )   # fully opaque - nothing behind bleeds through
	sb.border_color = Color(0.20, 0.24, 0.30, 1.0 )
	if anchor_left:
		sb.border_width_right = 1
	else:
		sb.border_width_left = 1
	sb.content_margin_left = 12; sb.content_margin_right = 12
	sb.content_margin_top = 12; sb.content_margin_bottom = 12
	p.add_theme_stylebox_override("panel", sb)
	add_child(p)
	return p

func _header(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 15 )
	l.add_theme_color_override("font_color", Color(0.55, 0.80, 1.0 ))
	return l

func _sub(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 11 )
	l.add_theme_color_override("font_color", Color(0.6, 0.63, 0.68 ))
	return l

func _metric(text: String, big := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 16 if big else 13 )
	l.add_theme_color_override("font_color", Color(0.9, 0.92, 0.95 ))
	return l

func _divider() -> HSeparator:
	var s := HSeparator.new()
	s.add_theme_constant_override("separation", 10 )
	return s

func _build_control_panel() -> void:
	var panel := _panel(true, PANEL_W)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8 )
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vb)

	vb.add_child(_header("EARTHQUAKE EVACUATION"))
	vb.add_child(_sub("Agent-based simulation control"))
	vb.add_child(_divider())

	# --- Scenario ---
	vb.add_child(_sub("SCENARIO"))
	_scenario_opt = OptionButton.new()
	for key in Manager.Scenario.keys():
		_scenario_opt.add_item(str(key).capitalize().replace("_", " "))
	_scenario_opt.selected = _current_scenario
	_scenario_opt.item_selected.connect(_on_scenario_selected)
	vb.add_child(_scenario_opt)

	# --- Constrained: block routes (shown only for the CONSTRAINED scenario) ---
	_block_section = VBoxContainer.new()
	_block_section.add_theme_constant_override("separation", 4 )
	_block_section.add_child(_sub("CONSTRAINED - BLOCK ROUTES"))
	_block_section.add_child(_sub("Tick a stair/exit to close it. Closed routes are marked red on the map."))
	var block_scroll := ScrollContainer.new()
	block_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	block_scroll.custom_minimum_size = Vector2(0, 100 )
	_block_list_vb = VBoxContainer.new()
	_block_list_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	block_scroll.add_child(_block_list_vb)
	_block_section.add_child(block_scroll)
	vb.add_child(_block_section)
	_block_section.visible = (_current_scenario == Manager.Scenario.CONSTRAINED)

	# --- Base occupancy (agents per floor) ---
	vb.add_child(_sub("AGENTS PER FLOOR  (0 = use scene value)"))
	_base_spin = SpinBox.new()
	_base_spin.min_value = 0; _base_spin.max_value = 1000; _base_spin.step = 5
	_base_spin.value = 0
	_base_spin.value_changed.connect(func(_v): _refresh_projection())
	vb.add_child(_base_spin)

	# --- Occupancy multiplier ---
	_occ_label = _metric("Occupancy x1.00")
	vb.add_child(_occ_label)
	_occ_slider = HSlider.new()
	_occ_slider.min_value = 0.25; _occ_slider.max_value = 5.0
	_occ_slider.step = 0.05; _occ_slider.value = 1.0
	_occ_slider.value_changed.connect(_on_occ_changed)
	vb.add_child(_occ_slider)
	vb.add_child(_sub("Slide LIVE during a run to add/remove crowd."))

	# --- Time to earthquake ---
	vb.add_child(_sub("TIME TO EARTHQUAKE (s)"))
	_quake_spin = SpinBox.new()
	_quake_spin.min_value = 0; _quake_spin.max_value = 60; _quake_spin.step = 0.5
	_quake_spin.value = Manager.time_to_earthquake
	_quake_spin.value_changed.connect(func(v): Manager.time_to_earthquake = v)
	vb.add_child(_quake_spin)

	# --- Simulation speed ---
	_speed_label = _metric("Sim speed x1.0")
	vb.add_child(_speed_label)
	_speed_slider = HSlider.new()
	_speed_slider.min_value = 0.25; _speed_slider.max_value = 4.0
	_speed_slider.step = 0.25; _speed_slider.value = 1.0
	_speed_slider.value_changed.connect(_on_speed_changed)
	vb.add_child(_speed_slider)

	vb.add_child(_divider())

	# --- Buttons ---
	_btn_start = Button.new()
	_btn_start.text = "SETUP  &  GO"
	_btn_start.custom_minimum_size = Vector2(0, 40 )
	_btn_start.pressed.connect(_on_start)
	vb.add_child(_btn_start)

	_btn_panic = Button.new()
	_btn_panic.text = "TRIGGER EARTHQUAKE"
	_btn_panic.disabled = true
	_btn_panic.pressed.connect(_on_panic)
	vb.add_child(_btn_panic)

	_btn_reset = Button.new()
	_btn_reset.text = "RESET"
	_btn_reset.pressed.connect(_on_reset)
	vb.add_child(_btn_reset)

	vb.add_child(_divider())

	# --- Live metrics ---
	vb.add_child(_header("LIVE METRICS"))
	_m_time = _metric("Elapsed:  0.0 s", true); vb.add_child(_m_time)
	_m_escaped = _metric("Escaped:  0 / 0", true); vb.add_child(_m_escaped)
	_m_pct = _metric("Evacuated:  0.0 %"); vb.add_child(_m_pct)
	_m_flow = _metric("Flow:  0.0 agents/s"); vb.add_child(_m_flow)
	_m_remaining = _metric("Remaining:  0"); vb.add_child(_m_remaining)
	_m_bottleneck = _metric("Bottleneck:  --")
	_m_bottleneck.add_theme_color_override("font_color", Color(1.0, 0.55, 0.45 ))
	vb.add_child(_m_bottleneck)

	vb.add_child(_divider())

	# --- Legend (meaning of agent colors) ---
	vb.add_child(_header("AGENT COLOR KEY"))
	vb.add_child(_legend_row(Color.BLACK, "Normal - wandering (pre-quake)"))
	vb.add_child(_legend_row(Color.RED, "Panic - evacuating to exit/stair"))
	vb.add_child(_legend_row(Color(0.4, 0.4, 0.4 ), "Hidden - in stair transit"))
	vb.add_child(_legend_row(Color(0.2, 0.8, 0.3 ), "Escaped - left the building"))

func _legend_row(c: Color, text: String) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8 )
	var sw := ColorRect.new()
	sw.color = c
	sw.custom_minimum_size = Vector2(15, 15 )
	h.add_child(sw)
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 10 )
	l.add_theme_color_override("font_color", Color(0.82, 0.84, 0.88 ))
	h.add_child(l)
	return h

func _build_graph_panel() -> void:
	var panel := _panel(false, GRAPH_W)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8 )
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(vb)

	vb.add_child(_header("LIVE PLOTS"))

	_g_escaped = LiveGraph.new()
	_g_escaped.title = "Cumulative escapes"
	_g_escaped.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_s_escaped = _g_escaped.add_series("Escaped", Color(0.25, 0.85, 0.45 ))
	vb.add_child(_g_escaped)

	_g_flow = LiveGraph.new()
	_g_flow.title = "Outflow rate (agents/s, 2s window)"
	_g_flow.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_s_flow = _g_flow.add_series("Flow", Color(0.98, 0.65, 0.20 ))
	vb.add_child(_g_flow)

	_g_floors = LiveGraph.new()
	_g_floors.title = "Agents remaining per floor"
	_g_floors.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(_g_floors)

func _build_summary_popup() -> void:
	_summary_panel = PanelContainer.new()
	_summary_panel.set_anchors_preset(Control.PRESET_CENTER)
	_summary_panel.custom_minimum_size = Vector2(440, 260 )
	_summary_panel.visible = false
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.10, 0.13, 0.98 )
	sb.border_color = Color(0.55, 0.80, 1.0, 0.6 )
	sb.set_border_width_all(2 )
	sb.set_corner_radius_all(5 )
	sb.content_margin_left = 15; sb.content_margin_right = 15
	sb.content_margin_top = 16; sb.content_margin_bottom = 16
	_summary_panel.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	_summary_panel.add_child(vb)
	_summary_label = RichTextLabel.new()
	_summary_label.bbcode_enabled = true
	_summary_label.fit_content = true
	_summary_label.custom_minimum_size = Vector2(300, 200 )
	vb.add_child(_summary_label)
	var close := Button.new()
	close.text = "Close"
	close.pressed.connect(func(): _summary_panel.visible = false)
	vb.add_child(close)
	add_child(_summary_panel)

# ---------------------------------------------------------------------------
# Control callbacks
# ---------------------------------------------------------------------------
func _on_scenario_selected(idx: int) -> void:
	if Manager.simulation_running:
		return
	_current_scenario = idx
	Manager.occupancy_multiplier[_current_scenario] = _occ_slider.value
	var is_constrained := (idx == Manager.Scenario.CONSTRAINED)
	if _block_section:
		_block_section.visible = is_constrained
	if is_constrained:
		_rebuild_block_list()
	else:
		_clear_manual_blocks()   # leaving Constrained: reopen everything
	_refresh_projection()


## (Re)builds one checkbox per exit/stair across all floors. Safe to call
## repeatedly - it rebuilds from the Manager's live floor list each time.
func _rebuild_block_list() -> void:
	if _block_list_vb == null:
		return
	for c in _block_list_vb.get_children():
		c.queue_free()
	_block_checks.clear()

	var floor_keys := Manager.floors.keys()
	floor_keys.sort()
	for f_idx in floor_keys:
		var f = Manager.floors[f_idx]
		if f == null:
			continue
		var routes: Array = []
		if f.has_method("get_stairs"):
			for s in f.get_stairs():
				routes.append({ "node": s, "kind": "stair" })
		if f.has_method("get_exits"):
			for e in f.get_exits():
				routes.append({ "node": e, "kind": "exit" })
		for r in routes:
			var node = r["node"]
			var cb := CheckBox.new()
			cb.text = "F%d  %s  (%s)" % [int(f_idx), node.name, r["kind"]]
			cb.add_theme_font_size_override("font_size", 11 )
			cb.button_pressed = node.name in _manual_blocks
			cb.toggled.connect(func(pressed): _on_block_toggled(node, pressed))
			_block_list_vb.add_child(cb)
			_block_checks.append(cb)

	if _block_list_vb.get_child_count() == 0:
		_block_list_vb.add_child(_sub("No stairs/exits registered yet - press Setup once."))


func _on_block_toggled(node, pressed: bool) -> void:
	var nm: String = node.name
	if pressed:
		if nm not in _manual_blocks:
			_manual_blocks.append(nm)
	else:
		_manual_blocks.erase(nm)
	Manager.set_manual_blocks(_manual_blocks)
	# Mark it in the world immediately, even before the run starts.
	if node.has_method("set_blocked"):
		node.set_blocked(pressed)


func _clear_manual_blocks() -> void:
	for f_idx in Manager.floors.keys():
		var f = Manager.floors[f_idx]
		if f == null:
			continue
		if f.has_method("get_stairs"):
			for s in f.get_stairs():
				if s.name in _manual_blocks and s.has_method("set_blocked"):
					s.set_blocked(false)
		if f.has_method("get_exits"):
			for e in f.get_exits():
				if e.name in _manual_blocks and e.has_method("set_blocked"):
					e.set_blocked(false)
	_manual_blocks.clear()
	Manager.set_manual_blocks(_manual_blocks)
	for cb in _block_checks:
		if is_instance_valid(cb):
			cb.set_pressed_no_signal(false)

func _on_occ_changed(v: float) -> void:
	_occ_label.text = "Occupancy x%.2f" % v
	Manager.occupancy_multiplier[_current_scenario] = v
	if Manager.simulation_running:
		Manager.update_occupancy_live(_current_scenario, v)
	_refresh_projection()

func _on_speed_changed(v: float) -> void:
	Engine.time_scale = v
	_speed_label.text = "Sim speed x%.2f" % v

func _refresh_projection() -> void:
	# Show the projected total agents from current controls (NetLogo-style feedback).
	var mult: float = _occ_slider.value
	var total := 0
	for idx in Manager.floors.keys():
		var f = Manager.floors[idx]
		var base = int(_base_spin.value) if _base_spin.value > 0 else f.base_occupancy
		total += int(round(base * mult))
	_occ_label.text = "Occupancy x%.2f   (~%d agents)" % [mult, total]

func _on_start() -> void:
	if Manager.simulation_running:
		return
	# Apply "agents per floor" override before spawning.
	if _base_spin.value > 0:
		for idx in Manager.floors.keys():
			Manager.floors[idx].base_occupancy = int(_base_spin.value)
	Manager.time_to_earthquake = _quake_spin.value
	# Only the Constrained scenario honours the UI-chosen route blocks.
	Manager.set_manual_blocks(_manual_blocks if _current_scenario == Manager.Scenario.CONSTRAINED else [])
	_reset_graphs()
	_summary_panel.visible = false
	_btn_start.disabled = true
	_btn_start.text = "RUNNING..."
	_btn_panic.disabled = false
	Manager.start_simulation(_current_scenario)

func _on_panic() -> void:
	if Manager.simulation_running and not Manager.earthquake_triggered:
		Manager.trigger_earthquake()
		_btn_panic.disabled = true
		_btn_panic.text = "QUAKE TRIGGERED"

func _on_reset() -> void:
	Manager.simulation_running = false
	Engine.time_scale = 1.0
	get_tree().reload_current_scene()

# ---------------------------------------------------------------------------
# Manager signal handlers
# ---------------------------------------------------------------------------
func _on_sim_started(_scenario_name: String) -> void:
	_reset_graphs()

func _on_escaped_updated(count: int, total: int) -> void:
	_m_escaped.text = "Escaped:  %d / %d" % [count, total]
	var pct := (float(count) / float(total) * 100.0 ) if total > 0 else 0.0
	_m_pct.text = "Evacuated:  %.1f %%" % pct

func _on_metrics(m: Dictionary) -> void:
	var t: float = m.get("time", 0.0 )
	# Cumulative escapes.
	_g_escaped.push(_s_escaped, t, m.get("escaped", 0 ))
	# Flow.
	var flow: float = m.get("flow", 0.0 )
	_g_flow.push(_s_flow, t, flow)
	_m_flow.text = "Flow:  %.1f agents/s" % flow
	# Per-floor remaining.
	var per_floor: Dictionary = m.get("floor_counts", {})
	var remaining := 0
	var keys := per_floor.keys()
	keys.sort()
	for idx in keys:
		if not _floor_series.has(idx):
			var col: Color = _floor_palette[int(idx) % _floor_palette.size()]
			_floor_series[idx] = _g_floors.add_series("Floor %d" % int(idx), col)
		_g_floors.push(_floor_series[idx], t, per_floor[idx])
		remaining += int(per_floor[idx])
	_m_remaining.text = "Remaining in building:  %d" % remaining
	# Bottleneck read-out (critical point).
	var peak: float = m.get("peak_density", 0.0 )
	var cell = m.get("peak_cell", null)
	if peak >= 3.0 and cell != null:
		_m_bottleneck.text = "Bottleneck:  density %.0f near (%d, %d)" % [peak, cell.x, cell.y]
	else:
		_m_bottleneck.text = "Bottleneck:  none (flow nominal)"
	# Refresh graphs.
	_g_escaped.queue_redraw()
	_g_flow.queue_redraw()
	_g_floors.queue_redraw()

func _on_sim_complete(stats: Dictionary) -> void:
	_btn_start.disabled = false
	_btn_start.text = "RESTART"
	_btn_panic.disabled = true
	_btn_panic.text = "TRIGGER EARTHQUAKE"
	var txt := "[b][color=#8fc7ff]Simulation Complete[/color][/b]\n\n"
	txt += "[b]Scenario:[/b]  %s\n" % stats.get("scenario", "?")
	txt += "[b]Clearance time:[/b]  %.2f s\n" % stats.get("total_evacuation_time", 0.0 )
	txt += "[b]Escaped:[/b]  %d / %d  (%.1f%%)\n" % [
		stats.get("escaped", 0 ), stats.get("total_agents", 0 ),
		stats.get("evacuated_percentage", 0.0 )]
	if stats.has("avg_flow"):
		txt += "[b]Average flow:[/b]  %.2f agents/s\n" % stats.get("avg_flow", 0.0 )
	if stats.has("peak_flow"):
		txt += "[b]Peak flow:[/b]  %.1f agents/s\n" % stats.get("peak_flow", 0.0 )
	txt += "\n[color=#9aa]Logs exported to user://logs/[/color]"
	_summary_label.text = txt
	_summary_panel.visible = true

func _reset_graphs() -> void:
	_g_escaped.reset()
	_g_flow.reset()
	_g_floors.reset()
	_floor_series.clear()
	# Rebuild the floors graph's series lazily as metrics arrive.
	_g_floors._series.clear()
