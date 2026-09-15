import math
N = 256

def write_cal(path, r, note):
    lines = ["CAL","",f'ORIGINATOR "{note}"','DEVICE_CLASS "DISPLAY"','COLOR_REP "RGB"',"",
             "NUMBER_OF_FIELDS 4","BEGIN_DATA_FORMAT","RGB_I RGB_R RGB_G RGB_B","END_DATA_FORMAT","",
             f"NUMBER_OF_SETS {N}","BEGIN_DATA"]
    for i,v in enumerate(r):
        lines.append(f"{i/(N-1):.10f}\t{v:.10f}\t{v:.10f}\t{v:.10f}")
    lines += ["END_DATA",""]
    open(path,"w").write("\n".join(lines))

# --- identity (native gamma 2.2, bright room) ---
ident = [i/(N-1) for i in range(N)]
write_cal("sdr-2.2-neutral.cal", ident, "identity")

# --- BT.1886 for a 2000:1 panel driven by a native gamma 2.2 display ---
Lb = 1/2000.0
g_disp = 2.2
inv = lambda x: x**(1/2.4)
b = inv(Lb) / (inv(1.0) - inv(Lb))
a = (inv(1.0) - inv(Lb))**2.4

def bt1886(V):
    return a*(V + b)**2.4

r1886 = []
for i in range(N):
    V = i/(N-1)
    Lt = bt1886(V)
    x = (Lt - Lb)/(1.0 - Lb)
    x = max(0.0, min(1.0, x))
    r1886.append(x**(1/g_disp))
write_cal("sdr-bt1886-dark.cal", r1886, "bt1886")

# --- plain power 2.4 for comparison ---
r24 = [(i/(N-1))**(2.4/2.2) for i in range(N)]
write_cal("sdr-2.4-power.cal", r24, "gamma2.4")

def show(name, r):
    pts = [2,5,10,20,40,64,128,192,230,255]
    print(name, " ".join(f"{p}->{r[p]*255:.1f}" for p in pts))
show("ident  ", ident); show("bt1886 ", r1886); show("pow2.4 ", r24)
print("b=%.5f a=%.5f  black floor V=0 -> %.6f" % (b,a,r1886[0]))
