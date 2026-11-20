# Lab09 QME — Spec 整理(輸入 → 輸出 完整流程)

> 本文所有範例數值都由 `model/spec_examples.py`(Python golden model)實際算出,
> 該 model 已用 spec 內的範例驗證(LFSR、Goals、Catch、Query 的 10/90/91 天)。
> 執行 `python3 model/spec_examples.py` 可重現。

## 1. 系統在做什麼

四支球隊(TeamID 0 Gryffindor、1 Hufflepuff、2 Ravenclaw、3 Slytherin),設計 QME 只看得到 2-bit TeamID。
所有資料都在 DRAM,以 **AXI4**(128-bit、INCR、ID 2-bit)存取。DRAM 內有三種 beat(每 beat 16 byte,位址是 byte address):

| 區域 | 位址 | 內容 |
|---|---|---|
| Player Profile | `0x10000 + (Team*16 + PlayerID)*16`(64 beats) | `{Attack,Defense,Speed,Exp}` 各 16 bit,低 64 bit 恆為 0 |
| Team Context   | `0x10500 + Team*16`(4 beats) | 7 個先發球員的 PlayerID(各 4 bit):`[127:124]`Keeper `[123:120]`Chaser0 `[119:116]`Chaser1 `[115:112]`Chaser2 `[111:108]`Beater0 `[107:104]`Beater1 `[103:100]`Seeker |
| Pair Record    | `0x10800 + index*16`,`index = Home*3 + (Away<Home ? Away : Away-1)`(12 beats) | `[127:126]`Result `[125:122]`Month `[121:117]`Day `[116:108]`ScoreHome `[107:99]`ScoreAway |

Profile 的 byte 順序(dram.dat):Attack 在 byte 15:14,故檔案裡 `A9 FD` = `16'hFDA9`(little-endian,低 byte 在前)。

## 2. 介面與時序

* 輸入:`in_valid_action / date / team / option` 四條 valid(各只拉 1 cycle,彼此不重疊)+ 9-bit `D`。
  同一指令的相鄰 valid 之間 2~5 個 idle cycle;`out_valid` 落下後 2~5 cycle 才有下一個指令。
* 輸入順序固定:
  * Build Team:`action → team`
  * Training:`action → team → option{slot[6:4], type[3:2], mode[1:0]}`
  * Match / Query:`action → date{month[8:5],day[4:0]} → home team → away team`
* 輸出:`out_valid`(1 cycle)、`complete`、`warn_msg[2:0]`、`out_info[127:0]`;只有 `out_valid` 為高時 complete/warn/info 才有意義,其餘 cycle 必須為 0。
* **Latency** = 最後一個輸入 valid 被取樣的 posedge,到 `out_valid` 被看見的 posedge 的 cycle 數,上限 2500。
* 評分:功能 70%、效能 30%(`Area × Latency × cycle_time`);面積 < 200000、不可有 latch、不可用 DesignWare/SRAM、不可用查表。

## 3. 四個 action

### 3.1 Build Team(`D=0`,輸入 Team)
1. 讀該隊 16 個候選者:4 個 `AR_LEN=3` 的 burst,基底 `0x10000 + Team*256 + {0x00,0x40,0x80,0xC0}`,4 個不同 ARID,可同時 4 個 outstanding。
2. 候選池:QD = Defense ≥ 4096、QS = Speed ≥ 4096、QA = Attack ≥ 4096。
3. 依序挑選(已選過的人不再選):
   * **Keeper/Seeker**:K∈QD、S∈QS、K≠S,使 `Defense[K]+Speed[S]` 最大;平手取最小 K 再最小 S;無解 → Roster_Warn。
   * **Beaters**:QD 內 Defense 最高的兩人(平手取小 PlayerID);不足兩人 → Roster_Warn。
   * **Chasers**:QA 內 Attack 最高的三人(平手取小 PlayerID);不足三人 → Roster_Warn。
4. 擺位 `{K, C0,C1,C2, B0,B1, S}` → 寫回 Team Context(1 beat)。`out_info` = 寫入的那個 beat。

範例(Team 0,16 個候選者見 `spec_examples.py`):
```
QD = [0,1,2,3,4,6,7,8,9,10,11,13,14,15]   QS = [0..10,13]   QA = [0..9,13,14,15]
Keeper = 6 (Defense 60000)  Seeker = 7 (Speed 61000)  Beaters = [8,9]  Chasers = [1,2,3]
Team Context @0x10500 = 61238970 0000...   complete=1  warn=No_Warn
AXI:4 個 read burst @0x10000/0x10040/0x10080/0x100C0,1 個 write @0x10500
```

### 3.2 Training(`D=1`,輸入 Team、option)
1. `slot=7` 或 `mode=3` → **Option_Warn**,且**完全不可有任何 AXI 交易**(在第一個 AR 之前決定)。
2. 讀 Team Context(取出該 slot 的 PlayerID),再讀該 Profile(第二個位址依賴第一個的資料)。
3. `Exp < Exp_needed`(Easy 2048 / Normal 8192 / Hard 16384)→ **Exp_Warn**,不寫回。
4. 依 type 算 Δ(三個屬性各自):
   * A:`Δ = ⌊(A+D+S)/8⌋`(三者相同)
   * B:把 (A,D,S) 由小到大排序(平手維持 A,D,S 順序)得 q0≤q1≤q2;`Δ(最低)=q1−q0`、`Δ(中間)=q2−q1`、`Δ(最高)=0`
   * C:`v<16383 ? 16383−v : 0`
   * D:`min(3000 + ((65535−v)>>4), 5047)`
5. 依 mode 縮放:Easy `Δ−⌊Δ/4⌋`、Normal `Δ`、Hard `Δ+⌊Δ/4⌋`;加到屬性上做**飽和加法**(Exp 不變);任一加法真的溢位 → **Saturation_Warn(`complete=1`,仍寫回)**。
6. 寫回 Profile(1 beat),`out_info` = 該 beat。

範例(team 0、slot 1、type B、mode Hard):
```
Player 1 before (A,D,S,E) = (1000, 20000, 5000, 20000)
sorted 1000 ≤ 5000 ≤ 20000 → Δ(Attack)=4000, Δ(Speed)=15000, Δ(Defense)=0
Hard:Attack 4000+1000=5000、Speed 15000+3750=18750
after = (6000, 20000, 23750, 20000)  warn=No_Warn complete=1
Exp 改成 3000(< 16384):warn=Exp_Warn complete=0 out_info=0,不寫回
slot=7:warn=Option_Warn,reads=[](完全沒有 AXI)
```

### 3.3 Match(`D=2`,輸入 Date、Home、Away)
1. Home==Away → **Team_Warn**(無 AXI)。
2. 讀兩個 Team Context(兩者互相獨立、順序自由),再依**固定順序**讀 14 個 Profile:Home slot 0..6、Away slot 0..6。
3. 計算(`model/qme_model.py::match` 與 spec Table 9 一一對應):
   * `TeamAttack = ⌊(Chaser0 + Chaser1 + Chaser2 的 Attack)/3⌋`、`TeamDefense = ⌊(Keeper + Beater0 + Beater1 的 Defense)/3⌋`、`Interference = max(Away.Beater0.Speed, Away.Beater1.Speed) >> 2`
   * `Goals_Home = max(0, (Home.TeamAttack>>12) − (Away.TeamDefense>>14))`,`Goals_Away` 對稱;分數 = Goals×10
   * 抓 Snitch(唯一的隨機部分):`DOY` = 當日是一年的第幾天(1/1=1);`s0 = DOY[7:0] ^ {6'b0,Home} ^ {4'b0,Away,2'b0}`,`seed = (s0==0)?1:s0`;8-bit LFSR `next(x)={x[6:0], x[7]^x[5]^x[4]^x[3]}`
     * `r1=next(seed)`;`(Home.Seeker.Speed>>1)+(r1<<8)−Interference ≥ 65536` → Home 抓到
     * 只有 Home 沒抓到才 `r2=next(r1)`;`(Away.Seeker.Speed>>1)+(r2<<8) ≥ 65536` → Away 抓到
     * 抓到的隊 +150 分且**立即獲勝**(即使進球較少);都沒抓到則進球多者勝,相同為平手
   * Result:0 Home 勝 / 1 Away 勝 / 2 Draw
4. 14 位球員更新(Table 10):贏家 A,D,S,Exp 各 +2048,輸家各 −2048,平手 A,D,S 各 −1024(Exp 不變);飽和運算,真的被夾住才算 Saturation_Warn。
5. 依固定順序寫回 14 個 Profile(最多 4 個 outstanding),並寫 Pair Record(日期=今日);`out_info` = Pair Record。Saturation_Warn 時 `complete=1`。

範例(spec 內的例子:3/1,Home=Team0 vs Away=Team1,DOY=60):
```
TeamAttack_H=40000 TeamDefense_H=50000 | TeamAttack_A=20000 TeamDefense_A=30000
Goals_Home = 40000>>12 − 30000>>14 = 9−1 = 8;Goals_Away = 20000>>12 − 50000>>14 = 4−3 = 1  → 80 : 10
seed:s0 = 60 ^ 0 ^ 4 = 56 = 8'h38  r1 = next(8'h38) = 8'h71 = 113
Interference = 30000>>2 = 7500  Catch_Home = 25000+113·256−7500 = 46428 < 65536 → 沒抓到
r2 = next(8'h71) = 8'hE2 = 226  Catch_Away = 30000+226·256 = 87856 ≥ 65536 → Away 抓到
Result = 1(Away 勝)  ScoreHome=80  ScoreAway=10+150=160  → Pair Record @0x10800(index 0)
```
(以上數字與 spec 範例逐項相同,`model/spec_examples.py` 輸出。)

### 3.4 Query(`D=3`,輸入 Date、Home、Away)
1. Home==Away → **Team_Warn**(無 AXI)。
2. 讀 Pair Record;`DeltaDays = (DOY(今天) − DOY(MatchMonth,MatchDay)) mod 365`;`> 90` → **Date_Warn**。
3. 不寫 DRAM;`out_info`:`{QueryMonth,QueryDay,MatchMonth,MatchDay,DeltaDays(7b),Result,ScoreHome,ScoreAway,83'b0}`。

範例(紀錄是 12/26):今天 1/5 → 10 天 ok;3/26 → 90 天 ok;3/27 → 91 天 → Date_Warn。

## 4. Warning 規則(Table 11)

| Action | 警告(優先權) | `warn_msg` | complete |
|---|---|---|---|
| Build | Roster_Warn | 3'b011 | 0 |
| Training | Option_Warn(1) / Exp_Warn(2) / Saturation_Warn(3) | 3'b100 / 3'b101 / 3'b111 | 0 / 0 / **1** |
| Match | Team_Warn(1) / Saturation_Warn(2) | 3'b010 / 3'b111 | 0 / **1** |
| Query | Team_Warn(1) / Date_Warn(2) | 3'b010 / 3'b001 | 0 / 0 |
| 全部 | No_Warn | 3'b000 | 1 |

* 除 No_Warn、Saturation_Warn 之外,`complete=0`、`out_info=0`、**不寫 DRAM**。
* 優先權 1 的警告必須在任何 AXI read 之前決定,且該指令不可有任何 AXI 交易。

## 5. AXI 規則(效能的決定因素)

* 讀寫各最多 4 個 outstanding;仍在進行的 ID 不可重用(Lab09 一個 ID 一次只有一筆交易)。
* DRAM 可能**亂序**回應不同 ID(`DRAM_REORDER=1`),同 ID 依序 → 資料要依 `R_ID` 歸位、寫入要依 `B_ID` 回收。
* W 資料必須在其 AW handshake 之後才能出現;同一指令的所有讀要先 drain 完才能發第一個寫。
* 同一位址不可同時有讀與寫 outstanding;兩個 outstanding 寫不可同位址。
* VALID 為高且 READY 為低時,payload 與 VALID 必須保持。
* **No prefetch**:收到最後一個輸入 valid 之前不可有 AR/AW handshake。
* `out_valid` 必須在該指令所有 AXI 交易都結束之後才可拉起。
* DRAM 參數(demo 範圍):`R_LATENCY 1~100`、`B_LATENCY 1~100`、`W_STALL 0~20`、`AR_AW_STALL 0~20`、`GAP 0~5`、`REORDER 0/1`。

## 6. 每個 action 的 DRAM 相依鏈(決定 latency 下限)

| Action | 依賴的往返 |
|---|---|
| Build | 4 個 burst 平行讀(16 beats 在 R channel 上至少 16 cycle)→ 1 次寫 |
| Training | 讀 ctx → 讀 profile(位址由 ctx 資料決定)→ 1 次寫 |
| Match | 讀 2 ctx → 讀 14 profile(4 outstanding,輪次由 R_LATENCY 決定)→ 寫 15 個 beat(4 outstanding) |
| Query | 讀 1 個 record |

最低 latency(`R=B=1`、無 stall):警告型 1 cycle;Query 約 4~5;Training 約 8;Build 約 24~26;Match 約 34。
R/B latency 大時 latency 幾乎完全由 DRAM 決定(Match ≈ 2 次 4-outstanding 往返 + ctx 往返)。

## 7. 本專案如何驗證(第一步的另一半:生 pattern + 自行驗證)

* `model/qme_model.py`:逐條對應 spec 的 golden model(含每個指令預期的 AXI 讀寫位址集合)。
* `model/gen_pattern.py`:產生 `dram.dat`(4 隊 × 16 候選者 + 4 個已建隊的 Team Context + 12 筆合法 Pair Record)、隨機指令序列(涵蓋 Build/Training/Match/Query、各種 warning、平手/飽和/門檻值/同分數等邊界)、預期輸出、最終 DRAM 影像。
* `00_TESTBED/`:`INF.sv`、`Usertype.sv`、`pseudo_DRAM.sv`(所有 DRAM 參數、亂序、可選的隨機 READY、AXI 協定 checker)、`PATTERN.sv`(逐指令比對 out_valid/complete/warn/info、latency ≤ 2500、no-prefetch、out_valid 前 AXI 已結束、AXI 讀寫位址集合與 Match 固定順序、最後整份 DRAM 比對)。
* `model/coverage.py`:統計 pattern 是否真的打到邊界(Build 的 K*==S*、option1/2/平手、Roster 失敗;Match 的 seed=0、catch 與進球衝突;Query 的 0/90/91/跨年;Training 全部 type×mode)。
* `scripts/regress.sh`(多 seed × 4 組 DRAM 參數)、`scripts/fuzz.sh`(隨機 DRAM 參數 + 隨機 READY + 隨機初始暫存器值)、`model/gen_directed.py`(spec 範例定向 pattern)。
