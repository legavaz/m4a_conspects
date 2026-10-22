"""GigaAM-v3 (onnx-asr) transcription helper for the Zoom pipeline.

Reads a 16 kHz mono WAV and writes <prefix>.txt and <prefix>.srt using
GigaAM-v3 e2e-RNN-T with Silero VAD long-form segmentation.

Called by programs/transcribe.ps1 (-Engine gigaam).
"""

from __future__ import annotations

import argparse
import os
import sys
import time


def _fmt_ts(seconds: float) -> str:
    if seconds < 0:
        seconds = 0.0
    ms = int(round(seconds * 1000))
    h, ms = divmod(ms, 3600_000)
    m, ms = divmod(ms, 60_000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def _providers(choice: str):
    return {
        "cpu": [["CPUExecutionProvider"]],
        "cuda": [["CUDAExecutionProvider"]],
        "dml": [["DmlExecutionProvider"]],
        "auto": [
            ["CUDAExecutionProvider"],
            ["DmlExecutionProvider"],
            ["CPUExecutionProvider"],
        ],
    }[choice]


def _probe(model_dir: str, prov: str) -> bool:
    """True if ORT can actually register this provider (not a silent CPU fallback)."""
    import glob
    import onnxruntime as ort

    decoders = glob.glob(os.path.join(model_dir, "v3_e2e_rnnt_decoder*.onnx"))
    if not decoders:
        return prov == "CPUExecutionProvider"
    try:
        sess = ort.InferenceSession(decoders[0], providers=[prov])
        return prov in sess.get_providers()
    except Exception:  # noqa: BLE001
        return False


def _load(onnx_asr, model_dir: str, provider_chain, quantization):
    import onnxruntime as ort

    available = ort.get_available_providers()
    for prov in provider_chain:
        name = prov[0]
        if name != "CPUExecutionProvider":
            if name not in available:
                print(f"[gigaam] provider {name} not in build ({available}), skipping", file=sys.stderr)
                continue
            if not _probe(model_dir, name):
                print(f"[gigaam] provider {name} unavailable at runtime, skipping", file=sys.stderr)
                continue
        try:
            t = time.time()
            model = onnx_asr.load_model(
                "gigaam-v3-e2e-rnnt",
                model_dir,
                providers=prov,
                quantization=quantization,
            )
            print(f"[gigaam] using provider {name}", file=sys.stderr)
            return model, name, time.time() - t
        except Exception as e:  # noqa: BLE001
            print(f"[gigaam] provider {name} failed: {e}", file=sys.stderr)
    raise RuntimeError("no usable provider")


def main() -> int:
    ap = argparse.ArgumentParser(description="GigaAM-v3 transcription (onnx-asr)")
    ap.add_argument("wav", help="input 16 kHz mono WAV")
    ap.add_argument("--out-prefix", required=True, help="output prefix (writes .txt/.srt)")
    ap.add_argument("--model-dir", default=os.path.join("models", "gigaam-v3-e2e-rnnt"))
    ap.add_argument("--provider", default="auto", choices=["auto", "cuda", "dml", "cpu"])
    ap.add_argument("--quantization", default=None, help="None (fp32) or int8")
    ap.add_argument("--min-silence-ms", type=float, default=100.0)
    ap.add_argument("--max-speech-s", type=float, default=20.0)
    ap.add_argument("--speech-pad-ms", type=float, default=30.0)
    ap.add_argument("--batch-size", type=int, default=8)
    args = ap.parse_args()

    import onnx_asr  # imported late so --help works without the env

    model, used, load_s = _load(onnx_asr, args.model_dir, _providers(args.provider), args.quantization)
    print(f"[gigaam] provider={used} load={load_s:.1f}s", file=sys.stderr)

    vad = onnx_asr.load_vad("silero", providers=["CPUExecutionProvider"])
    pipeline = model.with_vad(
        vad,
        min_silence_duration_ms=args.min_silence_ms,
        max_speech_duration_s=args.max_speech_s,
        speech_pad_ms=args.speech_pad_ms,
        batch_size=args.batch_size,
    )

    t = time.time()
    segments = list(pipeline.recognize(args.wav))
    elapsed = time.time() - t

    duration = segments[-1].end if segments else 0.0
    rtf = (duration / elapsed) if elapsed > 0 else 0.0
    print(f"[gigaam] segments={len(segments)} audio={duration:.0f}s time={elapsed:.1f}s ({rtf:.1f}x RT)", file=sys.stderr)

    srt_lines = []
    txt_lines = []
    n = 0
    for seg in segments:
        text = " ".join(seg.text.split())
        if not text:
            continue
        n += 1
        srt_lines.append(f"{n}")
        srt_lines.append(f"{_fmt_ts(seg.start)} --> {_fmt_ts(seg.end)}")
        srt_lines.append(text)
        srt_lines.append("")
        txt_lines.append(text)

    with open(args.out_prefix + ".srt", "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(srt_lines))
    with open(args.out_prefix + ".txt", "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(txt_lines) + ("\n" if txt_lines else ""))
    print(f"[gigaam] wrote {args.out_prefix}.txt / .srt", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
