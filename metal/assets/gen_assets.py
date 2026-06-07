#!/usr/bin/env python3
# gen_assets.py — generate the auxiliary binaries the Metal Whisper port needs,
# with ZERO third-party deps (pure stdlib). Run from the assets/ dir after the
# config/tokenizer files are downloaded.
#   mel_filters.bin     [128][201] f32  (Slaney mel filterbank, == whisper)
#   suppress_tokens.bin u32[]           (from generation_config.json)
#   WHISPER_BPE.bin     u32 vocab_size, then per-id (u32 len + raw bytes)
import json, math, struct, sys, os

OUT = os.path.dirname(os.path.abspath(__file__))

# ── 1. mel_filters.bin : Slaney mel filterbank (sr=16000,n_fft=400,n_mels=128)
def hz_to_mel(f):
    f_sp = 200.0 / 3.0
    mel = f / f_sp
    min_log_hz = 1000.0
    min_log_mel = min_log_hz / f_sp
    logstep = math.log(6.4) / 27.0
    return min_log_mel + math.log(f / min_log_hz) / logstep if f >= min_log_hz else mel

def mel_to_hz(mel):
    f_sp = 200.0 / 3.0
    f = f_sp * mel
    min_log_hz = 1000.0
    min_log_mel = min_log_hz / f_sp
    logstep = math.log(6.4) / 27.0
    return min_log_hz * math.exp(logstep * (mel - min_log_mel)) if mel >= min_log_mel else f

def gen_mel():
    SR, N_FFT, N_MELS = 16000, 400, 128
    n_freqs = N_FFT // 2 + 1  # 201
    mmin, mmax = hz_to_mel(0.0), hz_to_mel(SR / 2.0)
    mpts = [mmin + (mmax - mmin) * i / (N_MELS + 1) for i in range(N_MELS + 2)]
    fpts = [mel_to_hz(m) for m in mpts]
    fftf = [k * SR / N_FFT for k in range(n_freqs)]
    data = bytearray()
    for m in range(N_MELS):
        fl, fc, fr = fpts[m], fpts[m + 1], fpts[m + 2]
        enorm = 2.0 / (fpts[m + 2] - fpts[m])
        for k in range(n_freqs):
            f = fftf[k]
            lower = (f - fl) / (fc - fl) if fc != fl else 0.0
            upper = (fr - f) / (fr - fc) if fr != fc else 0.0
            w = max(0.0, min(lower, upper)) * enorm
            data += struct.pack('<f', w)
    with open(os.path.join(OUT, 'mel_filters.bin'), 'wb') as f:
        f.write(data)
    print(f"mel_filters.bin: [{N_MELS}][{n_freqs}] = {len(data)} bytes")

# ── 2. suppress_tokens.bin : from generation_config.json
def gen_suppress():
    gc = json.load(open(os.path.join(OUT, 'generation_config.json')))
    sup = gc.get('suppress_tokens', []) or []
    data = b''.join(struct.pack('<I', int(t)) for t in sup)
    with open(os.path.join(OUT, 'suppress_tokens.bin'), 'wb') as f:
        f.write(data)
    print(f"suppress_tokens.bin: {len(sup)} tokens")

# ── 3. WHISPER_BPE.bin : id -> raw bytes to emit on decode
def bytes_to_unicode():
    bs = list(range(ord("!"), ord("~") + 1)) + list(range(ord("¡"), ord("¬") + 1)) + list(range(ord("®"), ord("ÿ") + 1))
    cs = bs[:]
    n = 0
    for b in range(256):
        if b not in bs:
            bs.append(b); cs.append(256 + n); n += 1
    return {chr(c): b for b, c in zip(bs, cs)}  # unicode-char -> byte

def gen_bpe():
    tok = json.load(open(os.path.join(OUT, 'tokenizer.json')))
    vocab = tok['model']['vocab']           # token_str -> id  (byte-level encoded)
    added = tok.get('added_tokens', [])     # specials: {id, content}
    byte_decoder = bytes_to_unicode()
    id2bytes = {}
    for t, i in vocab.items():
        try:
            id2bytes[i] = bytes(byte_decoder[c] for c in t)
        except KeyError:
            id2bytes[i] = t.encode('utf-8')
    # special tokens (<|...|>) → empty so they don't pollute decoded text
    for a in added:
        id2bytes[a['id']] = b''
    vocab_size = max(id2bytes) + 1
    out = bytearray(struct.pack('<I', vocab_size))
    for i in range(vocab_size):
        b = id2bytes.get(i, b'')
        out += struct.pack('<I', len(b)) + b
    with open(os.path.join(OUT, 'WHISPER_BPE.bin'), 'wb') as f:
        f.write(out)
    print(f"WHISPER_BPE.bin: vocab_size={vocab_size}, {len(out)} bytes")

if __name__ == '__main__':
    gen_mel()
    gen_suppress()
    gen_bpe()
    print("✅ auxiliary assets generated")
