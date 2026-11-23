"""
Lab04 model (self-contained: only torch / torch.nn / torch.nn.functional).

Interface used by test.py:
    build_model() -> nn.Module
    model(x): x [B, 3, 360, 480] float in [0, 1]  ->  logits [B, 11, 360, 480]

This file holds three things:
  * SmallFCN   - the TA baseline (skip=False) and the FCN-8s style variant (skip=True)
                 used for the Model Study (M1..M4).  The encoder is unchanged; skip
                 connections are only 1x1 score convs + upsample + add (no decoder blocks).
  * UNetCtx    - my own model for Task 3: U-Net with a dilated context block at the bottleneck.
  * build_model() returns UNetCtx (the submitted model).
"""
import torch
import torch.nn as nn
import torch.nn.functional as F

NUM_CLASSES = 11


def _cbr(cin, cout, k=3, d=1):
    """conv - BN - ReLU (padding keeps the spatial size)."""
    p = d * (k // 2)
    return nn.Sequential(nn.Conv2d(cin, cout, k, padding=p, dilation=d, bias=False),
                         nn.BatchNorm2d(cout), nn.ReLU(inplace=True))


class ConvBlock(nn.Module):
    """two 3x3 conv-BN-ReLU (same as the TA baseline)."""

    def __init__(self, cin, cout):
        super().__init__()
        self.net = nn.Sequential(_cbr(cin, cout), _cbr(cout, cout))

    def forward(self, x):
        return self.net(x)


# --------------------------------------------------------------------------------------
# TA baseline (+ optional FCN-8s style skip connections for the Model Study)
# --------------------------------------------------------------------------------------
class SmallFCN(nn.Module):
    def __init__(self, num_classes=NUM_CLASSES, base=24, skip=False):
        super().__init__()
        c = [base, base * 2, base * 4, base * 8, base * 16]
        self.skip = skip
        self.stages = nn.ModuleList([ConvBlock(3, c[0])] + [ConvBlock(c[i], c[i + 1]) for i in range(4)])
        self.head = nn.Sequential(
            nn.Conv2d(c[4], c[4], 3, padding=1, bias=False), nn.BatchNorm2d(c[4]), nn.ReLU(inplace=True),
            nn.Conv2d(c[4], num_classes, 1))
        if skip:  # 1x1 "score" convs on the stride-16 and stride-8 encoder features (FCN-8s)
            self.score16 = nn.Conv2d(c[3], num_classes, 1)
            self.score8 = nn.Conv2d(c[2], num_classes, 1)

    def forward(self, x):
        H, W = x.shape[-2:]
        x = (x - 0.5) / 0.5
        feats = []
        for stage in self.stages:
            x = F.max_pool2d(stage(x), 2)
            feats.append(x)                       # strides 2, 4, 8, 16, 32
        out = self.head(x)                        # stride 32 logits
        if self.skip:
            up = lambda t, ref: F.interpolate(t, size=ref.shape[-2:], mode="bilinear", align_corners=False)
            out = up(out, feats[3]) + self.score16(feats[3])   # stride 16
            out = up(out, feats[2]) + self.score8(feats[2])    # stride 8
        return F.interpolate(out, size=(H, W), mode="bilinear", align_corners=False)


# --------------------------------------------------------------------------------------
# My model: U-Net + dilated context block
# --------------------------------------------------------------------------------------
class ContextBlock(nn.Module):
    """Residual block of dilated 3x3 convs: enlarges the receptive field at 1/16 resolution
    without further down-sampling (helps large regions: Sky / Building / Road / Tree)."""

    def __init__(self, c, dilations=(1, 2, 4, 8)):
        super().__init__()
        self.convs = nn.ModuleList([_cbr(c, c, 3, d) for d in dilations])

    def forward(self, x):
        for conv in self.convs:
            x = x + conv(x)
        return x


class Up(nn.Module):
    """bilinear up-sample -> concat encoder skip -> ConvBlock."""

    def __init__(self, cin, cskip, cout):
        super().__init__()
        self.block = ConvBlock(cin + cskip, cout)

    def forward(self, x, skip):
        x = F.interpolate(x, size=skip.shape[-2:], mode="bilinear", align_corners=False)
        return self.block(torch.cat([x, skip], dim=1))


class UNetCtx(nn.Module):
    def __init__(self, num_classes=NUM_CLASSES, c=(32, 64, 128, 160, 224), drop=0.1):
        super().__init__()
        self.enc = nn.ModuleList([ConvBlock(3, c[0])] + [ConvBlock(c[i], c[i + 1]) for i in range(4)])
        self.ctx = ContextBlock(c[4])
        self.drop = nn.Dropout2d(drop)
        self.up3 = Up(c[4], c[3], c[3])
        self.up2 = Up(c[3], c[2], c[2])
        self.up1 = Up(c[2], c[1], c[1])
        self.up0 = Up(c[1], c[0], c[0])
        self.cls = nn.Conv2d(c[0], num_classes, 1)

    def forward(self, x):
        x = (x - 0.5) / 0.5                       # normalize inside forward (required by the lab)
        e0 = self.enc[0](x)                       # stride 1
        e1 = self.enc[1](F.max_pool2d(e0, 2))     # stride 2
        e2 = self.enc[2](F.max_pool2d(e1, 2))     # stride 4
        e3 = self.enc[3](F.max_pool2d(e2, 2))     # stride 8
        e4 = self.enc[4](F.max_pool2d(e3, 2))     # stride 16
        z = self.drop(self.ctx(e4))
        z = self.up3(z, e3)
        z = self.up2(z, e2)
        z = self.up1(z, e1)
        z = self.up0(z, e0)
        return self.cls(z)


def build_baseline(skip=False):
    return SmallFCN(skip=skip)


def build_model():
    return UNetCtx()
