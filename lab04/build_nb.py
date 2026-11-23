"""Builds lab04/Lab04.ipynb. network.py is embedded via a %%writefile cell so the notebook is self-contained."""
import nbformat as nbf, sys

ROOT = "."   # run from lab04/
net_src = open(f"{ROOT}/model/network.py").read()
cells = []
md = lambda s: cells.append(nbf.v4.new_markdown_cell(s.strip("\n")))
code = lambda s: cells.append(nbf.v4.new_code_cell(s.strip("\n")))

md('''
# Lab04 — Semantic Segmentation: Diagnose & Improve

**Name:** TODO  **Student ID:** TODO

Runs on **Colab** (zip in `MyDrive/DL_Lab04/` or uploaded to `/content`), **Kaggle** (add the zip/extracted folder as a dataset) or locally (run inside `2026_DL_Lab04/`).
Every experiment is cached as `ckpt/<run>.json`; re-running the notebook skips finished runs (set `FORCE = True` to redo).

Flow: 0 Setup → 1 Config/Data → 2 Training code → 3 Task 1 (diagnosis) → 4 Model study (M1–M4) → 5 Task 2 (rounds) → 6 Task 3 (my model) → 7 Predict & package
''')

md("## 0. Setup")
code('''
STUDENT_ID = "TODO"      # <- fill in; used for the zip name
import os, sys, glob, shutil, subprocess

def sh(cmd):
    """run a shell command and print its output (same behaviour on Colab / Kaggle / local)."""
    p = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print(p.stdout); return p.returncode

ZIP = "2026_DL_Lab04.zip"
IN_KAGGLE = os.path.exists("/kaggle/input") or "KAGGLE_KERNEL_RUN_TYPE" in os.environ   # check Kaggle first: it also ships google.colab
IN_COLAB = (not IN_KAGGLE) and os.path.exists("/var/colab/hostname")                        # only real Colab has this file

if IN_COLAB:
    WORK = "/content/2026_DL_Lab04"; DRIVE_DIR = "/content/drive/MyDrive/DL_Lab04"
    if not os.path.exists(f"{WORK}/data/train"):
        if os.path.exists(f"/content/{ZIP}"):
            src = "/content"
        else:
            from google.colab import drive; drive.mount("/content/drive"); src = DRIVE_DIR
        sh(f"unzip -q -o {src}/{ZIP} -d /content")
    CKPT_DIR = f"{DRIVE_DIR}/ckpt" if os.path.exists("/content/drive") else f"{WORK}/ckpt"   # Drive = survives disconnects
elif IN_KAGGLE:
    WORK = "/kaggle/working/2026_DL_Lab04"
    if not os.path.exists(f"{WORK}/data/train"):
        zips = glob.glob(f"/kaggle/input/**/{ZIP}", recursive=True)
        if zips:
            sh(f"unzip -q -o {zips[0]} -d /kaggle/working")
        else:   # Kaggle usually extracts an uploaded zip already
            roots = glob.glob("/kaggle/input/**/data/train", recursive=True)
            assert roots, "dataset not found under /kaggle/input"
            shutil.copytree(os.path.dirname(os.path.dirname(roots[0])), WORK, dirs_exist_ok=True)
    CKPT_DIR = f"{WORK}/ckpt"
else:                    # local: run the notebook inside 2026_DL_Lab04/
    WORK = os.getcwd(); CKPT_DIR = f"{WORK}/ckpt"
os.makedirs(CKPT_DIR, exist_ok=True); os.makedirs(f"{WORK}/model", exist_ok=True)
os.chdir(WORK); sys.path.insert(0, WORK)
assert os.path.exists("utils/metric.py") and os.path.exists("test.py"), "utils/ or test.py missing in " + WORK
print("platform:", "Colab" if IN_COLAB else "Kaggle" if IN_KAGGLE else "local", "| work dir:", WORK, "| ckpt:", CKPT_DIR)
sh("nvidia-smi -L")
''')

md("The cell below writes `model/network.py` (identical to the submitted file: TA baseline `SmallFCN`, optional FCN-8s skip variant, and my U-Net `UNetCtx`).")
cells.append(nbf.v4.new_code_cell("%%writefile model/network.py\n" + net_src.rstrip("\n")))

md("## 1. Config and data")
code('''
import random, time, json, importlib
import numpy as np, pandas as pd, torch, torch.nn as nn, torch.nn.functional as F
import matplotlib.pyplot as plt
from torch.utils.data import DataLoader
from PIL import Image, ImageEnhance
from utils.dataset import CamVid, CLASSES, NUM_CLASSES, IGNORE_INDEX, colorize
from utils.metric import SegMetric
import model.network as network
importlib.reload(network)

dev = "cuda" if torch.cuda.is_available() else "cpu"
SMOKE = bool(os.environ.get("LAB04_SMOKE"))   # tiny dry-run switch (ignore)
EPOCHS = 40          # Model study / Task 2 (fixed by the handout)
EPOCHS_FINAL = 120   # Task 3 final model
BATCH, LR, DATA = 8, 1e-3, "data"
FORCE = False        # True = ignore cached results in ckpt/
if SMOKE: EPOCHS = EPOCHS_FINAL = 1
VIS_IDX = [10, 60]   # the same 2 val images are shown for every model (Model Study report item)

def seed_everything(s):
    random.seed(s); np.random.seed(s); torch.manual_seed(s); torch.cuda.manual_seed_all(s)
''')
code('''
def make_train_tf(label_interp=Image.NEAREST, photometric=False):
    """random flip + random scale (0.75-1.25, crop / pad) [+ optional photometric jitter].
    label_interp: resampling used for the *label* (NEAREST is the only correct choice; BILINEAR is the TA baseline)."""
    def tf(img, lab):
        if random.random() < 0.5:
            img, lab = img.transpose(Image.FLIP_LEFT_RIGHT), lab.transpose(Image.FLIP_LEFT_RIGHT)
        W, H = img.size
        s = random.uniform(0.75, 1.25)
        size = (int(W * s), int(H * s))
        img, lab = img.resize(size, Image.BILINEAR), lab.resize(size, label_interp)
        if s >= 1:
            x0, y0 = random.randint(0, size[0] - W), random.randint(0, size[1] - H)
            img, lab = img.crop((x0, y0, x0 + W, y0 + H)), lab.crop((x0, y0, x0 + W, y0 + H))
        else:
            pi, pl = Image.new("RGB", (W, H)), Image.new("L", (W, H), IGNORE_INDEX)
            x0, y0 = random.randint(0, W - size[0]), random.randint(0, H - size[1])
            pi.paste(img, (x0, y0)); pl.paste(lab, (x0, y0)); img, lab = pi, pl
        if photometric:   # image only: brightness / contrast / saturation (daytime vs dusk drives)
            for Enh in (ImageEnhance.Brightness, ImageEnhance.Contrast, ImageEnhance.Color):
                img = Enh(img).enhance(random.uniform(0.7, 1.3))
        return img, lab
    return tf

train_ds = CamVid(DATA, "train")
val_ds   = CamVid(DATA, "val")
val_dl   = DataLoader(val_ds, batch_size=BATCH, shuffle=False, num_workers=2, pin_memory=True)
print(f"train {len(train_ds)}  val {len(val_ds)}")

# pixel frequency of every class in the *training* labels (void excluded) -> class weights
freq = np.zeros(NUM_CLASSES)
for _, lab in train_ds.cache.values():
    freq += np.bincount(np.asarray(lab).ravel(), minlength=IGNORE_INDEX + 1)[:NUM_CLASSES]
freq_ratio = freq / freq.sum()
class_w = np.clip(np.median(freq_ratio) / freq_ratio, 0.2, 10)       # w_c = median(f)/f_c, clipped to [0.2, 10]
print(pd.DataFrame({"freq %": freq_ratio * 100, "weight": class_w}, index=CLASSES).round(3).T.to_string())
''')

md("## 2. Training code (shared by all experiments)")
code('''
class SegLoss(nn.Module):
    """cross-entropy (optionally class-weighted) + optional soft-Dice term. void pixels are ignored."""
    def __init__(self, weight=None, dice=0.0):
        super().__init__()
        self.register_buffer("w", None if weight is None else torch.tensor(weight, dtype=torch.float32))
        self.dice = dice

    def forward(self, logits, y):
        logits = logits.float()
        loss = F.cross_entropy(logits, y, weight=self.w, ignore_index=IGNORE_INDEX)
        if self.dice > 0:
            valid = (y != IGNORE_INDEX)[:, None].float()
            p = logits.softmax(1) * valid
            t = F.one_hot(y.clamp(max=NUM_CLASSES - 1), NUM_CLASSES).permute(0, 3, 1, 2).float() * valid
            inter, den = (p * t).sum((0, 2, 3)), p.sum((0, 2, 3)) + t.sum((0, 2, 3))
            loss = loss + self.dice * (1 - (2 * inter + 1) / (den + 1)).mean()
        return loss

@torch.no_grad()
def evaluate(net, loader, amp=True):
    """returns (unweighted val CE, SegMetric)."""
    net.eval(); metric = SegMetric(); tot, n = 0.0, 0
    for x, y in loader:
        x, y = x.to(dev), y.to(dev)
        with torch.autocast(device_type="cuda", dtype=torch.float16, enabled=(amp and dev == "cuda")):
            logits = net(x)
        logits = logits.float()
        tot += F.cross_entropy(logits, y, ignore_index=IGNORE_INDEX).item() * x.size(0); n += x.size(0)
        metric.update(logits.argmax(1), y)
    return tot / n, metric

RUNS = {}

def run(name, build, weighted=False, dice=0.0, label_interp=Image.NEAREST, photometric=False,
        select="miou", seed=0, epochs=None, lr=LR):
    """Train one experiment. select = metric used to pick the epoch ("miou" or "pixacc").
    Saves ckpt/<name>_best.pth + ckpt/<name>.json (history, per-class IoU, confusion matrix)."""
    epochs = epochs or EPOCHS
    jpath = f"{CKPT_DIR}/{name}.json"
    if os.path.exists(jpath) and not FORCE:
        RUNS[name] = json.load(open(jpath)); r = RUNS[name]
        print(f"[cached] {name}: val mIoU {r['miou']:.4f} (epoch {r['best_epoch']})"); return r
    seed_everything(seed)
    net = build().to(dev)
    n_params = sum(p.numel() for p in net.parameters())
    crit = SegLoss(class_w if weighted else None, dice).to(dev)
    train_ds.transform = make_train_tf(label_interp, photometric)
    g = torch.Generator(); g.manual_seed(seed)
    train_dl = DataLoader(train_ds, batch_size=BATCH, shuffle=True, num_workers=2, pin_memory=True,
                          drop_last=True, generator=g)
    opt = torch.optim.Adam(net.parameters(), lr=lr)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=epochs)
    scaler = torch.amp.GradScaler("cuda", enabled=(dev == "cuda"))
    hist, best, best_ep = [], -1.0, -1
    print(f"=== {name}: {n_params:,} params, {epochs} epochs, weighted={weighted}, dice={dice}, "
          f"label_interp={'NEAREST' if label_interp == Image.NEAREST else 'BILINEAR'}, photometric={photometric}, "
          f"select={select}, seed={seed}")
    for ep in range(epochs):
        t0 = time.time(); net.train(); tot, n = 0.0, 0
        for x, y in train_dl:
            x, y = x.to(dev, non_blocking=True), y.to(dev, non_blocking=True)
            opt.zero_grad(set_to_none=True)
            with torch.autocast(device_type="cuda", dtype=torch.float16, enabled=(dev == "cuda")):
                out = net(x)
            loss = crit(out, y)
            scaler.scale(loss).backward(); scaler.step(opt); scaler.update()
            tot += loss.item() * x.size(0); n += x.size(0)
        sched.step()
        va_ce, m = evaluate(net, val_dl)
        score = m.miou() if select == "miou" else m.pixel_acc()
        hist.append(dict(epoch=ep, train_loss=tot / n, val_ce=va_ce, val_miou=m.miou(), val_pixacc=m.pixel_acc()))
        if score > best:
            best, best_ep = score, ep; torch.save(net.state_dict(), f"{CKPT_DIR}/{name}_best.pth")
        if ep % 5 == 0 or ep == epochs - 1:
            print(f"ep {ep:3d}  train {tot / n:.3f}  val CE {va_ce:.3f}  mIoU {m.miou():.4f}  "
                  f"pixacc {m.pixel_acc():.4f}  best({select}) {best:.4f}@{best_ep}  {time.time() - t0:.0f}s")
    net.load_state_dict(torch.load(f"{CKPT_DIR}/{name}_best.pth", map_location=dev))
    _, m = evaluate(net, val_dl, amp=False)          # fp32, same as test.py
    r = dict(name=name, params=n_params, best_epoch=best_ep, miou=m.miou(), pixacc=m.pixel_acc(),
             iou=[float(v) for v in m.iou()], cm=m.cm.tolist(), hist=hist)
    json.dump(r, open(jpath, "w")); RUNS[name] = r
    print(f"--> {name}: val mIoU {r['miou']:.4f}  pixel acc {r['pixacc']:.4f}  (epoch {best_ep})\\n{m.report()}")
    return r

def load_net(name, build):
    net = build().to(dev); net.load_state_dict(torch.load(f"{CKPT_DIR}/{name}_best.pth", map_location=dev)); return net.eval()

def table(names):
    df = pd.DataFrame({n: RUNS[n]["iou"] + [RUNS[n]["miou"], RUNS[n]["pixacc"]] for n in names},
                      index=CLASSES + ["mIoU", "pixel acc"])
    return df.round(4)

def curves(names):
    fig, ax = plt.subplots(1, 3, figsize=(15, 3.6))
    for n in names:
        h = RUNS[n]["hist"]; e = [r["epoch"] for r in h]
        ax[0].plot(e, [r["train_loss"] for r in h], label=n); ax[1].plot(e, [r["val_ce"] for r in h], label=n)
        ax[2].plot(e, [r["val_miou"] for r in h], label=n)
    for a, t in zip(ax, ["train loss (of its own objective)", "val CE (unweighted)", "val mIoU"]):
        a.set_title(t); a.set_xlabel("epoch"); a.legend(fontsize=7)
    plt.tight_layout(); plt.show()

@torch.no_grad()
def show_preds(nets, ds, idxs):
    """rows = images, columns = image | ground truth | one prediction per model in `nets` (dict name->net)."""
    fig, ax = plt.subplots(len(idxs), 2 + len(nets), figsize=(3.2 * (2 + len(nets)), 2.5 * len(idxs)), squeeze=False)
    for r, i in enumerate(idxs):
        x, y = ds[i]
        cols = [(x.permute(1, 2, 0).numpy(), ds.files[i]), (colorize(y.numpy()), "ground truth")]
        for n, net in nets.items():
            cols.append((colorize(net(x[None].to(dev)).argmax(1)[0].cpu().numpy()), n))
        for c, (im, t) in enumerate(cols):
            ax[r, c].imshow(im); ax[r, c].set_title(t, fontsize=8); ax[r, c].axis("off")
    plt.tight_layout(); plt.show()
''')

md('''
## 3. Task 1 — Diagnose the baseline

`diag_TA` = the TA notebook **unchanged**: bilinear label resize in the augmentation, epoch selected by *pixel accuracy*, plain CE, TA FCN without skip.
''')
code('''
r_diag = run("diag_TA", lambda: network.build_baseline(skip=False), label_interp=Image.BILINEAR, select="pixacc")
curves(["diag_TA"])
h = r_diag["hist"]
b_acc = max(h, key=lambda r: r["val_pixacc"]); b_miou = max(h, key=lambda r: r["val_miou"])
print(f"epoch picked by pixel acc : {b_acc['epoch']}  (pixacc {b_acc['val_pixacc']:.4f}, mIoU {b_acc['val_miou']:.4f})")
print(f"epoch with best val mIoU  : {b_miou['epoch']}  (pixacc {b_miou['val_pixacc']:.4f}, mIoU {b_miou['val_miou']:.4f})")
''')
code('''
# per-class IoU vs. how many pixels the class has, and the confusion matrix
iou = np.array(r_diag["iou"]); cm = np.array(r_diag["cm"]); cmn = cm / np.maximum(cm.sum(1, keepdims=True), 1)
fig, ax = plt.subplots(1, 3, figsize=(17, 4.2))
ax[0].bar(CLASSES, iou); ax[0].set_title(f"per-class IoU (mIoU {r_diag['miou']:.3f})"); ax[0].tick_params(axis="x", rotation=60)
ax[1].bar(CLASSES, freq_ratio * 100); ax[1].set_yscale("log"); ax[1].set_title("training pixel frequency (%)"); ax[1].tick_params(axis="x", rotation=60)
im = ax[2].imshow(cmn, cmap="Blues", vmin=0, vmax=1); ax[2].set_title("confusion matrix (row-normalised)")
ax[2].set_xticks(range(NUM_CLASSES)); ax[2].set_xticklabels(CLASSES, rotation=60); ax[2].set_yticks(range(NUM_CLASSES)); ax[2].set_yticklabels(CLASSES)
ax[2].set_xlabel("prediction"); ax[2].set_ylabel("ground truth"); plt.colorbar(im, ax=ax[2]); plt.tight_layout(); plt.show()
print(table(["diag_TA"]).T.to_string())
''')
code('''
# Evidence for the data bug: resizing a *label map* with BILINEAR invents class ids that are not in the original label
lab = train_ds.cache[train_ds.files[0]][1]; W, H = lab.size
orig = np.unique(np.asarray(lab)).tolist()
fig, ax = plt.subplots(1, 3, figsize=(13, 3.2))
for k, (nm, interp) in enumerate([("NEAREST", Image.NEAREST), ("BILINEAR", Image.BILINEAR)]):
    r = np.asarray(lab.resize((int(W * 1.25), int(H * 1.25)), interp)); bad = ~np.isin(r, orig)
    print(f"{nm:9s}: values {sorted(np.unique(r).tolist())}   pixels with an id not in the original label: {bad.sum()} ({bad.mean() * 100:.2f}%)")
    ax[k + 1].imshow(bad, cmap="gray_r"); ax[k + 1].set_title(f"{nm}: invalid-id pixels"); ax[k + 1].axis("off")
ax[0].imshow(colorize(np.asarray(lab))); ax[0].set_title("original label"); ax[0].axis("off"); plt.show()
''')
code('''
# good and bad prediction cases (ranked by per-image mIoU on val)
@torch.no_grad()
def per_image_miou(net, ds):
    out = []
    for i in range(len(ds)):
        x, y = ds[i]; m = SegMetric(); m.update(net(x[None].to(dev)).argmax(1), y[None]); out.append(m.miou())
    return np.array(out)

net_diag = load_net("diag_TA", lambda: network.build_baseline(skip=False))
pim = per_image_miou(net_diag, val_ds); order = np.argsort(pim)
print("worst:", [(int(i), round(float(pim[i]), 3)) for i in order[:2]], " best:", [(int(i), round(float(pim[i]), 3)) for i in order[-2:]])
show_preds({"diag_TA": net_diag}, val_ds, [int(i) for i in order[-2:]] + [int(i) for i in order[:2]])
''')
md('''
**Problems found (write the final text in the report; each needs the evidence printed above):**

1. *Epoch selected with pixel accuracy, evaluation/selection mismatch* — TODO
2. *Label map resized with bilinear interpolation (invalid class ids / blurred boundaries)* — TODO
3. *No skip connection + stride-32 output → thin objects lost (Pole, SignSymbol, Pedestrian, Bicyclist)* — TODO
4. *Class imbalance with plain CE → small classes under-fitted* — TODO
''')

md('''
## 4. Model study: skip connections × class weights (M1–M4)

Task 1 fixes are applied to M1–M4 (nearest-neighbour label resize, epoch selected on val **mIoU**); 40 epochs, seed 0. M1 is also repeated with seed 1 to estimate seed noise.
''')
code('''
fcn  = lambda: network.build_baseline(skip=False)
fcn8 = lambda: network.build_baseline(skip=True)
run("M1",      fcn,  weighted=False)
run("M2",      fcn,  weighted=True)
run("M3",      fcn8, weighted=False)
run("M4",      fcn8, weighted=True)
run("M1_seed1", fcn, weighted=False, seed=1)
curves(["M1", "M2", "M3", "M4"])
T = table(["M1", "M1_seed1", "M2", "M3", "M4"]); display(T) if "display" in globals() else print(T)
''')
code('''
# analysis helpers for the 4 questions of the Model Study
d = pd.DataFrame({
    "skip effect (M3-M1)":   T["M3"] - T["M1"],
    "weight effect (M2-M1)": T["M2"] - T["M1"],
    "M4-M1":                 T["M4"] - T["M1"],
    "sum of singles":        (T["M3"] - T["M1"]) + (T["M2"] - T["M1"]),
    "seed noise |M1_s1-M1|": (T["M1_seed1"] - T["M1"]).abs()})
d["interaction (M4-M1-sum)"] = d["M4-M1"] - d["sum of singles"]
print(d.round(4).to_string())
nets = {n: load_net(n, f) for n, f in [("M1", fcn), ("M2", fcn), ("M3", fcn8), ("M4", fcn8)]}
show_preds(nets, val_ds, [min(i, len(val_ds) - 1) for i in VIS_IDX])
''')
md('''
**Answers (TODO, use the numbers above):** which classes change most with skip and why (Lecture 5-2) · small classes with / without weights, explained through the loss (Lecture 5-1) · is M4 = sum of the two single effects? · are the differences larger than the seed noise?
''')

md('''
## 5. Task 2 — hypothesis-driven improvement (≥ 2 rounds, one factor per round, on top of the previous one)

Starting point = M4 (TA encoder + skip + class weights). Rounds differ from M1–M4 and the architecture is not redesigned.

| round | problem | change (one factor) |
|---|---|---|
| R1 | train/test appearance gap (daytime vs dusk, only 445 images, overfitting) | + photometric augmentation |
| R2 | small / thin classes still low; mIoU is a per-class metric | + soft-Dice term in the loss |

Write hypothesis / prediction / result / explanation in the report (`RUNS` json files are the logs).
''')
code('''
run("R1_photometric", fcn8, weighted=True, photometric=True)
run("R2_dice",        fcn8, weighted=True, photometric=True, dice=0.5)
curves(["M4", "R1_photometric", "R2_dice"])
T2 = table(["M4", "R1_photometric", "R2_dice"]); print(T2.to_string())
print((T2.diff(axis=1).iloc[:, 1:]).round(4).to_string())
''')

md('''
## 6. Task 3 — my own model (`UNetCtx`, 4.73 M parameters)

U-Net (4 down-samplings, full-resolution decoder with concatenated skips) + a dilated residual context block at stride 16 (dilations 1, 2, 4, 8).
Trained with the best recipe from Task 2 (class-weighted CE + Dice, photometric augmentation) for a longer schedule.
''')
code('''
net_try = network.build_model()
print(f"parameters: {sum(p.numel() for p in net_try.parameters()):,}  (limit 5,000,000)")
for n, c in net_try.named_children(): print(f"  {n:6s} {sum(p.numel() for p in c.parameters()):>10,}")
del net_try
r_final = run("T3_unet", network.build_model, weighted=True, photometric=True, dice=0.5, epochs=EPOCHS_FINAL)
# controlled comparison: same recipe / same 40 epochs as R2, only the architecture changes
run("T3_unet_40ep", network.build_model, weighted=True, photometric=True, dice=0.5, epochs=EPOCHS)
curves(["R2_dice", "T3_unet_40ep", "T3_unet"])
print(table(["M1", "M4", "R2_dice", "T3_unet_40ep", "T3_unet"]).to_string())
''')
code('''
net_final = load_net("T3_unet", network.build_model)
pim = per_image_miou(net_final, val_ds)
show_preds({"M1": nets["M1"], "R2_dice": load_net("R2_dice", fcn8), "T3_unet": net_final}, val_ds, [min(i, len(val_ds) - 1) for i in VIS_IDX])
torch.save(net_final.state_dict(), "final_model.pth")        # state_dict, as required
print("saved final_model.pth  | val mIoU (fp32):", RUNS["T3_unet"]["miou"])
''')

md("## 7. Predict test_public and package")
code('''
# test.py = exactly what the TA runs (banned-package check, parameter limit, output shape)
sh("python test.py --weights final_model.pth --split val")
sh("python test.py --weights final_model.pth --split test_public --out test_public_pred")
print(len(os.listdir("test_public_pred")), "prediction PNGs")
''')
code('''
# sanity: PNGs are single channel, values in 0..10
from PIL import Image as _I
f = sorted(os.listdir("test_public_pred"))[0]; a = np.asarray(_I.open(f"test_public_pred/{f}"))
print(f, a.shape, a.dtype, "values:", np.unique(a).tolist())
assert a.ndim == 2 and a.max() < NUM_CLASSES

shutil.rmtree("submit", ignore_errors=True); os.makedirs("submit/model")
shutil.copy("final_model.pth", "submit/"); shutil.copy("model/network.py", "submit/model/")
shutil.copytree("test_public_pred", "submit/test_public_pred")
# add this notebook as submit/Lab04.ipynb (File -> Download .ipynb), then zip -> Lab04_<id>.zip
if os.path.exists("Lab04.ipynb"): shutil.copy("Lab04.ipynb", "submit/")
print(shutil.make_archive(f"Lab04_{STUDENT_ID}", "zip", "submit"))
''')

nb = nbf.v4.new_notebook(); nb.cells = cells
nb.metadata = {"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"}}
nbf.write(nb, f"{ROOT}/Lab04.ipynb"); print("wrote", f"{ROOT}/Lab04.ipynb", len(cells), "cells")
