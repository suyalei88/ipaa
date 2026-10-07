#!/usr/bin/env python3
"""Walk instance + class (metaclass) method lists of an ObjC class."""
import sys, struct
sys.path.insert(0, "client")
from macho_util import Image

def parse_methods(im, ml):
    if not ml: return []
    ef = im.u32(ml); cnt = im.u32(ml+4)
    if ef is None or cnt is None or cnt > 20000: return []
    entsize = ef & 0x0000FFFC or 12
    relative = bool(ef & 0x80000000)
    out=[]; p=ml+8
    for _ in range(cnt):
        if relative:
            noff=struct.unpack("<i", im.read(p,4))[0]
            ioff=struct.unpack("<i", im.read(p+8,4))[0]
            naddr=p+noff
            nm=im.cstr(im.deref(naddr)) or im.cstr(naddr)
            out.append((nm, p+8+(ioff & ~1)))
        else:
            nm=im.cstr(im.deref(p)); out.append((nm, im.deref(p+16)))
        p+=entsize
    return out

def dump(im, cls, tag):
    d=im.deref(cls+32)
    if not d: return
    nm=im.cstr(im.deref(d+24))
    ms=parse_methods(im, im.deref(d+32))
    print(f"=== {tag} {nm} @{hex(cls)}  ({len(ms)} methods)")
    for n,i in ms: print(f"   {hex(i) if i else '?'}  {n}")

if __name__=="__main__":
    im=Image(sys.argv[1])
    cls=int(sys.argv[2],0)
    dump(im, cls, "INSTANCE")
    meta=im.deref(cls)
    if meta: dump(im, meta, "CLASS(meta)")
