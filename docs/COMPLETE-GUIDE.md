# SCG01 (Galaxy S20 5G au / `x1q`) LineageOS 21 — 完全ガイド

このドキュメントは、**SCG01 (`x1q`) 向け LineageOS 21 のビルドと改修**で得た知見を、
**次にこの作業を引き継ぐ AI / 開発者が単体で理解できる**ようにまとめたものです。
`README.md` のパッチ一覧と対になる詳細リファレンスです。

---

## 0. TL;DR（結論）

- 端末: **Samsung Galaxy S20 5G au `SCG01` / codename `x1q` / SoC SM8250 (kona)**。
- 目標: LOS21 (Android 14 / SDK34) を実用的な daily driver にする（音声・VoLTE/SMS・NFC・音量・GApps・安定性）。
- 本リポジトリは **ROM 側に取り込んだ修正（パッチ0001〜0021）** とビルド手順を管理する。
- VoLTE 通話のみ **Magisk モジュール `s20volte_ims`** が現状最も確実（→ `nifuramoon/scg01-los21-toolkit`）。
- 主要な落とし穴は「**HAL / ベンダーブロブ / カーネル**」側に集中している。ROM 設定だけでは直らないものも多い。

---

## 1. 端末・環境

| 項目 | 値 |
|---|---|
| 端末 | Samsung Galaxy S20 5G au **SCG01** |
| codename | **`x1q`** |
| SoC | Qualcomm **SM8250 / kona** |
| ベンダー | Samsung Android **11** (`samsung/x1qksx/x1q:11/RP1A.200720.012/G981NKSS4IXE4`) |
| ROM | LineageOS **21** (Android 14, SDK34), `lineage_x1q-userdebug` |
| root | `WITH_SU := true` + Magisk（`boot` を Magisk パッチ） |
| PC | Arch Linux 6.18-lts, 6 cores / 15GB RAM（**`-j4` 推奨**、`-j6` は OOM） |

### ビルドの要点
```bash
# 依存
sudo pacman -S --needed base-devel git repo rsync ccache gperf jdk17-openjdk libxml2 schedtool

# ツリー
repo init -u https://github.com/LineageOS/android.git -b lineage-21
# local_manifests/x1q.xml を配置して repo sync

# ビルド
source build/envsetup.sh
breakfast x1q
mka bacon -j4            # または mka systemimage / bootimage / vendorimage
```
- **`out/soong` の再解析**が入ると 20〜35 分かかる。Android.bp / sepolicy 変更時は覚悟する。
- soong bootstrap が `signal: killed` になる場合はメモリ不足 → `-j4` + swap 拡張。
- `out/.lock` が残ると `Waiting up to 10s to lock` で失敗 → `rm -f out/.lock`。
- フラッシュは fastbootd: `adb reboot fastboot` → `fastboot flash system|vendor|product|boot` → `fastboot reboot`。
  - **`boot` を焼くと Magisk が消える**ため、通常は `system`/`vendor`/`product`/`system_ext` のみ焼く。
  - カーネル変更時は boot を焼き、その後 **Magisk 再パッチ**（後述）。

---

## 2. パッチ一覧（0001〜0021）

| # | 対象 | 内容 |
|---|---|---|
| 0001 | kernel `techpack/audio/asoc/kona.c` | **スピーカー無音 + 自発再起動の修正**。CS35L41 アンプをハードコード名でなく `of_node` で解決（後述 §3.1） |
| 0002 | `system/sepolicy` | `imsd`/`multiclientd` ドメイン追加 + `file_contexts` |
| 0003 | `device/samsung/x1q` | RRO→`/product/overlay`、`multiclientd.rc` トリガ修正、`WITH_SU` |
| 0004 | `device/samsung/sm8250-common/system.prop` | **音量バグ修正** `audio.offload.disable=1`（§3.3） |
| 0005 | `device/samsung/x1q/gapps` | **MindTheGapps の ROM 内蔵**（§3.4） |
| 0006 | `build/make`, `vendor/lineage`, `device/samsung/x1q` | GApps 内蔵用のビルドシステム変更（§3.4） |
| 0007 | `system/logging/logcat/logcatd.sh` | **`logcatd` クラッシュ再起動の恒久対策**（§3.2） |
| 0009 | `device/samsung/x1q/rootdir/etc/init.x1q.rc` | モデム `restart_level=RELATED` + StrongBox `stop`（§3.2） |
| 0010 | kernel `bcmdhd_101_16/dhd_pcie_linux.c`, `BoardConfig.mk` | **サスペンド再起動のカーネル対策** `pcie_aspm=off` + WiFi `dhd` runtime-PM 無効（§3.2） |

> 0008 は欠番（StrongBox を rc override でやろうとして、vendor blobs のコピー順に負けて断念した名残）。

---

## 3. 問題と解決の詳細

### 3.1 スピーカー無音 と 自発再起動（パッチ0001）

**症状**: スピーカーから音が出ない。数分おきに勝手に再起動。

**原因**:
- `kona.c` が CS35L41 アンプを `cs35l41-codec.0.auto` / `.4.auto` と**ハードコード**していた。
- MFD の自動採番がずれて実際は `.1.auto` / `.5.auto` になると `snd_soc_register_card` が失敗し、
  **サウンドカード自体が登録されない**（＝無音）。
- さらに、サウンドカードが無いと `system_server` のメインスレッドが
  `AudioSystem::listAudioProductStrategies` で **15秒ブロック**し、フレームワーク watchdog
  （`system_server_pre_watchdog`）が発火して**自発再起動**する。

**修正**: `msm_setup_cs35l41_components()` を追加し、DT の `qcom,component-devs` から
親 i2c ノードの子（`cirrus,cs35l41`）を辿って `.of_node` を設定。`msm_asoc_machine_probe` から呼ぶ。
→ `/proc/asound/cards` に `konamtpsndcard` が出る。無音も再起動も解消。

**教訓**: Samsung kona 系の ASoC は「デバイス名ハードコード」が地雷。`of_node` 解決が正解。

---

### 3.2 自発再起動（複数要因・重要）

再起動は **単一原因ではなく複数**あり、切り分けが必要だった。

#### (a) `logcatd` クラッシュループ（パッチ0007）
- `persist.logd.logpersistd.size` に **`32M`**（`/data/property` に手動設定）が入っていた。
- `logcatd.rc` はこの値を `-n`（回転**ファイル数**）にそのまま渡す。`logcat: Invalid -n '32M'` で即終了。
- init が「updatable プロセスが4分間に4回クラッシュ」と検知 → `sys.init.updatable_crashing=1` → 再起動。
- **診断**: `getprop sys.init.updatable_crashing[_process_name]`, `logcat -b all -d | grep 'logcatd.*exited|Invalid -n'`
- **対処**: 値を `16` に修正。さらに `logcatd.sh` で `-n` の非数値値を `256` に補正（恒久）。
- **背景**: `logd/README.property` は `.size` を “MB” と説明するが、実装は**ファイル数**として使う（AOSP のドキュメント不一致）。

#### (b) カーネル WDT / RCUストール（高負荷時）
- フラッシュ直後の高負荷（GApps/ドライバ初期化、load 8〜15）時に発生。
- `SYSTEM_LAST_KMSG` に `rcu_preempt/rcu_sched kthread starved for 1140 jiffies`。
- `/proc/reset_summary`: `UPLOAD CAUSE = TZBSP_ERR_FATAL_NON_SECURE_WDT`, `GCC_RESET_STATUS = SECURE_WATCHDOG | PMIC_RESIN`。
- → カーネルが進行停止 → セキュアモニタ経由の WDT → リセット。負荷沈静化で停止する**過渡的**要因。

#### (c) モデムSSRで全再起動（パッチ0009）
- モデム(esoc0)の `restart_level` が **`SYSTEM`**。SSR（サブシステム再起動）のたびに**端末全体が再起動**。
- 停止スタック: `vndbinder → wait_for_shutdown_ack → sysmon_send_shutdown → mdm_subsys_shutdown`（モデムACK待ちで固まる）。
- **対処**: `init.x1q.rc` の `on boot` で
  `write /sys/devices/platform/soc/soc:qcom,mdm0/subsys9/restart_level RELATED`
  （有効値は `SYSTEM`/`RELATED` のみ）。SSR でもモデムのみ再起動になる。

#### (d) サスペンド時の WiFi PCIe / RPMh ハング（パッチ0010）★最重要
- **再現条件**: **USB(充電)を外す（バッテリー駆動）と数分で再起動**。充電中は数時間安定。
- 充電中はサスペンドしない（`/sys/power/suspend_stats/success = 0`）＝ **バッテリー時に初めてサスペンド経路へ入る**。
- pstore に `spi_geni_suspend` / `msm_pcie_drv_suspend`(PCIe RC0/RC2) / `qsee_rpmh: Srcs Busy` が反復。
- `SYSTEM_LAST_KMSG` に `ufshcd_gate_work → ufs_qcom_set_bus_vote → rpmh_write_batch`（RPMh停止）。
- → サスペンド時の **Broadcom WiFi PCIe (ASPM L1) のハングが RPMh を巻き込み**、セキュアWDT。
- **対処（パッチ0010）**:
  1. `BoardConfig.mk` に **`BOARD_KERNEL_CMDLINE += pcie_aspm=off`**。
  2. `bcmdhd_101_16/dhd_pcie_linux.c` の **`dhd_runtimepm_state()` を無効化**（`return FALSE;`）。
     - 注意: C89 なので **宣言の後**に `return` を置く（`-Werror,-Wdeclaration-after-statement`）。
- **結果**: 再起動間隔 2〜4分 → **1時間以上安定**。

#### 診断の道具立て（再起動）
- `/proc/reset_summary`（HTML, リセット理由・RTB・タスク一覧）
- `/proc/reset_reason`（例 `WPON`）
- `/data/system/dropbox/SYSTEM_LAST_KMSG*`（前回起動のカーネルログ）
- `/sys/fs/pstore/console-ramoops-0`, `pmsg-ramoops-0`（前回クラッシュ）
- `/proc/last_kmsg` は無い（このカーネル）
- **`rebootlog` Magisk モジュール**（本リポジトリ外・端末側）で毎起動時に上記を
  `/data/local/tmp/rebootlogs/<ts>/` に保全。

---

### 3.3 音量バグ「1段で爆音 / 段階変化なし」（パッチ0004）

- **症状**: 既定の音楽アプリ（Eleven）で音量1でも爆音、段階変化なし。YouTube は正常。
- **原因**: Eleven は **圧縮オフロード再生パス**を使う。Samsung ベンダー HAL はオフロード時に
  音量ステップを適用せず（`out_set_volume` は PCM で実質未対応）、AOSP 側もオフロードでは
  ソフト音量を掛けない → 固定の大音量。YouTube は通常の Mixer(PCM) パスなので正常。
- **対処**: `audio.offload.disable=1`（`system.prop`）。全再生を Mixer パスに通し、AOSP のソフト音量を効かせる。
- **検証**: 再生中の Mixer スレッドで step1=−53dB → step15=0dB の段階変化。
- **補足**: デジタル出力自体は元々正常（HAL 出力の signal power が step1=−64dB〜step15=−11dB）。

#### 音量の追加知見（アンプ）
- スピーカーは **CS35L41**（`Digital PCM Volume` = 817 が 0dB, 917 超で boost / `AMP PCM Gain` 0..20）。
- 当初 `mixer_paths.xml` の**初期値が `AMP PCM Gain=0 / Digital PCM Volume=0`（=最大減衰）**で、
  speaker path（`18/817`）が再生時に適用されず、**最大音量が小さい**問題があった。
- 初期値を `18/817` にすると改善するが、**再起動が増える兆候**があり一度リバート。
  → 音量改善と安定性は要トレードオフ検証（`AMP PCM Gain` 中間値・`ro.config.media_vol_steps` 調整など）。

---

### 3.4 Play ストアが繰り返し落ちる / GApps の ROM 内蔵（パッチ0005, 0006）

- **症状**: `SecurityException: You either need MANAGE_USERS or CREATE_USERS permission to: query users`。
- **原因**: `product.img` を焼き直すと、実 `/product` に入れていた MindTheGapps（`Phonesky`/`GmsCore` 等）が消え、
  Play ストアが特権アプリ扱いされず `MANAGE_USERS` が付与されない。控えの Magisk モジュールも `disable` されていた。
- **対処**: MindTheGapps 14.0 を `device/samsung/x1q/gapps/system` に prebuilt として取り込み、
  `gapps.mk`（`PRODUCT_COPY_FILES`）で `product`/`system_ext` に同梱。
- **ビルドシステム変更（パッチ0006）**:
  - `build/make/core/Makefile`: `PRODUCT_COPY_FILES` は APK/ELF を拒否するため
    `BUILD_BROKEN_PREBUILT_APK_PRODUCT_COPY_FILES` で分岐を追加。
  - `BoardConfig.mk`: `BUILD_BROKEN_PREBUILT_APK_PRODUCT_COPY_FILES := true` / `BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES := true`。
  - `vendor/lineage/config/common.mk`: `ro.control_privapp_permissions` を `enforce`→`log`。
- **GApps バイナリの取り込み手順**:
  ```bash
  adb root
  adb shell su -c 'cp -r /data/adb/modules/mindthegapps/system /data/local/tmp/mtg_system'
  adb pull /data/local/tmp/mtg_system device/samsung/x1q/gapps/system
  ```
- **注意**: ROM 内蔵後は Magisk モジュール `mindthegapps` を無効化（`touch disable`）。

---

### 3.5 カメラの「セッションエラー」（WiFi HAL クラッシュ）★ROM ソース修正

- **症状**: カメラが `CameraProvider is not ready` / session error で使えない。
- **原因**: **WiFi HAL (`/vendor/bin/hw/android.hardware.wifi-service`) が SIGSEGV**。
  - Broadcom `libwifi-hal.so` が WiFi サブシステム再起動イベントを通知 → `onAsyncSubsystemRestart(char const* error)`
    に **null 文字列**が渡る → ハンドラが `__strlen` で落ちる。
  - WiFi HAL のクラッシュで **カメラプロバイダも再起動**し、カメラが復帰しない。
  - 9/14 時点で既に発生していた**カスタムROM定番のHALバグ**。
- **修正**: `hardware/interfaces/wifi/aidl/default/wifi_legacy_hal.cpp` の `onAsyncSubsystemRestart` に **null ガード**:
  ```cpp
  on_subsystem_restart_internal_callback(error != nullptr ? error : "");
  ```
- **検証**: 修正後、WiFi HAL クラッシュ0・カメラプロバイダ再起動0・カメラ正常。
- **教訓**: WiFi HAL は **AOSP ソースビルド**（`hardware/interfaces/wifi/aidl/default/`）なので、
  ブロブと思わずソースを見ること。ここは直せる。

---

### 3.6 サスペンド再起動（画面OFF / バッテリー）★最重要・継続調査

- **症状**: **USBを外し（バッテリー）、電源ボタンで画面OFF（サスペンド）にすると数分で再起動**。再現性あり。
- **重要な制約**: **USB接続中はサスペンドしない**。強制 `echo mem > /sys/power/state` しても
  `a600000.ssusb: Abort PM suspend!! (USB is outside LPM)`（errno -16）で失敗する。
  → **USBを物理的に外さないとサスペンド経路に入らない**ため、ADB接続中は再現・検証が難しい。
  （WiFi ADB を張れば、外した後も監視は可能。）
- **★真因（確定）**: ハングではなく、**「pending wakeup source によるサスペンド中断ループ」**。
  - `dpm_suspend()` が `-EBUSY` を返し、PM core が即再試行 → 延々とリトライ →
    **TZ側 `SECURE_WATCHDOG`** が発火してリセット。
  - 決め手はランタイムの `pm_debug_messages` と `/sys/power/suspend_stats`:
    ```
    cat /sys/power/suspend_stats/fail            # 8
    cat /sys/power/suspend_stats/success         # 30
    cat /sys/power/suspend_stats/last_failed_dev # 0002:01:00.0  (モデムMHI on PCIe RC2)
    cat /sys/power/suspend_stats/last_failed_step# freeze
    ```
    kmsg/pstore:
    ```
    PM: Some devices failed to suspend, or early wake event detected
    Abort: Last active Wakeup Source: 0306_02.01.00   ← MHI (dev_id 0306, BDF 0002:01:00.0)
    ...（0020後）...
    Abort: Pending Wakeup Sources: IPA_CLIENT_APPS_LAN_CONS IPA_WS
    ```
  - つまり Samsung スタックの **MHI（モデム）と IPA（データパス）が wakeup source を
    active のまま保持**しており、それが `pm_wakeup_pending()` を真にしてサスペンドを毎回中断させていた。
- **診断の作り方（再発時に必須）**:
  - `echo 1 > /sys/power/pm_debug_messages`（デバイス毎の suspend 成否が出る）
  - `klogcap` Magisk モジュール（`/dev/kmsg`＋`logcat` を持続保存）＋ pstore。
    ※ userspace の `/dev/kmsg` リーダは **freezer で凍る**ため、`PM: suspend entry` 以降は
    カーネル側（pstore／`suspend_stats`）でしか追えない。
- **対処（最終, パッチ0018〜0021）**:
  - **0018**: `spi_geni_suspend` が runtime-PM 非停止時に **`-EBUSY` でシステムサスペンドを中断**していたのを撤廃。
  - **0019**: `mhi_system_suspend` がリンクサスペンド失敗時に**エラーを返して全体を中断**していたのを止め、リンクONのまま成功扱い。
  - **0020**: サスペンド中の **MHI wakeup source を無効化**（`device_wakeup_disable`／resumeで戻す）。
  - **0021**: **IPA の wakeup source（`IPA_WS` / クライアントwlock）を登録しない**。
    `__pm_stay_awake`/`__pm_relax` は NULL 安全なので機能は維持。
  - **結果**: 画面OFF・バッテリー放置で**再起動しなくなった**（ユーザー確認）。
- **旧・周辺対処（0010/0012/0013/0014/0015/0016/0017）**: `pcie_aspm=off`, WiFi `dhd` runtime-PM／
  system-noirq no-op, `cs40l2x_suspend` no-op, 全PCIe `power/control=on`, AP watchdog `bark-time` 延長,
  `msm_pcie_drv_suspend`/`msm_pcie_pm_suspend` no-op。頻度は減らしたが**真因ではなかった**（wakeup source が本命）。
- **教訓**: 「サスペンドで再起動」= ドライバのハングと思い込みがちだが、実際は
  **`/sys/power/suspend_stats` の `last_failed_dev`/`last_failed_step` と
  `pm_debug_messages` の `Abort: ... Wakeup Source` を見るのが最短**。ここを見ずに
  ドライバを no-op しても解決しない。
- **検証方法（重要）**:
  1. WiFi ADB を張る（`adb tcpip 5555` → `adb connect <ip>:5555`）。
  2. **USB接続中はサスペンドできない**（`a600000.ssusb: Abort PM suspend / USB outside LPM`）。
     ソフトで外すには `echo none > /sys/devices/platform/soc/a600000.ssusb/mode`
     （USB ADBは切れるがWiFi ADBは残る）。物理的に外してもよい。
  3. `su -c "echo +15 > /sys/class/rtc/rtc0/wakealarm; echo mem > /sys/power/state"` を繰り返す。
  4. `cat /sys/power/suspend_stats/{success,fail,last_failed_dev}` で確認。
  5. 再起動したら `SYSTEM_LAST_KMSG` / `/proc/reset_summary` / `rebootlog` を回収。
- **状態（解決済み）**: パッチ0018〜0021 で**画面OFF・バッテリー放置でも再起動しない**ことを確認。
  USB接続中は元々サスペンドしない（仕様）なので、検証は必ずUSBを物理的に外して行う。
- **もし将来また再発したら**: まず `suspend_stats` の `last_failed_dev`/`last_failed_step` と
  `pm_debug_messages` の `Abort: ... Wakeup Source(s): ...` を読む。
  出てきた wakeup source を持つドライバを特定し、サスペンド中の `device_wakeup_disable` か
  wakeup source 非登録で潰す（MHI=0020, IPA=0021 と同じ手順）。

### 3.7 IMS / VoLTE / SMS（パッチ0002, 0003）

- AOSP(LOS21) に Samsung 独自 IMS (`com.sec.imsservice`) を載せるため、
  - **RRO**（`S20VoLTEImsOverlay.apk`）を `/product/overlay` に配置
    （`com.android.phone` の `config_ims_mmtel_package`/`config_ims_rcs_package` → `com.sec.imsservice`）。
  - `imsd`/`multiclientd` を init 起動（sepolicy ドメイン追加）。
  - `multiclientd.rc` のトリガを `ro.vendor.multisim.simslotcount` に修正。
- **SMS(VoLTE SmsIP)**: ROM 直込みでも動作。
- **音声通話(VoLTE)**: **Magisk モジュール `s20volte_ims` 併用で成立**
  （デーモンを magisk ドメインで実行する構成が確実）。
  - ROM 直込みのみだと AIDL `vendor.samsung.hardware.radio.bridge.ISehRadioBridge` の世代差
    （A11 ベンダーは HIDL `ISehBridge@2.0` のみ）で不安定。`multiclientd -s 1` が毎秒 AIDL を要求して失敗し続ける。
- 詳細・モジュールは **`nifuramoon/scg01-los21-toolkit`** を参照。

---

## 4. Magisk モジュール（端末側）

| モジュール | 用途 |
|---|---|
| `s20volte_ims` | **VoLTE 通話 + SMS**（必須）。デーモンを magisk ドメインで実行 |
| `nfcsefix` | NFC eSE のハード故障による自発再起動を恒久停止（secure_element HAL を `disabled` + NFC 無効化 + チップ電源OFF） |
| `mindthegapps` | GApps。ROM 内蔵後は **disable 推奨** |
| `playintegrityfix` | Play Integrity 対策 |
| `interceptmode` | HTTPS 傍受（proxy + frida-server + CA。ON/OFF トグル） |
| `rebootlog` | 毎起動で pstore/reset_summary/LAST_KMSG/永続logcat を `/data/local/tmp/rebootlogs/` に保全（診断用） |
| `klogcap` | `/dev/kmsg`＋`logcat` を `/data/local/tmp/klogcap/<ts>/` へ常時保存。`pm_debug_messages` も起動時にON。サスペンド再起動の真因特定に決定的だった（本リポジトリの `patches/` 外・端末側） |
| `suspendfix` | （実験用・無効化済み）UFS `rpm_lvl/spm_lvl` 調整 |

---

## 5. 診断ツール（自作・端末側 `/data/local/tmp/`）

| ツール | 説明 |
|---|---|
| `tinymix` | **arm64 静的ビルド**（tree の NDK sysroot + clang）。ALSA ミキサ操作。`tinymix` が端末に無い時に自作 |
| `tone` | AAudio で 1kHz テストトーン再生（音量検証） |
| `tone2` | AAudio 全二重（トーン + マイク） |
| `tinycap` | ALSA 直接キャプチャ（要 mixer パス設定） |

### `tinymix` のビルド方法（再現用）
```bash
S=/mnt/build/los21/out/soong/ndk/sysroot
CLANG=/mnt/build/los21/prebuilts/clang/host/linux-x86/clang-r487747c/bin/clang
CRT=/tmp/crt   # crtbegin_dynamic.o / crtend_android.o を out/soong/.intermediates からコピー
$CLANG --target=aarch64-linux-android30 --sysroot=$S -B$CRT -O2 -Iinclude \
  -o tinymix tinymix.c mixer.c mixer_hw.c mixer_plugin.c pcm.c pcm_hw.c pcm_plugin.c snd_utils.c
```
- NDK sysroot は `out/soong/ndk/sysroot`（`usr/include`, `usr/lib/aarch64-linux-android/30`）。
- `crtbegin_dynamic.o` は `out/soong/.intermediates/bionic/libc/crtbegin_dynamic/android_arm64_armv8-2a-dotprod/` にある。

---

## 6. Magisk 維持のまま boot を更新する手順（カーネル変更時）

```bash
# 1) 新 boot を生成（mka bootimage）
# 2) 端末に push
adb push out/target/product/x1q/boot.img /data/local/tmp/boot_new.img
# 3) 端末側で Magisk パッチ（現行 Magisk が動いている間に）
adb shell 'su -c "cd /data/adb/magisk && KEEPVERITY=true KEEPFORCEENCRYPT=true sh boot_patch.sh /data/local/tmp/boot_new.img"'
# 4) 読み取り可能な場所へコピーして pull
adb shell 'su -c "cp /data/adb/magisk/new-boot.img /data/local/tmp/new-boot.img; chmod 644 /data/local/tmp/new-boot.img"'
adb pull /data/local/tmp/new-boot.img /tmp/new-boot.img
# 5) fastboot で焼く
adb reboot fastboot
fastboot flash boot /tmp/new-boot.img
fastboot reboot
```
- `new-boot.img` は root 所有で `adb pull` 不可 → `su -c cp` + `chmod` が必要。
- パッチ後の `CMDLINE` に `pcie_aspm=off` が入っていることを確認すると良い。

---

## 7. 既知の残課題 / 注意

- **WiFi HAL クラッシュ**: 今回 null ガードで対処。Broadcom ファーム由来の SSR 自体は残る可能性。
- **音量**: 最大音量と再起動のトレードオフが未確定。`AMP PCM Gain`/`Digital PCM Volume`/`media_vol_steps` は要検証。
- **AIDL `ISehRadioBridge` 不在**: `multiclientd` が毎秒要求して失敗（ROM 直込み IMS の限界）。VoLTE は Magisk モジュール推奨。
- **`setenforce 0` 禁止**: Samsung RKP (EL2) が反応して即再起動する。
- **`i2c_pmic` probe 失敗 (-107)**: 起動時ログに出るが実害は不明。
- **pstore の文字化け**: `console-ramoops` がビット化けすることがある（`strings` で読む）。

### バッテリー / 負荷
- CPU・ウェイクロックは通常アイドル（`system_server` ~7%、ユーザ空間wakelock 0）。
- **永続ログ `logcatd` は消費源**（`-b all` を `/data/misc/logd` へ約1MB/分＝約1.4GB/日書き込み）。
  - デバッグ用途のみ。不要なら無効化推奨（I/O・フラッシュ摩耗を削減）:
    ```bash
    adb shell 'su -c "setprop logd.logpersistd stop; setprop persist.logd.logpersistd \"\"; setprop logd.logpersistd.enable false"'
    ```
- ビルドが **userdebug** のためカーネル/フレームワークのログが多弁（`sec_bat`, `SDE`, `spcom` 等）。
  user ビルドにすれば減るが root 等の制約がある。
- 正確な放電レートは **バッテリー駆動で数時間後**に `dumpsys batterystats` で確認する（充電中は計測不可）。

---

## 8. 関連リポジトリ

- **本リポジトリ**: `https://github.com/nifuramoon/x1q-los21-build`（ROM ビルド・パッチ・本ドキュメント）
- **VoLTE/NFC/傍受モジュール**: `https://github.com/nifuramoon/scg01-los21-toolkit`
- デバイスツリー元: `https://github.com/Youras-Eutopia/android_device_samsung_x1q`（lineage-21）
- IMS 互換レイヤ元: `https://github.com/myesxc/Samsung-s20-ims-compat-layer`

---

## 9. 用語

| 用語 | 意味 |
|---|---|
| x1q / SCG01 | 端末 codename / 型番 |
| CS35L41 | Cirrus 製スマートアンプ（スピーカー） |
| offload | 圧縮音声を DSP/HAL に直接渡す再生パス。音量適用が HAL 任せ |
| SSR | SubSystem Restart（モデム等サブシステムの再起動） |
| RPMh | Resource Power Manager hardware（AP↔RPM の電源管理通信） |
| TZBSP | TrustZone BSP。`TZBSP_ERR_FATAL_NON_SECURE_WDT` = セキュア側が非セキュアWDTを検知してリセット |
| RRO | Runtime Resource Overlay |
| privapp-permissions | 特権アプリの許可リスト（allowlist） |
| WDT | Watchdog Timer |
