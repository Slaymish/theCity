"""Converts KayKit glTF models to USDZ for RealityKit.

Run: Blender --background --python Assets/Pipeline/convert.py -- <out_dir> <model.gltf>...
"""
import os
import sys

import bpy

args = sys.argv[sys.argv.index("--") + 1:]
out_dir, sources = args[0], args[1:]
os.makedirs(out_dir, exist_ok=True)

for source in sources:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=source)
    name = os.path.splitext(os.path.basename(source))[0]
    target = os.path.join(out_dir, name + ".usdz")
    bpy.ops.wm.usd_export(filepath=target, export_materials=True, generate_preview_surface=True,
                          export_textures_mode="NEW", export_lights=False, export_cameras=False,
                          convert_orientation=True, export_global_forward_selection="NEGATIVE_Z", export_global_up_selection="Y")
    print(f"converted {name} -> {target} ({os.path.getsize(target) // 1024} KB)")
