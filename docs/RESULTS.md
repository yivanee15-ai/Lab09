# 結果(自建 proxy,只能比較版本間相對好壞)

Latency = 每指令平均 cycle(1000 個指令:4 seed × 250)。DRAM 組態:min = R1/B1/無 stall/無亂序;mid = R10/B10/W2/AR2/GAP1/亂序;max = R100/B100/W20/AR20/GAP5/亂序。
面積與 T_min 來自 yosys+abc 對 Nangate45 量級的自建 liberty(scripts/mklib.py)加自寫 STA(scripts/sta.py;I/O 路徑只有 0.5T)。
abc 會把 adder 攤成 ripple,算術路徑偏悲觀;**不是 DC 結果**。

| 版本 | 面積 µm² (toy) | T_min ns (toy) | latency min | mid | max | 面積×lat×T (min, 相對 v1) | (mid, 相對 v1) |
|---|---|---|---|---|---|---|---|
| v1 | 36548 | 25.84 | 25.66 | 53.30 | 322.52 | 1.000 | 1.000 |
| v2 | 21170 | 1.94 | 18.90 | 44.78 | 308.56 | 0.032 | 0.037 |
| v3 | 21523 | 1.33 | 19.87 | 46.74 | 310.13 | 0.023 | 0.027 |
| v4 | 18349 | 1.41 | 19.87 | 46.74 | 310.13 | 0.021 | 0.024 |
| v5 | 18037 | 1.45 | 19.14 | 45.93 | 310.14 | 0.021 | 0.024 |

所有版本:48 組回歸(12 seed × 4 組 DRAM 參數)、60 組 fuzz(隨機 DRAM 參數/隨機 READY/隨機初始暫存器值)、spec 範例定向 pattern 全 PASS。
v5 額外跑過 120 組 fuzz 全 PASS。原始輸出見 RESULTS_raw.txt。
