import struct

class MachO:
    def __init__(self, path):
        self.path=path
        self.f=open(path,"rb")
        self.data_head=self.f.read(0x200000)  # 2MB of headers+sections tables
        magic=struct.unpack_from("<I",self.data_head,0)[0]
        assert magic==0xfeedfacf
        _,self.cputype,self.cpusub,self.ftype,self.ncmds,self.sizeofcmds,self.flags=struct.unpack_from("<IiiIIII",self.data_head,0)
        self.segs=[]      # (name, vmaddr, vmsize, fileoff, filesize, segidx)
        self.secs=[]      # (segname, secname, addr, size, offset)
        off=32
        self.chained=None
        for _ in range(self.ncmds):
            cmd,sz=struct.unpack_from("<II",self.data_head,off)
            base=cmd & 0x7fffffff
            if base==0x19: # SEGMENT_64
                segname=self.data_head[off+8:off+24].split(b"\x00")[0].decode()
                vmaddr,vmsize,fileoff,filesize=struct.unpack_from("<QQQQ",self.data_head,off+24)
                maxprot,initprot,nsects,flags=struct.unpack_from("<IIII",self.data_head,off+56)
                self.segs.append(dict(name=segname,vmaddr=vmaddr,vmsize=vmsize,fileoff=fileoff,filesize=filesize,nsects=nsects))
                so=off+72
                for _s in range(nsects):
                    sname=self.data_head[so:so+16].split(b"\x00")[0].decode()
                    sseg=self.data_head[so+16:so+32].split(b"\x00")[0].decode()
                    addr,size=struct.unpack_from("<QQ",self.data_head,so+32)
                    offset,align,reloff,nreloc,flags2=struct.unpack_from("<IIIII",self.data_head,so+48)
                    self.secs.append(dict(seg=sseg,name=sname,addr=addr,size=size,offset=offset))
                    so+=80
            elif base==0x33: # DYLD_CHAINED_FIXUPS
                doff,dsize=struct.unpack_from("<II",self.data_head,off+8)
                self.chained=(doff,dsize)
            off+=sz
        self.image_base=self.segs[0]["vmaddr"]

    def read(self, off, n):
        self.f.seek(off); return self.f.read(n)

    def vm2off(self, vm):
        for s in self.segs:
            if s["vmaddr"]<=vm<s["vmaddr"]+s["vmsize"]:
                return s["fileoff"]+(vm-s["vmaddr"])
        return None

    def find_section(self, name):
        for s in self.secs:
            if s["name"]==name: return s
        return None

    def decode_chained(self):
        """Return dict fileoff_of_slot -> target_vmaddr (for rebase ptrs)"""
        doff,dsize=self.chained
        blob=self.read(doff,dsize)
        (ver,starts_off,imports_off,symbols_off,imports_count,imports_format,symbols_format)=struct.unpack_from("<IIIIIII",blob,0)
        seg_count=struct.unpack_from("<I",blob,starts_off)[0]
        res={}
        p=starts_off+4
        for _ in range(seg_count):
            size,page_size,pointer_format,segment_offset,max_valid_pointer,page_count=struct.unpack_from("<IIQIIH",blob,p)
            p+=22
            page_starts=struct.unpack_from("<%dH"%page_count,blob,p); p+=2*page_count
            for pi,ps in enumerate(page_starts):
                if ps==0xFFFF: continue
                chain_off=segment_offset+pi*page_size+ps
                while True:
                    slot_fileoff=self.vm2off(chain_off) if False else None
                    # chain_off is a file offset within the image
                    raw=struct.unpack_from("<Q",blob if False else None,0) if False else None
                    # read raw pointer from the actual file at chain_off
                    self.f.seek(chain_off); raw=struct.unpack("<Q",self.f.read(8))[0]
                    if pointer_format in (2,6):  # PTR_64 / PTR_64_KERNEL_CACHE
                        is_bind=(raw>>63)&1
                        nxt=(raw>>51)&0x7FF
                        tgt=raw & 0xFFFFFFFFF
                        tgt_vm = tgt + (0 if pointer_format==2 else self.image_base)
                    elif pointer_format==4:  # PTR_64_OFFSET
                        is_bind=(raw>>63)&1
                        nxt=(raw>>51)&0x7FF
                        tgt=raw & 0xFFFFFFFFF
                        tgt_vm=tgt+self.image_base
                    elif pointer_format==1:  # ARM64E
                        is_bind=(raw>>62)&1
                        nxt=(raw>>51)&0x7FF
                        tgt=raw & 0xFFFFFFFFF
                        tgt_vm=tgt
                    else:
                        break
                    if not is_bind:
                        res[chain_off]=tgt_vm
                    if nxt==0: break
                    chain_off+=nxt*4
        return res, pointer_format if False else None

    def find_ptr_to(self, vm, fixmap):
        out=[]
        for slot,tgt in fixmap.items():
            if tgt==vm: out.append(slot)
        return out
