extends RefCounted
class_name HeroBones

## The hero skeleton's bone names: the one place gameplay code learns them.
##
## The hero is rigged with Rigify in Blender (art/hero/hero_new.blend) and ships
## a 53-bone game skeleton baked from it (art/hero/scripts/build_gamerig.py).
## Its bones use Godot's `SkeletonProfileHumanoid` names, so any humanoid clip
## retargeted to that profile (Mixamo, Quaternius UAL, motion capture) plays on
## the hero without renaming.
##
## Facts about the rig that code relies on. They were MEASURED on the shipped
## skeleton (rig_regression.gd re-checks them), not assumed from Blender rolls,
## because Rigify re-rolls the finger chains it generates:
##   * every bone's local +Y runs along the bone, toward its child;
##   * there are no metacarpal bones for the four fingers: `<Finger>Proximal`
##     starts at the knuckle and is parented straight to the hand.
## Which way a finger curls and where the palm faces are NOT constants: rigs
## roll finger bones differently (the Quaternius rig mirrors the finger X axes
## between the hands), so RigIK derives both from the rest knuckles.

const ROOT := "Root"
const HIPS := "Hips"
const SPINE := "Spine"
const CHEST := "Chest"
const UPPER_CHEST := "UpperChest"
const NECK := "Neck"
const HEAD := "Head"

## Hips to neck, lowest first.
const SPINE_CHAIN := [SPINE, CHEST, UPPER_CHEST]
const FINGERS := ["Index", "Middle", "Ring", "Little"]
const PHALANGES := ["Proximal", "Intermediate", "Distal"]
const THUMB_SEGMENTS := ["ThumbMetacarpal", "ThumbProximal", "ThumbDistal"]

const _LOWER_PARTS := ["UpperLeg", "LowerLeg", "Foot", "Toes"]


## "L"/"Left" -> "Left", "R"/"Right" -> "Right".
static func side_name(side: String) -> String:
	return "Left" if side.begins_with("L") else "Right"


static func shoulder(side: String) -> String:
	return side_name(side) + "Shoulder"

static func upper_arm(side: String) -> String:
	return side_name(side) + "UpperArm"

static func lower_arm(side: String) -> String:
	return side_name(side) + "LowerArm"

static func hand(side: String) -> String:
	return side_name(side) + "Hand"

static func upper_leg(side: String) -> String:
	return side_name(side) + "UpperLeg"

static func lower_leg(side: String) -> String:
	return side_name(side) + "LowerLeg"

static func foot(side: String) -> String:
	return side_name(side) + "Foot"

static func toes(side: String) -> String:
	return side_name(side) + "Toes"


## `finger` is one of FINGERS; `segment` 0..2 is proximal..distal.
static func finger(side: String, finger_name: String, segment: int) -> String:
	return side_name(side) + finger_name + PHALANGES[segment]


## `segment` 0..2 is metacarpal..distal.
static func thumb(side: String, segment: int) -> String:
	return side_name(side) + THUMB_SEGMENTS[segment]


## Every finger and thumb bone of one hand, proximal first within each digit.
static func hand_digits(side: String) -> Array[String]:
	var out: Array[String] = []
	for finger_name in FINGERS:
		for segment in range(PHALANGES.size()):
			out.append(finger(side, finger_name, segment))
	for segment in range(THUMB_SEGMENTS.size()):
		out.append(thumb(side, segment))
	return out


## Spine, neck, head and both arms with their hands: what an upper-body layer owns.
static func upper_body() -> Array[String]:
	var out: Array[String] = []
	for bone in SPINE_CHAIN:
		out.append(bone)
	out.append(NECK)
	out.append(HEAD)
	for side in ["L", "R"]:
		out.append_array([shoulder(side), upper_arm(side), lower_arm(side), hand(side)])
		out.append_array(hand_digits(side))
	return out


## Root, hips and legs: what locomotion owns and an upper-body layer must not touch.
static func is_lower_body(bone: String) -> bool:
	if bone == ROOT or bone == HIPS:
		return true
	for part in _LOWER_PARTS:
		if bone == "Left" + part or bone == "Right" + part:
			return true
	return false


static func is_digit(bone: String) -> bool:
	if bone.contains("Thumb"):
		return true
	for finger_name in FINGERS:
		if bone.contains(finger_name):
			return true
	return false
