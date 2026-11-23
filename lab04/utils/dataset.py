"""CamVid dataset for Lab04. Label PNG: pixel value = class index, 11 = void."""
import os
import numpy as np
import torch
from PIL import Image
from torch.utils.data import Dataset

CLASSES = ["Sky", "Building", "Pole", "Road", "Sidewalk", "Tree",
           "SignSymbol", "Fence", "Car", "Pedestrian", "Bicyclist"]
NUM_CLASSES = 11
IGNORE_INDEX = 11
IMG_H, IMG_W = 360, 480

# visualization colors, index 11 = void
PALETTE = np.array([
    [128, 128, 128], [128, 0, 0], [192, 192, 128], [128, 64, 128],
    [60, 40, 222], [128, 128, 0], [192, 128, 128], [64, 64, 128],
    [64, 0, 128], [64, 64, 0], [0, 128, 192], [0, 0, 0]], dtype=np.uint8)


def to_tensor(img, lab=None):
    x = torch.from_numpy(np.asarray(img.convert("RGB"), dtype=np.float32) / 255.0).permute(2, 0, 1)
    if lab is None:
        return x
    y = torch.from_numpy(np.asarray(lab, dtype=np.int64))
    return x, y


class CamVid(Dataset):
    """transform: fn(img_pil, lab_pil) -> (img_pil, lab_pil). cache: keep decoded images in RAM."""

    def __init__(self, root, split, files=None, transform=None, cache=True):
        self.img_dir = os.path.join(root, split, "images")
        self.lab_dir = os.path.join(root, split, "labels")
        self.has_label = os.path.isdir(self.lab_dir)
        self.files = sorted(files if files is not None else os.listdir(self.img_dir))
        self.transform = transform
        self.cache = {}
        if cache:
            for name in self.files:
                self.cache[name] = self._load(name)

    def _load(self, name):
        img = Image.open(os.path.join(self.img_dir, name)).convert("RGB")
        lab = Image.open(os.path.join(self.lab_dir, name)) if self.has_label else None
        if lab is not None:
            lab.load()
        return img, lab

    def __len__(self):
        return len(self.files)

    def __getitem__(self, i):
        name = self.files[i]
        img, lab = self.cache[name] if name in self.cache else self._load(name)
        if not self.has_label:
            return to_tensor(img), name
        if self.transform is not None:
            img, lab = self.transform(img, lab)
        x, y = to_tensor(img, lab)
        return x, y


def colorize(label):
    label = np.asarray(label).copy()
    label[(label < 0) | (label > IGNORE_INDEX)] = IGNORE_INDEX
    return PALETTE[label]
