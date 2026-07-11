extends Node2D
## HeatMap.gd - Visualizes live crowd density as a heat map overlay.
## Attach to: "HeatMapCanvas" Node2D in Main.tscn.
##
## Reads Manager.live_density (a decaying Vector2i-cell -> count grid that
## every Agent feeds into via Manager.log_position() each physics frame).
##
## Thesis ref: Chapter 3.6 "Data Analysis" - heat maps highlighting
## congestion "Red Zones".

@export var enabled: bool = true

## Three-stop gradient, tuned so red is reserved for genuinely crowded
## cells and most low-traffic areas read as clearly green:
##   value <= low_density_threshold        -> solid green
##   low < value <= moderate_density_threshold   -> green fading to yellow
##   moderate < value <= high_density_threshold  -> yellow fading to red
##   value > high_density_threshold        -> solid red ("Red Zone")
## Push high_density_threshold up (or moderate_density_threshold closer to
## it) to make red progressively harder to reach.
@export var low_density_threshold: float = 8.0
@export var moderate_density_threshold: float = 30.0
@export var high_density_threshold: float = 70.0


func _process(_delta: float) -> void:
	if enabled:
		queue_redraw()


func _draw() -> void:
	if not enabled:
		return

	for cell in Manager.live_density.keys():
		var value: float = Manager.live_density[cell]
		if value < 0.5:
			continue  # Skip only essentially-empty decayed residue - real
					  # low traffic should still render, as green, not be
					  # invisible.

		var color := _heat_color(value)
		var rect_pos := Vector2(cell.x, cell.y) * Manager.cell_size
		draw_rect(Rect2(rect_pos, Vector2(Manager.cell_size, Manager.cell_size)), color)


func _heat_color(value: float) -> Color:
	var c: Color
	var t: float  # overall 0..1 position, used only to scale alpha below

	if value <= low_density_threshold:
		c = Color(0, 1, 0)
		t = 0.0
	elif value <= moderate_density_threshold:
		var seg_t: float = (value - low_density_threshold) / max(0.001, moderate_density_threshold - low_density_threshold)
		c = Color(0, 1, 0).lerp(Color(1, 1, 0), seg_t)
		t = seg_t * 0.5
	elif value <= high_density_threshold:
		var seg_t: float = (value - moderate_density_threshold) / max(0.001, high_density_threshold - moderate_density_threshold)
		c = Color(1, 1, 0).lerp(Color(1, 0, 0), seg_t)
		t = 0.5 + seg_t * 0.5
	else:
		c = Color(1, 0, 0)
		t = 1.0

	c.a = 0.15 + t * 0.5
	return c


func toggle() -> void:
	enabled = not enabled
	if not enabled:
		queue_redraw()
