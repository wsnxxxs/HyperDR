"""Generate H.265 VPS/SPS/PPS variants (7.3.2.1, 7.3.2.2.1, 7.3.2.3.1, E.2.1).
Each line: name expected(legal|illegal) vps sps pps (hex NAL units with emulation prevention)."""
import sys

class W:
    def __init__(s): s.bits = []
    def u(s, n, v):
        assert 0 <= v < (1 << n) or n == 0, (n, v)
        for i in range(n - 1, -1, -1): s.bits.append((v >> i) & 1)
    def ue(s, v):
        v += 1; n = v.bit_length()
        s.u(n - 1, 0); s.u(n, v)
    def se(s, v): s.ue(2 * v - 1 if v > 0 else -2 * v)
    def trailing(s):
        s.bits.append(1)
        while len(s.bits) % 8: s.bits.append(0)
    def bytes(s):
        return bytes(int("".join(map(str, s.bits[i:i + 8])), 2) for i in range(0, len(s.bits), 8))

def nal(t, rbsp):
    out = bytearray([t << 1, 1]); z = 0
    for b in rbsp:
        if z == 2 and b <= 3: out.append(3); z = 0
        out.append(b); z = z + 1 if b == 0 else 0
    return bytes(out)

def ptl(w, layers, idc=1, compat=(1, 2), one_picture=0, sub_profile=False, sub_level=False, level=93):
    def general(idc, compat, one_picture):
        w.u(2, 0); w.u(1, 0); w.u(5, idc)
        for j in range(32): w.u(1, 1 if j in compat else 0)
        w.u(1, 1); w.u(1, 0); w.u(1, 0); w.u(1, 1)  # progressive, interlaced, non_packed, frame_only
        if idc == 2 or 2 in compat:
            w.u(7, 0); w.u(1, one_picture); w.u(35, 0)
        else:
            w.u(43, 0)
        w.u(1, 0)  # inbld / reserved
    general(idc, compat, one_picture); w.u(8, level)
    for i in range(layers): w.u(1, int(sub_profile)); w.u(1, int(sub_level))
    if layers:
        for i in range(layers, 8): w.u(2, 0)
    for i in range(layers):
        if sub_profile: general(idc, compat, one_picture)
        if sub_level: w.u(8, level)

def ordering(w, layers, dpb, all_layers=True):
    w.u(1, int(all_layers))
    for i in (range(layers + 1) if all_layers else [layers]):
        w.ue(dpb); w.ue(min(dpb, 1)); w.ue(0)

def hrd(w, layers, nal_=True, vcl=True, sub_pic=False, cpb=1, fixed=True, low_delay=False):
    w.u(1, int(nal_)); w.u(1, int(vcl))
    if nal_ or vcl:
        w.u(1, int(sub_pic))
        if sub_pic: w.u(8, 23); w.u(5, 4); w.u(1, 1); w.u(5, 4)
        w.u(4, 1); w.u(4, 2)
        if sub_pic: w.u(4, 3)
        w.u(5, 23); w.u(5, 23); w.u(5, 23)
    for i in range(layers + 1):
        w.u(1, int(fixed))
        if not fixed: w.u(1, 0)  # fixed_pic_rate_within_cvs_flag
        within = fixed
        if within: w.ue(0)
        else: w.u(1, int(low_delay))
        if not low_delay: w.ue(cpb - 1)
        for enabled in (nal_, vcl):
            if enabled:
                for n in range(cpb if not low_delay else 1):
                    w.ue(1000 + n); w.ue(2000 + n)
                    if sub_pic: w.ue(900); w.ue(800)
                    w.u(1, 0)

def vps(layers=0, dpb=4, timing=False, hrd_=False, idc=1, compat=(1, 2), one_picture=0, sub=False, all_layers=True):
    w = W(); w.u(4, 0); w.u(1, 1); w.u(1, 1); w.u(6, 0); w.u(3, layers); w.u(1, 1); w.u(16, 0xFFFF)
    ptl(w, layers, idc, compat, one_picture, sub, sub)
    ordering(w, layers, dpb, all_layers)
    w.u(6, 0); w.ue(0)
    w.u(1, int(timing))
    if timing:
        w.u(32, 1001); w.u(32, 60000); w.u(1, 1); w.ue(0)
        w.ue(1 if hrd_ else 0)
        if hrd_: w.ue(0); hrd(w, layers)
    w.u(1, 0); w.trailing(); return nal(32, w.bytes())

def scaling_data(w, variant):
    for size in range(4):
        for matrix in range(0, 6, 3 if size == 3 else 1):
            if variant == "explicit" or (size == 0 and matrix == 0):
                w.u(1, 1)
                if size > 1: w.se(8)
                for i in range(min(64, 1 << (4 + 2 * size))): w.se(1 if i % 2 else -1)
            else:
                w.u(1, 0)
                # largest legal delta: matrixId for size<3, matrixId/3 for size 3
                w.ue(matrix // 3 if size == 3 else matrix)

def sps(width=512, height=512, depth=0, layers=0, dpb=4, min_cb=3, cb_diff=3, min_tb=2, tb_diff=3,
        crop=None, scaling=None, pcm=None, rps="simple", long_term=False, vui=None, idc=1, compat=(1, 2),
        one_picture=0, sub=False, all_layers=True, poc_minus4=4):
    w = W(); w.u(4, 0); w.u(3, layers); w.u(1, 1)
    ptl(w, layers, idc, compat, one_picture, sub, sub)
    w.ue(0); w.ue(1); w.ue(width); w.ue(height)
    w.u(1, int(crop is not None))
    if crop: [w.ue(c) for c in crop]
    w.ue(depth); w.ue(depth); w.ue(poc_minus4)
    ordering(w, layers, dpb, all_layers)
    w.ue(min_cb - 3); w.ue(cb_diff); w.ue(min_tb - 2); w.ue(tb_diff)
    ctb = min_cb + cb_diff
    w.ue(ctb - min_tb); w.ue(ctb - min_tb)
    w.u(1, int(scaling is not None))
    if scaling is not None:
        w.u(1, int(scaling != "default"))
        if scaling != "default": scaling_data(w, scaling)
    w.u(1, 1); w.u(1, 1)  # amp, sao
    w.u(1, int(pcm is not None))
    if pcm:
        bits, log2_min, log2_max = pcm
        w.u(4, bits - 1); w.u(4, bits - 1); w.ue(log2_min - 3); w.ue(log2_max - log2_min); w.u(1, 1)
    if rps == "none":
        w.ue(0)
    elif rps == "simple":
        w.ue(1); w.ue(1); w.ue(0); w.ue(0); w.u(1, 1)
    elif rps == "full":  # num_negative = dpb, then positive = 0; second set inter-predicted
        w.ue(3)
        w.ue(dpb); w.ue(0)
        for i in range(dpb): w.ue(i); w.u(1, 1)
        w.u(1, 0); w.ue(dpb - 1); w.ue(1)  # set 1 (explicit): negative dpb-1, positive 1
        for i in range(dpb - 1): w.ue(0); w.u(1, 1)
        w.ue(5); w.u(1, 0)
        # set 2: inter-predicted from set 1 (NumDeltaPocs = dpb), deltaRps = -1
        w.u(1, 1); w.u(1, 1); w.ue(0)
        for j in range(dpb + 1):
            if j == 0: w.u(1, 0); w.u(1, 0)   # dropped
            else: w.u(1, 1)
    elif rps == "over":  # num_negative_pics = dpb + 1
        w.ue(1); w.ue(dpb + 1); w.ue(0)
        for i in range(dpb + 1): w.ue(0); w.u(1, 1)
    elif rps == "inter-over":  # predicted set keeps all dpb references plus deltaRps itself
        w.ue(2); w.ue(dpb); w.ue(0)
        for i in range(dpb): w.ue(0); w.u(1, 1)
        w.u(1, 1); w.u(1, 1); w.ue(0)
        for j in range(dpb + 1): w.u(1, 1)
    w.u(1, int(long_term))
    if long_term:
        w.ue(2)
        for v in (3, 7): w.u(poc_minus4 + 4, v); w.u(1, 1)
    w.u(1, 1); w.u(1, 1)
    w.u(1, int(vui is not None))
    if vui is not None: write_vui(w, layers, **vui)
    w.u(1, 0); w.trailing(); return nal(33, w.bytes())

def write_vui(w, layers, sar=None, signal=True, chroma=True, window=False, timing=False, hrd_=False,
              restriction=True, mv=15):
    w.u(1, int(sar is not None))
    if sar is not None:
        w.u(8, 255); w.u(16, sar[0]); w.u(16, sar[1])
    w.u(1, 1); w.u(1, 0)  # overscan
    w.u(1, int(signal))
    if signal: w.u(3, 5); w.u(1, 1); w.u(1, 1); w.u(8, 12); w.u(8, 16); w.u(8, 9)
    w.u(1, int(chroma))
    if chroma: w.ue(2); w.ue(5)
    w.u(1, 0); w.u(1, 0); w.u(1, 0)
    w.u(1, int(window))
    if window: w.ue(1); w.ue(2); w.ue(3); w.ue(4)
    w.u(1, int(timing))
    if timing:
        w.u(32, 1); w.u(32, 30); w.u(1, 1); w.ue(0); w.u(1, int(hrd_))
        if hrd_: hrd(w, layers, sub_pic=True, cpb=2, fixed=False, low_delay=False)
    w.u(1, int(restriction))
    if restriction: w.u(1, 0); w.u(1, 1); w.u(1, 1); w.ue(4095); w.ue(16); w.ue(16); w.ue(mv); w.ue(mv)

def pps(depth=0, tiles=None, deblock=True, scaling=None, cu_qp=None, init_qp=0, ctb_log2=6, merge=None):
    w = W(); w.ue(0); w.ue(0); w.u(1, 0); w.u(1, 0); w.u(3, 0); w.u(1, 1); w.u(1, 0)
    w.ue(0); w.ue(0); w.se(init_qp); w.u(1, 0); w.u(1, 0)
    w.u(1, int(cu_qp is not None))
    if cu_qp is not None: w.ue(cu_qp)
    w.se(-12); w.se(12); w.u(1, 0); w.u(1, 0); w.u(1, 0); w.u(1, 0)
    w.u(1, int(tiles is not None)); w.u(1, 0)
    if tiles:
        cols, rows, widths, heights = tiles
        w.ue(cols - 1); w.ue(rows - 1); w.u(1, int(widths is None))
        if widths is not None:
            for x in widths: w.ue(x - 1)
            for y in heights: w.ue(y - 1)
        w.u(1, 1)
    w.u(1, 1)
    w.u(1, int(deblock))
    if deblock: w.u(1, 1); w.u(1, 0); w.se(-6); w.se(6)
    w.u(1, int(scaling is not None))
    if scaling is not None: scaling_data(w, scaling)
    w.u(1, 0); w.ue(ctb_log2 - 2 if merge is None else merge); w.u(1, 0)
    w.u(1, 0); w.trailing(); return nal(34, w.bytes())

cases = []
def case(name, legal, v, s, p): cases.append((name, legal, v, s, p))
V, S, P = vps(), sps(), pps()
case("baseline-main8", 1, V, S, P)
case("main10-10bit", 1, vps(idc=2, compat=(2,)), sps(depth=2, idc=2, compat=(2,)), pps(depth=2, init_qp=-38))
case("main10-still-one-picture", 1, vps(idc=2, compat=(2,), one_picture=1), sps(depth=2, idc=2, compat=(2,), one_picture=1), pps(depth=2))
case("main8-compat2-one-picture", 1, vps(one_picture=1), sps(one_picture=1), P)
case("main8-no-compat2", 1, vps(compat=(1,)), sps(compat=(1,)), P)
case("main8-compat-still3", 1, vps(compat=(1, 2, 3)), sps(compat=(1, 2, 3)), P)
case("crop", 1, V, sps(crop=(1, 2, 3, 4)), P)
case("width-not-ctb-multiple", 1, V, sps(width=520, height=264), P)
case("ctb16-mincb8-mintb4-invalid", 0, V, sps(min_cb=3, cb_diff=1, min_tb=3, tb_diff=1), pps(ctb_log2=4))
case("ctb16-mincb8-mintb4", 1, V, sps(min_cb=3, cb_diff=1, min_tb=2, tb_diff=2), pps(ctb_log2=4))
case("mincb-eq-mintb-illegal", 0, V, sps(min_cb=3, cb_diff=3, min_tb=3, tb_diff=2), P)
case("width-not-mincb-multiple-illegal", 0, V, sps(width=516), P)
case("scaling-default", 1, V, sps(scaling="default"), P)
case("scaling-sps-explicit", 1, V, sps(scaling="explicit"), P)
case("scaling-sps-max-deltas", 1, V, sps(scaling="pred"), P)
case("scaling-pps", 1, V, sps(scaling="default"), pps(scaling="pred"))
case("pcm-8bit-3-5", 1, V, sps(pcm=(8, 3, 5)), P)
case("pcm-mincb16-min4", 1, V, sps(min_cb=4, cb_diff=2, pcm=(8, 4, 5)), P)
case("pcm-mincb16-min3-illegal", 0, V, sps(min_cb=4, cb_diff=2, pcm=(8, 3, 5)), P)
case("pcm-ctb16-max4", 1, V, sps(min_cb=3, cb_diff=1, tb_diff=2, pcm=(7, 3, 4)), pps(ctb_log2=4))
case("pcm-ctb16-max5-illegal", 0, V, sps(min_cb=3, cb_diff=1, tb_diff=2, pcm=(7, 3, 5)), pps(ctb_log2=4))
case("pcm-main10-10bit", 1, vps(idc=2, compat=(2,)), sps(depth=2, idc=2, compat=(2,), pcm=(10, 3, 4)), pps(depth=2))
case("pcm-8bit-depth9-illegal", 0, V, sps(pcm=(9, 3, 4)), P)
case("rps-full-dpb4", 1, V, sps(rps="full", dpb=4), P)
case("rps-full-dpb15", 1, vps(dpb=15), sps(rps="full", dpb=15), P)
case("rps-over-illegal", 0, V, sps(rps="over"), P)
case("rps-inter-over-illegal", 0, V, sps(rps="inter-over"), P)
case("rps-none", 1, V, sps(rps="none"), P)
case("long-term", 1, V, sps(long_term=True), P)
case("sublayers-3", 1, vps(layers=2, sub=True), sps(layers=2, sub=True), P)
case("sublayers-3-highest-only", 1, vps(layers=2, all_layers=False), sps(layers=2, all_layers=False), P)
case("vps-timing-hrd", 1, vps(timing=True, hrd_=True), S, P)
case("vui-sar-zero", 1, V, sps(vui=dict(sar=(0, 0))), P)
case("vui-sar-4-3", 1, V, sps(vui=dict(sar=(4, 3))), P)
case("vui-window-timing-hrd", 1, V, sps(vui=dict(window=True, timing=True, hrd_=True)), P)
case("vui-mv16-illegal", 0, V, sps(vui=dict(mv=16)), P)
case("vui-minimal", 1, V, sps(vui=dict(signal=False, chroma=False, restriction=False)), P)
case("tiles-2x1-uniform", 1, V, S, pps(tiles=(2, 1, None, None)))
case("tiles-1x2-explicit", 1, V, S, pps(tiles=(1, 2, [], [3])))
case("tiles-3x3-explicit", 1, V, S, pps(tiles=(3, 3, [2, 3], [1, 1])))
case("tiles-1x1-illegal", 0, V, S, pps(tiles=(1, 1, None, None)))
case("cu-qp-delta-max", 1, V, S, pps(cu_qp=3))
case("pps-init-qp-26-8bit-illegal", 0, V, S, pps(init_qp=-27))
case("pps-merge-level-max", 1, V, S, pps(merge=4))
case("pps-no-deblock", 1, V, S, pps(deblock=False))
case("dpb-max15", 1, vps(dpb=15), sps(dpb=15), P)
case("poc-lsb16", 1, V, sps(poc_minus4=12), P)
for name, legal, v, s, p in cases:
    print(name, legal, v.hex(), s.hex(), p.hex())
