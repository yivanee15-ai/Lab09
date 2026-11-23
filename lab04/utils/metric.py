"""mIoU for Lab04. Do not modify."""
import numpy as np
import torch

from utils.dataset import NUM_CLASSES, IGNORE_INDEX, CLASSES


class SegMetric:
    """Confusion matrix: rows = ground truth, columns = prediction."""

    def __init__(self, num_classes=NUM_CLASSES, ignore_index=IGNORE_INDEX):
        self.n = num_classes
        self.ignore = ignore_index
        self.reset()

    def reset(self):
        self.cm = np.zeros((self.n, self.n), dtype=np.int64)

    def update(self, pred, target):
        if isinstance(pred, torch.Tensor):
            pred = pred.detach().cpu().numpy()
        if isinstance(target, torch.Tensor):
            target = target.detach().cpu().numpy()
        pred = np.asarray(pred).astype(np.int64).ravel()
        target = np.asarray(target).astype(np.int64).ravel()
        keep = (target != self.ignore) & (target >= 0) & (target < self.n)
        pred = np.clip(pred[keep], 0, self.n - 1)
        self.cm += np.bincount(target[keep] * self.n + pred,
                               minlength=self.n * self.n).reshape(self.n, self.n)

    def iou(self):
        tp = np.diag(self.cm).astype(np.float64)
        denom = self.cm.sum(0) + self.cm.sum(1) - tp
        with np.errstate(divide="ignore", invalid="ignore"):
            return np.where(denom > 0, tp / denom, np.nan)

    def miou(self):
        return float(np.nanmean(self.iou()))

    def pixel_acc(self):
        return float(np.diag(self.cm).sum() / max(self.cm.sum(), 1))

    def report(self):
        lines = [f"{c:<11s} IoU = {v:.4f}" for c, v in zip(CLASSES, self.iou())]
        lines.append(f"{'mIoU':<11s}       {self.miou():.4f}")
        lines.append(f"{'Pixel acc':<11s}       {self.pixel_acc():.4f}")
        return "\n".join(lines)
