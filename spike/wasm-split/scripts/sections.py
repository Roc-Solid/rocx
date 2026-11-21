import sys
data=open(sys.argv[1],'rb').read()
def leb(b,i):
    r=s=0
    while True:
        x=b[i];i+=1;r|=(x&0x7f)<<s;s+=7
        if x<0x80:return r,i
i=8;names={0:'custom',1:'type',2:'import',3:'func',4:'table',5:'memory',6:'global',7:'export',8:'start',9:'elem',10:'code',11:'data',12:'datacount'}
while i<len(data):
    sid=data[i];i+=1;size,i=leb(data,i)
    extra=''
    if sid==0:
        n,j=leb(data,i);extra=data[j:j+n].decode(errors='replace')
    print(names.get(sid,sid),extra,size)
    i+=size
