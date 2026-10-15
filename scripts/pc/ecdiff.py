import re, sys, glob, os
CAP = r"H:\steamdeck\captures"
row = re.compile(r"^([0-9a-f]{3}): ((?:[0-9a-f]{2} ?){1,16})\s*$")

def parse(path, which="last"):
    """Return dict offset->byte for the MMIO page dump in a capture file.
    which: 'last' = the final full dump in the file (+45 s snapshot)."""
    blocks = []
    cur = None
    for line in open(path, encoding="utf-8", errors="replace"):
        if line.startswith("--- page 0x100"):
            cur = {}
            blocks.append(cur)
        m = row.match(line.strip()) if cur is not None else None
        if m:
            base = int(m.group(1), 16)
            for i, b in enumerate(m.group(2).split()):
                cur[base + i] = int(b, 16)
    if not blocks:
        return None
    return blocks[-1] if which == "last" else blocks[0]

fail_files = ["ec-mmio-faulted-19-45.txt", "long-plugged-capture.txt"]
pass_files = ["ec-mmio-healthy-19-50.txt", "quick2-capture.txt", "long-charging-capture.txt",
              "long-unplugged-capture.txt", "repro-plugged-limit60-b-capture.txt",
              "repro-plugged-game-capture.txt", "test9-plugged-soak-capture.txt"]
fails = {f: parse(os.path.join(CAP, f)) for f in fail_files}
passes = {f: parse(os.path.join(CAP, f)) for f in pass_files}
for k, v in list(fails.items()) + list(passes.items()):
    print(f"{'FAIL' if k in fails else 'PASS'} {k}: {'no dump' if v is None else str(len(v)) + ' nonzero-row bytes'}")
fails = {k: v for k, v in fails.items() if v}
passes = {k: v for k, v in passes.items() if v}

all_offs = set()
for d in list(fails.values()) + list(passes.values()):
    all_offs |= set(d.keys())

print("\n=== offsets where ALL failing dumps agree on a value that NO passing dump has ===")
for off in sorted(all_offs):
    fv = {d.get(off, 0) for d in fails.values()}
    pv = {d.get(off, 0) for d in passes.values()}
    if len(fv) == 1 and not (fv & pv):
        print(f"0x{off:03x}: fail={fv.pop():02x}  pass={','.join(f'{x:02x}' for x in sorted(pv))}")

print("\n=== offsets where every PASSING dump agrees and the failing dumps differ from it ===")
for off in sorted(all_offs):
    fv = {d.get(off, 0) for d in fails.values()}
    pv = {d.get(off, 0) for d in passes.values()}
    if len(pv) == 1 and not (fv & pv):
        print(f"0x{off:03x}: pass={pv.pop():02x}  fail={','.join(f'{x:02x}' for x in sorted(fv))}")
