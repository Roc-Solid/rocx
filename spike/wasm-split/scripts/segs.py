# Data segments: an object's (names from linking WASM_SEGMENT_INFO) vs a final module's (name section, subsection 9).
import sys
def leb(b,i):
    r=s=0
    while True:
        x=b[i];i+=1;r|=(x&0x7f)<<s;s+=7
        if x<0x80:return r,i
def name(b,i):
    n,i=leb(b,i);return b[i:i+n].decode(errors='replace'),i+n
def info(path):
    d=open(path,'rb').read();i=8;segs=[];names={};objnames=[]
    while i<len(d):
        sid=d[i];i+=1;size,i=leb(d,i);end=i+size
        if sid==11:
            n,j=leb(d,i)
            for _ in range(n):
                fl,j=leb(d,j);off=None
                if fl in (0,2):
                    if fl==2:_,j=leb(d,j)
                    assert d[j]==0x41; off,j=leb(d,j+1); assert d[j]==0x0b; j+=1
                sz,j=leb(d,j);segs.append((off,sz));j+=sz
        if sid==0:
            nm,j=name(d,i)
            if nm=='name':
                while j<end:
                    sub=d[j];j+=1;ss,j=leb(d,j);se=j+ss
                    if sub==9:
                        n,k=leb(d,j)
                        for _ in range(n):
                            idx,k=leb(d,k);nm2,k=name(d,k);names[idx]=nm2
                    j=se
            if nm=='linking':
                _,j=leb(d,j)
                while j<end:
                    kind=d[j];j+=1;ss,j=leb(d,j);se=j+ss
                    if kind==5:
                        n,k=leb(d,j)
                        for _ in range(n):
                            nm2,k=name(d,k);_,k=leb(d,k);_,k=leb(d,k);objnames.append(nm2)
                    j=se
        i=end
    return segs,names,objnames
for p in sys.argv[1:]:
    segs,names,objnames=info(p)
    print(p.split('/')[-1],'segments',len(segs),'named(final)',len(names),'named(object)',len(objnames))
    print('  first:',[(names.get(i) or (objnames[i] if i<len(objnames) else None),segs[i]) for i in range(min(4,len(segs)))])
