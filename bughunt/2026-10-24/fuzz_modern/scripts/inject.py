import sys, struct, zlib
def jpeg(src, icc, dst):
    d = open(src,'rb').read(); assert d[:2]==b'\xff\xd8'
    segs=b''; chunk=65519; parts=[icc[i:i+chunk] for i in range(0,len(icc),chunk)] or [b'']
    for i,p in enumerate(parts):
        body=b'ICC_PROFILE\0'+bytes([i+1,len(parts)])+p
        segs+=b'\xff\xe2'+struct.pack('>H',len(body)+2)+body
    open(dst,'wb').write(d[:2]+segs+d[2:])
def png(src, icc, dst, extra=b''):
    d=open(src,'rb').read(); out=d[:8]; i=8
    def ch(t,b): return struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b)&0xffffffff)
    while i<len(d):
        n,=struct.unpack('>I',d[i:i+4]); t=d[i+4:i+8]; c=d[i:i+12+n]; i+=12+n
        if t in (b'iCCP',b'sRGB',b'gAMA',b'cHRM',b'cICP'): continue
        out+=c
        if t==b'IHDR':
            if icc is not None: out+=ch(b'iCCP', b'x\0\0'+zlib.compress(icc))
            out+=extra
    open(dst,'wb').write(out)
if __name__=='__main__':
    kind,src,iccf,dst=sys.argv[1:5]
    icc=open(iccf,'rb').read() if iccf!='-' else None
    {'jpeg':jpeg,'png':png}[kind](src,icc,dst)
