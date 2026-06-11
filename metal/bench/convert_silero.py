#!/usr/bin/env python3
"""Convert whisper.cpp's Silero-VAD ggml model to our flat f32 bin.

Usage: convert_silero.py <silero-ggml.bin> <out.bin>
Output layout (all little-endian):
  u32 magic 0x53564144 ('SVAD'), u32 n_window, u32 n_context,
  u32 n_encoder_layers, then per layer (in,out,k) u32×3,
  u32 lstm_input, u32 lstm_hidden, u32 final_in, u32 final_out,
  then tensors in FIXED order, each: u32 ndims, u32 dims[ndims], f32 data
  (f16 source tensors are converted to f32):
    stft_forward_basis,
    enc0_w, enc0_b, enc1_w, enc1_b, enc2_w, enc2_b, enc3_w, enc3_b,
    lstm_ih_w, lstm_ih_b, lstm_hh_w, lstm_hh_b,
    final_w, final_b
"""
import struct, sys

import numpy as np

f = open(sys.argv[1], 'rb')
def ri(): return struct.unpack('<i', f.read(4))[0]
magic = ri()
assert magic == 0x67676d6c, hex(magic)  # 'ggml'
slen = ri()
mtype = f.read(slen).decode()
ver = (ri(), ri(), ri())
n_window, n_context = ri(), ri()
nel = ri()
enc = [(ri(), ri(), ri()) for _ in range(nel)]
lstm_in, lstm_hid, fin_in, fin_out = ri(), ri(), ri(), ri()
print(f'type={mtype} ver={ver} n_window={n_window} n_context={n_context}')
print(f'encoder={enc} lstm={lstm_in}/{lstm_hid} final={fin_in}->{fin_out}')

tensors = {}
while True:
    hdr = f.read(12)
    if len(hdr) < 12:
        break
    nd, nlen, ttype = struct.unpack('<iii', hdr)
    ne = struct.unpack(f'<{nd}i', f.read(4 * nd))
    name = f.read(nlen).decode()
    n = int(np.prod(ne))
    if ttype == 0:   # f32
        data = np.frombuffer(f.read(4 * n), '<f4').astype(np.float32)
    elif ttype == 1: # f16
        data = np.frombuffer(f.read(2 * n), '<f2').astype(np.float32)
    else:
        raise SystemExit(f'unsupported ttype {ttype} for {name}')
    tensors[name] = (ne, data)
    print(f'  {name:40s} ne={ne} type={"f32" if ttype==0 else "f16"}')

ORDER = ['_model.stft.forward_basis_buffer',
         '_model.encoder.0.reparam_conv.weight', '_model.encoder.0.reparam_conv.bias',
         '_model.encoder.1.reparam_conv.weight', '_model.encoder.1.reparam_conv.bias',
         '_model.encoder.2.reparam_conv.weight', '_model.encoder.2.reparam_conv.bias',
         '_model.encoder.3.reparam_conv.weight', '_model.encoder.3.reparam_conv.bias',
         '_model.decoder.rnn.weight_ih', '_model.decoder.rnn.bias_ih',
         '_model.decoder.rnn.weight_hh', '_model.decoder.rnn.bias_hh',
         '_model.decoder.decoder.2.weight', '_model.decoder.decoder.2.bias']
missing = [k for k in ORDER if k not in tensors]
if missing:
    print('NAME MISMATCH — actual keys:')
    for k in tensors: print(' ', k)
    raise SystemExit(f'missing: {missing}')

o = open(sys.argv[2], 'wb')
o.write(struct.pack('<III', 0x53564144, n_window, n_context))
o.write(struct.pack('<I', nel))
for t in enc:
    o.write(struct.pack('<III', *t))
o.write(struct.pack('<IIII', lstm_in, lstm_hid, fin_in, fin_out))
for k in ORDER:
    ne, data = tensors[k]
    o.write(struct.pack('<I', len(ne)))
    o.write(struct.pack(f'<{len(ne)}I', *ne))
    o.write(data.tobytes())
o.close()
print(f'wrote {sys.argv[2]}')
