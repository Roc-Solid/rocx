# Function names (name section) and code sizes of a wasm module, as JSON: {name: bytes}.
import sys, json
def leb(b,i):
    r=s=0
    while True:
        x=b[i];i+=1;r|=(x&0x7f)<<s;s+=7
        if x<0x80:return r,i
def funcs(path):
    d=open(path,'rb').read(); i=8; imports=0; names={}; sizes=[]
    while i<len(d):
        sid=d[i];i+=1;size,i=leb(d,i);end=i+size
        if sid==2:
            n,j=leb(d,i)
            for _ in range(n):
                l,j=leb(d,j);j+=l;l,j=leb(d,j);j+=l;kind=d[j];j+=1
                if kind==0: _,j=leb(d,j); imports+=1
                elif kind==1: j+=1; fl,j=leb(d,j); _,j=leb(d,j); j = leb(d,j)[1] if fl&1 else j
                elif kind==2: fl,j=leb(d,j); _,j=leb(d,j); j = leb(d,j)[1] if fl&1 else j
                elif kind==3: j+=2
        elif sid==10:
            n,j=leb(d,i)
            for _ in range(n):
                s,j=leb(d,j); sizes.append(s); j+=s
        elif sid==0:
            l,j=leb(d,i); nm=d[j:j+l].decode(); j+=l
            if nm=='name':
                while j<end:
                    sub=d[j];j+=1; ss,j=leb(d,j); se=j+ss
                    if sub==1:
                        n,k=leb(d,j)
                        for _ in range(n):
                            idx,k=leb(d,k); l,k=leb(d,k); names[idx]=d[k:k+l].decode(errors='replace'); k+=l
                    j=se
        i=end
    out={}
    for k,s in enumerate(sizes):
        nm=names.get(imports+k, f"#{imports+k}")
        out[nm]=out.get(nm,0)+s
    return out
print(json.dumps(funcs(sys.argv[1])))
