#!/usr/bin/env python3
# export_enc_weights.py — export the encoder front-end weights from
# model.safetensors to raw f32 .bin files for wav_to_enc (no torch/numpy).
#   conv1_w.bin [k][in][out] f32   conv1_b.bin [out] f32
#   conv2_w.bin [k][in][out] f32   conv2_b.bin [out] f32
#   pos_emb.bin [1500][1280] f32   (encoder.embed_positions)
import json, struct, os, array

OUT = os.path.dirname(os.path.abspath(__file__))
ST = os.path.join(OUT, 'model.safetensors')

def load_header():
    f = open(ST, 'rb')
    n = struct.unpack('<Q', f.read(8))[0]
    hdr = json.loads(f.read(n))
    return f, 8 + n, hdr

def read_f16_as_f32(f, base, hdr, key):
    e = hdr[key]
    assert e['dtype'] == 'F16', e['dtype']
    s, t = e['data_offsets']
    f.seek(base + s)
    raw = f.read(t - s)
    cnt = (t - s) // 2
    a = struct.unpack(f'<{cnt}e', raw)   # IEEE half → float
    return a, e['shape']

def w_f32(name, floats):
    out = array.array('f', floats)
    with open(os.path.join(OUT, name), 'wb') as fo:
        out.tofile(fo)
    print(f"{name}: {len(out)} floats")

f, base, hdr = load_header()

# conv weights: safetensors [out][in][k] → quark layout [k][in][out]
def export_conv(key, name):
    a, shape = read_f16_as_f32(f, base, hdr, key)
    out_ch, in_ch, k = shape
    dst = [0.0] * (k * in_ch * out_ch)
    for oc in range(out_ch):
        for ic in range(in_ch):
            for ki in range(k):
                dst[ki * in_ch * out_ch + ic * out_ch + oc] = a[oc * in_ch * k + ic * k + ki]
    w_f32(name, dst)

def export_bias(key, name):
    a, shape = read_f16_as_f32(f, base, hdr, key)
    w_f32(name, list(a))

export_conv('model.encoder.conv1.weight', 'conv1_w.bin')
export_bias('model.encoder.conv1.bias', 'conv1_b.bin')
export_conv('model.encoder.conv2.weight', 'conv2_w.bin')
export_bias('model.encoder.conv2.bias', 'conv2_b.bin')
# positional embedding [1500][1280], used directly (row-major)
a, shape = read_f16_as_f32(f, base, hdr, 'model.encoder.embed_positions.weight')
print('pos_emb shape', shape)
w_f32('pos_emb.bin', list(a))
print("✅ encoder front-end weights exported")
