import mmap, os, time, sys
BASE=0xFE700000
fd=os.open("/dev/mem", os.O_RDONLY|os.O_SYNC)
m=mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=BASE)
def rd(): return m[:]
def hx(b,a,n): return " ".join("%02x"%b[a+i] for i in range(n))
H="/sys/class/hwmon/hwmon3/"
def sf(p):
    try: return open(p).read().strip()
    except Exception: return "?"
dur=float(sys.argv[1]) if len(sys.argv)>1 else 5.0
t0=time.time()
print("t(ms) | fan_in fault | 32E 39F 3B0-1 | 403-405 | 38C-38D MCUR(383-4) | B92-3 | BAT status/cur")
while time.time()-t0 < dur:
    b=rd()
    print("%5d | %5s %s | %02x %02x %s | %s | %s %s | %s | %s/%s" % (
        (time.time()-t0)*1000, sf(H+"fan1_input"), sf(H+"fan1_fault"),
        b[0x32E], b[0x39F], hx(b,0x3B0,2), hx(b,0x403,3), hx(b,0x38C,2), hx(b,0x383,2), hx(b,0xB92,2),
        sf("/sys/class/power_supply/BAT1/status"), sf("/sys/class/power_supply/BAT1/current_now")))
    time.sleep(0.2)
