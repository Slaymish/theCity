"""Models the office robot, monitor and keyboard, and exports each as USDZ.

Run: Blender --background --python Assets/Pipeline/robot.py -- <out_dir>
Parts are named so the app can find and animate them: Robot/Body/Head/{FaceScreen,AntennaTip*,Knob*,*Anchor},
Robot/Body/{ArmL,ArmR}/{ElbowL,ElbowR}, Robot/{LegL,LegR}. Knob*/AntennaTip*/Accent* parts carry the department colour at runtime.
"""
import math
import os
import sys

import bpy

out_dir = sys.argv[sys.argv.index("--") + 1]
os.makedirs(out_dir, exist_ok=True)


def material(name, colour, roughness=0.45, metallic=0.0, emission=None, strength=0.0):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*colour, 1)
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    if emission:
        bsdf.inputs["Emission Color"].default_value = (*emission, 1)
        bsdf.inputs["Emission Strength"].default_value = strength
    return mat


def srgb(hex_value):
    def channel(c):
        c = c / 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    return tuple(channel((hex_value >> shift) & 0xFF) for shift in (16, 8, 0))


def finish(obj, mat, bevel=0.0, segments=5, subdivide=0):
    if bevel:
        mod = obj.modifiers.new("Bevel", "BEVEL")
        mod.width = bevel
        mod.segments = segments
        mod.limit_method = "NONE"
    if subdivide:
        mod = obj.modifiers.new("Subdivision", "SUBSURF")
        mod.levels = subdivide
        mod.render_levels = subdivide
    obj.data.materials.append(mat)
    bpy.context.view_layer.objects.active = obj
    for mod in list(obj.modifiers):
        bpy.ops.object.modifier_apply(modifier=mod.name)
    bpy.ops.object.shade_smooth()
    return obj


def box(name, size, location, mat, bevel=0.0, parent=None, segments=5):
    bpy.ops.mesh.primitive_cube_add(size=1, location=location)
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = size
    bpy.ops.object.transform_apply(scale=True)
    finish(obj, mat, bevel=bevel, segments=segments)
    if parent:
        obj.parent = parent
        obj.matrix_parent_inverse = parent.matrix_world.inverted()
    return obj


def sphere(name, radius, location, mat, parent=None, scale=(1, 1, 1)):
    bpy.ops.mesh.primitive_uv_sphere_add(radius=radius, location=location, segments=48, ring_count=24)
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = scale
    bpy.ops.object.transform_apply(scale=True)
    finish(obj, mat)
    if parent:
        obj.parent = parent
        obj.matrix_parent_inverse = parent.matrix_world.inverted()
    return obj


def cylinder(name, radius, depth, location, mat, rotation=(0, 0, 0), parent=None, bevel=0.0):
    bpy.ops.mesh.primitive_cylinder_add(radius=radius, depth=depth, location=location, rotation=rotation, vertices=48)
    obj = bpy.context.active_object
    obj.name = name
    bpy.ops.object.transform_apply(rotation=True)
    finish(obj, mat, bevel=bevel, segments=4)
    if parent:
        obj.parent = parent
        obj.matrix_parent_inverse = parent.matrix_world.inverted()
    return obj


def empty(name, location, parent=None):
    bpy.ops.object.empty_add(location=location)
    obj = bpy.context.active_object
    obj.name = name
    if parent:
        obj.parent = parent
        obj.matrix_parent_inverse = parent.matrix_world.inverted()
    return obj


def export(name, root):
    bpy.ops.object.select_all(action="DESELECT")
    for obj in [root, *root.children_recursive]:
        obj.select_set(True)
    target = os.path.join(out_dir, name + ".usdz")
    bpy.ops.wm.usd_export(filepath=target, selected_objects_only=True, export_materials=True,
                          generate_preview_surface=True, export_lights=False, export_cameras=False,
                          convert_orientation=True, export_global_forward_selection="NEGATIVE_Z",
                          export_global_up_selection="Y")
    print(f"modelled {name} -> {target} ({os.path.getsize(target) // 1024} KB)")


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)


# Robot: Blender is Z-up; the exporter converts to RealityKit's Y-up. Front faces -Y here, which becomes +Z.
# A retro TV for a head: the app draws expressions onto FaceScreen. Accessories attach at the *Anchor empties.
reset()
shell = material("Shell", srgb(0xF5F2F8), roughness=0.3)
trim = material("Trim", srgb(0xD9DCE8), roughness=0.4)
glass = material("FaceGlass", srgb(0x2D3A36), roughness=0.08)
accent = material("Accent", srgb(0x7DBB5E), roughness=0.35)
dark_trim = material("DarkTrim", srgb(0x3B2F2A), roughness=0.5)

robot = empty("Robot", (0, 0, 0))
body = box("Body", (0.46, 0.38, 0.40), (0, 0, 0.52), shell, bevel=0.14, parent=robot, segments=8)
box("Belly", (0.24, 0.02, 0.16), (0, -0.19, 0.52), trim, bevel=0.008, parent=body)
head = empty("Head", (0, 0, 0.76), parent=body)
box("Casing", (0.80, 0.56, 0.62), (0, 0, 1.06), shell, bevel=0.13, parent=head, segments=8)
box("Bezel", (0.66, 0.03, 0.48), (0, -0.28, 1.06), dark_trim, bevel=0.06, parent=head, segments=6)
box("FaceScreen", (0.58, 0.02, 0.40), (0, -0.296, 1.06), glass, bevel=0.05, parent=head, segments=6)
cylinder("KnobL", 0.045, 0.05, (0.43, -0.12, 1.16), accent, rotation=(0, math.pi / 2, 0), parent=head, bevel=0.012)
cylinder("KnobR", 0.045, 0.05, (0.43, -0.12, 0.98), accent, rotation=(0, math.pi / 2, 0), parent=head, bevel=0.012)
for side, x, lean in (("L", -0.14, -0.35), ("R", 0.14, 0.35)):
    stem = cylinder(f"Ear{side}", 0.014, 0.34, (x + lean * 0.16, 0, 1.52), trim, rotation=(0, lean, 0), parent=head)
    sphere(f"AntennaTip{side}", 0.045, (x + lean * 0.33, 0, 1.68), accent, parent=head)
empty("HatAnchor", (0, 0, 1.37), parent=head)
empty("FaceAnchor", (0, -0.31, 1.06), parent=head)
for side, x in (("L", -0.27), ("R", 0.27)):
    arm = empty(f"Arm{side}", (x, 0, 0.66), parent=body)
    box(f"Upper{side}", (0.10, 0.10, 0.15), (x * 1.08, 0, 0.585), shell, bevel=0.045, parent=arm, segments=6)
    elbow = empty(f"Elbow{side}", (x * 1.08, 0, 0.52), parent=arm)
    box(f"Forearm{side}", (0.10, 0.10, 0.14), (x * 1.08, 0, 0.46), shell, bevel=0.045, parent=elbow, segments=6)
    sphere(f"Hand{side}", 0.065, (x * 1.08, -0.01, 0.39), trim, parent=elbow)
    empty(f"HandAnchor{side}", (x * 1.08, -0.02, 0.36), parent=elbow)
empty("ChestAnchor", (0, -0.21, 0.66), parent=body)
for side, x in (("L", -0.11), ("R", 0.11)):
    leg = empty(f"Leg{side}", (x, 0, 0.32), parent=robot)
    box(f"Shin{side}", (0.13, 0.14, 0.24), (x, 0, 0.18), shell, bevel=0.05, parent=leg, segments=6)
    box(f"Foot{side}", (0.15, 0.22, 0.07), (x, -0.03, 0.04), trim, bevel=0.03, parent=leg, segments=4)
export("robot", robot)

# Accessories. Parts named Accent* take the department colour at runtime.
def accessory(name, build):
    reset()
    root = empty(name, (0, 0, 0))
    build(root)
    export(name, root)

def hard_hat(root):
    bpy.ops.mesh.primitive_uv_sphere_add(radius=0.3, location=(0, 0, 0), segments=48, ring_count=24)
    dome = bpy.context.active_object
    dome.name = "AccentDome"
    for vertex in dome.data.vertices:
        vertex.co.z = max(vertex.co.z, 0.0)
    finish(dome, material("Hat", srgb(0xF2C14E), roughness=0.35))
    dome.parent = root
    cylinder("Brim", 0.38, 0.025, (0, -0.04, 0.0), material("HatBrim", srgb(0xF2C14E), roughness=0.35), parent=root, bevel=0.01)
    box("AccentBand", (0.05, 0.62, 0.05), (0, 0, 0.26), material("Band", srgb(0x7DBB5E)), bevel=0.02, parent=root)

def glasses(root):
    frame = material("Frames", srgb(0x3B2F2A), roughness=0.4)
    for x in (-0.14, 0.14):
        bpy.ops.mesh.primitive_torus_add(major_radius=0.1, minor_radius=0.014, location=(x, 0, 0), rotation=(math.pi / 2, 0, 0))
        ring = bpy.context.active_object
        ring.name = f"Rim{'L' if x < 0 else 'R'}"
        finish(ring, frame)
        ring.parent = root
    box("Bridge", (0.08, 0.02, 0.02), (0, 0, 0.02), frame, bevel=0.008, parent=root)

def magnifier(root):
    cylinder("Handle", 0.025, 0.22, (0, 0, -0.1), material("Handle", srgb(0x3B2F2A), roughness=0.5), parent=root, bevel=0.01)
    bpy.ops.mesh.primitive_torus_add(major_radius=0.12, minor_radius=0.02, location=(0, 0, 0.13), rotation=(math.pi / 2, 0, 0))
    ring = bpy.context.active_object
    ring.name = "AccentRing"
    finish(ring, material("Ring", srgb(0x7DBB5E), roughness=0.3))
    ring.parent = root
    cylinder("Lens", 0.105, 0.01, (0, 0, 0.13), material("Lens", srgb(0xDCEEFB), roughness=0.02), rotation=(math.pi / 2, 0, 0), parent=root)

def beret(root):
    sphere("AccentBeret", 0.3, (0.04, 0, 0.04), material("Beret", srgb(0x7DBB5E), roughness=0.7), parent=root, scale=(1.05, 1.0, 0.32))
    cylinder("Stalk", 0.02, 0.06, (0.04, 0, 0.14), material("Stalk", srgb(0x3B2F2A)), parent=root)

def cap(root):
    bpy.ops.mesh.primitive_uv_sphere_add(radius=0.29, location=(0, 0, 0), segments=48, ring_count=24)
    dome = bpy.context.active_object
    dome.name = "AccentCap"
    for vertex in dome.data.vertices:
        vertex.co.z = max(vertex.co.z * 0.8, 0.0)
    finish(dome, material("Cap", srgb(0x7DBB5E), roughness=0.6))
    dome.parent = root
    box("Visor", (0.34, 0.26, 0.025), (0, -0.3, 0.0), material("Visor", srgb(0x3B2F2A), roughness=0.5), bevel=0.02, parent=root)

def tie(root):
    box("Knot", (0.07, 0.03, 0.06), (0, 0, 0), material("TieKnot", srgb(0x7DBB5E)), bevel=0.015, parent=root)
    box("AccentTie", (0.1, 0.025, 0.24), (0, 0, -0.15), material("Tie", srgb(0x7DBB5E)), bevel=0.02, parent=root)

accessory("hardhat", hard_hat)
accessory("glasses", glasses)
accessory("magnifier", magnifier)
accessory("beret", beret)
accessory("cap", cap)
accessory("tie", tie)

# Monitor with a stand; the Screen part is re-coloured at runtime to show activity.
reset()
frame_mat = material("Frame", srgb(0x2A2C38), roughness=0.35)
screen_mat = material("Screen", srgb(0x2E303D), roughness=0.15)
stand_mat = material("Stand", srgb(0xB9BDCB), roughness=0.3, metallic=0.6)
monitor = empty("Monitor", (0, 0, 0))
box("Bezel", (0.70, 0.05, 0.44), (0, 0, 0.44), frame_mat, bevel=0.03, parent=monitor, segments=5)
box("Screen", (0.64, 0.01, 0.38), (0, -0.028, 0.44), screen_mat, bevel=0.01, parent=monitor, segments=3)
box("Neck", (0.06, 0.05, 0.22), (0, 0.03, 0.14), stand_mat, bevel=0.02, parent=monitor)
box("Base", (0.28, 0.20, 0.025), (0, 0.02, 0.012), stand_mat, bevel=0.012, parent=monitor)
export("monitor", monitor)

# Keyboard and mug.
reset()
key_mat = material("Keys", srgb(0xF5F2F8), roughness=0.4)
deck_mat = material("Deck", srgb(0xD9DCE8), roughness=0.35)
keyboard = empty("Keyboard", (0, 0, 0))
box("Deck", (0.46, 0.16, 0.025), (0, 0, 0.0125), deck_mat, bevel=0.01, parent=keyboard)
for row in range(3):
    for col in range(10):
        box(f"Key{row}{col}", (0.034, 0.034, 0.012), (-0.18 + col * 0.04, -0.045 + row * 0.042, 0.03), key_mat, bevel=0.004,
            parent=keyboard, segments=2)
export("keyboard", keyboard)

reset()
mug_mat = material("Mug", srgb(0xFAC740), roughness=0.3)
mug = empty("Mug", (0, 0, 0))
cylinder("Cup", 0.045, 0.10, (0, 0, 0.05), mug_mat, parent=mug, bevel=0.01)
bpy.ops.mesh.primitive_torus_add(major_radius=0.03, minor_radius=0.009, location=(0.055, 0, 0.055), rotation=(math.pi / 2, 0, 0))
handle = bpy.context.active_object
handle.name = "Handle"
finish(handle, mug_mat)
handle.parent = mug
export("mug", mug)
