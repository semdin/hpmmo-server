"""Two real client sessions against one world, with a contract-faithful persistence stub.
The PostgreSQL implementation is independently covered by integration_api.py.
"""
import os
import subprocess
import time
from pathlib import Path
import maps_sim as harness

def main():
    out = Path(__file__).parent / "out" / "equipment"
    out.mkdir(parents=True, exist_ok=True)
    for project, name in [(harness.CLIENT_DIR,"client"),(os.path.join(harness.SERVER_DIR,"world"),"world")]:
        with open(out / f"{name}-import.log","wb") as log:
            imported = subprocess.run([harness.marker_cmd(),"--headless","--path",project,"--editor","--import","--quit"],stdout=log,stderr=subprocess.STDOUT)
        if imported.returncode or "ERROR:" in (out / f"{name}-import.log").read_text(encoding="utf-8",errors="replace"): return 1
    stub = harness.StubService().start()
    sheet = harness.seeded_character(901,"arcane",[0,0.6,5],"grounds")
    sheet.update(base_max_hp=500,base_max_mana=300,max_hp=550,max_mana=300,current_hp=500,current_mana=300,
                 equipment_version=1,inventory_revision=1,wand_tier=0,
                 equipment={"main_hand":{"id":"wand_hawthorn","tier":0},"chest":{"id":"robe_apprentice","tier":0},"broom":{"id":"broom_nimbus2000","tier":0}},
                 inventory=[{"id":"ring_apprentice","amount":2,"tier":0},{"id":"wand_hawthorn","amount":1,"tier":4},{"id":"mat_phoenix_ash","amount":5,"tier":0}])
    stub.add_character("arcane",sheet)
    port = harness.free_port()
    server = harness.start_server(port,424242,str(out),{
        "HPMMO_API_URL":f"http://127.0.0.1:{stub.httpd.server_port}","HPMMO_SERVICE_TOKEN":stub.token})
    try:
        if not server.wait_for(f"listening on :{port}"): return 1
        for name,extra in [("equip",[]),("rejoin",["--verify"])]:
            args = [harness.marker_cmd(),"--headless","--path",harness.CLIENT_DIR,
                    "res://scenes/test/equipment_net_probe.tscn","--",f"--port={port}",*extra]
            with open(out / f"{name}.log","wb") as log:
                result = subprocess.run(args,stdout=log,stderr=subprocess.STDOUT,timeout=65)
            content = (out / f"{name}.log").read_text(encoding="utf-8",errors="replace")
            print(content)
            if result.returncode or "EQUIPMENT NETWORK RESULT: 0 failures" not in content: return 1
            deadline = time.monotonic()+8
            while time.monotonic() < deadline and not stub.saved(901): time.sleep(.1)
            time.sleep(.4)
        world_log = Path(server.log_path).read_text(encoding="utf-8",errors="replace")
        assert "SCRIPT ERROR:" not in world_log and "ERROR:" not in world_log, "Dedicated world logged an error; inspect its transcript"
        saved = stub.saved(901)
        assert saved and saved[-1]["equipment"]["main_hand"]["tier"] == 1
        print("EQUIPMENT SESSION RESULT: equip, refine, duplicate request, disconnect save and rejoin passed")
        return 0
    finally:
        server.stop()
        stub.stop()

if __name__ == "__main__":
    raise SystemExit(main())
