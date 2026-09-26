"""Prints the size (width x height x depth, Y-up metres) of each USDZ: Blender --background --python measure.py -- files..."""
import sys

import bpy
from mathutils import Vector

for path in sys.argv[sys.argv.index("--") + 1:]:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.wm.usd_import(filepath=path)
    points = [obj.matrix_world @ Vector(corner) for obj in bpy.context.scene.objects if obj.type == "MESH" for corner in obj.bound_box]
    lo = Vector((min(p.x for p in points), min(p.y for p in points), min(p.z for p in points)))
    hi = Vector((max(p.x for p in points), max(p.y for p in points), max(p.z for p in points)))
    size = hi - lo
    print(f"SIZE {path.split('/')[-1]:<34} w {size.x:5.2f}  h {size.z:5.2f}  d {size.y:5.2f}  (floor at {lo.z:5.2f})")
