import subprocess,pathlib,json,re,time,argparse,os
root=pathlib.Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--app', type=pathlib.Path, default=root/'.build/debug/Manping')
parser.add_argument('--out', type=pathlib.Path, default=pathlib.Path('/tmp/manping-shader-matrix'))
parser.add_argument('--evidence', type=pathlib.Path, default=root/'docs/evidence/shader-runtime-matrix.json')
parser.add_argument('--linear', action='store_true', help='Use production EDR target instead of forcing SDR')
args=parser.parse_args();out=args.out;out.mkdir(parents=True,exist_ok=True)
presets=['None']+[f'Anime4K/{level}{variant}' for level in ['Low','High'] for variant in ['A','B','C','AA','BB','CA']]+['ArtCNN/'+v for v in ['C4F16','C4F16_DN','C4F16_DS','C4F32','C4F32_DN','C4F32_DS','C4F32Ani4KI2','C4F32AniSDI4']]+['Ravu/'+v for v in ['lite-ar-r2','lite-ar-r3','lite-ar-r4','lite-r2','lite-r3','lite-r4']]+['nnedi3/'+v for v in ['Basic','Plus','Pro','ProMax']]
results=[]
for preset in presets:
 name=preset.replace('/','-');path=out/(name+'.json')
 cmd=[str(args.app),'--diagnose','/tmp/manping-static.mp4','--sdr','--seconds',('12' if preset.startswith('nnedi3') else '6'),'--report',str(path)]
 if args.linear:cmd.remove('--sdr')
 if preset!='None':cmd+=['--preset',preset]
 with open(out/(name+'.log'),'w') as log:
  t=time.monotonic();p=subprocess.run(cmd,stdout=log,stderr=log,timeout=90,env=dict(os.environ,PATH='/usr/bin:/bin:/usr/sbin:/sbin'))
 if path.exists():
  data=json.loads(path.read_text());r={'preset':preset,'exit':p.returncode,'elapsed':round(time.monotonic()-t,2),'render':data['render'],'error':data['error'],'hwdec':data['hwdec'],'time':data['time'],'metrics':data['metrics'],'shaderRequested':data['shaderRequested'],'shaderErrors':[x for x in data['shaderEvents'] if any(y in x.lower() for y in ['error','failed','status=0'])]}
 else:r={'preset':preset,'exit':p.returncode,'missingReport':True}
 results.append(r);print(json.dumps(r),flush=True)
 args.evidence.write_text(json.dumps(results,indent=2)+'\n')
