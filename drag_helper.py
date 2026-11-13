# sidebar2/drag_helper.py
# Win32 mouse press-hold-drag-release helper for Tern Kanban Sidebar (sidebar2).

import ctypes
import ctypes.wintypes as wt
import getpass
import json
import math
import os
import shutil
import subprocess
import sys
import time

CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)
DETACHED_PROCESS = getattr(subprocess, "DETACHED_PROCESS", 0x00000008)
CREATE_NEW_PROCESS_GROUP = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200)

VK_LBUTTON = 0x01
GA_ROOT = 2
DRAG_THRESHOLD_PX = 5.0
GRIP_WIDTH_PX = 34.0
RIGHT_ICON_RESERVE_PX = 32.0
GROUP_IDS = ("todo", "doing", "review", "paused", "stuck", "done")
# The surface the last snapshot found rects on; tried first next time (see snapshot_geometry).
_last_surface = ""

# The two surfaces draw the same rows with different roles: the sidebar lists them in one column
# per stage, the `Tổng quan` board wraps six columns. The plugin publishes a DOM map per surface,
# so the rects are read with the selectors of the surface that painted last.
SURFACE_SELECTORS = {
    "sidebar": (
        "[data-role^='sidebar2.group.']",
        "[data-role^='sidebar2.level1']",
        "[data-role^='sidebar2.level2']",
    ),
    "overview": (
        "[data-role^='sidebar2.ov.stage.']",
        "[data-role^='sidebar2.ov.card']",
        "[data-role^='sidebar2.ov.tab']",
    ),
}


def resolve_tern_env(kv: dict | None = None) -> tuple[str, dict]:
    env = dict(os.environ)
    user = env.get("USERNAME") or getpass.getuser()
    if not env.get("TERN_PANE_SOCKET"):
        env["TERN_PANE_SOCKET"] = r"\\.\pipe\tern-" + user
    if kv:
        ap = (kv.get("dom_map") or {}).get("active_pane")
        if ap:
            # The worker outlives the pane that spawned it; the inherited value goes stale.
            env["TERN_PANE"] = str(ap)
    tern_bin = env.get("TERN_EXE") or os.path.expandvars(r"%LOCALAPPDATA%\Programs\Tern\tern.com")
    if not tern_bin or not os.path.exists(tern_bin):
        tern_bin = shutil.which("tern") or "tern"
    return tern_bin, env


def load_kv(kv_path: str) -> dict:
    for _ in range(5):
        try:
            with open(kv_path, "r", encoding="utf-8", errors="replace") as f:
                data = json.load(f)
                return data if isinstance(data, dict) else {}
        except FileNotFoundError:
            return {}
        except Exception:
            time.sleep(0.008)
    return {}


def update_kv(kv_path: str, updates: dict) -> bool:
    tmp_path = kv_path + f".tmp.{os.getpid()}"
    for _ in range(8):
        try:
            data = load_kv(kv_path)
            data.update(updates)
            with open(tmp_path, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False)
            os.replace(tmp_path, kv_path)
            return True
        except Exception:
            time.sleep(0.01)
    try:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
    except Exception:
        pass
    return False


def write_status(data_dir: str, info: dict):
    try:
        status_path = os.path.join(data_dir, "drag_helper_status.json")
        with open(status_path, "w", encoding="utf-8") as f:
            json.dump(info, f, ensure_ascii=False)
    except Exception:
        pass


def _query_rects(tern_bin: str, env: dict, selectors: tuple) -> tuple[list, str]:
    """Rects of every node matching `selectors`, in list order, with the last stderr seen."""
    procs = [
        subprocess.Popen(
            [tern_bin, "ctl", "tree", sel],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=env,
            creationflags=CREATE_NO_WINDOW,
        )
        for sel in selectors
    ]
    raw_lists = []
    last_err = ""
    for p in procs:
        out, err = p.communicate(timeout=1.5)
        if p.returncode != 0 and err:
            last_err = err.strip()
        nodes = (json.loads(out).get("nodes") or []) if (p.returncode == 0 and out) else []
        raw_lists.append([
            n["rect"] for n in nodes
            if isinstance(n.get("rect"), list)
            and len(n["rect"]) == 4
            and n["rect"][2] > 0
            and n["rect"][3] > 0
            # A pane in a tab that is not shown is parked far off the left/top edge; its rows
            # are not on screen, and keeping them would hit-test against another surface.
            and n["rect"][0] + n["rect"][2] > 0
            and n["rect"][1] + n["rect"][3] > 0
        ])
    return raw_lists, last_err


def snapshot_geometry(kv_path: str, avoid: str = "") -> dict:
    """Rects of the surface on screen; `avoid` demotes a surface that just missed a hit test."""
    global _last_surface
    kv = load_kv(kv_path)
    dom_map = kv.get("dom_map") or {}
    ov_map = kv.get("ov_dom_map") or {}
    state = kv.get("state") or {}
    hint = (kv.get("dom_surface") or {}).get("surface")
    if hint not in ("sidebar", "overview"):
        hint = ""
    # The plugin says which surface it last painted; the paint counters are a weaker tie-break
    # (a map keeps its old seq while its fingerprint is unchanged, so they often tie).
    seq_side = int(dom_map.get("seq") or 0)
    seq_ov = int(ov_map.get("seq") or 0)
    if not state.get("visible", True):
        # The sidebar is hidden: only the board can still be showing rows.
        if seq_ov <= 0 and hint != "overview":
            return {"valid": False, "reason": "hidden"}
        order = ["overview"]
    else:
        guessed = "overview" if seq_ov > seq_side else "sidebar"
        promo = hint or _last_surface or guessed
        order = [promo] + [n for n in ("sidebar", "overview") if n != promo]
    if avoid in order and len(order) > 1:
        order = [n for n in order if n != avoid] + [avoid]

    tern_bin, env = resolve_tern_env(kv)
    active = ""
    raw_lists = None
    last_err = ""
    try:
        for name in order:
            dm = ov_map if name == "overview" else dom_map
            if not dm:
                continue
            raw_lists, err = _query_rects(tern_bin, env, SURFACE_SELECTORS[name])
            last_err = err or last_err
            # An empty first probe means that map is stale: the other surface is the one drawn.
            if raw_lists[0]:
                active = name
                break
            raw_lists = None
    except Exception as exc:
        return {"valid": False, "reason": str(exc)}
    if raw_lists is None or not active:
        return {"valid": False, "reason": last_err or "no_groups"}
    _last_surface = active

    dm = ov_map if active == "overview" else dom_map
    l1_meta = dm.get("level1") or []
    l2_meta = dm.get("level2") or []
    side = dm.get("side") or state.get("side") or "left"
    seq = int(dm.get("seq") or 0)
    g_rects, l1_rects, l2_rects = raw_lists

    group_ids = dm.get("groups") or list(GROUP_IDS)
    groups = []
    for idx, gid in enumerate(group_ids):
        if idx < len(g_rects):
            groups.append({"id": gid, "rect": g_rects[idx]})

    # A missed `ctl tree` call returns partial rects; caching that would shift every slot.
    if l1_meta and len(l1_rects) != len(l1_meta):
        return {"valid": False, "reason": "count_mismatch"}
    if l2_meta and len(l2_rects) != len(l2_meta):
        return {"valid": False, "reason": "count_mismatch"}

    level1 = []
    for idx in range(min(len(l1_rects), len(l1_meta))):
        item = dict(l1_meta[idx])
        item["rect"] = l1_rects[idx]
        level1.append(item)

    level2 = []
    for idx in range(min(len(l2_rects), len(l2_meta))):
        item = dict(l2_meta[idx])
        item["rect"] = l2_rects[idx]
        level2.append(item)

    if not groups:
        return {"valid": False, "reason": last_err or "no_groups"}

    # The board wraps six columns, so a stage is a 2D box: a short or empty column shares its row
    # with taller ones, and the press must find it anywhere in that row's height.
    for g in groups:
        gx = g["rect"][0]
        y_min = g["rect"][1]
        y_max = g["rect"][1] + g["rect"][3]
        for other in groups:
            if abs(other["rect"][0] - gx) < 20.0:
                y_min = min(y_min, other["rect"][1])
                y_max = max(y_max, other["rect"][1] + other["rect"][3])
        g["y_min"] = y_min
        g["y_max"] = y_max

    x_min = min(g["rect"][0] for g in groups)
    x_max = max(g["rect"][0] + g["rect"][2] for g in groups)
    y_min = min(g["y_min"] for g in groups)
    y_max = max(g["y_max"] for g in groups)

    return {
        "valid": True,
        "seq": seq,
        "surface": active,
        "side": side,
        "ts": time.monotonic(),
        "bounds": (x_min, y_min, x_max, y_max),
        "groups": groups,
        "level1": level1,
        "level2": level2,
    }


def hit_test_start(snap: dict, vx: float, vy: float) -> dict | None:
    if not snap.get("valid"):
        return None
    x_min, y_min, x_max, y_max = snap["bounds"]
    if vx < x_min - 20 or vx > x_max + 20 or vy < y_min - 20 or vy > y_max + 40:
        return None

    for item in snap["level1"]:
        rx, ry, rw, rh = item["rect"]
        if rx <= vx <= max(rx + GRIP_WIDTH_PX, rx + rw - RIGHT_ICON_RESERVE_PX) and ry <= vy <= (ry + rh):
            return {
                "kind": "session",
                "skey": item["skey"],
                "sess_id": item["sess_id"],
                "start_group": item["group"],
                "start_pos": int(item.get("pos", 1)),
            }

    for item in snap["level2"]:
        rx, ry, rw, rh = item["rect"]
        if int(item.get("tab_count", 2)) >= 2:
            x_end = (rx + rw - RIGHT_ICON_RESERVE_PX) if item.get("has_sub") else (rx + rw)
            if rx <= vx <= max(rx + GRIP_WIDTH_PX, x_end) and ry <= vy <= (ry + rh):
                return {
                    "kind": "tab",
                    "tab_id": item["tab_id"],
                    "sess_id": item["sess_id"],
                    "start_pos": int(item["pos"]),
                }
    return None


def compute_hover_target(snap: dict, drag_item: dict, vx: float, vy: float):
    if not snap.get("valid"):
        return None
    x_min, y_min, x_max, y_max = snap["bounds"]
    if vx < x_min - 140 or vx > x_max + 140:
        return None

    if drag_item["kind"] == "session":
        groups = snap["groups"]
        if not groups or vy < y_min - 50 or vy > y_max + 160:
            return None
        # Stages wrap on the board, so a stage is a box: horizontal bounds + the whole row's
        # height. Ties fall back to the nearest box, so a press just outside one still lands.
        best_gid = None
        best_group = None
        best_dist = 1e9
        for g in groups:
            gx, gy, gw, gh = g["rect"]
            y0 = g.get("y_min", gy)
            y1 = g.get("y_max", gy + gh)
            inside = (gx <= vx <= gx + gw) and (y0 <= vy <= y1)
            dx = 0.0 if gx <= vx <= gx + gw else min(abs(vx - gx), abs(vx - (gx + gw)))
            dy = 0.0 if y0 <= vy <= y1 else min(abs(vy - y0), abs(vy - y1))
            if inside:
                best_gid = g["id"]
                best_group = g
                break
            dist = math.hypot(dx, dy)
            if dist < best_dist:
                best_dist = dist
                best_gid = g["id"]
                best_group = g
        if best_gid is None:
            return None

        gy, gh = best_group["rect"][1], best_group["rect"][3]
        g_sessions = sorted(
            [s for s in snap["level1"] if s.get("group") == best_gid],
            key=lambda s: s["rect"][1],
        )
        if not g_sessions:
            return {"group": best_gid, "pos": 1}

        n = len(g_sessions)
        if drag_item.get("start_group") == best_gid:
            # Intra-group: only slots 1..N exist, so land on the slot covering the cursor.
            first = g_sessions[0]
            if vy <= first["rect"][1] + first["rect"][3]:
                return {"group": best_gid, "pos": int(first.get("pos", 1))}
            best_pos = int(g_sessions[-1].get("pos", n))
            for i in range(n - 1):
                cur, nxt = g_sessions[i], g_sessions[i + 1]
                if vy <= (cur["rect"][1] + cur["rect"][3] + nxt["rect"][1]) * 0.5:
                    best_pos = int(cur.get("pos", i + 1))
                    break
            return {"group": best_gid, "pos": best_pos}

        # Cross-group: slots 1..N+1, N+1 appends after the last session.
        for i in range(n - 1):
            cur, nxt = g_sessions[i], g_sessions[i + 1]
            if vy <= (cur["rect"][1] + cur["rect"][3] + nxt["rect"][1]) * 0.5:
                return {"group": best_gid, "pos": int(cur.get("pos", i + 1))}
        last = g_sessions[-1]
        lry, lrh = last["rect"][1], last["rect"][3]
        lrbot = lry + lrh
        gbot = gy + gh
        # Unfolded tabs sit under the header: header row = N, below it = N+1. Folded: 65/35 split.
        last_split_y = lrbot if (gbot > lrbot + 10.0) else (lry + lrh * 0.65)
        if vy <= last_split_y:
            return {"group": best_gid, "pos": int(last.get("pos", n))}
        return {"group": best_gid, "pos": n + 1}
    if drag_item["kind"] == "tab":
        siblings = [
            t for t in snap["level2"]
            if t.get("sess_id") == drag_item["sess_id"]
        ]
        if len(siblings) < 2:
            return None
        s_ymin = min(t["rect"][1] for t in siblings)
        s_ymax = max(t["rect"][1] + t["rect"][3] for t in siblings)
        s_xmin = min(t["rect"][0] for t in siblings)
        s_xmax = max(t["rect"][0] + t["rect"][2] for t in siblings)
        # Sibling tabs share a session's column: a cursor parked in another column is not a drop.
        if vy < s_ymin - 50 or vy > s_ymax + 80:
            return None
        if vx < s_xmin - 80 or vx > s_xmax + 80:
            return None
        best_pos = None
        best_dist = 1e9
        for t in siblings:
            rx, ry, rw, rh = t["rect"]
            cy = ry + rh * 0.5
            dist = abs(vy - cy)
            if dist < best_dist:
                best_dist = dist
                best_pos = int(t["pos"])
        return best_pos

    return None


def run_simulated_drag(kv_path: str, x0: float, y0: float, x1: float, y1: float) -> int:
    snap = snapshot_geometry(kv_path)
    drag_item = hit_test_start(snap, x0, y0)
    if not drag_item and snap.get("surface"):
        # The guess landed on the other surface's rects: read the other one and retry once.
        alt = snapshot_geometry(kv_path, avoid=snap["surface"])
        if alt.get("valid"):
            snap = alt
            drag_item = hit_test_start(snap, x0, y0)
    if not drag_item:
        print(json.dumps({"ok": False, "error": "no draggable item at start", "x0": x0, "y0": y0, "snap": snap}))
        return 1

    target = compute_hover_target(snap, drag_item, x1, y1)
    if drag_item["kind"] == "session" and isinstance(target, dict):
        hgroup = target.get("group")
        hpos = target.get("pos")
        update_kv(kv_path, {
            "drag_state": {
                "active": True,
                "kind": "session",
                "skey": drag_item["skey"],
                "hover_group": hgroup,
                "hover_pos": hpos,
            }
        })
        time.sleep(0.16)
        seq = int(time.time() * 1000)
        if hgroup in GROUP_IDS:
            drop_obj = {
                "seq": seq,
                "kind": "session",
                "skey": drag_item["skey"],
                "target_group": hgroup,
            }
            if hpos is not None:
                drop_obj["target_pos"] = int(hpos)
            update_kv(kv_path, {
                "drag_state": {"active": False},
                "drag_drop": drop_obj,
            })
            print(json.dumps({"ok": True, **drop_obj}))
            return 0
    elif drag_item["kind"] == "tab":
        update_kv(kv_path, {
            "drag_state": {
                "active": True,
                "kind": "tab",
                "tab_id": drag_item["tab_id"],
                "sess_id": drag_item["sess_id"],
                "hover_pos": target,
            }
        })
        time.sleep(0.16)
        seq = int(time.time() * 1000)
        if target is not None and int(target) != int(drag_item["start_pos"]):
            update_kv(kv_path, {
                "drag_state": {"active": False},
                "drag_drop": {
                    "seq": seq,
                    "kind": "tab",
                    "tab_id": drag_item["tab_id"],
                    "sess_id": drag_item["sess_id"],
                    "target_pos": int(target),
                },
            })
            print(json.dumps({"ok": True, "kind": "tab", "tab_id": drag_item["tab_id"], "target_pos": int(target), "seq": seq}))
            return 0

    update_kv(kv_path, {"drag_state": {"active": False}})
    print(json.dumps({"ok": False, "error": "invalid drop target", "drag_item": drag_item, "target": target}))
    return 1


def is_worker_healthy(data_dir: str) -> bool:
    hb_file = os.path.join(data_dir, "drag_helper.hb")
    try:
        st = os.stat(hb_file)
        if (time.time() - st.st_mtime) >= 4.0:
            return False
    except Exception:
        return False
    # A worker left over from an older drag_helper.py would keep hit-testing with deleted layout
    # code; the pid file records when it started, so a newer script means "replace it".
    pid_file = os.path.join(data_dir, "drag_helper.pid")
    try:
        return os.path.getmtime(os.path.abspath(__file__)) <= os.path.getmtime(pid_file)
    except Exception:
        return False


def spawn_detached_worker(kv_path: str):
    data_dir = os.path.dirname(kv_path)
    if is_worker_healthy(data_dir):
        return
    subprocess.Popen(
        [sys.executable, os.path.abspath(__file__), kv_path, "--worker"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=True,
        creationflags=CREATE_NO_WINDOW | DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP,
    )


def worker_loop(kv_path: str):
    data_dir = os.path.dirname(kv_path)
    os.makedirs(data_dir, exist_ok=True)
    pid_file = os.path.join(data_dir, "drag_helper.pid")
    hb_file = os.path.join(data_dir, "drag_helper.hb")
    my_pid = str(os.getpid())
    try:
        with open(pid_file, "w", encoding="utf-8") as f:
            f.write(my_pid)
        with open(hb_file, "w", encoding="utf-8") as f:
            f.write(str(time.time()))
    except Exception:
        pass

    u32 = ctypes.windll.user32
    try:
        u32.SetProcessDPIAware()
    except Exception:
        pass

    cls_buf = ctypes.create_unicode_buffer(64)

    def get_stencil_client_pos():
        pt = wt.POINT()
        if not u32.GetCursorPos(ctypes.byref(pt)):
            return None
        hwnd = u32.WindowFromPoint(pt)
        root = (u32.GetAncestor(hwnd, GA_ROOT) or hwnd) if hwnd else 0
        if root:
            u32.GetClassNameW(root, cls_buf, 64)
        if not root or cls_buf.value != "StencilWindow":
            fg = u32.GetForegroundWindow()
            if fg:
                u32.GetClassNameW(fg, cls_buf, 64)
                if cls_buf.value == "StencilWindow":
                    root = fg
                else:
                    return None
            else:
                return None
        rc = wt.RECT()
        if not u32.GetClientRect(root, ctypes.byref(rc)):
            return None
        cw = rc.right - rc.left
        ch = rc.bottom - rc.top
        if cw <= 0 or ch <= 0:
            return None
        cpt = wt.POINT(pt.x, pt.y)
        if not u32.ScreenToClient(root, ctypes.byref(cpt)):
            return None
        if cpt.x < 0 or cpt.y < 0 or cpt.x > cw or cpt.y > ch:
            return None
        return float(cpt.x), float(cpt.y), float(cw), float(ch)

    cached_snap = snapshot_geometry(kv_path)
    write_status(data_dir, {
        "pid": int(my_pid),
        "snap_valid": bool(cached_snap.get("valid")),
        "snap_reason": cached_snap.get("reason", "ok"),
        "seq": cached_snap.get("seq", 0),
        "l1_count": len(cached_snap.get("level1") or []),
        "l2_count": len(cached_snap.get("level2") or []),
    })

    last_hb = time.monotonic()
    last_kv_mtime = 0.0
    last_periodic_snap = time.monotonic()
    # The plugin spawns a fresh worker on its own check; an edited script must not keep hit-testing
    # with the layout code it was started with.
    script_mtime = os.path.getmtime(os.path.abspath(__file__))

    was_down = False
    press_pos = None
    drag_item = None
    dragging = False
    last_hover = None

    while True:
        now = time.monotonic()
        if now - last_hb >= 1.0:
            last_hb = now
            try:
                if os.path.getmtime(os.path.abspath(__file__)) != script_mtime:
                    return
                with open(pid_file, "r", encoding="utf-8") as f:
                    if f.read().strip() != my_pid:
                        return
                with open(hb_file, "w", encoding="utf-8") as f:
                    f.write(str(time.time()))
            except Exception:
                return

        is_down = (u32.GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0

        if not is_down and not was_down:
            need_snap = not cached_snap.get("valid")
            try:
                st = os.stat(kv_path)
                if st.st_mtime != last_kv_mtime:
                    last_kv_mtime = st.st_mtime
                    kv = load_kv(kv_path)
                    if not (kv.get("state") or {}).get("visible", True):
                        return
                    dm_seq = (kv.get("dom_map") or {}).get("seq", 0)
                    if dm_seq != cached_snap.get("seq"):
                        need_snap = True
            except Exception:
                pass

            if not need_snap and (now - last_periodic_snap) >= 2.5:
                if get_stencil_client_pos() is not None:
                    need_snap = True

            if need_snap:
                last_periodic_snap = now
                snap = snapshot_geometry(kv_path)
                if snap.get("valid"):
                    cached_snap = snap
                    write_status(data_dir, {
                        "pid": int(my_pid),
                        "snap_valid": True,
                        "seq": cached_snap.get("seq", 0),
                        "l1_count": len(cached_snap.get("level1") or []),
                        "l2_count": len(cached_snap.get("level2") or []),
                    })
            time.sleep(0.020)
            continue

        if is_down and not was_down:
            was_down = True
            dragging = False
            drag_item = None
            last_hover = None
            press_pos = None

            pos = get_stencil_client_pos()
            if pos is not None:
                vx, vy, cw, _ch = pos
                press_pos = (vx, vy)
                bounds = cached_snap.get("bounds")
                in_band = (
                    (bounds[0] - 60 <= vx <= bounds[2] + 60)
                    if bounds
                    else (vx <= cw * 0.65 or vx >= cw * 0.35)
                )
                refreshed = False
                if in_band:
                    try:
                        st = os.stat(kv_path)
                        if st.st_mtime != last_kv_mtime:
                            last_kv_mtime = st.st_mtime
                            refreshed = True
                    except Exception:
                        pass
                    if not refreshed and (now - cached_snap.get("ts", 0.0)) > 1.2:
                        refreshed = True
                if refreshed:
                    snap = snapshot_geometry(kv_path)
                    if snap.get("valid"):
                        cached_snap = snap
                    refreshed = bool(snap.get("valid"))
                if cached_snap.get("valid"):
                    drag_item = hit_test_start(cached_snap, vx, vy)
                # A miss means the cached rects belong to the other surface, or to a layout that
                # moved since: re-probe whenever the snapshot is older than one press, even when it
                # was refreshed a moment ago (bounds from the other surface must not veto this).
                if drag_item is None and (not refreshed or (now - cached_snap.get("ts", 0.0)) > 0.35):
                    # The cached rects may belong to the other surface: ask for the other one.
                    snap = snapshot_geometry(kv_path, avoid=cached_snap.get("surface") or "")
                    if snap.get("valid"):
                        cached_snap = snap
                        drag_item = hit_test_start(cached_snap, vx, vy)
                if drag_item is not None:
                    write_status(data_dir, {
                        "pid": int(my_pid),
                        "snap_valid": bool(cached_snap.get("valid")),
                        "seq": cached_snap.get("seq", 0),
                        "last_press": [vx, vy],
                        "drag_item": drag_item,
                    })
            continue

        if is_down and was_down:
            if drag_item is not None and press_pos is not None:
                pos = get_stencil_client_pos()
                if pos is not None:
                    vx, vy, _cw, _ch = pos
                    if not dragging:
                        if math.hypot(vx - press_pos[0], vy - press_pos[1]) >= DRAG_THRESHOLD_PX:
                            dragging = True
                    if dragging:
                        hover = compute_hover_target(cached_snap, drag_item, vx, vy)
                        if hover != last_hover or last_hover is None:
                            last_hover = hover
                            if drag_item["kind"] == "session" and isinstance(hover, dict):
                                update_kv(kv_path, {
                                    "drag_state": {
                                        "active": True,
                                        "kind": "session",
                                        "skey": drag_item["skey"],
                                        "hover_group": hover.get("group"),
                                        "hover_pos": hover.get("pos"),
                                    }
                                })
                            elif drag_item["kind"] == "tab":
                                update_kv(kv_path, {
                                    "drag_state": {
                                        "active": True,
                                        "kind": "tab",
                                        "tab_id": drag_item["tab_id"],
                                        "sess_id": drag_item["sess_id"],
                                        "hover_pos": hover,
                                    }
                                })
            time.sleep(0.008)
            continue

        if not is_down and was_down:
            was_down = False
            if drag_item is not None and press_pos is not None:
                pos = get_stencil_client_pos()
                if not dragging and pos is not None:
                    if math.hypot(pos[0] - press_pos[0], pos[1] - press_pos[1]) >= DRAG_THRESHOLD_PX:
                        dragging = True
                if dragging:
                    hover = last_hover
                    if pos is not None:
                        h2 = compute_hover_target(cached_snap, drag_item, pos[0], pos[1])
                        if h2 is not None:
                            hover = h2
                    seq = int(time.time() * 1000)
                    if drag_item["kind"] == "session" and isinstance(hover, dict):
                        hgroup = hover.get("group")
                        hpos = hover.get("pos")
                        same_slot = (
                            hgroup == drag_item.get("start_group")
                            and (hpos is None or int(hpos) == int(drag_item.get("start_pos", 1)))
                        )
                        if hgroup in GROUP_IDS and not same_slot:
                            drop_obj = {
                                "seq": seq,
                                "kind": "session",
                                "skey": drag_item["skey"],
                                "target_group": hgroup,
                            }
                            if hpos is not None:
                                drop_obj["target_pos"] = int(hpos)
                            update_kv(kv_path, {
                                "drag_state": {"active": False},
                                "drag_drop": drop_obj,
                            })
                        else:
                            update_kv(kv_path, {"drag_state": {"active": False}})
                    elif (
                        drag_item["kind"] == "tab"
                        and hover is not None
                        and int(hover) != int(drag_item["start_pos"])
                    ):
                        update_kv(kv_path, {
                            "drag_state": {"active": False},
                            "drag_drop": {
                                "seq": seq,
                                "kind": "tab",
                                "tab_id": drag_item["tab_id"],
                                "sess_id": drag_item["sess_id"],
                                "target_pos": int(hover),
                            },
                        })
                    else:
                        update_kv(kv_path, {"drag_state": {"active": False}})
                    # Let window.luau apply drag_drop before a fallback snapshot re-reads geometry.
                    last_periodic_snap = time.monotonic() - 2.35
            dragging = False
            drag_item = None
            press_pos = None
            last_hover = None
            time.sleep(0.015)


def main():
    if len(sys.argv) < 2:
        return
    kv_path = os.path.abspath(sys.argv[1])
    if len(sys.argv) >= 7 and sys.argv[2] == "--simulate-drag":
        sys.exit(run_simulated_drag(
            kv_path,
            float(sys.argv[3]),
            float(sys.argv[4]),
            float(sys.argv[5]),
            float(sys.argv[6]),
        ))
    if len(sys.argv) >= 3 and sys.argv[2] == "--worker":
        worker_loop(kv_path)
        return
    spawn_detached_worker(kv_path)


if __name__ == "__main__":
    main()
