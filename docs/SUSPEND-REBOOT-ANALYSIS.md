# サスペンド再起動 解析ノート（2026-09-16）

x1q (SCG01 / LineageOS 21) の自発再起動について、原因・証拠・仮説・次の一手を整理する。
`COMPLETE-GUIDE.md` §3.6 の補足（詳細ログ解析編）。

---

## 1. 結論サマリ

- **v2.0（パッチ0021まで）でも再起動する**ことを確認。頻度は **2〜4分おき**と高い。
- リセットの直接証拠はカーネルではなく **AOP（Always-On Processor）のクラッシュ**:
  ```
  reset_summary:
    QC_IMAGE_VERSION_STRING=AOP.HO.2.0-317806
    LR : 0xde63 (do_crash_dump)
    PC : 0x3011 (abort)
  ```
- 落ちた**全ブートで共通**して、起動後 **約66.5秒**に:
  ```
  spss_utils [spss_wait_for_event]: wait for event [1] timeout [60] sec expired
  ```
  → **SPSS (Samsung Sensor Processor / SP) がイベントを返さず60秒タイムアウト**。
- つまり「サスペンドのwakeup源」だけでは説明できず、**センサー系（SP/SPSS → AOP）** が
  リセットの本命である可能性が高い。

> 中間報告の「サスペンドwakeup源（MHI/IPA）」は**実際に効いていた**（0018〜0021）。
> ただし、それでも止まらない再起動が別にあり、こちらが AOP/SP 系。

---

## 2. 証拠（時系列）

| 時刻(実時間) | ブート | uptime | 事象 |
|---|---|---|---|
| 07:20:07 | 20260916_072007 | ~66.5s | `spss_wait_for_event timeout` → 再起動 |
| 07:29:37 | 20260916_072937 | ~66.5s | 同上 |
| 07:33:04 | 20260916_073304 | ~66.5s | 同上 |
| 07:37:42 | 20260916_073742 | ~66.5s→333s | suspend entry/exit チャーン → 再起動 |
| 07:44:18 | 20260916_074418 | ~66.5s→134s | `Resume caused by IRQ 324, pm8xxx_rtc_alarm` 等 → 再起動 |
| 07:51:03 | 20260916_075103 | ~66.5s→130s | `sec_debug_user_reset` / `ap_health_work_write_fn` → 再起動 |

- `reset_summary`（Samsung HTML dump）: **AOP crash dump**（`do_crash_dump` / `abort`）。
- 別 boot の reset_summary には `MDM session ID` / `Modem magic not valid! should-be(5ecdeb6)` も
  出ていた（modem 側の異常も併発）。
- `sec_debug_user_reset`（Samsung の user reset 経路）と `ap_health_work_write_fn`（AP health）が記録。

### 各ブートの最期（共通パターン）
```
last active wakeup source: eventpoll   /  DIAG_WS   /  mmc0_detect
PM: suspend entry                       ← 直後にハング（userspaceロガーはfreezeで停止）
→ TZ SECURE_WATCHDOG / AOP クラッシュでリセット
```
特に **`DIAG_WS`**（モデム DIAG インタフェースの wakeup source）が残るケースが複数。
多数の wakeup source が常時 active のままサスペンド入りし、定着せずリセットしている疑い。

### サスペンドチャーン（別レイヤの問題、0018〜0021で対処済み）
```
PM: suspend entry / PM: suspend exit の連続
Resume caused by IRQ 426, dhdpcie_host_wake     ← WiFiドングル
Resume caused by IRQ 324, pm8xxx_rtc_alarm
active wakeup source: mmc0_detect
Abort: Last active Wakeup Source: 0306_02.01.00          (MHI, 0020で対処)
Abort: Pending Wakeup Sources: IPA_CLIENT_APPS_LAN_CONS IPA_WS  (IPA, 0021で対処)
msm_pcie_pm_control: PCIe RC2 ... active EP(s): 0
spi_geni_suspend: End（多数）
cs40l2x ... Failed to write register 0x0001302C: -107（resume時）
```

---

## 3. 仮説（優先順）

1. **SP/SPSS（Samsung Sensor Processor）不調 → AOP クラッシュ → リセット**〔最有力〕
   - `spdaemon` が `spss_wait_for_event` で60秒タイムアウト（全ブート共通）。
   - AOP はセンサーの低電力アイランド。SP と密接。
   - 疑わしいもの: `spcom` / `spss_utils` / `subsys-pil-tz` の spss 経路、
     `spdaemon`（Samsung 独自）、AOP ファーム（blob）。
2. **modem（MDM/MHI）系の異常**（`Modem magic not valid`）
   - `subsys9 restart_level=RELATED`（0009）は効いているが、modem 自体が落ちている可能性。
   - `s20volte_ims`（Magisk・magi skドメインで RIL デーモン実行）との相性。
3. **ハードウェア（NFC eSE 等）** の劣化
   - `nfcsefix` は有効だが、eSE ハード故障が再発している可能性。
4. サスペンド経路の残存問題（WiFi dhdチャーン等、0010/0012で緩和済み）
   - v2.0 で**残る**が、AOP クラッシュとは別レイヤ。

---

## 4. 次の一手（端末が戻ったら）

### 4.1 切り分け（最優先）
1. **画面ONで使っている最中にも落ちるか / 画面OFF放置時だけか** を確認。
   → OFF時だけなら suspend 経路、ON中もなら AOP/SP/modem 系。
2. **SIM を抜いて**再起動するか（modem 切り分け）。
3. **`s20volte_ims` を一旦 disable** して再起動するか（RIL 切り分け）。
4. `nfcsefix` を一旦 disable して（＝NFC/secure_element を元に戻して）再起動するか。

### 4.2 ログ取得（端末接続時）
```sh
su -c 'cat /proc/reset_summary'                 # AOP/リセットヘッダ
su -c 'ls -l /sys/fs/pstore/; cat /sys/fs/pstore/console-ramoops-0'
su -c 'cat /sys/kernel/debug/msm_subsys/spss /sys/kernel/debug/msm_subsys/modem'
dmesg | grep -iE 'spss|spdaemon|spcom|aop|adsp|slpi|MDM|modem'
```
- `klogcap` / `rebootlogs` は `/data/local/tmp/` に自動保存済み（回収済み: 2026-09-16 分）。

### 4.3 候補修正（要検証）
- **SP/SPSS 無効化 or タイムアウト回避**（`spdaemon` 停止、`subsystem_restart` の spss 扱い変更）。
- **AOP ウォッチドッグ無効化**（可能なら）。
- **modem restart_level を更に下げる / RIL 構成見直し**。
- **NFC eSE を完全OFF**（`nfcsefix` の再確認・強化）。

---

## 4.4 AstroOS との比較（2026-09-16）

`Desktop/SCG01_flash/images/AstroOS_4.0.0_20260615_x1q.zip` と
`lineage-21.0-20240714-UNOFFICIAL-x1q.zip` の boot.img を比較。

| | AstroOS | 元LOS21 (2024) |
|---|---|---|
| kernel | **AstroKernel 4.19.325-g7f1b0a81c99e** | 4.19.306-perf-gff51b3d968f1 |
| CONFIG_QCOM_WATCHDOG_V2 | **OFF** | ON |
| CONFIG_SOFT_WATCHDOG | **ON** | OFF |
| CONFIG_DEBUG_KERNEL | OFF | ON |
| CONFIG_BUS_AUTO_SUSPEND | y | (なし) |
| CONFIG_CNSS2_QMI / CNSS_QMI_SVC | y / y | - / OFF |
| DTB | 実質同一（spss/aop/slpi のアドレス一致） | 同 |

- AstroKernel のソースは GitHub 検索で見つからず（非公開）。
- **差異の本命候補: QCOM_WATCHDOG_V2**。`Non Secure Watchdog Bark` でリセットする経路が
  AstroOS では無効化されている。
- → **パッチ0022**（`CONFIG_QCOM_WATCHDOG_V2=n` + `CONFIG_SOFT_WATCHDOG=y`、
  `emerg_pet_watchdog()` スタブ追加）をビルド済み（build29b, 17:10）。

## 4.5 RIL AIDL ブリッジ欠落（`ISehRadioBridge`）— 2026-09-18
`s20volte_ims` 有効でも毎秒これが出てCPUがidleしない:
```
servicemanager: 'vendor.samsung.hardware.radio.bridge.ISehRadioBridge/slot1' could not be found
```
→ **フレームワーク/`multiclientd` が要求する AIDL `ISehRadioBridge` がベンダーに無い**。
ベンダー(A11)は HIDL `@2.0::ISehBridge` のみ。`manifest_radio.xml` が HIDL を宣言、
`samsung_framework_compatibility_matrix.xml` が AIDL `ISehRadioBridge`（slot1/slot2, version 1）を必須宣言。

### AIDL インタフェース完全マッピング（`vendor.samsung.hardware.radio.bridge-V1-ndk.so` のシンボルから復元）
```aidl
interface ISehRadioBridge {
    void setResponseFunctions(ISehRadioBridgeResponse rsp, ISehRadioBridgeIndication ind);
    void sendRequestRaw(int type, in byte[] data, int id);
}
interface ISehRadioBridgeResponse {
    void sendRequestRawResponse(SehRadioResponseInfo info, in byte[] data, int id);
}
interface ISehRadioBridgeIndication {
    void hookRaw(SehRadioIndicationType type, in byte[] data, int id);
    void openFd(String path, int flags, int mode, out ParcelFileDescriptor fd);
    void execute(String command);
    void convertToUtf8(String src, int len, String enc, out String out);
}
```
依存型: `SehRadioResponseInfo` / `SehRadioIndicationType` / `SehRadioRequestType`（`aidl::vendor::samsung::hardware::radio::...`）。

- つまり**「生バイトのモデムブリッジ」**。実装すれば AIDL 側を HIDL `ISehBridge@2.0` に中継するだけで良い（簡単な形）。
- これが無いと毎秒リトライでサスペンドに入りにくい＋VoLTE の raw ブリッジが不成立。

### HIDL `ISehBridge@2.0` も完全マッピング（`vendor.samsung.hardware.radio.bridge@2.0.so` から復元）
AIDL V1 と**ほぼ1:1対応**:
```hal
interface ISehBridge {
  setResponseFunctions(ISehBridgeResponse rsp, ISehBridgeIndication ind);
  sendRequestRaw(int32_t type, vec<uint8_t> data, int32_t id);
};
interface ISehBridgeResponse {
  sendRequestRawResponse(android.hardware.radio@1.0::RadioResponseInfo info, vec<uint8_t> data, int32_t id);
};
interface ISehBridgeIndication {
  hookRaw(int32_t type, vec<uint8_t> data, int32_t id);
  openFd(string path, int32_t flags, int32_t mode) generates (int32_t fd);
  execute(string command);
};
```
→ **シム方針（確定）**: AIDL `ISehRadioBridge` サービスを実装し、各メソッドを
HIDL `ISehBridge@2.0`（`sehradiomanager` 等が提供）へそのまま中継する。
- **ブロッカー**: AIDL 側の型 `SehRadioResponseInfo` / `SehRadioIndicationType` /
  `SehRadioRequestType` の**正確な定義**（parcelable/enum）がツリーに無く、
  `-V1-ndk.so` からの完全復元は困難。型定義を入手できれば実装可能。

## 4.6 サスペンドハングの最下層特定（NIFURA計装で判明）— 2026-09-18

`no_console_suspend` + NIFURA printk計装（`NIFURA-SUSPEND`/`NIFURA-DPM`/`NIFURA-LATE`/
`NIFURA-NOIRQ`/`NIFURA-LPM`/`NIFURA-CPU`）で、ハング地点を特定した。

### ① バッテリー時のサスペンド再起動（主因）
```
全デバイスsuspend(late/noirq含む)は成功 → suspend_enter
  → "Disabling non-boot CPUs ..."
  → CPU1〜CPU6 は psci killed 成功
  → CPU7 の cpu_down() が ~14秒ハング（psci: CPU7 killed が出ない）
  → watchdog bark（サスペンド中はpetできない）→ TZBSP_ERR_FATAL_NON_SECURE_WDT
```
- 犯人: **CPU7のホットアンプラグ（cpu_down(7)）がハング**。タスク移行（stop_machine）か
  CPUHP_DOWN_PREPARE notifier のどちらか（`NIFURA-CPU` で切り分け中）。
- 注: これは「最後の非ブートCPU」に起きている可能性（CPU7固有ではないかも）。

### ② 充電時の再起動（サスペンド無関係・別原因）
```
binder: page allocation failure (GFP_HIGHUSER_MOVABLE|__GFP_CMA, fatal_signal:1)
  → 全CPUが watchdog pet を停止（cpu alive mask from last pet 00）
  → Watchdog bark（last pet から ~11.7秒後）
```
- サスペンドせずに（充電中）落ちる別経路。メモリ確保失敗→全CPUハング→WDT。
- 低メモリ/CMA枯渇 or binderのメモリバグが疑わしい。

### リセット原因の変遷（全てパワー/サスペンド経路）
`Non Secure Watchdog Bark` / `RPM_ERR` / `RPM_WDOG` / `XPU_VIOLATION` /
`KERNEL PANIC (mhi_pm_state != M3 = 我々のMHIパッチ起因→修正)` / `sd unrecoverable`。

---

## 5. 現状のカーネル構成（v2.0相当）

有効パッチ: 0001, 0010, 0012, 0013, 0015, 0016, 0017, 0018, 0019, 0020, 0021
（build28 = v2.0 相当。0010〜0017 を一度戻したら WiFi dhd チャーンが再発したため、
**0010/0012 は load-bearing と確認**。→ これらは消さず残す）

- 0010/0012: WiFi dhd の runtime-PM / system-suspend no-op（**必要**）
- 0013: ハプティクス suspend no-op
- 0015: AP watchdog bark-time 延長
- 0016/0017: PCIe suspend no-op
- 0018: spi_geni `-EBUSY` 撤廃
- 0019: mhi_system_suspend の中断廃止
- 0020: MHI wakeup 無効化
- 0021: IPA wakeup 源 非登録

---

## 6. 計測メモ

- 再起動間隔: 約2〜4分（2026-09-16 07:20〜07:51 は特に頻発）
- `spss_wait_for_event` タイムアウト: **全ブート共通・約66.5s**
- AOP: `AOP.HO.2.0-317806`, crash dump (`abort`)
