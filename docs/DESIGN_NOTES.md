# 設計說明(v1 → v5)

* **v1 基線**:全部資料存進暫存器陣列,每個演算步驟一個大組合邏輯 state(Build 用 16 筆掃描函式)。邏輯層數極深(約 856 層),面積 36.5k。
* **v2 低 latency**:最後一個輸入 valid 的同一拍載入第一個 AR(位址取自 D);ID 在 R_LAST/B 同拍重用;W 與 AW handshake 同拍載入;out_valid 在最後一個 B 取樣的同拍設定;Build 改成邊收邊插入 top-N 排序表(QD 4 筆/QS 2 筆/QA 7 筆);Match 的總和/catch/goals 是 free-running 流水線,result 在最後一筆 profile 後 2~3 拍出來,Pair Record 先寫以隱藏運算。min 組態 25.7 → 18.9 cycles,面積 36.5k → 21.2k。
* **v3 降 cycle time**:one-hot 指令旗標、idle 時預先初始化狀態、輸入端路徑只留淺邏輯(per-ID one-hot entry tag、已註冊的「最後一次讀/寫」預測旗標、只在暫存器看不到空閒 ID 時才用 R_ID/B_ID)、AW 觸發改用 drained 事件、Match 運算結果以倒數 scoreboard 釋放、Training/Query 多切一級、Build 以「保證有解」條件提早發 AW。T 估計 1.94 → 1.33 ns,latency 略增(min 19.9)。
* **v4 降面積**:Build 的 lists/capture/選擇暫存、Training 的 Δ/和暫存、Query 的紀錄與日期運算暫存全部映射進 Match 的 14×64 profile store `pm`(這些指令用不到它)。flop 1985 → 1461,面積 21.5k → 18.3k,cycle 不變。
* **v5 微調**:Query 少一級(4.6 cycles)、out_info 改由既有暫存器經 oki 旗標閘控(省 64 個 flop)、資料暫存器去掉 reset、ctx→第一筆 profile 的專用 bypass(Training/Match 各省 1 cycle)。面積 18.0k,min 19.1 cycles。

## 沒採用的想法
* 第二次讀取取代儲存:不可行,同一指令所有讀必須在第一個寫之前 drain,所以 14 筆舊 profile 一定得存。
* 把 Match 讀出 mux 改成 shift:mux 數量等價,沒有收益。
* Training 單通道序列化:約省 5% 面積但 Training +2 cycles,收益太小。

## 假設與風險
* Match 先寫 Pair Record 再寫 14 個 profile(spec 未規定順序)。
* 不做 profile 讀取 burst 合併,維持 spec 的固定順序。
* 資料暫存器(pm、ohr、cH/cA 等)無 reset;已用 Verilator 隨機初始值測過,但沒做 4-state X 模擬。
* 面積/T 是 proxy;DC、gate-level 都沒跑。TA 的 INF.sv/Usertype.sv/pseudo_DRAM.sv 是依 spec 自己寫的替身。
