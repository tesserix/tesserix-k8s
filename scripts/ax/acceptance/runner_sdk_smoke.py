import asyncio, json, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
seen=[]
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_POST(self):
        seen.append(self.path)
        self.rfile.read(int(self.headers.get('Content-Length',0)))
        payload=json.dumps({'candidates':[{'content':{'role':'model','parts':[{'text':'AX_SDK_OK'}]},'finishReason':'STOP'}],'usageMetadata':{'promptTokenCount':1,'candidatesTokenCount':1,'totalTokenCount':2}})
        self.send_response(200)
        if 'alt=sse' in self.path:
            self.send_header('Content-Type','text/event-stream');self.end_headers();self.wfile.write(('data: '+payload+'\n\n').encode())
        else:
            self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(payload.encode())
server=HTTPServer(('127.0.0.1',18888),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
import importlib.util, os
os.makedirs('/tmp/workspace', exist_ok=True)
os.environ.update({'AX_MODEL_GATEWAY_URL':'http://127.0.0.1:18888/vertex','AX_MODEL_NAME':'gemini-2.5-flash','AX_VERTEX_PROJECT':'test-project','AX_VERTEX_LOCATION':'global'})
spec=importlib.util.spec_from_file_location('bootstrap','/usr/local/bin/antigravity_bootstrap.py')
bootstrap=importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)
asyncio.run(asyncio.wait_for(bootstrap.run_bootstrap('Reply AX_SDK_OK without using tools','/tmp/workspace','/tmp/state'),90))
assert seen and all('/projects/test-project/locations/global/' in path for path in seen),seen
print('AX_SDK_OK: native Vertex requests and response verified',seen)
