import sys,struct
src,dst,w,h=sys.argv[1],sys.argv[2],int(sys.argv[3]),int(sys.argv[4])
d=bytearray(open(src,'rb').read())
i=d.find(b'ispe')
if i<0: print("no ispe"); sys.exit(1)
# ispe: 'ispe'(4) version+flags(4) width(4) height(4)
struct.pack_into('>II', d, i+8, w, h)
open(dst,'wb').write(d)
print("ispe at",i,"set",w,h)
