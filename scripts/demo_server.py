#!/usr/bin/env python3
import json
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock
from urllib.parse import urlparse

HOST = "127.0.0.1"
PORT = 8787

STATE_LOCK = Lock()
STATE = {
    "trainId": "9812",
    "trainNumber": "6201",
    "speed": 285,
    "wifiQuality": 4,
    "devices": 246,
    "consumedData": 12000,
    "remainingData": 28000,
    "nextResetMinutes": 95,
    "barAttendance": 3,
    "delayMins": 0,
    "delayCause": "",
    "stationStatus": "moving",  # moving | station
    "currentStationIndex": 1,
    "minutesToNextStop": 6,
    "minutesToFinalStop": 22,
    "stops": [
        {"id": "paris", "label": "Paris Gare de Lyon"},
        {"id": "lyon", "label": "Lyon Part Dieu"},
        {"id": "marseille", "label": "Marseille St-Charles"},
    ],
}


def iso_in(minutes):
    ts = datetime.now(timezone.utc) + timedelta(minutes=minutes)
    return ts.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def build_stops(state):
    current_idx = max(0, min(int(state.get("currentStationIndex", 1)), len(state["stops"]) - 1))
    next_minutes = max(0, int(state.get("minutesToNextStop", 6)))
    final_minutes = max(next_minutes, int(state.get("minutesToFinalStop", 22)))

    out = []
    for idx, stop in enumerate(state["stops"]):
        if idx < current_idx:
            progress_pct = 100.0
            stop_minutes = -5
        elif idx == current_idx:
            if state.get("stationStatus") == "station":
                progress_pct = 100.0
                stop_minutes = 0
            else:
                progress_pct = 35.0
                stop_minutes = next_minutes
        else:
            # Spread future times between next and final stop.
            segment_count = max(1, len(state["stops"]) - current_idx - 1)
            segment_pos = idx - current_idx
            ratio = segment_pos / segment_count
            stop_minutes = int(next_minutes + (final_minutes - next_minutes) * ratio)
            progress_pct = 0.0

        stop_iso = iso_in(stop_minutes)
        out.append({
            "id": stop["id"],
            "label": stop["label"],
            "theoricDate": stop_iso,
            "realDate": stop_iso,
            "delay": 0,
            "progress": {
                "progressPercentage": progress_pct,
                "traveledDistance": 1000.0 * idx,
                "remainingDistance": 1000.0 * max(0, len(state["stops"]) - idx - 1),
            },
            "coordinates": {
                "latitude": 48.0 - idx,
                "longitude": 2.0 + idx,
            },
        })
    return out


def current_payloads():
    with STATE_LOCK:
        state = dict(STATE)
        stops = build_stops(state)

    gps = {
        "speed": int(state.get("speed", 0)) if state.get("stationStatus") != "station" else 0,
        "latitude": 47.0,
        "longitude": 3.0,
    }
    progress = {
        "trainId": str(state.get("trainId", "9812")),
        "number": str(state.get("trainNumber", "6201")),
        "delay": int(state.get("delayMins", 0)),
        "delayReason": state.get("delayCause", ""),
        "disruption": {"cause": state.get("delayCause", "")},
        "stops": stops,
    }
    bar = {
        "attendance": int(state.get("barAttendance", 0)),
    }
    stats = {
        "quality": int(state.get("wifiQuality", 3)),
        "devices": int(state.get("devices", 180)),
    }
    next_reset_minutes = max(0, int(state.get("nextResetMinutes", 95)))
    next_reset_ms = int((datetime.now(timezone.utc) + timedelta(minutes=next_reset_minutes)).timestamp() * 1000)
    status = {
        "consumed_data": max(0, int(state.get("consumedData", 12000))),
        "remaining_data": max(0, int(state.get("remainingData", 28000))),
        "next_reset": next_reset_ms,
    }
    return gps, progress, bar, stats, status


HTML = """<!doctype html>
<html lang=\"fr\">
<head>
  <meta charset=\"utf-8\" />
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
  <title>SNCF Demo Server</title>
  <style>
    body { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; margin: 24px; background: #f5f5f2; color: #1a1a1a; }
    .card { background: #fff; border: 1px solid #dcdad3; border-radius: 10px; padding: 16px; max-width: 760px; }
    h1 { margin-top: 0; }
    .grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
    label { display: block; font-size: 12px; margin-bottom: 4px; color: #444; }
    input, select { width: 100%; padding: 8px; border: 1px solid #c8c5bc; border-radius: 6px; box-sizing: border-box; }
    button { margin-top: 14px; padding: 10px 12px; border: 0; border-radius: 6px; background: #0f766e; color: white; cursor: pointer; }
    code { background: #eceae3; padding: 2px 4px; border-radius: 4px; }
  </style>
</head>
<body>
  <div class=\"card\">
    <h1>SNCF WiFi Demo Server</h1>
    <p>API locale: <code>http://127.0.0.1:8787/router/api/...</code></p>
    <div class=\"grid\">
      <div><label>Train ID (rame)</label><input id="trainId" /></div>
      <div><label>Numéro train</label><input id="trainNumber" /></div>
      <div><label>Statut</label><select id=\"stationStatus\"><option value=\"moving\">En mouvement</option><option value=\"station\">En gare</option></select></div>
      <div><label>Vitesse (km/h)</label><input id=\"speed\" type=\"number\" min=\"0\" max=\"360\" /></div>
      <div><label>Index gare courante (0..2)</label><input id=\"currentStationIndex\" type=\"number\" min=\"0\" max=\"2\" /></div>
      <div><label>Minutes prochaine gare</label><input id=\"minutesToNextStop\" type=\"number\" min=\"0\" max=\"120\" /></div>
      <div><label>Minutes gare finale</label><input id=\"minutesToFinalStop\" type=\"number\" min=\"0\" max=\"240\" /></div>
            <div><label>Qualite WiFi (1..5)</label><input id=\"wifiQuality\" type=\"number\" min=\"1\" max=\"5\" /></div>
            <div><label>Appareils connectes</label><input id=\"devices\" type=\"number\" min=\"0\" /></div>
            <div><label>Data consommee</label><input id=\"consumedData\" type=\"number\" min=\"0\" /></div>
            <div><label>Data restante</label><input id=\"remainingData\" type=\"number\" min=\"0\" /></div>
            <div><label>Reset dans (minutes)</label><input id=\"nextResetMinutes\" type=\"number\" min=\"0\" max=\"1440\" /></div>
      <div><label>File Bar (personnes, 0 = pas d'attente)</label><input id="barAttendance" type="number" min="0" /></div>
      <div><label>Retard (min)</label><input id="delayMins" type="number" min="0" /></div>
      <div><label>Cause du retard</label><input id="delayCause" /></div>
    </div>
    <button onclick=\"save()\">Appliquer</button>
    <p id=\"status\"></p>
  </div>
  <script>
    async function load() {
      const res = await fetch('/api/state');
      const s = await res.json();
      Object.keys(s).forEach((k) => {
        const el = document.getElementById(k);
        if (!el) return;
        el.value = String(s[k]);
      });
    }
    async function save() {
      const payload = {
        trainId: document.getElementById('trainId').value,
        trainNumber: document.getElementById('trainNumber').value,
        stationStatus: document.getElementById('stationStatus').value,
        speed: Number(document.getElementById('speed').value),
        currentStationIndex: Number(document.getElementById('currentStationIndex').value),
        minutesToNextStop: Number(document.getElementById('minutesToNextStop').value),
        minutesToFinalStop: Number(document.getElementById('minutesToFinalStop').value),
        wifiQuality: Number(document.getElementById('wifiQuality').value),
        devices: Number(document.getElementById('devices').value),
        consumedData: Number(document.getElementById('consumedData').value),
        remainingData: Number(document.getElementById('remainingData').value),
        nextResetMinutes: Number(document.getElementById('nextResetMinutes').value),
        barAttendance: Number(document.getElementById('barAttendance').value),
        delayMins: Number(document.getElementById('delayMins').value),
        delayCause: document.getElementById('delayCause').value,
      };
      const res = await fetch('/api/state', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify(payload) });
      document.getElementById('status').textContent = res.ok ? 'Etat mis a jour.' : 'Erreur de mise a jour.';
    }
    load();
  </script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def _json(self, status_code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _html(self, payload):
        body = payload.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path
        gps, progress, bar, stats, status = current_payloads()

        if path == "/":
            self._html(HTML)
            return
        if path == "/api/state":
            with STATE_LOCK:
                self._json(200, STATE)
            return
        if path == "/router/api/train/gps":
            self._json(200, gps)
            return
        if path in ("/router/api/train/progress", "/router/api/train/details"):
            self._json(200, progress)
            return
        if path == "/router/api/bar/attendance":
            self._json(200, bar)
            return
        if path == "/router/api/connection/statistics":
            self._json(200, stats)
            return
        if path == "/router/api/connection/status":
            self._json(200, status)
            return

        self._json(404, {"error": "not_found"})

    def do_POST(self):
        path = urlparse(self.path).path
        if path != "/api/state":
            self._json(404, {"error": "not_found"})
            return

        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8")) if raw else {}
        except json.JSONDecodeError:
            self._json(400, {"error": "invalid_json"})
            return

        with STATE_LOCK:
            for key in (
                "trainId", "speed", "wifiQuality", "devices", "consumedData", "remainingData", "nextResetMinutes", "barAttendance", "barQueueEmpty",
                "stationStatus", "currentStationIndex", "minutesToNextStop", "minutesToFinalStop"
            ):
                if key in payload:
                    STATE[key] = payload[key]

            if STATE.get("stationStatus") not in ("moving", "station"):
                STATE["stationStatus"] = "moving"

        self._json(200, {"ok": True})


if __name__ == "__main__":
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Demo server listening on http://{HOST}:{PORT}")
    server.serve_forever()
