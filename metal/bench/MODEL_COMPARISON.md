# Speaker-embedding model comparison (for the Metal port decision)

Measured on AMI ES2004a (4 speakers, md-eval.pl collar 0.25s), CPU onnxruntime,
1.5 s segments. Goal: pick the best DER / port-effort / footprint tradeoff.

| metric | **ResNet34** ⭐ | CAM++ | ERes2Net |
|---|---|---|---|
| **DER @ K=4** | **31.7 %** | 47.0 % | 39.3 % |
| DER best (K) | 31.6 % (K5) | 47.0 % (K4) | 32.5 % (K5) |
| speaker separation (intra−inter cos) | **0.307** | 0.121 | 0.244 |
| model size | **27 MB** | 30 MB | 40 MB |
| params | 6.63 M | 7.24 M | 9.88 M |
| weights resident (f32) | ~27 MB | ~29 MB | ~40 MB |
| embedding dim | 256 | 512 | 512 |
| onnx nodes | **110** | 3102 | 516 |
| conv layers | **36** | 225 | 96 |
| op zoo | Conv/Relu/Add/ReduceMean/Gemm | +Sigmoid/Where/AvgPool/Concat (CAM mask, D-TDNN dense) | +Sigmoid/Concat (Res2Net+SE) |
| inference / 1.5 s seg (CPU) | 9.9 ms | 6.9 ms | 9.5 ms |
| **port complexity** | **LOW** (vanilla ResNet34) | VERY HIGH | HIGH |
| license | Apache-2.0 (wespeaker) | Apache-2.0 (3D-Speaker) | Apache-2.0 (3D-Speaker) |
| training data | VoxCeleb1+2 | VoxCeleb | 3D-Speaker/VoxCeleb |

DER (lower = better) — distance to oracle ceiling (28.8%):
```
ResNet34  ████████████████████████████████  31.7%  ← near oracle, simplest
ERes2Net  ███████████████████████████████████████  39.3%
CAM++     ███████████████████████████████████████████████  47.0%
(oracle)  ███████████████████████████████  28.8%  (our 1.5s segmentation ceiling)
(mel,now) ███████████████████████████████████████████████████████████████████  67%
```

Port complexity (onnx nodes, lower = simpler):
```
ResNet34   ██  110
ERes2Net   ██████████  516
CAM++      ████████████████████████████████████████████████████████  3102
```

## Recommendation: **wespeaker ResNet34**
Best on every axis that matters: lowest DER (31.7%, near the 28.8% oracle),
highest speaker separation (0.307), smallest, and by far the simplest to port
(110 nodes / 36 conv vs CAM++'s 3102 / 225, and no context-aware masking,
dense connections, or SE blocks). Standard ResNet34: conv2d 3×3 residual
blocks → temporal stats pooling → FC → 256-d. Apache-2.0.

Caveat: trained on VoxCeleb (research dataset); weights are Apache-2.0 but
verify dataset terms for commercial deployment.

### Port plan (ResNet34)
1. dump onnx weights → flat binary + manifest (conv/bn/fc shapes)
2. 80-dim kaldi fbank in Zig (25 ms / 10 ms, CMN)
3. ResNet34 forward (conv2d+BN+relu+residual, stats pooling, FC) — CPU first
   (offline, ~10 ms/seg is fine), verify layer-by-layer vs onnx
4. wire into diarization (replace mel features), re-measure AMI DER, target <40%
