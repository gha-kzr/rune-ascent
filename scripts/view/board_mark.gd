class_name BoardMark
extends Node3D
## A mark a teammate put on the board: a pulsing ring on the cell and a speech bubble with their message above it (above
## the head of the unit standing there, if any). It removes itself with its bubble.

const RING_RADIUS := 0.42
const PULSE := 1.18
const PULSE_SECONDS := 0.45

var _color := Color.WHITE
var _text := ""
var _bubble_height := 1.2


## `bubble_height`: where the bubble's tail points, above the cell (world units).
func _init(message := "", ring_color := Color.WHITE, bubble_height := 1.2) -> void:
	name = "BoardMark"
	_text = message
	_color = ring_color
	_bubble_height = bubble_height


func _ready() -> void:
	var ring := MeshInstance3D.new()
	ring.name = "Ring"
	var torus := TorusMesh.new()
	torus.inner_radius = RING_RADIUS - 0.06
	torus.outer_radius = RING_RADIUS
	torus.rings = 24
	torus.ring_segments = 6
	ring.mesh = torus
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = _color
	material.no_depth_test = true  # Seen through a unit standing on the cell.
	material.render_priority = 1
	ring.material_override = material
	ring.position.y = 0.05
	add_child(ring)
	var pulse := create_tween().set_loops()
	pulse.tween_property(ring, "scale", Vector3.ONE * PULSE, PULSE_SECONDS).set_trans(Tween.TRANS_SINE)
	pulse.tween_property(ring, "scale", Vector3.ONE, PULSE_SECONDS).set_trans(Tween.TRANS_SINE)
	var bubble := SpeechBubble.new(_text)
	bubble.position.y = _bubble_height
	add_child(bubble)
	create_tween().tween_callback(queue_free).set_delay(SpeechBubble.SECONDS)  # As the bubble fades out.


func text() -> String:
	return _text
