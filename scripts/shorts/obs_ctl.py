"""Drive OBS over its WebSocket (Bruno gave Claude OBS control, 2026-11-17).
python scripts/shorts/obs_ctl.py status | scenes | start | stop | video [W H [FPS]]
The password is read from OBS's own config at runtime and never printed.
Run with plain `python` (not -I): obsws-python is a --user package."""
import json, os, sys
import obsws_python as obs

def client():
    cfg = os.path.join(os.environ["APPDATA"], "obs-studio", "plugin_config", "obs-websocket", "config.json")
    c = json.load(open(cfg, encoding="utf-8"))
    return obs.ReqClient(host="localhost", port=c.get("server_port", 4455), password=c.get("server_password", ""), timeout=10)

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    cl = client()
    if cmd == "status":
        v = cl.get_version(); r = cl.get_record_status(); vs = cl.get_video_settings()
        print(f"OBS {v.obs_version}, websocket {v.obs_web_socket_version}")
        print(f"recording={r.output_active} paused={r.output_paused} time={r.output_timecode}")
        print(f"canvas {vs.base_width}x{vs.base_height} -> output {vs.output_width}x{vs.output_height} @ {vs.fps_numerator}/{vs.fps_denominator}")
        print(f"scene: {cl.get_current_program_scene().current_program_scene_name}")
        print(f"record dir: {cl.get_record_directory().record_directory}")
    elif cmd == "scenes":
        for s in cl.get_scene_list().scenes:
            items = cl.get_scene_item_list(s["sceneName"]).scene_items
            print(s["sceneName"], "->", [(i["sourceName"], i["inputKind"] if "inputKind" in i else "") for i in items])
    elif cmd == "start":
        cl.start_record(); print("recording started")
    elif cmd == "stop":
        r = cl.stop_record(); print("saved:", r.output_path)
    elif cmd == "video":
        w, h = int(sys.argv[2]), int(sys.argv[3]); fps = int(sys.argv[4]) if len(sys.argv) > 4 else 60
        cl.set_video_settings(numerator=fps, denominator=1, base_width=w, base_height=h, out_width=w, out_height=h)
        print(f"video set to {w}x{h} @ {fps}")
    else:
        print(__doc__)

if __name__ == "__main__":
    main()
