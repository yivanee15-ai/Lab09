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
 "M2":   ([.8380, .5891, .0641, .8868, .6989, .7276, .1790, .3061, .7827, .2915, .4629], .5297),
 "M3":   ([.8988, .7956, .0934, .9352, .7567, .7822, .2801, .5028, .8614, .4704, .6560], .6393),
 "M4":   ([.8748, .6423, .1239, .9295, .7489, .7587, .2483, .3679, .8226, .3783, .6199], .5923),
 "R2":   ([.8797, .6972, .1196, .9263, .7614, .7646, .2606, .3984, .8130, .4123, .6133], .6042),
 "T40":  ([.8739, .6410, .1418, .9408, .7952, .7596, .2029, .3828, .8210, .4158, .6855], .6055),
 "T120": ([.8932, .7645, .2774, .9459, .8059, .7773, .3525, .5471, .8515, .5739, .7960], .6896),
 "T3":   ([.8792, .6390, .1551, .9343, .7884, .7484, .2053, .3825, .8062, .3952, .6940], .6025),
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
from docx.shared import Cm
pic_par = after(P[4], "")
pic_par.add_run().add_picture("shot.png", width=Cm(6.8))
def nolist(par):
    pPr = par._p.pPr
    if pPr is not None:
        for n in pPr.findall(docx.oxml.ns.qn("w:numPr")): pPr.remove(n)
        par.paragraph_format.left_indent = Cm(1.0)
nolist(pic_par)
chain(P[4], [])
P[4]._p.addnext(pic_par._p)
_t = chain(P[5], [
 "上圖上半部為 test.py --split val（per-class IoU、mIoU 0.6446、pixel acc 0.9026），下半部為 test.py --split test_public --out test_public_pred（三個 [OK]、參數量 3,987,945、wrote 50 predictions）。提交的 final_model.pth = FCN + skip，一般 CE，40 epoch，epoch 37。"])
nolist(_t)

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
ms = [("M1", "3,984,755", f"seed 0: {f4(RES['M1'][1])}  seed 1: 0.5613"), ("M2", "3,984,755", f4(RES["M2"][1])),
      ("M3", "3,987,945", f4(RES["M3"][1])), ("M4", "3,987,945", f4(RES["M4"][1]))]
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
 "結果（val mIoU，seed 0）：M1 0.5682（seed 1：0.5613，seed noise ≈ 0.007）、M2 0.5297、M3 0.6393、M4 0.5923。",
 "(1) skip 的效果（M3−M1 = +0.071）遠大於 seed noise（0.007）：變化最大的是 Bicyclist +0.220、Pedestrian +0.144、SignSymbol +0.110、Fence +0.092、Pole +0.080；Sky、Building、Tree 只增加 0.01–0.02。原因：5 次 max-pool 使輸出為 1/32 解析度，細小或細長物體的空間資訊被丟失，FCN-8s 式 skip 把 stride 8/16 的高解析度特徵補回（Lec 5-2）。pixel acc 也由 0.885 升至 0.900。",
 "(2) 小類別在有/無 class weight 下：單獨使用加權 CE（M2−M1）反而使 mIoU 下降 0.039，僅 Pole +0.051、Bicyclist +0.027 上升，Building −0.198、Fence −0.105、Sky −0.044、Tree −0.045 大幅下降，pixel acc −0.074。解釋：加權 CE 讓稀有類別的錯誤在 loss 中被放大（w_c 最大 10），模型為了降低它們的 loss 增加對這些類別的預測，造成大類別（Building 等）被誤判，FP 增加使其 IoU 下降；沒有 skip 時模型本來就看不清小物體，放大 loss 也學不到細節，只是移動了決策邊界。有 skip（M4−M3）時加權同樣使 mIoU 降低 0.047：Pole 0.093→0.124 上升，但 Building、Fence、Pedestrian 下降。",
 "(3) M4 不是兩個單獨效果之和：M4−M1 = +0.024，兩者之和為 0.071 − 0.039 = +0.033，交互作用 −0.009（Pedestrian −0.057、Bicyclist −0.063、SignSymbol −0.041 的交互作用為負；Sky、Sidewalk、Tree 為正）。原因：skip 與 class weight 都是在補強小類別，效果重疊，而 skip 已經讓小類別的特徵可用，額外的加權不再有同等的邊際收益，只剩下對大類別的副作用。注意 M4（0.5923）低於 M3（0.6393），即此設定下 class weight 對 mIoU 是負面的。",
 "(4) 差異是否大於 seed noise：M1 兩個 seed 的 mIoU 相差 0.0069，單類別最大差 Fence 0.065、SignSymbol 0.034。skip 效果（+0.071）、加權效果（−0.039）的 mIoU 差距都大於 0.007，可認為真實；單類別則需謹慎，例如 Fence 的 M3−M1（+0.092）僅略大於其 seed noise（0.065），M4 的 Fence 變化（−0.043）小於 seed noise，不能下結論。",
])

# ---- Task 2 ---------------------------------------------------------------------------
t4 = T[4]
r1 = ["1", "外觀差異（白天/傍晚）與僅 445 張訓練圖造成的泛化差距（Task 1 #1 / train-val 差距）", "加入亮度/對比/飽和度抖動，增加訓練分佈多樣性，應降低過擬合並使 val 提升。",
      "預期 mIoU 小幅提升（約 +0.005 ~ +0.01），主要在 Sky/Building/Tree 等受光線影響的類別。",
      "M4 0.5923 → R1 0.5887（−0.0036），pixel acc 0.8498 → 0.8477。Sky +0.007、Building +0.010、Sidewalk +0.016、Pedestrian +0.016；SignSymbol −0.020、Fence −0.019、Bicyclist −0.018、Pole −0.009。",
      "預測未成立：mIoU 沒有提升（−0.0036，小於 M1 的 seed noise 0.007，視為沒有可量測的差異）。只有受光線影響的大類別（Sky、Building、Sidewalk）小幅上升，但稀有類別（SignSymbol、Fence、Bicyclist）反而下降；可能原因是限制 mIoU 的是稀有類別的特徵與樣本數，而非光照變化，且光度抖動讓本來就少的小物體更難學（此為推測，未另做實驗驗證）。"]
r2 = ["2", "小/細長類別仍然偏低（Task 1 #1）", "mIoU 為各類別 IoU 的平均，Dice 直接優化區域重疊，對小類別的梯度不會被像素數稀釋，應補強加權 CE 的不足。",
      "預期 mIoU 再提升約 +0.01，Pole / SignSymbol / Pedestrian 上升。",
      f"R1 0.5887 → R2 {f4(RES['R2'][1])}（+0.0155），pixel acc 0.8477 → 0.8625。Fence +0.050、Building +0.045、SignSymbol +0.033、Pedestrian +0.018、Tree +0.014、Bicyclist +0.012、Pole +0.005；Sidewalk −0.004、Sky −0.003。",
      "預測大致成立：+0.0155 約為 seed noise（0.007）的兩倍，且為單一 seed，只能說「很可能是真實改善」。上升最多的是 Fence、Building、SignSymbol（與 Dice 對區域重疊的優化吻合），Pole 只增加 0.005，仍是最大瓶頸。注意 R2（0.6042）仍低於 M3（0.6393，無 class weight 的 skip 模型），顯示 Task 2 以 M4（加權 CE）為起點本身就不是最佳起點。"]
for i, row in enumerate([r1, r2]):
    for j, txt in enumerate(row): setcell(t4.rows[i + 1].cells[j], txt, 8)
chain(P[23], [("【貼圖】R1、R2 的訓練曲線或 log（ckpt/R1_photometric.json、R2_dice.json）。", PH)])

# ---- Task 3 ---------------------------------------------------------------------------
tb = d.add_table(rows=1, cols=4); tb.style = T[2].style
hdr = ["模組", "結構", "輸出 stride / 通道", "參數量"]
rows3 = [
 ("Encoder ×5", "ConvBlock（2×[3×3 conv-BN-ReLU]）+ 2×2 max-pool；forward 內先 (x−0.5)/0.5 normalize", "2,4,8,16,32；24/48/96/192/384", "—"),
 ("Head", "3×3 conv-BN-ReLU（384）→ 1×1 conv → 11 類 logits", "32；11", "—"),
 ("Skip（FCN-8s 式）", "stride-16（192 ch）與 stride-8（96 ch）特徵各接 1×1 score conv；bilinear 上採樣後逐元素相加（無額外 decoder block）", "16, 8；11", "3,190"),
 ("輸出", "bilinear 放大至 360×480，輸出 [B,11,360,480] logits", "1；11", "—"),
 ("合計", "TA encoder + 兩條 skip，輸出 stride 8 後放大", "—", "3,987,945（≤ 5,000,000；encoder + head 為 3,984,755）"),
]
for j, h in enumerate(hdr): setcell(tb.rows[0].cells[j], h, 8, True)
for r in rows3:
    cells = tb.add_row().cells
    for j, v in enumerate(r): setcell(cells[j], v, 8)
P[26]._p.addnext(tb._tbl)
chain(P[26], [])  # keep anchor
cur = after(P[26], "訓練設定：loss = 一般 cross-entropy（void 忽略，無 class weight、無 Dice）；Adam，lr 1e-3，CosineAnnealing；batch size 8；混合精度 fp16；epochs = 40（選 val mIoU 最高的 epoch 37）；augmentation：水平翻轉、隨機縮放 0.75–1.25（crop/pad，label 用 NEAREST），無光度增強；seed 0；val 僅用於驗證與選模，未用於訓練，test_public 僅用於產生預測。", hl=False)
# the table must come before the training-settings paragraph: move it
P[26]._p.addnext(tb._tbl)

chain(P[29], [
 ("設計理由與證據：", dict(bold=True)),
 "• 最終模型 = TA baseline 的 encoder + FCN-8s 式 skip（Model Study 的 M3 配置，一般 CE）。它是由實驗結果選出，不是事先設計的複雜架構：M3 在 val mIoU 上是 M1–M4 中最高。",
 "• 薄物體 / 小類別（Task 1 #2）：skip 把 stride 8/16 的高解析度特徵補回，M3−M1：Bicyclist +0.220、Pedestrian +0.144、SignSymbol +0.110、Fence +0.092、Pole +0.080，遠大於 M1 的 seed noise（mIoU 0.007）。",
 "• 使用一般 CE：Model Study 顯示 class weight 使 mIoU 下降（M2−M1 −0.039、M4−M3 −0.047），故最終模型不使用。",
 "• 參數預算：3.99M，低於 5M，且無額外 decoder block（skip 只增加 3,190 個參數）。",
 ("證據（val mIoU）：", dict(bold=True)),
 f"M1 {f4(RES['M1'][1])}（seed 1：0.5613）→ M3 {f4(RES['M3'][1])}（skip，+0.071）；提交模型為 M3 配置重新訓練一次：0.6446（與第一次的差 0.005，屬於重訓雜訊範圍）。M2 0.5297、M4 0.5923。",
 "• 另外嘗試過自己設計的 U-Net + 膨脹卷積 context block（4.73M 參數，加權 CE + Dice + 光度增強）：40 epoch val mIoU 為 0.6055 / 0.6025（兩次執行），低於 M3；先前一次 120 epoch 版本曾達 0.6896，但該權重遺失、未提交，且與 M3 的差異同時包含架構、loss 與訓練長度，無法分離歸因。",
 ("誠實的限制：", dict(bold=True)),
 "val 也用於選 epoch，所以 val mIoU 對 public/private test 略為樂觀；沒有實驗比較「M3 訓練 120 epoch」，無法判斷更長的訓練是否也會讓 M3 提升。",
])

# ---- Reflections ----------------------------------------------------------------------
chain(P[32], [
 "學到：mIoU 對每個類別等權，因此 pixel accuracy 高不代表分割好；M1→M4 pixel acc 下降 0.035 但 mIoU 上升 0.024。",
 "失敗的嘗試：（最大的一個）把 class weight + Dice 放進自己設計的 U-Net，預期能改善小類別，但 Model Study 顯示加權 CE 讓 mIoU 下降，U-Net（40 epoch 0.6025）低於 M3（0.6393），最後改交 M3 配置。另外預期把 label 的 BILINEAR 改成 NEAREST 會改善稀有類別，但 M1 與 diag_TA 的 mIoU 沒有可量測的差異（−0.0044）；資料問題確實存在（0.94% 像素 id 無效），但在此設定下影響小。另一個教訓是流程上的：Kaggle 互動式 session 重啟後 /kaggle/working 被清空，所有實驗結果與 ckpt 消失，只能重新執行；之後改以 Save Version 並立即下載輸出。",
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
