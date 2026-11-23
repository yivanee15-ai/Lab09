"""
Lab04 inference script. Do not modify.

    python test.py --weights final_model.pth --split val
    python test.py --weights final_model.pth --split test_public --out test_public_pred
"""
import argparse
import os
import re
import sys

import numpy as np
import torch
from PIL import Image
from torch.utils.data import DataLoader

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from utils.dataset import CamVid, NUM_CLASSES, IMG_H, IMG_W  # noqa: E402
from utils.metric import SegMetric  # noqa: E402

MAX_PARAMS = 5_000_000
BANNED = [
    r"torchvision\.models", r"from\s+torchvision\s+import\s+models",
    r"\btimm\b", r"segmentation_models_pytorch", r"\bmmseg\b", r"\bmmcv\b",
    r"\btransformers\b", r"torch\.hub", r"load_state_dict_from_url",
]


def check_source(path):
    src = open(path, encoding="utf-8").read()
    code = "\n".join(l.split("#", 1)[0] for l in src.splitlines())
    code = re.sub(r'"""[\s\S]*?"""|\'\'\'[\s\S]*?\'\'\'', "", code)
    hits = [p for p in BANNED if re.search(p, code)]
    if hits:
        raise SystemExit(f"[FAIL] banned package/usage in {path}: {hits}")
    print(f"[OK] {path}: no banned packages")


def count_params(model):
    seen, total = set(), 0
    for p in model.parameters():           # shared weights counted once
        if id(p) not in seen:
            seen.add(id(p)); total += p.numel()
    return total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="data")
    ap.add_argument("--split", default="test_public")
    ap.add_argument("--weights", default="final_model.pth")
    ap.add_argument("--network", default="model/network.py")
    ap.add_argument("--out", default=None, help="folder for predicted PNGs")
    ap.add_argument("--batch", type=int, default=4)
    args = ap.parse_args()

    check_source(args.network)
    import importlib.util
    spec = importlib.util.spec_from_file_location("network", args.network)
    net = importlib.util.module_from_spec(spec); spec.loader.exec_module(net)
    model = net.build_model()

    n = count_params(model)
    print(f"[{'OK' if n <= MAX_PARAMS else 'FAIL'}] parameters: {n:,} (limit {MAX_PARAMS:,})")
    if n > MAX_PARAMS:
        raise SystemExit(1)

    dev = "cuda" if torch.cuda.is_available() else "cpu"
    state = torch.load(args.weights, map_location="cpu")
    if isinstance(state, dict) and isinstance(state.get("model"), dict):
        state = state["model"]
    model.load_state_dict(state)
    model.to(dev).eval()

    ds = CamVid(args.data, args.split)
    dl = DataLoader(ds, batch_size=args.batch, shuffle=False, num_workers=2)
    metric = SegMetric() if ds.has_label else None
    if args.out:
        os.makedirs(args.out, exist_ok=True)

    idx = 0
    with torch.no_grad():
        for x, y in dl:
            logits = model(x.to(dev))
            if tuple(logits.shape[1:]) != (NUM_CLASSES, IMG_H, IMG_W):
                raise SystemExit(f"[FAIL] output shape {tuple(logits.shape)}, expected [B, {NUM_CLASSES}, {IMG_H}, {IMG_W}]")
            pred = logits.argmax(1).cpu().numpy().astype(np.uint8)
            names = ds.files[idx: idx + len(pred)]; idx += len(pred)
            if metric is not None:
                metric.update(pred, y)
            if args.out:
                for p, nm in zip(pred, names):
                    Image.fromarray(p).save(os.path.join(args.out, nm))

    if args.out:
        print(f"[OK] wrote {idx} predictions to {args.out}/")
    if metric is not None:
        print(metric.report())


if __name__ == "__main__":
    main()
