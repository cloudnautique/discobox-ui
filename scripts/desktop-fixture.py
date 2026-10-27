#!/usr/bin/env python3
"""Offline WebKit clipboard fixture. Prints its ephemeral loopback URL."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PAGE = b'<html><body><h1>Offline desktop fixture</h1><script type="module" src="/app.js"></script></body></html>'
SCRIPT = b'''window.fixture = { pasted: null, keys: [] };
const rfb = new EventTarget();
rfb.clipboardPasteFrom = text => { window.fixture.pasted = text; };
rfb.sendKey = (...args) => {
  window.fixture.keys.push(args);
  if (args[0] === 99) rfb.dispatchEvent(new CustomEvent('clipboard', {detail:{text:'Remote caf\\u00e9\\nsecond line'}}));
};
const state = {rfb, connected:true};
'''
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ('/', '/app.js'):
            self.send_error(404)
            return
        content = SCRIPT if self.path == '/app.js' else PAGE
        self.send_response(200)
        self.send_header('Content-Type', 'text/javascript' if self.path == '/app.js' else 'text/html')
        self.send_header('Content-Length', str(len(content)))
        self.end_headers()
        self.wfile.write(content)
    def log_message(self, *args):
        pass
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print('http://127.0.0.1:' + str(server.server_port), flush=True)
server.serve_forever()
