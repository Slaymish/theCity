"""Builds woodland trees from the Kenney Nature Kit, repainted from the KayKit Medieval Hexagon atlas so they sit with the other models, exported as USDZ.

Run: Blender --background --python Assets/Pipeline/nature.py -- <rock_single_A.gltf> <out_dir> <tree.glb>...
"""
import os
import sys

import bpy

args = sys.argv[sys.argv.index("--") + 1:]
atlas_source, out_dir, sources = args[0], args[1], args[2:]
os.makedirs(out_dir, exist_ok=True)

# Atlas swatches as (u, dark foot v, light head v), matching foliage.py.
BROADLEAF = (0.5625, 0.53, 0.73)
CONIFER = (0.1875, 0.28, 0.47)
BARK = (0.3125, 0.56, 0.68)

for source in sources:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=atlas_source)
    rock = next(o for o in bpy.data.objects if o.type == "MESH")
    atlas = rock.data.materials[0]
    bpy.data.objects.remove(rock)
    bpy.ops.import_scene.gltf(filepath=source)
    name = os.path.splitext(os.path.basename(source))[0]
    leaf = CONIFER if "pine" in name else BROADLEAF
    for obj in [o for o in bpy.data.objects if o.type == "MESH"]:
        mesh = obj.data
        leafy = {i for i, m in enumerate(mesh.materials) if m and m.name.startswith("leafs")}
        heights = [(obj.matrix_world @ v.co).z for p in mesh.polygons if p.material_index in leafy for v in (mesh.vertices[i] for i in p.vertices)]
        low, high = (min(heights), max(heights)) if heights else (0, 1)
        uv = mesh.uv_layers.new(name="Atlas")
        for polygon in mesh.polygons:
            u, foot, head = leaf if polygon.material_index in leafy else BARK
            for index in polygon.loop_indices:
                z = (obj.matrix_world @ mesh.vertices[mesh.loops[index].vertex_index].co).z
                t = min(max((z - low) / max(high - low, 1e-4), 0), 1) if polygon.material_index in leafy else 0.5
                uv.data[index].uv = (u, foot + (head - foot) * t)
        for layer in [layer for layer in mesh.uv_layers if layer.name != "Atlas"]:
            mesh.uv_layers.remove(layer)
        mesh.materials.clear()
        mesh.materials.append(atlas)
        for polygon in mesh.polygons:
            polygon.material_index = 0
    target = os.path.join(out_dir, name + ".usdz")
    bpy.ops.wm.usd_export(filepath=target, export_materials=True, generate_preview_surface=True,
                          export_textures_mode="NEW", export_lights=False, export_cameras=False,
                          convert_orientation=True, export_global_forward_selection="NEGATIVE_Z", export_global_up_selection="Y")
    print(f"built {name} -> {target} ({os.path.getsize(target) // 1024} KB)")
