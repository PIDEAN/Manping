import subprocess, socket, json, time, pathlib, math
import numpy as np
root=pathlib.Path(__file__).resolve().parents[1]
out=pathlib.Path('/tmp/manping-golden');out.mkdir(exist_ok=True)
shaders=root/'Sources/ManpingApp/Resources/Shaders'
report=root/'docs/evidence/artcnn-golden-gpu-next.json'
results=json.loads(report.read_text()) if report.exists() else []
def render(name,folder):
 path=out/(folder+'-'+name+'.png');sock=out/'ipc.sock'
 sock.unlink(missing_ok=True)
 with open(out/(folder+'-'+name+'.log'),'w') as log:
  p=subprocess.Popen(['/opt/homebrew/bin/mpv','--no-config','--vo=gpu-next','--gpu-api=vulkan','--gpu-context=macvk','--hwdec=no','--pause','--keep-open=yes','--geometry=640x360','--hidpi-window-scale=no','--no-terminal','--target-colorspace-hint=no','--target-prim=bt.709','--target-trc=srgb','--target-peak=203','--dither-depth=no','--screenshot-format=png','--screenshot-high-bit-depth=yes','--glsl-shaders='+('' if name=='none' else str(shaders/folder/name)),'--input-ipc-server='+str(sock),'/tmp/manping-static.mp4'],stdout=log,stderr=log)
  try:
   for _ in range(200):
    if sock.exists(): break
    if p.poll() is not None: raise RuntimeError('mpv exited '+str(p.returncode))
    time.sleep(.05)
   s=socket.socket(socket.AF_UNIX);s.connect(str(sock));s.settimeout(60)
   time.sleep(1)
   s.sendall(json.dumps({'command':['screenshot-to-file',str(path),'window']}).encode()+b'\n')
   response=''
   while '"request_id"' not in response: response+=s.recv(65536).decode()
   assert '"error":"success"' in response,response
   s.sendall(b'{"command":["quit"]}\n');p.wait(timeout=10)
  finally:
   if p.poll() is None:p.terminate();p.wait()
 raw=subprocess.check_output(['/opt/homebrew/bin/ffmpeg','-v','error','-i',str(path),'-f','rawvideo','-pix_fmt','rgb48le','-'])
 return np.frombuffer(raw,dtype='<u2').reshape(360,640,3).astype(np.float64)/65535
import sys
selected = set(sys.argv[1:])
for name in sorted(p.name for p in (shaders/'ArtCNN').glob('*.glsl') if not selected or p.name in selected):
 original=render(name,'ArtCNN');compat=render(name,'ArtCNNCompat'); delta=np.abs(original-compat)
 inner=delta[12:-12,12:-12]
 mse=np.mean(delta**2)
 result={'file':name,'size':list(delta.shape),'mae':float(np.mean(delta)),'max':float(np.max(delta)),'psnr':float(-10*math.log10(mse)) if mse else None,'interiorMAE':float(np.mean(inner)),'interiorMax':float(np.max(inner)),'changedFraction':float(np.mean(np.any(delta>0,axis=2)))}
 results=[r for r in results if r["file"]!=name]; results.append(result);print(json.dumps(result),flush=True)
 (root/'docs/evidence/artcnn-golden-gpu-next.json').write_text(json.dumps(results,indent=2)+'\n')
