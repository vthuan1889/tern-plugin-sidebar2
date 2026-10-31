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
GROUP_IDS = ("todo", "doing", "done")


def resolve_tern_env(kv: dict | None = None) -> tuple[str, dict]:
    env = dict(os.environ)
    user = env.get("USERNAME") or getpass.getuser()
    if not env.get("TERN_PANE_SOCKET"):
        env["TERN_PANE_SOCKET"] = r"\\.\pipe\tern-" + user
    if kv:
        ap = (kv.get("dom_map") or {}).get("active_pane")
        if ap and not env.get("TERN_PANE"):
            env["TERN_PANE"] = str(ap)
    tern_bin = env.get("TERN_EXE") or os.path.expandvars(r"%LOCALAPPDATA%\Programs\Tern\tern.com")
    if not tern_bin or not os.path.exists(tern_bin):
        tern_bin = shutil.which("tern") or "tern"
    return tern_bin, env


def load_kv(kv_path: str) -> dict:
    for _ in range(5):
        try:
            with open(kv_path, "r", encoding="utf-8") as f:
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


def snapshot_geometry(kv_path: str) -> dict:
    kv = load_kv(kv_path)
    dom_map = kv.get("dom_map") or {}
    state = kv.get("state") or {}
    if not state.get("visible", True):
        return {"valid": False, "reason": "hidden"}

    l1_meta = dom_map.get("level1") or []
    l2_meta = dom_map.get("level2") or []
    side = dom_map.get("side") or state.get("side") or "left"
    seq = dom_map.get("seq", 0)
    tern_bin, env = resolve_tern_env(kv)

    try:
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
            for sel in (
                "[data-role^='sidebar2.group.']",
                "[data-role^='sidebar2.level1']",
                "[data-role^='sidebar2.level2']",
            )
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
            ])
        g_rects, l1_rects, l2_rects = raw_lists
    except Exception as exc:
        return {"valid": False, "reason": str(exc)}

    groups = []
    for idx, gid in enumerate(GROUP_IDS):
        if idx < len(g_rects):
            groups.append({"id": gid, "rect": g_rects[idx]})

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

    x_min = min(g["rect"][0] for g in groups)
    x_max = max(g["rect"][0] + g["rect"][2] for g in groups)
    y_min = min(g["rect"][1] for g in groups)
    y_max = max(g["rect"][1] + g["rect"][3] for g in groups)

    return {
        "valid": True,
        "seq": seq,
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
        if rx <= vx <= (rx + GRIP_WIDTH_PX) and ry <= vy <= (ry + rh):
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
            if rx <= vx <= (rx + GRIP_WIDTH_PX) and ry <= vy <= (ry + rh):
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
        best_gid = None
        for g in groups:
            gx, gy, gw, gh = g["rect"]
            if gy <= vy <= gy + gh:
                best_gid = g["id"]
                break
        if best_gid is None:
            best_dist = 1e9
            for g in groups:
                gx, gy, gw, gh = g["rect"]
                dist = 0.0 if (gy <= vy <= gy + gh) else min(abs(vy - gy), abs(vy - (gy + gh)))
                if dist < best_dist:
                    best_dist = dist
                    best_gid = g["id"]
        if best_gid is None:
            return None

        g_sessions = [s for s in snap["level1"] if s.get("group") == best_gid]
        best_pos = None
        if g_sessions:
            first_y = min(s["rect"][1] for s in g_sessions)
            if vy >= first_y - 8:
                best_sdist = 1e9
                for s in g_sessions:
                    rx, ry, rw, rh = s["rect"]
                    cy = ry + rh * 0.5
                    dist = abs(vy - cy)
                    if dist < best_sdist:
                        best_sdist = dist
                        best_pos = int(s.get("pos", 1))
        return {"group": best_gid, "pos": best_pos}
    if drag_item["kind"] == "tab":
        siblings = [
            t for t in snap["level2"]
            if t.get("sess_id") == drag_item["sess_id"]
        ]
        if len(siblings) < 2:
            return None
        s_ymin = min(t["rect"][1] for t in siblings)
        s_ymax = max(t["rect"][1] + t["rect"][3] for t in siblings)
        if vy < s_ymin - 50 or vy > s_ymax + 80:
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
        if (time.time() - st.st_mtime) < 4.0:
            return True
    except Exception:
        pass
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
                if cached_snap.get("valid"):
                    drag_item = hit_test_start(cached_snap, vx, vy)
                if drag_item is None:
                    bounds = cached_snap.get("bounds")
                    in_band = (
                        (bounds[0] - 60 <= vx <= bounds[2] + 60)
                        if bounds
                        else (vx <= cw * 0.65 or vx >= cw * 0.35)
                    )
                    if in_band:
                        snap = snapshot_geometry(kv_path)
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
            time.sleep(0.010)
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
                    last_periodic_snap = 0.0
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
