extends Control
class_name LiveGraph
## LiveGraph.gd - A lightweight, self-contained real-time line chart.
##
## Godot ships no built-in plotting widget, so this Control draws its own axes,
## gridlines, auto-scaled series, a legend, and live value read-outs via _draw().
## It is the NetLogo-style "plot" equivalent: push data as the simulation runs
## and call queue_redraw() to refresh.
##
## Usage:
##   var g := LiveGraph.new()
##   g.title = "Escaped over time"
##   var s := g.add_series("Escaped", Color.LIME_GREEN)
##   g.push(s, elapsed_time, escaped_count)   # then g.queue_redraw()
##
## Multiple series are supported (e.g. one line per floor).

var title: String = ""
var y_unit: String = ""
var max_points: int = 900          # rolling cap per series (memory guard)
var fixed_y_max = null             # set a float to lock the y-axis top; null = auto
var x_window: float = 0.0          # 0 = show whole run; >0 = show only last N seconds

# Each series: { "name": String, "color": Color, "pts": Array[Vector2] }
var _series: Array = []

const PAD_L := 46.0
const PAD_R := 12.0
const PAD_T := 26.0
const PAD_B := 22.0

func _ready() -> void:
	custom_minimum_size = Vector2(300, 150 )

func add_series(series_name: String, color: Color) -> int:
	_series.append({ "name": series_name, "color": color, "pts": [] })
	return _series.size() - 1

func push(series_idx: int, x: float, y: float) -> void:
	if series_idx < 0 or series_idx >= _series.size():
		return
	var pts: Array = _series[series_idx]["pts"]
	pts.append(Vector2(x, y))
	if pts.size() > max_points:
		pts.pop_front()

func reset() -> void:
	for s in _series:
		s["pts"].clear()
	queue_redraw()

func _draw() -> void:
	var font: Font = ThemeDB.fallback_font
	var fs := 11

	# Panel background + border.
	var full := Rect2(Vector2.ZERO, size)
	draw_rect(full, Color(0.10, 0.11, 0.14, 0.92 ), true)
	draw_rect(full, Color(1, 1, 1, 0.10 ), false, 1.0 )

	# Title.
	if title != "":
		draw_string(font, Vector2(PAD_L, 16 ), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.92, 0.92, 0.95 ))

	var plot := Rect2(PAD_L, PAD_T, size.x - PAD_L - PAD_R, size.y - PAD_T - PAD_B)
	if plot.size.x <= 4 or plot.size.y <= 4:
		return

	# Determine data ranges.
	var x_min := INF
	var x_max := -INF
	var y_max := 0.0
	for s in _series:
		for p in s["pts"]:
			var pv: Vector2 = p
			x_min = min(x_min, pv.x)
			x_max = max(x_max, pv.x)
			y_max = max(y_max, pv.y)
	if x_min == INF:
		# No data yet - draw empty frame only.
		_draw_frame(font, plot, 0.0, 1.0, 0.0, 1.0 )
		return

	if x_window > 0.0:
		x_min = max(x_min, x_max - x_window)
	if x_max - x_min < 0.001:
		x_max = x_min + 1.0
	if fixed_y_max != null:
		y_max = float(fixed_y_max)
	y_max = max(y_max, 1.0 ) * 1.12   # headroom

	_draw_frame(font, plot, x_min, x_max, 0.0, y_max)

	# Series polylines.
	for s in _series:
		var pts: Array = s["pts"]
		if pts.size() < 1:
			continue
		var screen: PackedVector2Array = []
		for p in pts:
			var pv: Vector2 = p
			if pv.x < x_min:
				continue
			var sx := plot.position.x + (pv.x - x_min) / (x_max - x_min) * plot.size.x
			var sy := plot.position.y + plot.size.y - (pv.y / y_max) * plot.size.y
			screen.append(Vector2(sx, sy))
		if screen.size() >= 2:
			draw_polyline(screen, s["color"], 2.0, true)
		elif screen.size() == 1:
			draw_circle(screen[0], 2.5, s["color"])

	# Legend + latest values (top-right of plot).
	var ly := PAD_T + 4.0
	for s in _series:
		var pts: Array = s["pts"]
		var latest := 0.0
		if pts.size() > 0:
			var lp: Vector2 = pts[pts.size() - 1]
			latest = lp.y
		var label := "%s: %s" % [s["name"], _fmt(latest)]
		var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var lx := plot.position.x + plot.size.x - tw - 14.0
		draw_rect(Rect2(lx - 12, ly + 1, 8, 8 ), s["color"], true)
		draw_string(font, Vector2(lx, ly + 9 ), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.85, 0.87, 0.9 ))
		ly += 14.0

func _draw_frame(font: Font, plot: Rect2, x0: float, x1: float, _y0: float, y1: float) -> void:
	var grid := Color(1, 1, 1, 0.08 )
	var axis := Color(1, 1, 1, 0.28 )
	var txt := Color(0.7, 0.72, 0.76 )
	# Horizontal gridlines + y labels.
	var steps := 4
	for i in range(steps + 1 ):
		var frac := float(i) / float(steps)
		var gy := plot.position.y + plot.size.y - frac * plot.size.y
		draw_line(Vector2(plot.position.x, gy), Vector2(plot.position.x + plot.size.x, gy), grid, 1.0 )
		var val := frac * y1
		draw_string(font, Vector2(4, gy + 3 ), _fmt(val), HORIZONTAL_ALIGNMENT_LEFT, PAD_L - 6, 10, txt)
	# Axes.
	draw_line(plot.position + Vector2(0, plot.size.y), plot.position + plot.size, axis, 1.5 )
	draw_line(plot.position, plot.position + Vector2(0, plot.size.y), axis, 1.5 )
	# X range labels.
	draw_string(font, Vector2(plot.position.x, size.y - 6 ), "%.0fs" % x0, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, txt)
	draw_string(font, Vector2(plot.position.x + plot.size.x - 34, size.y - 6 ), "%.0fs" % x1, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, txt)

func _fmt(v: float) -> String:
	if absf(v) >= 100.0:
		return "%.0f" % v
	elif absf(v) >= 10.0:
		return "%.1f" % v
	return "%.2f" % v
