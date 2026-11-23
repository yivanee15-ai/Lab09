"""Fill the Lab04 report template. Numbers come from RES; "TBD" = not available yet (never invented)."""
import copy, docx
from docx.shared import Pt
from docx.enum.text import WD_COLOR_INDEX

TBD = "TBD"
CL = ["Sky", "Building", "Pole", "Road", "Sidewalk", "Tree", "SignSymbol", "Fence", "Car", "Pedestrian", "Bicyclist"]
# per-class IoU + mIoU (values reported by the user from the Kaggle run whose files were later lost)
RES = {
 "diag": ([.8843, .7898, .0076, .9085, .7094, .7699, .1756, .4581, .8223, .3286, .4443], .5726),
 "M1":   ([.8818, .7873, .0135, .9066, .7275, .7723, .1702, .4108, .8175, .3267, .4362], .5682),
 "M4":   ([.8748, .6423, .1239, .9295, .7489, .7587, .2483, .3679, .8226, .3783, .6199], .5923),
 "R2":   ([.8797, .6972, .1196, .9263, .7614, .7646, .2606, .3984, .8130, .4123, .6133], .6042),
 "T40":  ([.8739, .6410, .1418, .9408, .7952, .7596, .2029, .3828, .8210, .4158, .6855], .6055),
 "T3":   ([.8932, .7645, .2774, .9459, .8059, .7773, .3525, .5471, .8515, .5739, .7960], .6896),
}
f4 = lambda x: f"{x:.4f}"

d = docx.Document("tpl.docx")
P = list(d.paragraphs)           # snapshot of template paragraphs (indices from the inspection)
T = d.tables

def style_runs(par, size=10, bold=False, hl=False):
    for r in par.runs:
        r.font.size = Pt(size); r.bold = bold
        if hl: r.font.highlight_color = WD_COLOR_INDEX.YELLOW

def after(par, text, size=10, bold=False, hl=False):
    """insert a new paragraph after `par` (copy of its paragraph properties), return it."""
    new = copy.deepcopy(par._p)
    for ch in list(new):
        if ch.tag.endswith("}r") or ch.tag.endswith("}hyperlink"): new.remove(ch)
    par._p.addnext(new)
    np_ = docx.text.paragraph.Paragraph(new, par._parent)
    run = np_.add_run(text); run.font.size = Pt(size); run.bold = bold
    if hl: run.font.highlight_color = WD_COLOR_INDEX.YELLOW
    return np_

def chain(par, items):
    for it in items:
        if isinstance(it, tuple): par = after(par, it[0], **it[1])
        else: par = after(par, it)
    return par

PH = dict(hl=True)   # highlighted placeholder (user must fill / paste)

def setcell(cell, text, size=8, bold=False):
    p = cell.paragraphs[0]
    for r in list(p.runs): r._r.getparent().remove(r._r)
    r = p.add_run(text); r.font.size = Pt(size); r.bold = bold
    for extra in cell.paragraphs[1:]: extra._p.getparent().remove(extra._p)

# ---- header table -------------------------------------------------------------------
setcell(T[0].rows[0].cells[0], "Name: 許逸凡", 11); setcell(T[0].rows[0].cells[1], "Student ID: 315505009", 11)

# ---- result screenshots ---------------------------------------------------------------
chain(P[4], [("【貼上截圖：test.py --split test_public 的終端輸出：3 個 [OK]、參數量 4,734,795、wrote 50 predictions】", PH)])
chain(P[5], [("【貼上截圖：test.py --split val 的 per-class IoU 與 mIoU】", PH),
             f"（參考：先前一次完整執行的最終模型 val mIoU = {f4(RES['T3'][1])}；本報告提交的 final_model.pth 以最終截圖為準：val mIoU = TBD。）"])

# ---- Task 1 ---------------------------------------------------------------------------
t1 = T[1]
rows = [
 ("1", "小類別與細長物體幾乎沒有學到（Pole、SignSymbol、Pedestrian）",
  "diag_TA（TA 原版）per-class IoU：Pole 0.008、SignSymbol 0.176、Pedestrian 0.329、Bicyclist 0.444；Road 0.909、Sky 0.884。訓練像素比例：Pole 1.24%、SignSymbol 1.34%、Pedestrian 0.70%、Bicyclist 0.32%，Road 31.1%（Fig. 2）。mIoU 0.5726，pixel acc 0.8854。",
  "Lec 5-1：類別不平衡下，CE 的總和被大類別主導；mIoU 對每類等權，小類別拖低 mIoU。",
  "class-weighted CE（M2/M4）、Dice loss（R2）、最終模型使用加權 CE + Dice。"),
 ("2", "baseline 沒有 skip connection，輸出 stride 為 32",
  "5 次 max-pool，在 1/32 解析度預測後以 bilinear 放大 32 倍；細長的 Pole 寬度僅數個像素，IoU 0.008。（Fig. 3 / Fig. 4：Pole 被預測為何類，待貼圖確認。）",
  "Lec 5-2：重複下採樣丟失空間細節；skip / 多尺度特徵融合（FCN-8s、U-Net）可補回高解析度資訊。",
  "M3/M4 加入 FCN-8s 式 skip（stride 16 與 8）；最終模型使用 U-Net（stride 1/2/4/8 skip）。"),
 ("3", "資料增強時 label 以 BILINEAR 縮放，產生不存在的 class id",
  "第一張訓練標籤原本只有 id {0,1,2,3,4,5,6,8,11}；以 1.25 倍 BILINEAR 縮放後出現 7、9、10（Fence / Pedestrian / Bicyclist，皆為稀有類別），共 2546 像素（0.94%）；NEAREST 為 0 像素。",
  "標籤是離散類別 id，不可內插（Lec 5-1：loss 的目標必須是有效類別）。",
  "label 改用 NEAREST（M1 起）。對照：M1 mIoU 0.5682 vs diag_TA 0.5726（−0.0044），在目前已知的雜訊範圍內看不出可量測的改善；M1 訓練 loss 0.253 vs 0.376。"),
]
for i, row in enumerate(rows):
    if i + 1 >= len(t1.rows): t1._tbl.append(copy.deepcopy(t1.rows[-1]._tr))
    for j, txt in enumerate(row): setcell(t1.rows[i + 1].cells[j], txt, 8)
cur = chain(P[8], [
 ("已檢查但未造成差異：以 pixel accuracy 或 val mIoU 選 epoch，diag_TA 兩者皆選到 epoch 37（mIoU 0.5726），因此不列為問題。", {}),
 ("訓練／驗證曲線（Fig. 1）：diag_TA 的 train loss 0.376、val CE 0.369（訓練時有增強，故 train loss 未必較低）；標籤改乾淨後 M1 train loss 0.253、val CE 0.352，開始出現輕微的泛化差距，val mIoU 約在 epoch 28 之後趨於持平。", {}),
 ("【貼圖】Fig. 1 訓練/驗證曲線　Fig. 2 per-class IoU 與像素頻率　Fig. 3 confusion matrix（row-normalised）　Fig. 4 好/壞案例預測（最好 val #45、#46，mIoU 0.653/0.649；最差 val #8、#6，mIoU 0.182/0.211；場景與錯誤類型請依圖補述）", PH),
])

# ---- Model study ----------------------------------------------------------------------
t2 = T[2]
ms = [("M1", "3,984,755", f"seed 0: {f4(RES['M1'][1])}  seed 1: TBD"), ("M2", "3,984,755", TBD),
      ("M3", "3,987,945", TBD), ("M4", "3,987,945", f4(RES["M4"][1]))]
for i, (_, par, miou) in enumerate(ms):
    setcell(t2.rows[i + 1].cells[3], par, 9); setcell(t2.rows[i + 1].cells[4], miou, 9)
t3 = T[3]
for i, k in enumerate(["M1", "M2", "M3", "M4"]):
    vals = [f"{v:.3f}" for v in RES[k][0]] if k in RES else [TBD] * 11
    for j, v in enumerate(vals): setcell(t3.rows[i + 1].cells[j + 1], v, 7)

chain(P[17], [("【貼圖】M1–M4 在同一 2 張 val 圖（val #10、#60）上的預測與 ground truth。", PH)])
chain(P[20], [
 ("預期：skip 讓 Pole、SignSymbol、Fence、Bicyclist 等細長/小物體提升（Lec 5-2：高解析度特徵補回細節），對 Sky、Road 等大區域影響小；class weight 提高小類別 recall，但以犧牲大類別精度（Building、Road 的 FP/FN）與 pixel accuracy 為代價（Lec 5-1：加權 CE 改變各類別的梯度比重）；M4 預期約為兩者效果相加，但可能小於相加（兩者都在修補小類別，效果重疊）。", {}),
 ("已有結果（M1 → M4，seed 0）：mIoU 0.5682 → 0.5923；pixel accuracy 0.8852 → 0.8498（下降）。變化最大的類別：Bicyclist 0.436 → 0.620（+0.184）、Pole 0.014 → 0.124（+0.110）、SignSymbol 0.170 → 0.248（+0.078）、Pedestrian +0.052；代價：Building 0.787 → 0.642（−0.145）、Fence −0.043。這符合加權 CE 以大類別精度換取小類別 recall 的預期。", {}),
 ("M2 與 M3 的單獨效果、M4 是否等於兩者之和、以及與 M1 seed 1 雜訊的比較：TBD（取得 M2、M3、M1 seed 1 數字後填入；差異未大於 seed noise 時，應只寫為「無法確認」）。", PH),
])

# ---- Task 2 ---------------------------------------------------------------------------
t4 = T[4]
r1 = ["1", "小類別與外觀差異（白天/傍晚、僅 445 張）導致泛化差距（Task 1 #1）", "加入亮度/對比/飽和度抖動，增加訓練分佈的多樣性，應降低過擬合並使 val 提升。",
      "預期 mIoU 小幅提升（約 +0.005 ~ +0.01），主要在 Sky/Building/Tree 等受光線影響的類別。", "TBD（R1_photometric 的 val mIoU 與 per-class 尚未取得）", "TBD"]
r2 = ["2", "小/細長類別仍然偏低（Task 1 #1）", "mIoU 為各類別 IoU 的平均，Dice 直接優化區域重疊，對小類別的梯度不會被像素數稀釋，應補強加權 CE 的不足。",
      "預期 mIoU 再提升約 +0.01，Pole/SignSymbol/Pedestrian 上升。",
      f"M4 {f4(RES['M4'][1])} → R2 {f4(RES['R2'][1])}（相對 M4 +{RES['R2'][1]-RES['M4'][1]:.4f}，含 R1 的光度增強，R1 單獨數字 TBD）。Pole 0.124→0.120、SignSymbol 0.248→0.261、Pedestrian 0.378→0.412、Fence 0.368→0.398、Building 0.642→0.697；Bicyclist 0.620→0.613。",
      "TBD（需先取得 R1，才能分開 R1 與 R2 各自的貢獻；M4→R2 的 +0.012 是否大於 seed noise 亦待 M1 seed 1）。"]
for i, row in enumerate([r1, r2]):
    for j, txt in enumerate(row): setcell(t4.rows[i + 1].cells[j], txt, 8)
chain(P[23], [("【貼圖】R1、R2 的訓練曲線或 log（ckpt/R1_photometric.json、R2_dice.json）。", PH)])

# ---- Task 3 ---------------------------------------------------------------------------
tb = d.add_table(rows=1, cols=4); tb.style = T[2].style
hdr = ["模組", "結構", "輸出 stride / 通道", "參數量"]
rows3 = [
 ("Encoder ×5", "ConvBlock（2×[3×3 conv-BN-ReLU]）；前 4 個之後 2×2 max-pool", "1,2,4,8,16；32/64/128/160/224", "1,477,856"),
 ("Context block", "4 個殘差 3×3 dilated conv-BN-ReLU（d = 1,2,4,8），Dropout2d 0.1", "16；224", "1,808,128"),
 ("Decoder up3→up0", "bilinear 上採樣 + concat 對應 encoder 特徵（skip）+ ConvBlock", "8,4,2,1；160/128/64/32", "784,000 + 479,744 + 147,712 + 36,992"),
 ("Classifier", "1×1 conv → 11 類 logits（輸入先於 forward 內 normalize）", "1；11", "363"),
 ("合計", "UNetCtx，輸出 [B,11,360,480]", "—", "4,734,795（≤ 5,000,000）"),
]
for j, h in enumerate(hdr): setcell(tb.rows[0].cells[j], h, 8, True)
for r in rows3:
    cells = tb.add_row().cells
    for j, v in enumerate(r): setcell(cells[j], v, 8)
P[26]._p.addnext(tb._tbl)
chain(P[26], [])  # keep anchor
cur = after(P[26], "訓練設定：loss = class-weighted CE（w_c = median(f)/f_c，截斷於 [0.2,10]）+ 0.5 × soft-Dice；Adam，lr 1e-3，CosineAnnealing；batch size 8；混合精度 fp16；epochs = TBD（最終提交模型的實際 epoch 數）；augmentation：水平翻轉、隨機縮放 0.75–1.25（crop/pad，label 用 NEAREST）、亮度/對比/飽和度抖動 0.7–1.3；seed 0；以 val mIoU 選 epoch，val 僅用於驗證與選模，未用於訓練，test_public 僅用於產生預測。", hl=False)
# the table must come before the training-settings paragraph: move it
P[26]._p.addnext(tb._tbl)

chain(P[29], [
 ("設計理由：", dict(bold=True)),
 "• 薄物體（Pole、SignSymbol）：U-Net 的全解析度 skip（stride 1/2/4/8）把高解析度特徵直接接到 decoder，對應 Task 1 #2（stride-32 輸出）。",
 "• 大區域（Sky、Road、Building）：stride-16 的 dilated residual context block（d=1,2,4,8）在不再下採樣的前提下擴大感受野。",
 "• 小類別：沿用 Task 2 的加權 CE + Dice 與光度增強（Task 1 #1）。",
 "• 參數預算：通道數取 32/64/128/160/224，總參數 4.73M，留約 5% 餘裕，並使用 Dropout2d 抑制 445 張影像的過擬合。",
 ("證據（val mIoU；除最終模型外，皆為先前一次完整執行、40 epoch 的結果）：", dict(bold=True)),
 f"M1 {f4(RES['M1'][1])} → M4 {f4(RES['M4'][1])} → R2 {f4(RES['R2'][1])}（TA FCN）；同一訓練配方下的 U-Net 40 epoch：{f4(RES['T40'][1])}；U-Net 長訓練（120 epoch，先前執行）：{f4(RES['T3'][1])}；本次提交模型：TBD。",
 "誠實的限制：在相同 40 epoch 下，U-Net（0.6055）與加了 skip 的 FCN R2（0.6042）幾乎相同，差距遠小於可能的 seed noise；較高的最終分數來自更長的訓練，而我沒有跑「FCN 120 epoch」的對照，因此無法把提升分開歸因於架構或訓練長度。",
])

# ---- Reflections ----------------------------------------------------------------------
chain(P[32], [
 "學到：mIoU 對每個類別等權，因此 pixel accuracy 高不代表分割好；M1→M4 pixel acc 下降 0.035 但 mIoU 上升 0.024。",
 "失敗的嘗試：預期把 label 的 BILINEAR 改成 NEAREST 會改善稀有類別，但 M1 與 diag_TA 的 mIoU 沒有可量測的差異（−0.0044）；資料問題確實存在（0.94% 像素 id 無效），但在此設定下影響小。另一個教訓是流程上的：Kaggle 互動式 session 重啟後 /kaggle/working 被清空，所有實驗結果與 ckpt 消失，只能重新執行；之後改以 Save Version 並立即下載輸出。",
 "若有 10× 算力：每個實驗跑多個 seed 以估計雜訊並以均值比較；補跑 FCN 長訓練以分離架構與訓練長度的貢獻；做多尺度訓練與 flip 測試時增強；系統化搜尋 loss 權重與 Dice 係數。",
 ("【依實際情況修改】主要困難：平台排隊與 session 遺失、時間壓力。", PH),
])

# ---- AI-use log -----------------------------------------------------------------------
chain(P[39], [
 "本作業使用了 Claude（Claude Code）協助：閱讀講義、診斷 TA baseline、撰寫 model/network.py 與 Lab04.ipynb、產生報告草稿；程式與結果由本人在 Kaggle/Colab 執行並核對。",
 ("【貼上公開分享連結（非私人聊天頁 URL）】", PH),
 ("【貼上 3–5 張關鍵 prompt 截圖】", PH),
])

d.save("Lab04_report_315505009.docx")
print("saved")
