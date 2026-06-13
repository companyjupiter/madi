#!/usr/bin/env python3
"""quantize_q8.py — F16 safetensors → Q8 safetensors (ships ~1.9x smaller).

ZERO quality change by construction: the engine already quantizes these exact
weights to Q8_0 in-memory at load (transcribe.zig quantInto/upVecQ8). This tool
pre-applies the IDENTICAL quantization offline and stores K.qs (int8) + K.scales
(f16); the engine loads them directly instead of re-quantizing F16. Every other
tensor (layernorm/bias/conv/pos_emb) is copied F16 unchanged.

Bit-identity is the contract and is VERIFIED downstream (F16-load vs Q8-load
transcript must be byte-identical). The quantize-key list is the engine's
ground truth (captured via QDUMP), not a guess.

Quantization mirrors quantInto EXACTLY:
  per 32-block: scale_f32 = max(|w|)/127 (or 1.0 if all-zero); store f16(scale);
  q = clamp(round_half_away(w / scale_f32), -127, 127) as int8.

Usage: quantize_q8.py <in.safetensors> <q8keys.txt> <out.safetensors>
"""
import sys, numpy as np
from safetensors import safe_open
from safetensors.numpy import save_file

inp, keylist, outp = sys.argv[1], sys.argv[2], sys.argv[3]
qkeys = set(l.strip() for l in open(keylist) if l.strip())

def quant(w_f16):
    # f16 -> f32 EXACTLY as h2f does, then quantize in f32 (matches Zig)
    w = w_f16.astype(np.float32)
    out, inn = w.shape
    assert inn % 32 == 0, f"in-dim {inn} not /32"
    nb = inn // 32
    wb = w.reshape(out, nb, 32)
    mx = np.abs(wb).max(axis=2)                       # [out, nb] f32
    scale = np.where(mx > 0, mx / 127.0, 1.0).astype(np.float32)
    inv = (1.0 / scale)[:, :, None]
    q = wb * inv
    q = np.sign(q) * np.floor(np.abs(q) + 0.5)        # round half away from zero (Zig @round)
    q = np.clip(q, -127, 127).astype(np.int8).reshape(out, inn)
    return q, scale.astype(np.float16)                 # scales [out, nb] f16

out_tensors, n_q, n_copy = {}, 0, 0
with safe_open(inp, "numpy") as f:
    for k in f.keys():
        t = f.get_tensor(k)
        if k in qkeys:
            assert t.ndim == 2, f"{k} not 2D"
            qs, sc = quant(t)
            out_tensors[k + ".qs"] = qs
            out_tensors[k + ".scales"] = sc
            n_q += 1
        else:
            out_tensors[k] = t
            n_copy += 1

assert n_q == len(qkeys), f"quantized {n_q} != expected {len(qkeys)} (key mismatch)"
save_file(out_tensors, outp, metadata={"format": "sovereign-q8", "quantized": str(n_q)})
print(f"quantized {n_q} weights, copied {n_copy} tensors -> {outp}")
import os
print(f"size: {os.path.getsize(inp)/1e6:.0f}MB -> {os.path.getsize(outp)/1e6:.0f}MB "
      f"({os.path.getsize(inp)/os.path.getsize(outp):.2f}x)")
