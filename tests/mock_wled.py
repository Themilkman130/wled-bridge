"""Tiny fake WLED controller for CI: /json/state, /json/eff, /json/pal on 127.0.0.1:8080."""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

EFF = ["Solid","Blink","Breathe","Fire Flicker","Candle","Twinkle","Sparkle","Aurora","Fire 2012"]
PAL = ["Default","Random Cycle","Forest","Fire"]
seg = lambda i,a,b: {"id":i,"start":a,"stop":b,"col":[[255,160,0,0],[0,0,0,0],[0,0,0,0]],"fx":0,"sx":128,"ix":128,"pal":0,"bri":255}
state = {"on": True, "bri": 128, "seg": [seg(0,0,300)]}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        self._send({"/json/state":state,"/json/eff":EFF,"/json/pal":PAL}.get(self.path, {}))
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        for k in ("on","bri"):
            if k in body: state[k] = body[k]
        for s in body.get("seg", []):
            i = s.get("id", 0)
            while len(state["seg"]) <= i: state["seg"].append(seg(len(state["seg"]),0,0))
            cur = state["seg"][i]
            for k, v in s.items():
                if k not in ("i",): cur[k] = v
        self._send({"success": True})

HTTPServer(("127.0.0.1", 8080), H).serve_forever()
