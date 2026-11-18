#!/usr/bin/env python3
"""Linux contract checks for the actual Swift client against a fixture HTTP bridge."""
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]

class Bridge(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, body, code=200):
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def do_GET(self):
        if self.headers.get('X-Bridge-Token') != 'contract-token':
            return self.reply({'detail': 'bad token'}, 401)
        if self.path == '/health':
            return self.reply({'ok': True})
        if self.path == '/scan/ble?seconds=8':
            return self.reply({'devices': [{'addr': 'AA:BB:CC:DD:EE:FF', 'name': 'Fixture', 'rssi': -60}]})
        if self.path == '/buds/status':
            return self.reply({'parsed': {'battery': {'left': {'percent': 82, 'state': 'not charging'}, 'case': {'percent': 50, 'state': 'charging'}}, 'anc': 'active', 'eq': [0, 1, -2, 3, 4], 'software': {'left': {'version': '1.2', 'build': 3}}, 'gesture_control': {'left': 'anc'}, 'multipoint': True}, 'raw': {'ohd': {'rc': 0, 'stdout': 'true\n', 'stderr': ''}}})
        if self.path == '/ble/AA:BB:CC:DD:EE:FF/gatt':
            return self.reply({'services': [{'uuid': 'abc', 'handle': 1, 'characteristics': [{'uuid': 'def', 'handle': 5, 'properties': ['read', 'write-without-response', 'notify'], 'description': 'Fixture'}]}]})
        if self.path == '/notifications?since=4':
            return self.reply({'notifications': [{'seq': 5, 'addr': 'AA:BB:CC:DD:EE:FF', 'char': '5', 'hex': '01ff'}]})
        self.reply({'detail': 'unexpected path'}, 404)

    def do_POST(self):
        if self.headers.get('X-Bridge-Token') != 'contract-token':
            return self.reply({'detail': 'bad token'}, 401)
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if self.path == '/ble/connect' and body == {'addr': 'AA:BB:CC:DD:EE:FF'}:
            return self.reply({'connected': True})
        if self.path == '/ble/write' and body == {'addr': 'AA:BB:CC:DD:EE:FF', 'char': 5, 'hex': '01 ff', 'response': False}:
            return self.reply({'detail': 'device not trusted'}, 403)
        self.reply({'detail': 'unexpected request'}, 400)

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Bridge)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory() as directory:
        binary = Path(directory) / 'bridge-contract'
        subprocess.run(['swiftc', '-swift-version', '5', str(ROOT / 'App/Bridge.swift'), str(ROOT / 'Tests/BridgeContract.swift'), '-o', str(binary)], check=True)
        subprocess.run([str(binary), f'http://127.0.0.1:{server.server_port}'], check=True, timeout=30)
finally:
    server.shutdown()
