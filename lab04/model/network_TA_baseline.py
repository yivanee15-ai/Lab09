"""
Lab04 model. Keep the interface:
    build_model() -> nn.Module
    model(x): x [B, 3, 360, 480] in [0, 1]  ->  logits [B, 11, 360, 480]
"""
import torch
import torch.nn as nn
import torch.nn.functional as F

NUM_CLASSES = 11


class ConvBlock(nn.Module):
    def __init__(self, cin, cout):
        super().__init__()
        self.net = nn.Sequential(
            nn.Conv2d(cin, cout, 3, padding=1, bias=False), nn.BatchNorm2d(cout), nn.ReLU(inplace=True),
            nn.Conv2d(cout, cout, 3, padding=1, bias=False), nn.BatchNorm2d(cout), nn.ReLU(inplace=True))

    def forward(self, x):
        return self.net(x)


class SmallFCN(nn.Module):
    def __init__(self, num_classes=NUM_CLASSES, base=24):
        super().__init__()
        c = [base, base * 2, base * 4, base * 8, base * 16]
        self.stages = nn.ModuleList([ConvBlock(3, c[0])] + [ConvBlock(c[i], c[i + 1]) for i in range(4)])
        self.head = nn.Sequential(
            nn.Conv2d(c[4], c[4], 3, padding=1, bias=False), nn.BatchNorm2d(c[4]), nn.ReLU(inplace=True),
            nn.Conv2d(c[4], num_classes, 1))

    def forward(self, x):
        H, W = x.shape[-2:]
        x = (x - 0.5) / 0.5
        for stage in self.stages:
            x = F.max_pool2d(stage(x), 2)
        x = self.head(x)
        return F.interpolate(x, size=(H, W), mode="bilinear", align_corners=False)


def build_model():
    return SmallFCN()
