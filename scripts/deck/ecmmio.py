import mmap, os, sys, struct
BASE=0xFE700000
fd=os.open("/dev/mem", os.O_RDONLY|os.O_SYNC)
m=mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=BASE)
b=m[:]
def at(o): return b[o]
print("FNCK(0x39F)=%d  CTMP(0x186)=%d C  FNRL/FNRH(0x3B0/1)=%d rpm  FSLO/FSHI(0xB92/3)=%d  CRLO/CRHI(0xB90/1)=%d  CPUT=%d GN=%d FRPR=%d HYST=%d" % (
  at(0x39F)&1, at(0x186), at(0x3B0)|(at(0x3B1)<<8), at(0xB92)|(at(0xB93)<<8), at(0xB90)|(at(0xB91)<<8), at(0xB94), at(0xB95)|(at(0xB96)<<8), at(0xB97), at(0xB98)))
print("byte 0x39F raw = 0x%02x ; 0x3A8 raw = 0x%02x" % (at(0x39F), at(0x3A8)))
for page in (0x100,0x300,0x400,0x800,0xA00,0xB00,0xC00,0xD00):
    print("--- page 0x%03x" % page)
    for row in range(0,0x100,16):
        chunk=b[page+row:page+row+16]
        if any(chunk): print("%03x: %s" % (page+row, " ".join("%02x"%x for x in chunk)))
