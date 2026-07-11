extends CanvasLayer
## UI.gd - Heads-up display: timer, escaped count, scenario, start button.
## Attach to: "CanvasLayer" node under "UI" in Main.tscn.
## Children expected (already present in Main.tscn): Label_Timer,
## Label_Escaped, Label_Scenario, Button_Start.

@onready var label_timer: Label = $Label_Timer
@onready var label_escaped: Label = $Label_Escaped
@onready var button_start: Button = $Button_Start
@onready var button_panic: Button = $Button_Panic
@onready var slider_occupancy: HSlider = $slider_occupancy

var _current_scenario: int = Manager.Scenario.BASELINE

func _ready() -> void:
	button_start.pressed.connect(_on_button_start_pressed)
	button_panic.pressed.connect(_on_button_panic_pressed)
	slider_occupancy.value_changed.connect(_on_slider_occupancy_value_changed)
	Manager.agent_escaped_updated.connect(_on_agent_escaped_updated)
	Manager.simulation_complete.connect(_on_simulation_complete)
	label_escaped.text = "Escaped: 0 / 0"
	label_timer.text = "Time: 0.0s"
	# Push the initial slider value in immediately so Manager isn't holding a stale default.
	Manager.occupancy_multiplier[_current_scenario] = slider_occupancy.value

func _process(_delta: float) -> void:
	if Manager.simulation_running:
		label_timer.text = "Time: %.1fs" % Manager.elapsed_time

func _on_slider_occupancy_value_changed(value: float) -> void:
	Manager.occupancy_multiplier[_current_scenario] = value
	if Manager.simulation_running:
		Manager.update_occupancy_live(_current_scenario, value)

func _on_button_start_pressed() -> void:
	if Manager.simulation_running:
		return
	button_start.disabled = true
	button_start.text = "Running..."
	button_panic.disabled = false
	label_escaped.text = "Escaped: 0 / 0"
	Manager.start_simulation(_current_scenario)

func _on_button_panic_pressed() -> void:
	if Manager.simulation_running and not Manager.earthquake_triggered:
		Manager.trigger_earthquake()
		button_panic.disabled = true

func _on_scenario_label_input(event: InputEvent) -> void:
	if Manager.simulation_running:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_current_scenario = (_current_scenario + 1) % Manager.Scenario.size()
		# Keep Manager's stored value in sync with whichever scenario is now active.
		Manager.occupancy_multiplier[_current_scenario] = slider_occupancy.value

func _on_agent_escaped_updated(count: int, total: int) -> void:
	label_escaped.text = "Escaped: %d / %d" % [count, total]

func _on_simulation_complete(stats: Dictionary) -> void:
	label_timer.text = "Done in %.1fs (%.0f%% evacuated)" % [stats.get("total_evacuation_time", 0.0), stats.get("evacuated_percentage", 0.0)]
	button_start.disabled = false
	button_start.text = "Restart"
	button_panic.disabled = true
