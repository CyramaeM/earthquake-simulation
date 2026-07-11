extends Node2D
class_name CriticalPointsOverlay
## CriticalPointsOverlay.gd - Draws live "critical point" markers directly in the
## world view, over the densest congestion cells (the emergent bottlenecks).
## This is the in-world companion to the dashboard's text bottleneck read-out.
##
## SETUP: add a plain Node2D to Main.tscn at the TOP level (position 0,0, no
## offset) and attach this script. It reads Manager.live_density, which is keyed
## by global-space cells, so it must not be nested under an offset parent.
##
## Requires Manager.get_top_density_cells() from Manager_ADDITIONS.gd.

@export var max_markers: int = 5          # how many hottest cells to flag
@export var density_threshold: float = 3.0 # ignore mild congestion
@export var refresh_hz: float = 8.0

var _accum := 0.0
var _pulse := 0.0

func _ready() -> void:
	z_index = 100   # draw above floors/agents

func _process(delta: float) -> void:
	_pulse += delta
	if not Manager.simulation_running:
		if _accum != -1.0:
			_accum = -1.0
			queue_redraw()   # clear when idle
		return
	_accum += delta
	if _accum >= 1.0 / refresh_hz:
		_accum = 0.0
		queue_redraw()

func _draw() -> void:
	if not Manager.simulation_running:
		return
	if not Manager.has_method("get_top_density_cells"):
		return
	var cells: Array = Manager.get_top_density_cells(max_markers, density_threshold)
	var cs: float = Manager.cell_size
	var font: Font = ThemeDB.fallback_font
	var wobble := 0.5 + 0.5 * sin(_pulse * 4.0 )
	for i in range(cells.size()):
		var entry = cells[i]              # { "cell": Vector2i, "value": float }
		var cell: Vector2i = entry["cell"]
		var val: float = entry["value"]
		var center := Vector2((cell.x + 0.5 ) * cs, (cell.y + 0.5 ) * cs)
		# Radius scales with severity; opacity pulses to draw the eye.
		var sev: float = clampf(val / 10.0, 0.25, 1.5 )
		var r: float = cs * (0.7 + sev)
		var col := Color(1.0, 0.25, 0.2, 0.20 + 0.25 * wobble)
		draw_circle(center, r, col)
		draw_arc(center, r, 0, TAU, 32, Color(1.0, 0.35, 0.3, 0.9 ), 2.0, true)
		if i == 0:
			# Label the single worst bottleneck.
			draw_string(font, center + Vector2(r + 4, -4 ), "CRITICAL  (%.0f)" % val,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1.0, 0.5, 0.4 ))
