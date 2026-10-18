#!/usr/bin/env python3
"""Re-export fixed ArtCNN weights with its official fragment generator; no ML dependency.
Generator: Artoriuz/ArtCNN 8789539dfae120f2877a89bb6218026d56809612,
Notebooks/ArtCNN_C_Keras.ipynb cell 7. Original MIT headers remain in every shader.
"""
from pathlib import Path
from types import SimpleNamespace
import re, ast, math, hashlib, json
ROOT = Path(__file__).resolve().parents[1]
HASHES = {
'ArtCNN_C4F16.glsl':'03d0b3d31cb82c898a94a46663021a3e8f02c5a21d69c5cfdf0208de4bfd453e',
'ArtCNN_C4F16_DN.glsl':'047f33cd43ca3751b00c7c81206e076ac921c1fbc06d49f23010a0b428271acf',
'ArtCNN_C4F16_DS.glsl':'57df650fddec3969e17799f5522c9b03dd2d33b1aeace237fef216bf3858125a',
'ArtCNN_C4F32.glsl':'f773bce6cf5fe7e5e5d599a695edd40df5cd7a20c3d08c4d164d07591d5bead3',
'ArtCNN_C4F32_DN.glsl':'6b51a6f7d75826c9492c3f78b5e60acffa24a71928e2d47c4a329423922a143c',
'ArtCNN_C4F32_DS.glsl':'a04c9cba6fbb8e6db9239d61848390208aedf8e348ef116e12174c803d22077e'}
class Flat:
 def __init__(self,v): self.v=v
 def flatten(self): return self.v
class Bias:
 def __init__(self,d): self.d=d
 def __getitem__(self,s): return Flat([v for p in range(s.start//4,s.stop//4) for v in self.d[p]])
class Kernel:
 def __init__(self,d): self.d=d
 def __getitem__(self,key):
  y,x,z,p=key
  assert z.stop-z.start==4 and p.stop-p.start==4
  return Flat(self.d[(p.start//4,z.start//4,y,x)])
class Layer:
 def __init__(self,name,b=None,w=None): self.name=name; self.b=b; self.w=w
 def get_weights(self): return Kernel(self.w),Bias(self.b)
def zero_padding(output):
 blocks=[]
 for block in output.split('//!DESC'):
  if 'Conv' in block:
   names=sorted(set(re.findall(r'(\w+)_texOff\(',block)))
   for name in names: block=block.replace(name+'_texOff(',name+'_zeroTexOff(')
   functions = 'vec2 artcnnTextureSize(sampler2D tex) { return vec2(textureSize(tex, 0)); }\n'
   functions += 'vec2 artcnnTextureSize(sampler2DRect tex) { return vec2(textureSize(tex)); }\n'
   for name in names:
    functions += f'vec4 {name}_zeroTexOff(vec2 offset) {{ vec2 p={name}_pos+{name}_rot*offset/{name}_size; vec2 upper=artcnnTextureSize({name}_raw)*{name}_pt; if(any(lessThan(p,vec2(0.0)))||any(greaterThanEqual(p,upper))) return vec4(0.0); return {name}_texOff(offset); }}\n'
   block=block.replace('vec4 hook() {',functions+'\nvec4 hook() {')
  blocks.append(block)
 return '//!DESC'.join(blocks)
def main():
 src=(ROOT/'scripts/vendor/artcnn_fragment_generator.py').read_text()
 assert hashlib.sha256(src.encode()).hexdigest()=='3ca2b6fe4210571ffc9462f3095bd6a22ba112f8bf45074c6b2510e3adfb617f'
 ns={'np':SimpleNamespace(ceil=math.ceil)}
 exec(compile(ast.parse(src),'<official-fragment-generator>','exec'),ns)
 root=ROOT/'Sources/ManpingApp/Resources/Shaders'
 destination=root/'ArtCNNCompat'; destination.mkdir(exist_ok=True)
 reports=[]
 for filename,digest in HASHES.items():
  f=root/'ArtCNN'/filename; data=f.read_bytes()
  assert hashlib.sha256(data).hexdigest()==digest
  s=data.decode(); count=16 if 'C4F16' in f.name else 32
  source={}; output=''; previous=Layer('input_layer'); layers={}
  for block in s.split('//!DESC')[1:]:
   m=re.search(r'//!SAVE (conv2d(?:_\d+)?)\n',block)
   if not m: continue
   name=m.group(1); bias={}; weights={}
   for p,v in re.findall(r'V4 result(\d+) = V4\(([^)]+)\);',block):
    vals=tuple(x.strip() for x in v.split(',')); bias[int(p)]=vals; source[(name,'b',int(p))]=vals
   for p,v,z,x,y in re.findall(r'result(\d+) \+= (?:V4|M4)\(([^)]+)\) \* inp_(\d+)_(\d+)_(\d+);',block):
    vals=tuple(t.strip() for t in v.split(',')); key=(int(p),int(z),int(y),int(x)); weights[key]=vals; source[(name,'w')+key]=vals
   layer=Layer(name,bias,weights); layers[name]=layer
   if name=='conv2d': channels_in=1; channels_out=count
   elif name=='conv2d_6': channels_in=count; channels_out=4; previous=Layer('add')
   else: channels_in=count; channels_out=count
   ns['filters']=count
   output+=ns['generate_shader_code'](layer,previous,channels_in,channels_out)
   previous=layer
  output+=ns['generate_shader_code'](Layer('depth_to_space'),layers['conv2d_6'],4,1)
  actual={}
  for block in output.split('//!DESC')[1:]:
   m=re.search(r'//!SAVE (conv2d(?:_\d+)?)_(\d+)\n',block)
   if not m: continue
   name,p=m.group(1),int(m.group(2))
   v=re.search(r'vec4 result = vec4\(([^)]+)\);',block).group(1)
   actual[(name,'b',p)]=tuple(x.strip() for x in v.split(','))
   for v,tail in re.findall(r'result \+= (?:vec4|mat4)\(([^)]+)\) \* ([^;]+);',block):
    x,y=map(int,re.search(r'vec2\((-?\d+), (-?\d+)\)',tail).groups())
    zm=re.search(r'conv2d(?:_[1-6])?_(\d+)_texOff',tail)
    z=int(zm.group(1)) if zm else 0
    actual[(name,'w',p,z,y+1,x+1)]=tuple(t.strip() for t in v.split(','))
  assert source==actual,(f.name,len(source),len(actual))
  # LUMA replaces one plane. gpu-next tolerates four components here, but
  # mpv gpu combines LUMA + CHROMA and asserts if the sum exceeds four.
  tail=output.rindex('//!DESC')
  output=output[:tail]+output[tail:].replace('//!COMPONENTS 4','//!COMPONENTS 1')
  output=zero_padding(output)
  header=s[:s.index('//!DESC')]
  output=header+'// Generated by scripts/generate_artcnn.py; original weights preserved.\n'+output
  (destination/f.name).write_text(output)
  reports.append({'file':f.name,'passes':output.count('//!HOOK'),'tokens':sum(map(len,source.values())),'tensorTokensEqual':source==actual,'sourceSHA256':digest,'tensorTokenSHA256':hashlib.sha256(json.dumps(sorted(source.items()),separators=(',',':')).encode()).hexdigest(),'boundary':'explicit zero padding (matches measured macvk compute OOB)','sha256':hashlib.sha256(output.encode()).hexdigest()})
 for f in sorted((root/'ArtCNN').glob('Ani*.glsl')):
  original=f.read_text(); tail=original.rindex('//!DESC')
  output=original[:tail]+original[tail:].replace('//!COMPONENTS 4','//!COMPONENTS 1')
  assert original != output and original.count('//!COMPONENTS 4')-output.count('//!COMPONENTS 4')==1
  (destination/f.name).write_text(output)
  reports.append({'file':f.name,'change':'final LUMA COMPONENTS 4 -> 1 only','sha256':hashlib.sha256(output.encode()).hexdigest()})
 print(json.dumps(reports,indent=2))
if __name__=='__main__': main()
