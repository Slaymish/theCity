"""Builds ground cover (grass tufts, flower clumps, pebbles) textured from the KayKit Medieval Hexagon atlas, exported as USDZ.

Run: Blender --background --python Assets/Pipeline/foliage.py -- <rock_single_A.gltf> <out_dir>
"""
import math
import os
import random
import sys

import bmesh
import bpy

source, out_dir = sys.argv[sys.argv.index("--") + 1:][:2]
os.makedirs(out_dir, exist_ok=True)

# The atlas is an 8 x 4 grid of vertical gradients; v runs from a swatch's dark foot to its light head.
GRASS = (0.5625, 0.52, 0.74)
LEAF = (0.1875, 0.27, 0.48)
YELLOW = (0.3125, 0.2, 0.24)
PINK = (0.9375, 0.35, 0.47)
WHITE = (0.6875, 0.47, 0.49)
STONE = (0.3125, 0.8, 0.95)


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=source)
    rock = next(o for o in bpy.data.objects if o.type == "MESH")
    material = rock.data.materials[0]
    bpy.data.objects.remove(rock)
    return material


def blade(mesh, uv, x, y, height, lean, turn, width, swatch):
    """A three-sided spike, so it reads from every side without double-sided materials."""
    u, foot, head = swatch
    base = []
    for k in range(3):
        angle = turn + k * 2 * math.pi / 3
        base.append(mesh.verts.new((x + math.cos(angle) * width, y + math.sin(angle) * width, 0)))
    tip = mesh.verts.new((x + math.cos(turn) * lean, y + math.sin(turn) * lean, height))
    for k in range(3):
        face = mesh.faces.new((base[k], base[(k + 1) % 3], tip))
        for loop in face.loops:
            loop[uv].uv = (u, head if loop.vert is tip else foot)


def blob(mesh, uv, centre, radius, squash, swatch, seed):
    rng = random.Random(seed)
    made = bmesh.ops.create_icosphere(mesh, subdivisions=1, radius=radius)
    u, low, high = swatch
    for vert in made["verts"]:
        vert.co.x = vert.co.x * rng.uniform(0.85, 1.15) + centre[0]
        vert.co.y = vert.co.y * rng.uniform(0.85, 1.15) + centre[1]
        vert.co.z = vert.co.z * squash + centre[2]
    faces = {f for v in made["verts"] for f in v.link_faces}
    for face in faces:
        for loop in face.loops:
            t = (loop.vert.co.z - centre[2]) / max(radius * squash * 2, 1e-4) + 0.5
            loop[uv].uv = (u, low + (high - low) * min(max(t, 0), 1))


def tuft(mesh, uv, rng, blades, spread, height):
    for _ in range(blades):
        r, a = rng.uniform(0, spread), rng.uniform(0, 2 * math.pi)
        blade(mesh, uv, math.cos(a) * r, math.sin(a) * r, height * rng.uniform(0.65, 1.1), height * rng.uniform(0.1, 0.35),
              rng.uniform(0, 2 * math.pi), height * 0.07, GRASS)


def export(name, build, material):
    mesh = bmesh.new()
    uv = mesh.loops.layers.uv.new("UVMap")
    build(mesh, uv, random.Random(name))
    data = bpy.data.meshes.new(name)
    mesh.to_mesh(data)
    mesh.free()
    data.materials.append(material)
    obj = bpy.data.objects.new(name, data)
    bpy.context.scene.collection.objects.link(obj)
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    target = os.path.join(out_dir, name + ".usdz")
    bpy.ops.wm.usd_export(filepath=target, selected_objects_only=True, export_materials=True, generate_preview_surface=True,
                          export_textures_mode="NEW", export_lights=False, export_cameras=False,
                          convert_orientation=True, export_global_forward_selection="NEGATIVE_Z", export_global_up_selection="Y")
    print(f"built {name} -> {target} ({os.path.getsize(target) // 1024} KB)")


def grass(mesh, uv, rng):
    tuft(mesh, uv, rng, 9, 0.05, 0.13)


def flowers(heads):
    def build(mesh, uv, rng):
        tuft(mesh, uv, rng, 6, 0.05, 0.1)
        for index, swatch in enumerate(heads):
            a = index * 2.3 + rng.uniform(0, 0.6)
            x, y, h = math.cos(a) * 0.04, math.sin(a) * 0.04, rng.uniform(0.13, 0.17)
            blade(mesh, uv, x, y, h, 0.01, a, 0.006, LEAF)
            blob(mesh, uv, (x + math.cos(a) * 0.01, y + math.sin(a) * 0.01, h), 0.022, 0.6, swatch, index)
    return build


def pebbles(mesh, uv, rng):
    for index in range(4):
        a, r = rng.uniform(0, 2 * math.pi), rng.uniform(0, 0.07)
        size = rng.uniform(0.018, 0.035)
        blob(mesh, uv, (math.cos(a) * r, math.sin(a) * r, size * 0.3), size, 0.55, STONE, index)


for name, build in [("grass_tuft", grass), ("flowers_A", flowers([YELLOW, WHITE, YELLOW])),
                    ("flowers_B", flowers([PINK, WHITE, PINK])), ("pebbles", pebbles)]:
    export(name, build, reset())
