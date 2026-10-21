# Builds and renders one explainer shot in Blender.
#   Blender -b -P build_shot.py -- <phone|watch|tv|intro|outro> <name> <clip|-> <seconds> [--still]
import bpy, sys, os, math

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
kind, name = argv[0], argv[1]
clip = argv[2] if len(argv) > 2 and argv[2] != "-" else None
seconds = float(argv[3]) if len(argv) > 3 else 10.0
still = "--still" in argv

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "assets")
CFR = os.path.join(HERE, "..", "capture", "cfr")
RENDERS = os.path.join(HERE, "renders")
os.makedirs(RENDERS, exist_ok=True)
FPS = 30
FRAMES = int(round(seconds * FPS))

def srgb(r, g, b, a=1.0):
    def c(v):
        v /= 255.0
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    return (c(r), c(g), c(b), a)

NAVY, DEEP = srgb(5, 18, 63), srgb(2, 7, 28)
TIDE, FOAM, ORANGE = srgb(11, 107, 203), srgb(51, 196, 255), srgb(254, 160, 46)
TITANIUM = srgb(38, 40, 46)

# ---------------------------------------------------------------- scene
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = 'BLENDER_EEVEE'
scene.render.resolution_x, scene.render.resolution_y = 1920, 1080
scene.render.resolution_percentage = 100
scene.render.fps = FPS
scene.frame_start, scene.frame_end = 1, FRAMES
scene.view_settings.view_transform = 'Standard'
scene.view_settings.look = 'None'
for attr, val in (("taa_render_samples", 24), ("use_raytracing", True), ("use_shadows", True),
                  ("shadow_ray_count", 2), ("shadow_step_count", 4)):
    try: setattr(scene.eevee, attr, val)
    except Exception as e: print("eevee", attr, e)
if still:
    scene.render.image_settings.file_format = 'PNG'
    scene.render.filepath = os.path.join(RENDERS, f"{name}_still.png")
else:
    try: scene.render.image_settings.media_type = 'VIDEO'
    except Exception as e: print("media_type", e)
    scene.render.image_settings.file_format = 'FFMPEG'
    scene.render.ffmpeg.format = 'MPEG4'
    scene.render.ffmpeg.codec = 'H264'
    scene.render.ffmpeg.constant_rate_factor = 'PERC_LOSSLESS'
    scene.render.ffmpeg.ffmpeg_preset = 'GOOD'
    scene.render.ffmpeg.gopsize = 15
    scene.render.filepath = os.path.join(RENDERS, f"{name}_")

target = bpy.data.objects.new("target", None)
scene.collection.objects.link(target)

# ---------------------------------------------------------------- helpers
def key(ob, path, frame, value, index=-1):
    if index >= 0:
        v = list(getattr(ob, path)); v[index] = value; setattr(ob, path, v)
    else:
        setattr(ob, path, value)
    ob.keyframe_insert(path, frame=frame, index=index)

def fcurves(ob):
    ad = ob.animation_data
    if not ad or not ad.action: return []
    act = ad.action
    if hasattr(act, "fcurves"):
        try: return list(act.fcurves)
        except Exception: pass
    out = []
    for layer in act.layers:
        for strip in layer.strips:
            for cb in strip.channelbags: out.extend(cb.fcurves)
    return out

def smooth(ob):
    if True:
        for fc in fcurves(ob):
            for kp in fc.keyframe_points:
                kp.interpolation = 'BEZIER'; kp.easing = 'EASE_IN_OUT'; kp.handle_left_type = kp.handle_right_type = 'AUTO_CLAMPED'

def rounded_plane(name, w, h, radius, segments=14):
    bpy.ops.mesh.primitive_plane_add(size=1)
    ob = bpy.context.active_object
    ob.name = name
    ob.scale = (w, h, 1)
    bpy.ops.object.transform_apply(scale=True)
    bev = ob.modifiers.new("corners", 'BEVEL')
    bev.affect = 'VERTICES'; bev.width = radius; bev.segments = segments
    return ob

def solid(ob, thickness, edge=0.006):
    s = ob.modifiers.new("solid", 'SOLIDIFY'); s.thickness = thickness; s.offset = 0
    e = ob.modifiers.new("edge", 'BEVEL'); e.width = edge; e.segments = 4; e.limit_method = 'ANGLE'
    ob.modifiers.new("smooth", 'WEIGHTED_NORMAL')
    try: bpy.ops.object.shade_smooth()
    except Exception: pass

def principled(name, color, metallic=0.0, rough=0.5, spec=0.5):
    m = bpy.data.materials.new(name); m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = color
    b.inputs["Metallic"].default_value = metallic
    b.inputs["Roughness"].default_value = rough
    b.inputs["Specular IOR Level"].default_value = spec
    return m

def screen_material(name, path):
    m = bpy.data.materials.new(name); m.use_nodes = True
    nt = m.node_tree; b = nt.nodes["Principled BSDF"]
    img = bpy.data.images.load(path)
    img.colorspace_settings.name = 'sRGB'
    tex = nt.nodes.new("ShaderNodeTexImage"); tex.image = img
    if img.source == 'MOVIE':
        iu = tex.image_user
        iu.frame_duration = img.frame_duration; iu.frame_start = 1
        iu.use_cyclic = True; iu.use_auto_refresh = True
        print("movie frames", img.frame_duration)
    b.inputs["Base Color"].default_value = (0, 0, 0, 1)
    b.inputs["Roughness"].default_value = 0.22
    b.inputs["Specular IOR Level"].default_value = 0.35
    nt.links.new(tex.outputs["Color"], b.inputs["Emission Color"])
    b.inputs["Emission Strength"].default_value = 1.0
    return m

def image_plane(name, path, width):
    """An emissive, alpha-keyed plane showing a PNG; returns (object, fade value node)."""
    img = bpy.data.images.load(path)
    img.colorspace_settings.name = 'sRGB'
    aspect = img.size[1] / img.size[0]
    bpy.ops.mesh.primitive_plane_add(size=1); ob = bpy.context.active_object; ob.name = name
    ob.scale = (width, width * aspect, 1); bpy.ops.object.transform_apply(scale=True)
    m = bpy.data.materials.new(name); m.use_nodes = True; nt = m.node_tree
    b = nt.nodes["Principled BSDF"]
    tex = nt.nodes.new("ShaderNodeTexImage"); tex.image = img
    nt.links.new(tex.outputs["Color"], b.inputs["Emission Color"])
    b.inputs["Emission Strength"].default_value = 1.0
    b.inputs["Base Color"].default_value = (0, 0, 0, 1)
    b.inputs["Specular IOR Level"].default_value = 0.0
    b.inputs["Roughness"].default_value = 1.0
    fade = nt.nodes.new("ShaderNodeValue"); fade.name = "fade"; fade.outputs[0].default_value = 1.0
    mul = nt.nodes.new("ShaderNodeMath"); mul.operation = 'MULTIPLY'
    nt.links.new(tex.outputs["Alpha"], mul.inputs[0]); nt.links.new(fade.outputs[0], mul.inputs[1])
    nt.links.new(mul.outputs[0], b.inputs["Alpha"])
    for attr, val in (("surface_render_method", 'BLENDED'), ("blend_method", 'BLEND')):
        try: setattr(m, attr, val)
        except Exception: pass
    try: m.use_backface_culling = False
    except Exception: pass
    ob.data.materials.append(m)
    ob.rotation_euler = (math.radians(90), 0, 0)
    return ob, fade

def fade_in(fade, f0, f1):
    s = fade.outputs[0]
    s.default_value = 0.0; s.keyframe_insert("default_value", frame=f0)
    s.default_value = 1.0; s.keyframe_insert("default_value", frame=f1)

def camera(loc, rot_deg, lens=50):
    cam = bpy.data.cameras.new("cam"); cam.lens = lens
    ob = bpy.data.objects.new("cam", cam); scene.collection.objects.link(ob)
    ob.location = loc; ob.rotation_euler = [math.radians(a) for a in rot_deg]
    scene.camera = ob
    return ob

def light(name, kind, loc, energy, color=(1, 1, 1), size=2.0, track=True):
    l = bpy.data.lights.new(name, kind); l.energy = energy; l.color = color
    if kind == 'AREA': l.size = size
    ob = bpy.data.objects.new(name, l); scene.collection.objects.link(ob); ob.location = loc
    if track:
        tc = ob.constraints.new('TRACK_TO'); tc.target = target
        tc.track_axis = 'TRACK_NEGATIVE_Z'; tc.up_axis = 'UP_Y'
    return ob

def backdrop(glow_at=(0, 0), glow_radius=2.4):
    """A big emissive plane behind the device: navy gradient with a tide-blue glow."""
    bpy.ops.mesh.primitive_plane_add(size=1); ob = bpy.context.active_object; ob.name = "backdrop"
    ob.scale = (40, 24, 1); bpy.ops.object.transform_apply(scale=True)
    ob.rotation_euler = (math.radians(90), 0, 0); ob.location = (0, 6, 0)
    m = bpy.data.materials.new("backdrop"); m.use_nodes = True; nt = m.node_tree
    for n in list(nt.nodes): nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    em = nt.nodes.new("ShaderNodeEmission"); em.inputs["Strength"].default_value = 1.0
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(tc.outputs["Object"], sep.inputs[0])
    ramp_in = nt.nodes.new("ShaderNodeMapRange"); ramp_in.inputs["From Min"].default_value = -12; ramp_in.inputs["From Max"].default_value = 12
    nt.links.new(sep.outputs["Y"], ramp_in.inputs["Value"])
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = DEEP; ramp.color_ramp.elements[1].color = srgb(10, 32, 96)
    nt.links.new(ramp_in.outputs[0], ramp.inputs["Fac"])
    # radial glow
    map_ = nt.nodes.new("ShaderNodeMapping")
    map_.inputs["Location"].default_value = (-glow_at[0], -glow_at[1], 0)
    map_.inputs["Scale"].default_value = (1 / glow_radius, 1 / glow_radius, 1)
    nt.links.new(tc.outputs["Object"], map_.inputs["Vector"])
    grad = nt.nodes.new("ShaderNodeTexGradient"); grad.gradient_type = 'SPHERICAL'
    nt.links.new(map_.outputs[0], grad.inputs["Vector"])
    pw = nt.nodes.new("ShaderNodeMath"); pw.operation = 'POWER'; pw.inputs[1].default_value = 2.2
    nt.links.new(grad.outputs["Fac"], pw.inputs[0])
    glow_col = nt.nodes.new("ShaderNodeMixRGB"); glow_col.blend_type = 'MULTIPLY'; glow_col.inputs["Fac"].default_value = 1.0
    glow_col.inputs["Color1"].default_value = TIDE; glow_col.inputs["Color2"].default_value = (0.55, 0.55, 0.55, 1)
    mulf = nt.nodes.new("ShaderNodeMixRGB"); mulf.blend_type = 'MULTIPLY'; mulf.inputs["Fac"].default_value = 1.0
    nt.links.new(glow_col.outputs[0], mulf.inputs["Color1"])
    nt.links.new(pw.outputs[0], mulf.inputs["Color2"])
    add = nt.nodes.new("ShaderNodeMixRGB"); add.blend_type = 'ADD'; add.inputs["Fac"].default_value = 1.0
    nt.links.new(ramp.outputs["Color"], add.inputs["Color1"]); nt.links.new(mulf.outputs[0], add.inputs["Color2"])
    nt.links.new(add.outputs[0], em.inputs["Color"]); nt.links.new(em.outputs[0], out.inputs["Surface"])
    ob.data.materials.append(m)
    return ob

def world(sky=False):
    w = bpy.data.worlds.new("world"); scene.world = w; w.use_nodes = True
    nt = w.node_tree; bg = nt.nodes["Background"]
    if not sky:
        bg.inputs["Color"].default_value = NAVY; bg.inputs["Strength"].default_value = 0.6
        return
    tc = nt.nodes.new("ShaderNodeTexCoord"); sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(tc.outputs["Generated"], sep.inputs[0])
    mr = nt.nodes.new("ShaderNodeMapRange"); mr.inputs["From Min"].default_value = -0.25; mr.inputs["From Max"].default_value = 0.6
    nt.links.new(sep.outputs["Z"], mr.inputs["Value"])
    ramp = nt.nodes.new("ShaderNodeValToRGB"); cr = ramp.color_ramp
    cr.elements[0].position = 0.0; cr.elements[0].color = srgb(30, 60, 140)
    cr.elements[1].position = 1.0; cr.elements[1].color = DEEP
    e = cr.elements.new(0.33); e.color = srgb(120, 110, 120)   # dusk haze at the horizon
    e = cr.elements.new(0.40); e.color = srgb(18, 50, 130)
    nt.links.new(mr.outputs[0], ramp.inputs["Fac"]); nt.links.new(ramp.outputs["Color"], bg.inputs["Color"])
    bg.inputs["Strength"].default_value = 1.0

def ocean():
    bpy.ops.mesh.primitive_plane_add(size=1); ob = bpy.context.active_object; ob.name = "ocean"
    ob.location = (0, 10, 0)
    m = ob.modifiers.new("ocean", 'OCEAN')
    m.geometry_mode = 'GENERATE'; m.resolution = 16; m.viewport_resolution = 8
    m.spatial_size = 60; m.size = 1.0; m.repeat_x = 1; m.repeat_y = 1
    m.wave_scale = 0.45; m.wave_scale_min = 0.05; m.choppiness = 1.6; m.wind_velocity = 14.0
    m.wave_alignment = 0.6; m.depth = 200; m.damping = 0.5
    m.time = 0.0; m.keyframe_insert("time", frame=1)
    m.time = seconds * 0.9; m.keyframe_insert("time", frame=FRAMES)
    for fc in fcurves(ob):
        for kp in fc.keyframe_points: kp.interpolation = 'LINEAR'
    mat = bpy.data.materials.new("water"); mat.use_nodes = True; nt = mat.node_tree
    b = nt.nodes["Principled BSDF"]
    lw = nt.nodes.new("ShaderNodeLayerWeight"); lw.inputs["Blend"].default_value = 0.35
    mix = nt.nodes.new("ShaderNodeMixRGB"); mix.inputs["Color1"].default_value = srgb(3, 28, 86); mix.inputs["Color2"].default_value = srgb(20, 110, 200)
    nt.links.new(lw.outputs["Fresnel"], mix.inputs["Fac"]); nt.links.new(mix.outputs[0], b.inputs["Base Color"])
    b.inputs["Roughness"].default_value = 0.06; b.inputs["Specular IOR Level"].default_value = 0.8
    b.inputs["Coat Weight"].default_value = 0.2
    ob.data.materials.append(mat)
    try: bpy.ops.object.shade_smooth()
    except Exception: pass
    return ob

# ---------------------------------------------------------------- devices
def build_phone(path):
    body = rounded_plane("phone", 0.72, 1.50, 0.105); solid(body, 0.078, 0.010)
    body.data.materials.append(principled("titanium", TITANIUM, 0.9, 0.32))
    screen = rounded_plane("screen", 0.69, 1.47, 0.09)
    screen.data.materials.append(screen_material("screen", path))
    screen.location = (0, 0, 0.0405)      # the plane faces +Z; solidify grows both ways by 0.039
    screen.parent = body
    body.rotation_euler = (math.radians(90), 0, 0)   # face -Y, toward the camera
    return body

def build_tv(path):
    body = rounded_plane("tv", 1.80, 1.02, 0.02); solid(body, 0.035, 0.004)
    body.data.materials.append(principled("bezel", srgb(14, 14, 16), 0.3, 0.45))
    screen = rounded_plane("screen", 1.76, 0.99, 0.006)
    screen.data.materials.append(screen_material("screen", path))
    screen.location = (0, 0, 0.019); screen.parent = body
    # a slim stand
    bpy.ops.mesh.primitive_cube_add(size=1); st = bpy.context.active_object; st.name = "stand"
    st.scale = (0.9, 0.02, 0.05); bpy.ops.object.transform_apply(scale=True)
    st.location = (0, -0.55, 0.0); st.parent = body
    st.data.materials.append(principled("stand", srgb(30, 30, 34), 0.8, 0.3))
    bpy.ops.mesh.primitive_cube_add(size=1); ft = bpy.context.active_object; ft.name = "foot"
    ft.scale = (0.9, 0.03, 0.25); bpy.ops.object.transform_apply(scale=True)
    ft.location = (0, -0.57, 0.12); ft.parent = body
    ft.data.materials.append(principled("foot", srgb(30, 30, 34), 0.8, 0.3))
    body.rotation_euler = (math.radians(90), 0, 0)
    return body

def build_watch(path):
    body = rounded_plane("watch", 0.38, 0.45, 0.13); solid(body, 0.11, 0.012)
    body.data.materials.append(principled("case", TITANIUM, 0.9, 0.3))
    screen = rounded_plane("screen", 0.352, 0.428, 0.115)
    screen.data.materials.append(screen_material("screen", path))
    screen.location = (0, 0, 0.056); screen.parent = body
    band = principled("band", srgb(6, 10, 26), 0.15, 0.8)
    for sign in (1, -1):
        bpy.ops.mesh.primitive_cube_add(size=1); b = bpy.context.active_object; b.name = "band"
        b.scale = (0.26, 0.6, 0.075); bpy.ops.object.transform_apply(scale=True)
        bv = b.modifiers.new("round", 'BEVEL'); bv.width = 0.03; bv.segments = 6
        b.location = (0, sign * 0.5, -0.01); b.parent = body; b.data.materials.append(band)
    bpy.ops.mesh.primitive_cylinder_add(radius=0.035, depth=0.03); cr = bpy.context.active_object; cr.name = "crown"
    cr.rotation_euler = (0, math.radians(90), 0); cr.location = (0.205, 0.09, 0.0); cr.parent = body
    cr.data.materials.append(principled("crown", TITANIUM, 0.9, 0.25))
    body.rotation_euler = (math.radians(90), 0, 0)
    return body

def studio_lights():
    light("key", 'AREA', (-2.6, -3.2, 2.4), 420, (1.0, 0.96, 0.9), 3.0)
    light("fill", 'AREA', (2.8, -3.0, 0.4), 140, (0.8, 0.9, 1.0), 4.0)
    light("rim", 'AREA', (1.8, 2.0, 2.2), 600, srgb(51, 196, 255)[:3], 1.5)
    light("rim2", 'AREA', (-2.2, 1.6, -1.0), 260, srgb(254, 160, 46)[:3], 1.5)

def device_shot(builder, path, cam_dist, rot_from, rot_to, dolly=0.06, tilt=(-4, -1), x=0.0, z=0.0):
    world(); backdrop(glow_at=(x, z), glow_radius=cam_dist * 0.45); studio_lights()
    ob = builder(path); ob.location = (x, 0, z); target.location = (x, 0, z)
    cam = camera((x, -cam_dist, z), (90, 0, 0))
    key(cam, "location", 1, -cam_dist, 1); key(cam, "location", FRAMES, -cam_dist + dolly * cam_dist, 1)
    key(ob, "rotation_euler", 1, math.radians(rot_from), 2); key(ob, "rotation_euler", FRAMES, math.radians(rot_to), 2)
    key(ob, "rotation_euler", 1, math.radians(90 + tilt[0]), 0); key(ob, "rotation_euler", FRAMES, math.radians(90 + tilt[1]), 0)
    smooth(cam); smooth(ob)

# ---------------------------------------------------------------- shots
if kind == "phone":
    device_shot(build_phone, clip, 4.7, -22, -8, x=1.05)
elif kind == "tv":
    device_shot(build_tv, clip, 3.9, -13, -5, dolly=0.07, tilt=(-2, 0), z=0.12)
elif kind == "watch":
    device_shot(build_watch, clip, 1.7, 26, 10, dolly=0.08, tilt=(-6, -2), x=0.42)
elif kind in ("intro", "outro"):
    world(sky=True); ocean()
    sun = light("sun", 'SUN', (0, 30, 4), 2.5, srgb(255, 170, 90)[:3], track=False)
    sun.rotation_euler = (math.radians(81), 0, math.radians(152))
    sun.data.energy = 1.6
    light("fill", 'AREA', (0, -4, 6), 200, srgb(51, 196, 255)[:3], 6.0, track=False).rotation_euler = (0, 0, 0)
    cam = camera((0, -7.0, 1.6), (86.5, 0, 0))
    key(cam, "location", 1, -7.0, 1); key(cam, "location", FRAMES, -6.4, 1); smooth(cam)
    Y = 4.0
    if kind == "intro":
        mark, mf = image_plane("mark", os.path.join(ASSETS, "mark.png"), 2.4)
        mark.location = (0, Y, -0.6)
        key(mark, "location", 10, -0.6, 2); key(mark, "location", 75, 2.55, 2); smooth(mark)
        wm, wf = image_plane("wordmark", os.path.join(ASSETS, "wordmark.png"), 3.6); wm.location = (0, Y, 1.5); fade_in(wf, 70, 100)
        key(wm, "location", 70, 1.3, 2); key(wm, "location", 100, 1.5, 2); smooth(wm)
        tg, tf = image_plane("tagline", os.path.join(ASSETS, "tagline.png"), 3.0); tg.location = (0, Y, 0.92); fade_in(tf, 115, 140)
        pl, pf = image_plane("platforms", os.path.join(ASSETS, "platforms.png"), 2.6); pl.location = (0, Y, 0.56); fade_in(pf, 150, 175)
    else:
        ic, icf = image_plane("appicon", os.path.join(ASSETS, "appicon.png"), 1.25); ic.location = (0, Y, 2.35)
        key(ic, "location", 1, 2.0, 2); key(ic, "location", 50, 2.4, 2); smooth(ic); fade_in(icf, 1, 30)
        wm, wf = image_plane("wordmark", os.path.join(ASSETS, "wordmark.png"), 3.2); wm.location = (0, Y, 1.35); fade_in(wf, 25, 55)
        url, uf = image_plane("url", os.path.join(ASSETS, "url.png"), 2.4); url.location = (0, Y, 0.8); fade_in(uf, 60, 90)
        fr, ff = image_plane("free", os.path.join(ASSETS, "free.png"), 1.9); fr.location = (0, Y, 0.42); fade_in(ff, 90, 120)
elif kind == "trio":
    world(); backdrop(glow_radius=2.4); studio_lights()
    phone = build_phone(os.path.join(CFR, "sessions.mp4")); phone.location = (-1.45, 0.0, -0.08)
    tv = build_tv(os.path.join(CFR, "tv.mp4")); tv.location = (0.9, 1.4, 0.3); tv.scale = (1.3, 1.3, 1.3)
    watch = build_watch(os.path.join(CFR, "watch.mp4")); watch.location = (1.5, -0.6, -0.62)
    cam = camera((0.05, -7.2, -0.05), (90, 0, 0))
    key(cam, "location", 1, -7.2, 1); key(cam, "location", FRAMES, -6.7, 1); smooth(cam)
    for ob, a, b in ((phone, 16, 9), (tv, -14, -9), (watch, -24, -14)):
        key(ob, "rotation_euler", 1, math.radians(a), 2); key(ob, "rotation_euler", FRAMES, math.radians(b), 2); smooth(ob)
elif kind == "card":
    world(sky=True); ocean()
    sun = light("sun", 'SUN', (0, 30, 4), 2.5, srgb(255, 170, 90)[:3], track=False)
    sun.rotation_euler = (math.radians(81), 0, math.radians(152))
    sun.data.energy = 1.6
    light("fill", 'AREA', (0, -4, 6), 200, srgb(51, 196, 255)[:3], 6.0, track=False).rotation_euler = (0, 0, 0)
    cam = camera((0, -7.0, 1.6), (86.5, 0, 0))
    key(cam, "location", 1, -7.0, 1); key(cam, "location", FRAMES, -6.5, 1); smooth(cam)
    Y = 4.0
    hd, hf = image_plane("datahead", os.path.join(ASSETS, "datahead.png"), 3.4); hd.location = (0, Y, 2.2); fade_in(hf, 1, 25)
    key(hd, "location", 1, 2.05, 2); key(hd, "location", 25, 2.2, 2); smooth(hd)
    fm, ff = image_plane("formats", os.path.join(ASSETS, "formats.png"), 4.2); fm.location = (0, Y, 1.35); fade_in(ff, 40, 70)
    os_, of = image_plane("opensource", os.path.join(ASSETS, "opensource.png"), 4.2); os_.location = (0, Y, 0.8); fade_in(of, 200, 230)
else:
    raise SystemExit("unknown kind " + kind)

if still:
    scene.frame_set(max(1, int(FRAMES * 0.6)))
    bpy.ops.render.render(write_still=True)
else:
    bpy.ops.render.render(animation=True)
print("DONE", name)
