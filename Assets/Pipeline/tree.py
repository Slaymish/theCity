"""Builds a street tree from the KayKit bush: its canopy on a trunk textured from the same atlas, exported as USDZ.

Run: Blender --background --python Assets/Pipeline/tree.py -- <bush.gltf> <out_dir>
"""
import os
import sys

import bmesh
import bpy

source, out_dir = sys.argv[sys.argv.index("--") + 1:][:2]
os.makedirs(out_dir, exist_ok=True)
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=source)
bush = next(o for o in bpy.data.objects if o.type == "MESH")
bush.name = "Canopy"

mesh = bmesh.new()
mesh.from_mesh(bush.data)
uv = mesh.loops.layers.uv.active
pot = [face for face in mesh.faces if face.loops[0][uv].uv.x > 0.5]
bmesh.ops.delete(mesh, geom=pot, context="FACES")
base = min(v.co.z for v in mesh.verts)
trunk_height = 0.16
for vertex in mesh.verts:
    vertex.co.z = (vertex.co.z - base) * 1.25 + trunk_height
mesh.to_mesh(bush.data)
mesh.free()

bpy.ops.mesh.primitive_cylinder_add(radius=0.022, depth=trunk_height + 0.04, location=(0, 0, (trunk_height + 0.04) / 2), vertices=12)
trunk = bpy.context.active_object
trunk.name = "Trunk"
trunk.data.materials.append(bush.data.materials[0])
for loop in trunk.data.uv_layers.active.data:
    loop.uv = (0.81, 0.85)

root = bpy.data.objects.new("Tree", None)
bpy.context.scene.collection.objects.link(root)
for part in (bush, trunk):
    part.parent = root
bpy.ops.object.select_all(action="DESELECT")
for obj in (root, bush, trunk):
    obj.select_set(True)
target = os.path.join(out_dir, "tree.usdz")
bpy.ops.wm.usd_export(filepath=target, selected_objects_only=True, export_materials=True, generate_preview_surface=True,
                      export_textures_mode="NEW", export_lights=False, export_cameras=False,
                      convert_orientation=True, export_global_forward_selection="NEGATIVE_Z", export_global_up_selection="Y")
print(f"built tree -> {target} ({os.path.getsize(target) // 1024} KB)")
