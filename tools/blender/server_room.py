#!/usr/bin/env python3
"""生成开始菜单的机房背景（两张 PNG，直接进 assets/title/）。

    Blender --background --factory-startup --python tools/blender/server_room.py -- \
        --out assets/title --width 1920 --height 1080 --samples 64

产出：
    title_room.png   机房本体。不透明，铺满全屏，构图是"站在机柜通道口往里看"。
    title_fore.png   前景剪影。带透明通道，是贴着镜头的那几件东西（机柜边、吊线），
                     在 Godot 里用更大的视差量盖在机房之上，做出纵深。

为什么是两张而不是一张：菜单要有"镜头随鼠标微动"的纵深，一张平图做不到——
近处那层必须能相对远处滑开。机房本体内部不再分层：机柜是坐在地上的，
把地面和机柜拆到两层里，滑动时接缝和倒影会露馅（见 Godot 那边的说明）。

构图刻意留白：灭点偏画面右侧 10%，左边三分之一只有机柜的暗面，
菜单文字压在那里不打架。

光是烘进去的（发光材质 + 合成器 Glare 雾状辉光），Godot 那边只做轻微调色，
不做后处理辉光——GL Compatibility 渲染器的辉光支持有限，而且烘死的光
在菜单这种静态画面里更好控制。

跑一遍约 1~2 分钟（1920×1080 / 64 采样）。迭代时先 960×540 / 16 采样看构图。
"""

import argparse
import math
import os
import random
import sys

import bpy

# ---------------------------------------------------------------- 尺寸常量（米）

RACK_W = 0.70          # 机柜宽（x）
RACK_D = 1.00          # 机柜深（y）
RACK_H = 2.05          # 机柜高（z）
AISLE_X = 1.70         # 通道半宽：机柜正面所在的 x
RACK_CX = AISLE_X + RACK_W * 0.5   # 机柜中心 x = 1.80
RACK_Y0 = -4.0         # 第一台机柜的 y
RACK_STEP = 1.06       # 机柜间距（比柜宽略大，留出缝）
RACK_N = 18            # 单侧机柜数

CEIL_Z = 3.30
WALL_X = 3.90
FAR_Y = 17.0           # 尽头那面墙
FLOOR_STRIP_X = 1.30   # 地面导光条（贴着机柜脚）
CEIL_STRIP_X = 1.05    # 天花灯带

CAM_LOC = (0.0, -6.40, 1.55)
CAM_YAW = 4.0          # 度。往左偏一点，灭点因此落在画面右侧 8% 处
CAM_PITCH = 2.0        # 度。略向下压
CAM_LENS = 40.0

SEED = 0x50525453      # "PRTS"。固定种子：每次生成的机柜灯珠完全一样

# ---------------------------------------------------------------- 配色（线性空间）

C_BLUE = (0.05, 0.22, 1.00)
C_BLUE_HI = (0.25, 0.60, 1.00)
C_ICE = (0.62, 0.82, 1.00)
C_WHITE = (0.90, 0.96, 1.00)
C_FLOOR = (0.010, 0.014, 0.020)
C_BODY = (0.020, 0.024, 0.032)
C_PANEL = (0.008, 0.010, 0.014)
C_WALL = (0.006, 0.008, 0.012)
C_HAZE = (0.010, 0.024, 0.045)

# ---------------------------------------------------------------- 基础设施


def parse_args():
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--out", default="assets/title")
    p.add_argument("--width", type=int, default=1920)
    p.add_argument("--height", type=int, default=1080)
    p.add_argument("--samples", type=int, default=64)
    p.add_argument("--haze", type=float, default=1.0)
    return p.parse_args(argv)


def clear_scene():
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob, do_unlink=True)
    for coll in list(bpy.data.collections):
        bpy.data.collections.remove(coll)
    for mesh in list(bpy.data.meshes):
        bpy.data.meshes.remove(mesh)
    for mat in list(bpy.data.materials):
        bpy.data.materials.remove(mat)
    for ng in list(bpy.data.node_groups):
        bpy.data.node_groups.remove(ng)


def collection(name):
    coll = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(coll)
    return coll


_MESH_CACHE = {}

# 网格按**材质**缓存：机柜、灯珠加起来上千个物体，各建一份网格太慢；
# 但网格是共享的，材质又是挂在网格上的（Blender 的材质槽属于 mesh 不属于 object），
# 所以不能所有盒子共用一份网格——那样所有物体都会用上同一个材质。
# 缓存键是"形状 + 材质名"，同一个材质的所有盒子共用一份网格，两边都满足。


def _cube_mesh(mat):
    verts = [(-0.5, -0.5, -0.5), (0.5, -0.5, -0.5), (0.5, 0.5, -0.5), (-0.5, 0.5, -0.5),
             (-0.5, -0.5, 0.5), (0.5, -0.5, 0.5), (0.5, 0.5, 0.5), (-0.5, 0.5, 0.5)]
    faces = [(0, 1, 2, 3), (4, 7, 6, 5), (0, 4, 5, 1), (1, 5, 6, 2),
             (2, 6, 7, 3), (3, 7, 4, 0)]
    mesh = bpy.data.meshes.new("cube_" + mat.name)
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    return mesh


def _cyl_mesh(mat, segments):
    verts, faces = [], []
    for i in range(segments):
        a = math.tau * i / segments
        verts.append((math.cos(a) * 0.5, math.sin(a) * 0.5, -0.5))
    for i in range(segments):
        a = math.tau * i / segments
        verts.append((math.cos(a) * 0.5, math.sin(a) * 0.5, 0.5))
    for i in range(segments):
        j = (i + 1) % segments
        faces.append((i, j, j + segments, i + segments))
    faces.append(tuple(range(segments - 1, -1, -1)))
    faces.append(tuple(range(segments, segments * 2)))
    mesh = bpy.data.meshes.new("cyl_%s_%d" % (mat.name, segments))
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    return mesh


def _ring_mesh(mat, major_segments=96, minor_segments=8):
    """主半径 1、管半径 0.02 的圆环（躺在 xy 平面上）。尽头的"核心环"用。"""
    verts, faces = [], []
    r = 0.02
    for i in range(major_segments):
        a = math.tau * i / major_segments
        for j in range(minor_segments):
            b = math.tau * j / minor_segments
            verts.append((
                math.cos(a) * (1.0 + math.cos(b) * r),
                math.sin(a) * (1.0 + math.cos(b) * r),
                math.sin(b) * r))
    for i in range(major_segments):
        i2 = (i + 1) % major_segments
        for j in range(minor_segments):
            j2 = (j + 1) % minor_segments
            faces.append((i * minor_segments + j, i2 * minor_segments + j,
                          i2 * minor_segments + j2, i * minor_segments + j2))
    mesh = bpy.data.meshes.new("ring_" + mat.name)
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    return mesh


def mesh_for(kind, mat, segments=10):
    key = "%s|%s|%d" % (kind, mat.name, segments)
    if key not in _MESH_CACHE:
        if kind == "cube":
            mesh = _cube_mesh(mat)
        elif kind == "cyl":
            mesh = _cyl_mesh(mat, segments)
        else:
            mesh = _ring_mesh(mat)
        mesh.materials.append(mat)
        _MESH_CACHE[key] = mesh
    return _MESH_CACHE[key]


def solid_mat(name, color, rough=0.5, metallic=0.0, spec=0.5):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Specular IOR Level"].default_value = spec
    return mat


def emit_mat(name, color, strength):
    """纯发光。用 Emission 节点而不是 Principled 的自发光：灯珠只要颜色和强度，
    套一层 BSDF 只会让高光把颜色冲淡。"""
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.remove(nt.nodes["Principled BSDF"])
    out = nt.nodes["Material Output"]
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs["Color"].default_value = (*color, 1.0)
    em.inputs["Strength"].default_value = strength
    nt.links.new(em.outputs["Emission"], out.inputs["Surface"])
    return mat


def haze_mat(name, color, density, glow=(0.0016, 0.0050, 0.0120)):
    """通道里的空气：吸收 + 自发光。

    只给 Density 的话，体积只是"把远处压黑"（没有光就没有散射，雾是黑的）；
    自发光那一项才是"雾"——远处的机柜会慢慢褪成这个颜色，越远越蓝。
    自发光压得很暗：它是空气，不是霓虹灯。
    """
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.remove(nt.nodes["Principled BSDF"])
    out = nt.nodes["Material Output"]
    vol = nt.nodes.new("ShaderNodeVolumePrincipled")
    vol.inputs["Color"].default_value = (*color, 1.0)
    vol.inputs["Density"].default_value = density
    vol.inputs["Anisotropy"].default_value = 0.2
    vol.inputs["Emission Color"].default_value = (*glow, 1.0)
    vol.inputs["Emission Strength"].default_value = 1.0
    nt.links.new(vol.outputs["Volume"], out.inputs["Volume"])
    return mat


def add_box(name, coll, mat, loc, size, rot=(0.0, 0.0, 0.0)):
    ob = bpy.data.objects.new(name, mesh_for("cube", mat))
    ob.location = loc
    ob.scale = size
    ob.rotation_euler = rot
    coll.objects.link(ob)
    return ob


def add_cyl(name, coll, mat, loc, size, rot=(0.0, 0.0, 0.0), segments=10):
    ob = bpy.data.objects.new(name, mesh_for("cyl", mat, segments))
    ob.location = loc
    ob.scale = size
    ob.rotation_euler = rot
    coll.objects.link(ob)
    return ob


def add_ring(name, coll, mat, loc, scale, rot=(0.0, 0.0, 0.0)):
    ob = bpy.data.objects.new(name, mesh_for("ring", mat))
    ob.location = loc
    ob.scale = scale
    ob.rotation_euler = rot
    coll.objects.link(ob)
    return ob


# ---------------------------------------------------------------- 机房


def build_shell(coll, mats):
    """地面、天花、侧墙、尽头墙。"""
    add_box("floor", coll, mats["floor"], (0.0, 6.0, -0.05), (16.0, 40.0, 0.1))
    add_box("ceiling", coll, mats["wall"], (0.0, 6.0, CEIL_Z + 0.05), (16.0, 40.0, 0.1))
    add_box("wall_l", coll, mats["wall"], (-WALL_X - 0.05, 6.0, CEIL_Z * 0.5),
            (0.1, 40.0, CEIL_Z))
    add_box("wall_r", coll, mats["wall"], (WALL_X + 0.05, 6.0, CEIL_Z * 0.5),
            (0.1, 40.0, CEIL_Z))

    # 尽头：暗墙 + 中间那条竖缝（"核心"）。缝里的光就是灭点上的那个亮点。
    add_box("far_wall", coll, mats["wall"], (0.0, FAR_Y + 0.2, CEIL_Z * 0.5),
            (8.4, 0.4, CEIL_Z))
    add_box("core_slot", coll, mats["core"], (0.0, FAR_Y - 0.02, 1.55), (0.30, 0.06, 2.10))
    add_box("core_slot2", coll, mats["core_dim"], (0.0, FAR_Y - 0.02, 1.55), (0.56, 0.04, 0.09))

    # 核心环：套在竖缝外圈。斜着一点点，别太像正圆。
    add_ring("core_ring", coll, mats["ring"], (0.0, FAR_Y - 0.05, 1.55), (0.92, 0.92, 1.0),
             rot=(math.radians(90.0), 0.0, 0.0))
    add_ring("core_ring2", coll, mats["ring_dim"], (0.0, FAR_Y - 0.04, 1.55),
             (1.22, 1.22, 1.0), rot=(math.radians(90.0), 0.0, 0.0))

    # 尽头墙上的横向灯带 + 一层很暗的墙板格：给"墙"一点尺度感。
    # 光靠那圈环，尽头看着是"悬在虚空里的一个环"（踩过）。
    for i, z in enumerate((0.35, 2.75)):
        add_box("far_line_%d" % i, coll, mats["strip_dim"], (0.0, FAR_Y - 0.02, z),
                (7.6, 0.04, 0.03))
    for i in range(6):
        add_box("far_panel_%d" % i, coll, mats["wall_lit"],
                (-3.5 + i * 1.4, FAR_Y + 0.14, CEIL_Z * 0.5), (1.15, 0.05, 2.9))

    # 地面导光条 + 天花灯带：四条往灭点收的荧光长线，纵深全靠它们
    for side in (-1.0, 1.0):
        add_box("floor_strip_%s" % side, coll, mats["strip"][0],
                (side * FLOOR_STRIP_X, 6.0, 0.012), (0.06, 40.0, 0.02))
        add_box("ceil_strip_%s" % side, coll, mats["ceil"],
                (side * CEIL_STRIP_X, 6.0, CEIL_Z - 0.02), (0.065, 40.0, 0.03))
    # 天花正中再加一条更暗的：三条一起看才像灯槽阵列，两条会像两条铁轨
    add_box("ceil_strip_mid", coll, mats["strip_dim"], (0.0, 6.0, CEIL_Z - 0.02),
            (0.05, 40.0, 0.02))


def build_racks(coll, mats, rng):
    """两侧机柜阵列。每台：柜体 + 面板 + 边条 + 灯珠阵 + 顶部走线架。"""
    for side in (-1.0, 1.0):
        cx = side * RACK_CX
        # 正面朝向通道：左侧柜面朝 +x，右侧柜面朝 -x
        inward = -side
        face_x = cx + inward * (RACK_W * 0.5 + 0.012)
        for i in range(RACK_N):
            y = RACK_Y0 + i * RACK_STEP
            tag = "%s_%02d" % ("L" if side < 0 else "R", i)
            # 距离档：0 = 最近的机柜，4 = 最远。灯珠与边条按档取材质。
            bucket = min(4, i * 5 // RACK_N)
            led = mats["led"][bucket]
            add_box("rack_%s" % tag, coll, mats["body"], (cx, y, RACK_H * 0.5),
                    (RACK_W, RACK_D, RACK_H))
            # 正面板：比柜体略窄，压暗一档，让柜体和面板分得开
            add_box("panel_%s" % tag, coll, mats["panel"],
                    (face_x, y, RACK_H * 0.5), (0.024, RACK_D * 0.86, RACK_H * 0.94))
            # 边条：柜门把手那侧的竖线，暗一档——它是"柜子在哪儿"的轮廓线，
            # 不是主光源（早先给到 6.0，整个通道看着像一排日光灯管）
            add_box("strip_%s" % tag, coll, mats["strip"][bucket],
                    (face_x + inward * 0.014, y + RACK_D * 0.40, RACK_H * 0.5),
                    (0.012, 0.03, RACK_H * 0.86))

            # 灯珠阵：3 列 × 14 行，**浮在面板外面**（贴着放会被面板盒子吃掉，
            # 渲染出来一台机器只有一条竖线——踩过）。
            #
            # 三件事一起决定"像不像机房"：
            #   · 稀疏——六成以上的位置根本不长灯珠。铺满的话是一面发光壁纸，
            #     真实机柜是黑的，只有零星几颗在闪。
            #   · 小——1.6×2.4×3.8cm。早先做到 5cm，看着像一排窗户。
            #   · 越远越暗——按机柜序号取一档材质，光在空气里是会衰减的，
            #     远处的灯和近处一样亮，画面就"平"了（见 led_mats）。
            # 具体哪颗亮、什么颜色，全部来自固定种子：每次生成的机房完全一样。
            for col in range(3):
                for row in range(14):
                    r = rng.random()
                    if r < 0.62:
                        continue        # 暗着的位置连几何都不建
                    if r < 0.80:
                        mat = led["dim"]
                    elif r < 0.92:
                        mat = led["mid"]
                    elif r < 0.975:
                        mat = led["ice"]
                    else:
                        mat = led["white"]
                    lz = 0.22 + row * 0.126
                    ly = y + (col - 1.0) * 0.135
                    add_box("led_%s_%d_%d" % (tag, col, row), coll, mat,
                            (face_x + inward * 0.018, ly, lz), (0.016, 0.024, 0.038))

            # 顶部走线架：两根线缆，暗一档
            add_box("tray_%s" % tag, coll, mats["body"],
                    (cx, y, RACK_H + 0.06), (RACK_W * 0.92, RACK_D * 0.92, 0.04))
            for k, off in enumerate((-0.12, 0.10)):
                add_cyl("cable_%s_%d" % (tag, k), coll, mats["cable"],
                        (cx + off, y, RACK_H + 0.12), (0.035, 0.035, RACK_D * 0.9),
                        rot=(math.radians(90.0), 0.0, 0.0), segments=8)


def build_side_detail(coll, mats):
    """侧墙上的横向管线：补几条纵向分布的荧光线，让两侧不至于全黑。"""
    for side in (-1.0, 1.0):
        for k, z in enumerate((0.55, 1.45, 2.35)):
            add_box("wall_line_%s_%d" % (side, k), coll, mats["strip_dim"],
                    (side * (WALL_X - 0.02), 6.0, z), (0.02, 34.0, 0.03))


def build_foreground(coll, mats):
    """贴着镜头的剪影：压底边、右侧一条、右上几根垂线。

    它们的作用是"框住"画面，并在鼠标移动时相对机房滑开——纵深一半靠这个。

    位置是**按视野算**的，不是拍脑袋摆的：40mm 镜头在 1.1~1.4 米处的半宽
    只有 0.5~0.7 米、半高 0.3 米左右，摆到 2 米开外、又贴着地的东西
    整个在画面外（第一版就是这样，前景层渲染出来一片全黑，什么都没有）。
    所以这几件都贴着镜头放，并且只从画面边缘探进来一条。

    另外它们全部压得很暗：这是剪影，只靠轮廓光勾一条边，不是主体。
    """
    # 底边：横过画面下缘的一束线缆。3 米处、离地 0.7~0.9 米，
    # 正好压在画面下沿——相机在 1.55 米高略朝下看，3 米处的画面下沿在 0.69 米。
    for k in range(3):
        add_cyl("fore_bundle_%d" % k, coll, mats["fore"],
                (0.0, -3.40, 0.70 + k * 0.085), (0.045, 0.045, 7.0),
                rot=(0.0, math.radians(90.0), 0.0), segments=8)
    # 右侧：一根立柱/线束，占住右边一条。细一点——粗了就是一根黑柱子压在机柜上
    add_cyl("fore_post", coll, mats["fore"], (0.95, -3.20, 1.50), (0.075, 0.075, 3.4),
            segments=10)
    # 右上：垂下来的线束（斜着切过右上角）
    for k in range(3):
        add_cyl("fore_cable_%d" % k, coll, mats["fore"],
                (0.16 + k * 0.17, -4.00, 2.20 + k * 0.05),
                (0.034, 0.034, 1.80), rot=(math.radians(28.0), 0.0, math.radians(-12.0)),
                segments=8)


# ---------------------------------------------------------------- 灯光 / 相机 / 渲染


def build_lights(coll):
    """灯单独一个集合，两次渲染都留着——前景那次要是把灯也藏了，
    剪影就是一团纯黑，什么都看不见（踩过）。

    场景本身靠自发光照明，这里补的几盏冷光很弱，只给机柜和地面一点方向性，
    避免全是"贴图般的"平光。功率是试出来的：面光在这种全黑场景里
    要几十瓦才看得见，几瓦等于没开。"""
    specs = [
        ("key", (0.0, -1.0, 2.9), 6.0, (0.55, 0.75, 1.0), 45.0),
        ("mid", (0.0, 6.0, 2.9), 5.0, (0.45, 0.68, 1.0), 55.0),
        ("far", (0.0, 13.0, 2.7), 4.0, (0.60, 0.80, 1.0), 65.0),
    ]
    for name, loc, size, color, power in specs:
        data = bpy.data.lights.new(name, type="AREA")
        data.shape = "RECTANGLE"
        data.size = size
        data.size_y = 0.4
        data.color = color
        data.energy = power
        ob = bpy.data.objects.new("light_%s" % name, data)
        ob.location = loc
        ob.rotation_euler = (0.0, 0.0, 0.0)     # 面光朝下
        coll.objects.link(ob)
    # 前景剪影的轮廓光：从镜头侧后方打，只勾一条边。
    # 功率大是因为它离得近、又是斜掠过去，勾边要的正是"掠射"这一段。
    for name, loc, rot, color, power in [
        ("rim_l", (-1.70, -6.10, 1.05), (0.0, math.radians(-76.0), math.radians(22.0)),
         (0.45, 0.70, 1.0), 220.0),
        ("rim_r", (1.90, -5.90, 0.90), (0.0, math.radians(78.0), math.radians(-16.0)),
         (0.55, 0.78, 1.0), 200.0),
    ]:
        data = bpy.data.lights.new(name, type="AREA")
        data.size = 2.0
        data.size_y = 0.3
        data.color = color
        data.energy = power
        ob = bpy.data.objects.new("light_%s" % name, data)
        ob.location = loc
        ob.rotation_euler = rot
        coll.objects.link(ob)


def build_haze(coll, mats, amount):
    """通道里的一团体积雾。没有它，机柜灯珠只是些亮点，纵深全靠线条；
    有了它，面光在空气里散开，越远越蓝——"机房"的味道一半在这里。

    浓度压得很低（0.004）：这是"空气里有灰"，不是"着火冒烟"。
    amount 是给迭代用的倍率，1.0 是定稿值。"""
    if amount <= 0.0:
        return
    ob = bpy.data.objects.new("haze", bpy.data.meshes.new("haze"))
    # 体积立方体只要一个封闭盒子：用 8 个顶点搭出来，材质只接 Volume 输出
    verts = [(-3.7, -14.0, 0.0), (3.7, -14.0, 0.0), (3.7, 26.0, 0.0), (-3.7, 26.0, 0.0),
             (-3.7, -14.0, CEIL_Z), (3.7, -14.0, CEIL_Z), (3.7, 26.0, CEIL_Z),
             (-3.7, 26.0, CEIL_Z)]
    faces = [(0, 1, 2, 3), (4, 7, 6, 5), (0, 4, 5, 1), (1, 5, 6, 2),
             (2, 6, 7, 3), (3, 7, 4, 0)]
    ob.data.from_pydata(verts, [], faces)
    ob.data.update()
    ob.data.materials.append(mats["haze"])
    coll.objects.link(ob)


def setup_camera(coll):
    data = bpy.data.cameras.new("cam")
    data.lens = CAM_LENS
    data.sensor_width = 36.0
    cam = bpy.data.objects.new("cam", data)
    cam.location = CAM_LOC
    cam.rotation_euler = (
        math.radians(90.0 - CAM_PITCH), 0.0, math.radians(CAM_YAW))
    coll.objects.link(cam)
    bpy.context.scene.camera = cam


def setup_world():
    world = bpy.data.worlds.new("W")
    bpy.context.scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (0.006, 0.009, 0.014, 1.0)
    bg.inputs["Strength"].default_value = 1.0
    world.mist_settings.use_mist = True
    world.mist_settings.start = 5.0
    world.mist_settings.depth = 22.0
    world.mist_settings.falloff = "QUADRATIC"
    world.mist_settings.intensity = 0.55


def setup_render(args):
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_EEVEE"
    sc.render.resolution_x = args.width
    sc.render.resolution_y = args.height
    sc.render.resolution_percentage = 100
    sc.render.image_settings.file_format = "PNG"
    sc.render.film_transparent = False
    sc.eevee.taa_render_samples = args.samples
    sc.eevee.use_raytracing = True
    sc.eevee.use_volumetric_shadows = True
    sc.eevee.volumetric_start = 0.5
    sc.eevee.volumetric_end = 40.0
    sc.view_settings.view_transform = "AgX"
    try:
        sc.view_settings.look = "AgX - Punchy"
    except TypeError:
        pass


def setup_compositor():
    """合成器只做一件事：Glare 雾状辉光，把灯珠和灯带"糊"成荧光。
    机房之所以像机房，一半靠这层辉光——没有它，灯珠只是些亮点。

    雾不在这里做：Blender 5 把合成器的 Mix 节点拿掉了，而且体积雾能吃到
    面光散射，比在合成器里混一层蓝更真（见 build_haze）。"""
    sc = bpy.context.scene
    ng = bpy.data.node_groups.new("title_comp", "CompositorNodeTree")
    sc.compositing_node_group = ng
    sc.use_nodes = True
    nodes, links = ng.nodes, ng.links

    rl = nodes.new("CompositorNodeRLayers")
    rl.location = (-300, 0)
    glare = nodes.new("CompositorNodeGlare")
    glare.location = (0, 0)
    glare.inputs["Type"].default_value = "Fog Glow"
    glare.inputs["Quality"].default_value = "High"
    glare.inputs["Threshold"].default_value = 1.0
    glare.inputs["Strength"].default_value = 0.32
    glare.inputs["Size"].default_value = 6.0
    glare.inputs["Smoothness"].default_value = 0.4

    out = nodes.new("NodeGroupOutput")
    out.location = (320, 0)

    links.new(rl.outputs["Image"], glare.inputs["Image"])
    links.new(glare.outputs["Image"], out.inputs[0])
    return glare


def render_to(path, glare, use_glare, transparent, color_mode):
    sc = bpy.context.scene
    sc.render.film_transparent = transparent
    sc.render.image_settings.color_mode = color_mode
    glare.mute = not use_glare
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)


# ---------------------------------------------------------------- 主流程


def main():
    args = parse_args()
    rng = random.Random(SEED)

    clear_scene()
    setup_world()

    room = collection("room")
    fore = collection("fore")
    lights = collection("lights")

    mats = {
        "floor": solid_mat("floor", C_FLOOR, rough=0.26, metallic=0.15, spec=0.6),
        "wall": solid_mat("wall", C_WALL, rough=0.85),
        "body": solid_mat("body", C_BODY, rough=0.42, metallic=0.75, spec=0.55),
        "panel": solid_mat("panel", C_PANEL, rough=0.62, metallic=0.35),
        "cable": solid_mat("cable", (0.03, 0.035, 0.045), rough=0.7),
        "fore": solid_mat("fore", (0.030, 0.040, 0.055), rough=0.30, metallic=0.55, spec=0.7),
        "strip_dim": emit_mat("strip_dim", C_BLUE, 1.2),
        "ceil": emit_mat("ceil", C_ICE, 2.0),
        "core": emit_mat("core", C_WHITE, 8.5),
        "core_dim": emit_mat("core_dim", C_ICE, 5.0),
        "ring": emit_mat("ring", C_BLUE_HI, 5.5),
        "ring_dim": emit_mat("ring_dim", C_BLUE, 2.5),
        "wall_lit": solid_mat("wall_lit", (0.020, 0.030, 0.050), rough=0.6),
        "haze": haze_mat("haze", C_HAZE, 0.014 * max(args.haze, 0.0)),
    }
    # 灯珠/边条按距离分 5 档，最远那档只有最近档的 38% 亮。
    # 这不是"效果"，是透视的一部分：不做的话远处的灯和近处一样亮，
    # 画面会平得像贴纸（体积雾只管一小部分）。
    mats["led"] = []
    mats["strip"] = []
    for b in range(5):
        f = 1.0 - 0.62 * (b / 4.0)
        mats["led"].append({
            "dim": emit_mat("led_dim_%d" % b, C_BLUE, 1.1 * f),
            "mid": emit_mat("led_mid_%d" % b, C_BLUE_HI, 2.0 * f),
            "ice": emit_mat("led_ice_%d" % b, C_ICE, 3.0 * f),
            "white": emit_mat("led_white_%d" % b, C_WHITE, 4.0 * f),
        })
        mats["strip"].append(emit_mat("strip_%d" % b, C_BLUE_HI, 1.0 * f))

    build_shell(room, mats)
    build_racks(room, mats, rng)
    build_side_detail(room, mats)
    build_haze(room, mats, args.haze)
    build_foreground(fore, mats)
    build_lights(lights)
    setup_camera(room)
    setup_render(args)
    glare = setup_compositor()

    out_dir = os.path.abspath(args.out)
    os.makedirs(out_dir, exist_ok=True)

    # 机房本体：不透明，含辉光与雾
    fore.hide_render = True
    render_to(os.path.join(out_dir, "title_room.png"), glare, True, False, "RGB")

    # 前景剪影：透明底，不带辉光（透明底上跑 Glare 会在 alpha 边缘留下灰边）
    fore.hide_render = False
    room.hide_render = True
    render_to(os.path.join(out_dir, "title_fore.png"), glare, False, True, "RGBA")

    print("done:", out_dir)


if __name__ == "__main__":
    main()
