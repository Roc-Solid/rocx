import sys, json, subprocess, os
d=sys.argv[1]; py=sys.argv[2]
def load(n): return json.loads(subprocess.check_output(['python3','-I',py,f'{d}/{n}.wasm']))
allf=load('all'); core=load('core')
print('functions: all',len(allf),'core',len(core),'core not in all',len(set(core)-set(allf)))
pages=[f[6:-5] for f in os.listdir(d) if f.startswith('minus-') and f.endswith('.wasm')]
excl={}; union=set()
for p in sorted(pages):
    m=load('minus-'+p); e=set(allf)-set(m); excl[p]=e; union|=e
    if e: print(f'{p}\t{len(e)} fns\t{sum(allf[x] for x in e)} code bytes\t(minus-build has {len(set(m)-set(allf))} names all lacks)')
shared=set(allf)-set(core)-union
print('shared-among-pages',len(shared),'fns',sum(allf[x] for x in shared),'bytes; core fns in all',len(set(core)&set(allf)),sum(allf[x] for x in set(core)&set(allf)),'bytes')
with open(f'{d}/manifest.txt','w') as f:
    blocks=[]
    for p in sorted(excl):
        if excl[p]: blocks.append(p+'\n'+'\n'.join(sorted(excl[p])))
    if shared: blocks.append('SharedPages\n'+'\n'.join(sorted(shared)))
    f.write('\n\n'.join(blocks)+'\n')
