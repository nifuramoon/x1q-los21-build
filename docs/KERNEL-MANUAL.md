# SCG01 (x1q) LineageOS 21 — カーネル開発マニュアル

> **この文書の目的**: 初めてこのプロジェクトを見るAI/エンジニアが、前提知識ゼロから
> 「何が起きていて、何が直っていて、何が未解決で、次に何をすべきか」を一読で理解できるように、
> 大手ベンダーのAPIリファレンス並みの粒度で記録する。
>
> 対象: Samsung Galaxy S20 5G au版 **SCG01**（コードネーム **x1q**, Snapdragon SM8250/kona）
> に **LineageOS 21**（Android 14）を焼き、**VoLTE/SMS/NFC/カメラ/GAppsが動き、自発再起動が無い**
> 完全な daily driver にするプロジェクト。

---

## 0. 現在の状況（要約・30秒で把握）

| 項目 | 状態 |
|---|---|
| 音声（スピーカー無音） | ✅ 修正済み（パッチ0001） |
| 音量バグ | ✅ 修正済み（0004） |
| VoLTE通話/SMS | ✅ 動作（Magisk `s20volte_ims` v9 をHIDL経路で使用。詳細は後述） |
| NFC eSE再起動 | ✅ 恒久対策（`nfcsefix`） |
| カメラ | ✅ 修正済み（0011） |
| GApps / Play Store | ✅ ROM内蔵（0005/0006） |
| **自発再起動** | ⚠️ **未解決（最重要）**。base LOS21カーネルのサスペンドでAPがハング |
| VoLTE rawブリッジ（AIDL） | ⚠️ 未実装。型定義がSamsung非公開 |

**最重要の未解決問題** = 「画面OFF（サスペンド）で数分後に再起動する」。詳細は §4.3 / §6。

---

## 1. 端末とROMの全体像

### 1.1 ハードウェア
- **SCG01** = Galaxy S20 5G の au/KDDI版。コードネーム **x1q**（Snapdragon版。Exynos版は x1s で別物）
- SoC: Qualcomm **SM8250**（Snapdragon 865 / kona）
- 初期ファーム: Android 12 / One UI 4.1 / `SCG01KDU1CVC2` / 2022-03
- ベンダーパーティション: **Samsung Android 11** 由来（`samsung/x1qksx/x1q:11/.../G981NKSS4IXE4`）
- UFS 128GB、PIT 88エントリ。データパーティション `sda37`

### 1.2 ソフトウェア構成
| レイヤ | 内容 |
|---|---|
| ROM | LineageOS 21（AOSP Android 14, SDK34, arm64-v8a） |
| カーネル | `4.19.315`（リポジトリ `Youras-Eutopia/android_kernel_samsung_sm8250`, branch lineage-21） |
| ベンダー | Samsung A11 のブコブ（`/vendor`） |
| 参照（正常動作する） | **AstroOS 4.0.0**（OneUI系）＝ **AstroKernel 4.19.325**。これだけがサスペンド再起動しない |

### 1.3 主要な作業ディレクトリ
| パス | 内容 |
|---|---|
| `/mnt/build/los21` | AOSP/LOS21 ソースツリー |
| `/mnt/build/los21/kernel/samsung/sm8250` | **カーネルソース（直接編集する）** |
| `/mnt/build/los21/device/samsung/x1q` | デバイス設定（BoardConfig, init.x1q.rc, s20volte_ims等） |
| `/mnt/build/x1q-los21-build` | **本ドキュメントのリポジトリ**（patches/, docs/） |
| `/home/nifuramu/Desktop/SCG01` | ROM/module/log のアーカイブ |

---

## 2. ビルドとフラッシュ（再現手順）

### 2.1 ビルド
```bash
cd /mnt/build/los21
source build/envsetup.sh
lunch lineage_x1q-userdebug
mka bootimage   # カーネル+boot.img のみ（高速）
# または mka bacon -j4 で全イメージ
```
- **`-j4` 必須**（それ以上は soong bootstrap がメモリ不足で kill される）
- `rm -f out/.lock`（"Trying to lock out/.lock" が出た場合）
- soong 再解析に 20〜35分かかる（config変更時）

### 2.2 フラッシュ（Magisk root を維持する）
```bash
# 1. 端末で root 取得
adb root; adb push out/target/product/x1q/boot.img /data/local/tmp/boot_new.img
# 2. 端末上のMagiskでパッチ
adb shell 'su -c "cd /data/adb/magisk && KEEPVERITY=true KEEPFORCEENCRYPT=true sh boot_patch.sh /data/local/tmp/boot_new.img"'
adb shell 'su -c "cp /data/adb/magisk/new-boot.img /data/local/tmp/new-boot.img; chmod 644 /data/local/tmp/new-boot.img"'
adb pull /data/local/tmp/new-boot.img /tmp/new-boot.img
# 3. fastbootd で書き込み
adb reboot fastboot; fastboot flash boot /tmp/new-boot.img; fastboot reboot
```

### 2.3 重要な注意
- **`setenforce 0` 禁止**（Samsung RKP が反応して再起動する）
- USBを物理的に接続しているとサスペンドしない（`a600000.ssusb: Abort PM suspend`）
- テストは必ず**バッテリー駆動＋画面OFF**で行う

---

## 3. パッチカタログ（0001〜0025）

各パッチは `patches/` に差分として保存。カーネル側は `/mnt/build/los21/kernel/samsung/sm8250` の
ワーキングツリーに適用済み（未コミットの `git diff` 状態）。

| # | 対象 | 内容 | 状態 |
|---|---|---|---|
| 0001 | `techpack/audio/asoc/kona.c` | スピーカー無音。CS35L41アンプをhardcode名でなく `of_node` 解決（MFD採番オフセット対策） | ✅ |
| 0002 | `system/sepolicy` | `imsd`/`multiclientd` ドメイン追加 | ✅ |
| 0003 | `device/samsung/x1q` | RRO, multiclientd.rc, WITH_SU | ✅ |
| 0004 | `sm8250-common/system.prop` | `audio.offload.disable=1`（音量バグ: 圧縮オフロードで音量ステップ非適用） | ✅ |
| 0005/0006 | device/build | MindTheGapps ROM内蔵（`PRODUCT_COPY_FILES` + BROKENフラグ + privapp log） | ✅ |
| 0007 | `system/logging/logcatd.sh` | `-n` 非数値→256（logcatd再起動対策） | ✅ |
| 0009 | `init.x1q.rc` | モデム `restart_level=RELATED`, StrongBox stop | ✅ |
| 0010 | kernel `dhd_pcie_linux.c` + BoardConfig | `pcie_aspm=off` + WiFi dhd runtime-PM無効 | ✅（**load-bearing**） |
| 0011 | `hardware/interfaces/wifi` | WiFi HAL nullガード（カメラsession error対策） | ✅ |
| 0012 | kernel `dhd_pcie_linux.c` | `dhdpcie_pm_suspend`/`_noirq` no-op | ✅（**load-bearing**） |
| 0013 | kernel `cs40l2x.c` | ハプティクス suspend no-op | ✅ |
| 0014 | `init.x1q.rc` | 全PCIe `power/control=on` | ✅ |
| 0015 | kernel `kona.dtsi` | AP watchdog `bark-time` 11000→30000 | ⚠️ 効果薄（TZ側が本命なので） |
| 0016 | kernel `pci-msm.c` | `msm_pcie_drv_suspend` no-op | ✅ |
| 0017 | kernel `pci-msm.c` | `msm_pcie_pm_suspend` no-op | ✅ |
| 0018 | kernel `spi-geni-qcom.c` | `spi_geni_suspend` の `-EBUSY` 撤廃 | ✅ |
| 0019 | kernel `mhi_qcom.c` | `mhi_system_suspend` の中断廃止 | ✅ |
| 0020 | kernel `mhi_qcom.c` | サスペンド中のMHI wakeup無効化 | ✅ |
| 0021 | kernel `ipa.c`/`ipa_pm.c` | IPA wakeup源 非登録 | ✅（**解決の主要因**） |
| 0022 | kernel config + `sec_debug.c` | `QCOM_WATCHDOG_V2` 無効化（AstroKernel合わせ） | ⚠️ 実験・結果は別panic。現在**戻し済み** |
| 0023 | kernel `kona.dtsi` | SP/SPSS 無効化 | ⚠️ 実験・別panic。**戻し済み** |
| 0024 | kernel `qmi_rmnet.c` | powersave workqueue を `WQ_FREEZABLE` 化 | ✅ |
| 0025 | kernel `suspend.c`/`main.c`/`rpmh-rsc.c` | **NIFURAマーカーprintk**（サスペンド/リセット経路の診断ログ） | 🧪 診断用（テストROM） |

> 0022/0023 は実験で適用→別のpanic（MHI panic等）を招いたため**リバート済み**。カレント構成は
> 0001〜0021, 0024, 0025。

---

## 4. カーネルの重要メカニズム（本プロジェクトで判明した知見）

### 4.1 サスペンド/レジュームの流れ
`kernel/power/suspend.c` が中核。
```
pm_suspend(state)
 └ enter_state()
    ├ ksys_sync()                    # "Syncing filesystems"
    ├ suspend_prepare()              # フリーザー（userspace凍結）
    └ suspend_devices_and_enter()
       ├ platform_suspend_begin()
       ├ dpm_suspend_start()         # 各デバイスの .suspend（pm_debug_messagesで個別表示）
       ├ suspend_enter()             # 実際のスリープ
       └ dpm_resume_end()            # 復帰
```
- **フリーザー**はuserspaceを凍結するので、`/dev/kmsg` を読む userspace ロガーは**この時点で止まる**。
  → サスペンド中のログは userspace では取れない。カーネル側（`no_console_suspend` + pstore/console）で取る。
- `pm_debug_messages=1`（`/sys/power/pm_debug_messages`）でデバイス毎の suspend 成否が出る。

### 4.2 ウォッチドッグの階層（最重要）
| 層 | 実体 | 動作 |
|---|---|---|
| AP watchdog | `msm_watchdog`（`drivers/soc/qcom/watchdog_v2.c`） | `[pet_watchdog]` を定期出力。`bark_time`で噛む |
| TZ watchdog | TrustZone の `SECURE_WATCHDOG` | APがハングすると `TZBSP_ERR_FATAL_*` でリセット |
| AOP | Always-On Processor（blobファーム） | センサー/RPM/クロック担当。APのbite通知を受けてダンプ |

**決定的な知見**: AOP の `aop_fsm_process_event → abort`（`do_crash_dump`）は**原因ではなく結果**。
実際の順序は:
```
APがサスペンド/パワーコラプス中にハング
  → AP watchdog が bite（Non Secure Watchdog Bark）
  → AOP が bite interrupt を受けて abort/dump（AOP_NON_SECURE_WD_BITE_INT_RECEIVED）
  → TZ が SECURE_WATCHDOG / RPM_ERR でリセット
```
つまり「AOPクラッシュ」と見えたものは、**APが先にハングした事後ダンプ**だった。

### 4.3 自発再起動の全体像
- **根本**: LOS21ベースカーネル（4.19.306/315）のサスペンド経路に、この端末特有のハングがある。
  - 元の無改造カーネル（4.19.306, 2024-07）でも再起動することを確認済み。
- **増幅要因1**: `s20volte_ims`（Samsung RILスタック）。無効化すると再起動間隔が 2〜4分→約27分に激減。
- **増幅要因2**: AIDL `ISehRadioBridge` 欠落 → `multiclientd` が毎秒リトライ（CPUがidleしない）。
- **増幅要因3**: 低バッテリー（充電切れ）による低電圧/PMICリセット。
- **唯一正常なカーネル**: AstroKernel 4.19.325（非公開）。これのサスペンド処理が正しい。

### 4.4 RPMH / RSC / AOP（ハング候補）
- `drivers/soc/qcom/rpmh-rsc.c` の `rpmh_rsc_send_data()` は **TCS Busy 時に無制限リトライ**する。
  ```c
  do { ret = tcs_write(...); if (ret == -EBUSY) { udelay(10); } } while (ret == -EBUSY);
  ```
  → 恒久的に Busy だとここで永久ループ＝APハングの有力候補。
- AOP がクロックを提供（`qmp-aop-clk`）しており、AOPが死ぬと RPMH 通信も詰まる。
- リセット時の `TZBSP_ERR_FATAL_RPM_ERR` / `TCS Busy, retrying` がこの経路の証拠。

### 4.5 PCIe / MHI / モデム
- PCIe RC0 = WiFi, RC2 = モデムMHI（`drivers/pci/controller/pci-msm.c`）。
- MHI（`drivers/bus/mhi/controllers/mhi_qcom.c`）は M0/M3 の状態機械。`MHI_ASSERT(mhi_pm_state != M3)` が
  panicする（＝サスペンド復帰時に状態が合わない）。
- モデムSSR: `subsys9`（`soc:qcom,mdm0`）の `restart_level`。`SYSTEM`だとSSRで端末全体が再起動する→`RELATED`へ。
- QMI: `qmi_rmnet.c` の powersave work がサスペンド中に走ると `wda_set_powersave_mode` が
  `-110`(ETIMEDOUT) する。→ `WQ_FREEZABLE` で凍結して解決（0024）。

### 4.6 IPA（IPアクセラレータ / データパス）
- `drivers/platform/msm/ipa/`。モデム/WiFiのデータパス。
- `IPA_WS` とクライアントwlock（`IPA_CLIENT_APPS_LAN_CONS`等）が wakeup source を握り、
  `pm_wakeup_pending()` を真にしてサスペンドを abort していた（0021で非登録化）。

### 4.7 WiFi（Broadcom bcmdhd）
- `drivers/net/wireless/broadcom/bcmdhd_101_16/dhd_pcie_linux.c`。
- D3ハンドシェイク（`dhdpcie_set_suspend_resume`）がACK待ちで固まる → 0010/0012 で no-op。
- この2パッチは**戻すと再起動が復活する（load-bearing）**ことを実験で確認。

### 4.8 SP / SPSS / センサー
- SP = Samsung Sensor Processor（SPSS）。`qcom,spss@1880000`（PIL）。ファーム `spss2p.*`（`kona-v2.dtsi`）。
- `spss_utils`（`drivers/soc/qcom/spss_utils.c`）の `spss_wait_for_event` が毎ブート**60秒タイムアウト**する
  （SPが応答しない）。ただし、これは必ずしも再起動の直接原因ではない（相関のみ）。
- センサーHAL = `vendor.sensors-hal-multihal` / `vendor.spdaemon`（Samsung製、SP経由）。

### 4.9 RIL / VoLTE ブリッジ（AIDL/HIDL世代差）
- **フレームワーク（A14）が要求するのは AIDL** `vendor.samsung.hardware.radio.bridge.ISehRadioBridge/slot1`
  （`samsung_framework_compatibility_matrix.xml` で必須宣言）。
- **ベンダー（A11）が提供するのは HIDL** `@2.0::ISehBridge`（`manifest_radio.xml`）。
- この不一致で `multiclientd` が毎秒リトライ。
- AIDL `ISehRadioBridge`(V1) と HIDL `ISehBridge@2.0` は **1:1対応**（シンボルから完全復元済み）:
  ```
  ISehRadioBridge: setResponseFunctions(rsp, ind) / sendRequestRaw(int, byte[], int)
  ISehRadioBridgeResponse: sendRequestRawResponse(SehRadioResponseInfo, byte[], int)
  ISehRadioBridgeIndication: hookRaw / openFd / execute / convertToUtf8
  ```
- → シム（AIDL→HIDL中継）は**設計済み**。ただし型 `SehRadioResponseInfo` 等の正確な定義が
  Samsung非公開で未入手。

### 4.10 音声
- スピーカーアンプ CS35L41（2基）。カーネルのサウンドカード登録が MFD 自動採番のオフセットで失敗→無音。
- 音量は `audio.offload.disable=1` で AOSPソフトウェア音量を効かせる。

---

## 5. 診断技法（ツールと手順）

| 技法 | コマンド/場所 | 備考 |
|---|---|---|
| リセット原因 | `su -c "cat /proc/reset_summary"` | **最も重要**。`UPLOAD CAUSE` と AOPログが出る |
| 前ブートのカーネルログ | `su -c "cat /proc/last_kmsg"` | **クリーン**（pstoreより信頼できる） |
| pstore | `su -c "cat /sys/fs/pstore/console-ramoops-0"` | サスペンド中も残るが**ビット化けする** |
| サスペンド統計 | `cat /sys/power/suspend_stats/{fail,success,last_failed_dev,last_failed_step}` | 失敗デバイス特定 |
| デバイス毎suspend | `echo 1 > /sys/power/pm_debug_messages` | デバイス名で成否 |
| サスペンド中もコンソール維持 | `no_console_suspend loglevel=8`（cmdline） | パッチでBoardConfigに追加済み |
| 常時ログ保存 | `klogcap` Magiskモジュール | `/dev/kmsg`+logcat を `/data/local/tmp/klogcap/` に保存 |
| 強制サスペンド | `echo +15 > /sys/class/rtc/rtc0/wakealarm; echo mem > /sys/power/state` | 再現用 |

**NIFURA マーカー**（パッチ0025）: `dmesg | grep NIFURA` でサスペンド経路の到達点が分かる。
`NIFURA-SUSPEND` / `NIFURA-DPM` / `NIFURA-RPMH` の3種。

---

## 6. 未解決問題と次の一手

### 6.1 自発再起動（最優先・未解決）
- **必要材料**: AstroKernel（4.19.325）のソース。または base 4.19.315 サスペンド経路のハング点特定。
- **進行中の診断**: パッチ0025のprintkを焼いたテストROMで、`last_kmsg` の `NIFURA-*` 最後の行から
  **APがどこでハングしたか**を特定する。
- 候補: `rpmh_rsc_send_data` のTCS Busyループ（0025でカウンタ+BUG()仕込み済み）。

### 6.2 VoLTE rawブリッジ（AIDLシム）
- **必要材料**: `SehRadioResponseInfo` / `SehRadioIndicationType` / `SehRadioRequestType` の
  正確な AIDL 定義（Samsung非公開）。Samsung OSRC リリース申請か、公式ファームの解析で入手。

### 6.3 直近のTODO
1. build34（NIFURA instrumentation）を焼いて、再起動後の `last_kmsg` を解析
2. ハング点が判明したら、そこを修正
3. AIDL型定義を入手できたらシム実装

---

## 7. 用語集

| 用語 | 意味 |
|---|---|
| AOP | Always-On Processor。センサー/RPM/クロックを司る常時起動プロセッサ（blobファーム） |
| TZ | TrustZone（セキュアOS）。`SECURE_WATCHDOG` を持つ |
| RPMH / RSC | Resource Power Manager Handler / Resource State Coordinator。電源状態のメッセージング |
| MHI | Modem Host Interface（PCIe経由のモデムI/F） |
| IPA | IP Accelerator（データパスのハードウェア） |
| SP / SPSS | Samsung Sensor Processor（セキュア・センサー用プロセッサ） |
| SSR | Subsystem Restart（サブシステムの再起動） |
| PIL | Peripheral Image Loader（ファームローダー） |
| WDT / WDOG | Watchdog |
| AIDL / HIDL | Android Interface Definition Language / Hardware Interface Definition Language |
| TCS | Transfer Command Set（RPMHのコマンドキュー） |

---

## 8. リポジトリ・参照

- ビルド: `https://github.com/nifuramoon/x1q-los21-build`（tag `v2.0`）
- ツール/モジュール: `https://github.com/nifuramoon/scg01-los21-toolkit`
- カーネル: `https://github.com/Youras-Eutopia/android_kernel_samsung_sm8250`（lineage-21）
- 関連ドキュメント: 本リポジトリの `docs/COMPLETE-GUIDE.md`, `docs/SUSPEND-REBOOT-ANALYSIS.md`
