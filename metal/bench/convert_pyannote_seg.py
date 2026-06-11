#!/usr/bin/env python3
"""Convert pyannote segmentation-3.0 ONNX (sherpa-onnx export) to our flat
f32 bin + dump an onnxruntime reference output for Zig validation.

Usage: convert_pyannote_seg.py <model.onnx> <out.bin> [ref_wav ref_out.bin]

Graph (verified by node dump):
  IN(1,affine) → SincConv(80,1,251,s10) → Abs → MaxPool3 → IN(80) → LReLU
  → Conv(60,80,5) → MaxPool3 → IN(60) → LReLU
  → Conv(60,60,5) → MaxPool3 → IN(60) → LReLU
  → 4× BiLSTM(h=128, ONNX gate order i,o,f,c; W[2,512,in] R[2,512,128]
     B[2,1024]=Wb|Rb; dir0=fwd dir1=bwd)
  → Linear 256→128 +LReLU → 128→128 +LReLU → 128→7 → LogSoftmax
Output layout: u32 magic 'POSD', then tensors in fixed order, each
u32 ndims + dims + f32 data:
  in0_scale[1], in0_bias[1], sinc_w[80,1,251],
  norm0_w[80], norm0_b[80], conv1_w[60,80,5], conv1_b[60],
  norm1_w[60], norm1_b[60], conv2_w[60,60,5], conv2_b[60],
  norm2_w[60], norm2_b[60],
  per LSTM l in 0..4: W[2,512,inl], R[2,512,128], B[2,1024],
  lin0_w[256,128], lin0_b[128], lin1_w[128,128], lin1_b[128],
  cls_w[128,7], cls_b[7]
"""
import struct, sys

import numpy as np
import onnx
from onnx import numpy_helper

m = onnx.load(sys.argv[1])
g = m.graph
init = {i.name: numpy_helper.to_array(i) for i in g.initializer}

# the two scalar IN params for the input norm (token names vary; find by use)
in_norm = None
for n in g.node:
    if n.op_type == 'InstanceNormalization' and n.input[0] == 'x':
        in_norm = (init[n.input[1]], init[n.input[2]])
assert in_norm is not None
cls_b = None
for n in g.node:
    if n.op_type == 'Add' and any('token_109' in i for i in n.input):
        cls_b = init[[i for i in n.input if 'token_109' in i][0]]
assert cls_b is not None

ORDER = [
    in_norm[0], in_norm[1],
    init['/sincnet/conv1d.0/Concat_2_output_0'],
    init['sincnet.norm1d.0.weight'], init['sincnet.norm1d.0.bias'],
    init['sincnet.conv1d.1.weight'], init['sincnet.conv1d.1.bias'],
    init['sincnet.norm1d.1.weight'], init['sincnet.norm1d.1.bias'],
    init['sincnet.conv1d.2.weight'], init['sincnet.conv1d.2.bias'],
    init['sincnet.norm1d.2.weight'], init['sincnet.norm1d.2.bias'],
]
for w, r, b in (('784', '785', '783'), ('827', '828', '826'),
                ('870', '871', '869'), ('913', '914', '912')):
    ORDER += [init[f'onnx::LSTM_{w}'], init[f'onnx::LSTM_{r}'], init[f'onnx::LSTM_{b}']]
ORDER += [init['onnx::MatMul_915'], init['linear.0.bias'],
          init['onnx::MatMul_916'], init['linear.1.bias'],
          init['onnx::MatMul_917'], cls_b]

with open(sys.argv[2], 'wb') as o:
    o.write(struct.pack('<I', 0x504F5344))
    for t in ORDER:
        a = np.asarray(t, dtype=np.float32)
        o.write(struct.pack('<I', a.ndim))
        o.write(struct.pack(f'<{a.ndim}I', *a.shape))
        o.write(a.tobytes())
print(f'wrote {sys.argv[2]} ({len(ORDER)} tensors)')

if len(sys.argv) > 4:
    import wave
    import onnxruntime as ort
    w = wave.open(sys.argv[3])
    assert w.getframerate() == 16000
    x = np.frombuffer(w.readframes(160000), dtype=np.int16).astype(np.float32) / 32768.0
    x = np.pad(x, (0, max(0, 160000 - len(x))))
    sess = ort.InferenceSession(sys.argv[1])
    y = sess.run(['y'], {'x': x.reshape(1, 1, -1)})[0][0]  # [589,7] log-probs
    with open(sys.argv[4], 'wb') as o:
        o.write(struct.pack('<II', *y.shape))
        o.write(x.tobytes())              # the exact input samples
        o.write(y.astype(np.float32).tobytes())
    print(f'reference: y{y.shape} → {sys.argv[4]}')
    print('frame 0 logp:', y[0].round(3), '\nframe 300 logp:', y[300].round(3))
