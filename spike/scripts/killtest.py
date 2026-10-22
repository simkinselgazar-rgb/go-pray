#!/usr/bin/env python3
# kill -9 the agent, measure time until launchd has a new pid for it
import subprocess, time, sys
def pid():
    out = subprocess.run(["launchctl","list"],capture_output=True,text=True).stdout
    for l in out.splitlines():
        p = l.split("\t")
        if len(p)==3 and p[2]=="com.gopray.spike.agent": return None if p[0]=="-" else int(p[0])
    return None
old = pid(); print("pid before:", old, flush=True)
t=time.time(); subprocess.run(["kill","-9",str(old)])
new=None
while time.time()-t < 40:
    n = pid()
    if n and n != old: new=n; break
    time.sleep(0.02)
print(f"new pid {new} after {time.time()-t:.3f} s (kill -9 of {old})")
