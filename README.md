# x1q (Galaxy S20 5G Snapdragon / SCG01) LineageOS 21 build

Samsung Galaxy S20 5G Snapdragon (x1q / SCG01 / SM-G981N) 向けに
LineageOS 21 (Android 14) をビルドするための設定・パッチ置き場。

## 構成

```
x1q-los21-build/
├── README.md                 # この文書（ビルド手順 + 知見）
├── local_manifests/x1q.xml   # LOS マニフェストに追加するリポジトリ
├── patches/                  # 当てるパッチ（下記）
└── scripts/build.sh          # ビルドスクリプト
```

## 使用リポジトリ

| path | repository | branch |
|---|---|---|
| device/samsung/x1q | Youras-Eutopia/android_device_samsung_x1q | lineage-21 |
| device/samsung/sm8250-common | Youras-Eutopia/android_device_samsung_sm8250-common | lineage-21 |
| kernel/samsung/sm8250 | Youras-Eutopia/android_kernel_samsung_sm8250 | lineage-21 |
| hardware/samsung | LineageOS/android_hardware_samsung | lineage-21.0 |

## パッチ一覧

| # | 対象 | 内容 |
|---|---|---|
| 0001 | `kernel/samsung/sm8250` (`techpack/audio/asoc/kona.c`) | **スピーカー音声修正**。CS35L41 アンプをハードコードされたデバイス名 (`cs35l41-codec.0.auto`/`.4.auto`) ではなく **`of_node` で解決**。MFD の自動採番がオフセットし `.1.auto`/`.5.auto` になると `snd_soc_register_card` が失敗し、**サウンドカード自体が登録されない**（＝無音、かつ後述の再起動）のを防ぐ。 |
| 0002 | `system/sepolicy` | **`imsd`/`multiclientd` ドメイン追加**（`type ...; type ..._exec, exec_type, file_type, system_file_type; typeattribute ... coredomain; init_daemon_domain(...); permissive ...;`）＋ `file_contexts`。ROM 直込みで IMS デーモンを init 起動できるようにする。 |
| 0003 | `device/samsung/x1q` | **統合設定**: `s20volte_ims` の RRO を `/product/overlay` へ（`Android.mk`, `s20volte_ims.mk`）、`multiclientd.rc` のトリガを `ro.vendor.multisim.simslotcount` に修正、`WITH_SU:=true`（`BoardConfig.mk`, `lineage_x1q.mk`）。 |
| 0004 | `device/samsung/sm8250-common` (`system.prop`) | **音量バグ修正**: `audio.offload.disable=1`。Samsung ベンダー HAL が**圧縮オフロード再生パスで音量ステップを適用しない**ため、オフロードを使うアプリ（デフォルトの音楽アプリ Eleven 等）が音量1でも爆音になっていた。全再生を Mixer(PCM) パスに通し、AOSP のソフト音量を効かせる。 |
| 0005 | `device/samsung/x1q` (`gapps/`, `device.mk`) | **GApps の ROM 内蔵**: MindTheGapps 14.0 を prebuilt として `product`/`system_ext` に同梱（`PRODUCT_COPY_FILES`）。`product.img`/`system_ext.img` を焼き直しても GApps（Play ストア等）が消えず、特権権限（`MANAGE_USERS` 等）も allowlist ごと入るため Play ストアが落ちない。 |
| 0006 | `build/make`, `vendor/lineage`, `device/samsung/x1q` | **GApps内蔵のためのビルドシステム変更**: ① `build/make/core/Makefile` に `BUILD_BROKEN_PREBUILT_APK_PRODUCT_COPY_FILES` で APK の `PRODUCT_COPY_FILES` を許可する分岐を追加、② `BoardConfig.mk` に APK/ELF の BROKEN フラグ、③ `vendor/lineage/config/common.mk` の `ro.control_privapp_permissions` を `enforce`→`log`（GApps が allowlist 外の特権権限を要求しても boot 失敗しないように）。 |
| 0007 | `system/logging` (`logcat/logcatd.sh`) | **自発再起動のROM側恒久対策**: `logcatd` ラッパで `-n` 値が非数値（例 `32M`）なら既定 `256` に補正。`logd/README.property` が `.size` を “MB” と記載しているのに `logcatd.rc` が `-n`（回転ファイル数）へそのまま渡すため、`logcat: Invalid -n '32M'` で即終了 → init が updatable クラッシュと誤検知して再起動、を防ぐ。 |

> GApps バイナリ（`device/samsung/x1q/gapps/system`, 約 630MB, 39 ファイル）はリポジトリに含めず、
> MindTheGapps 14.0 モジュール（`/data/adb/modules/mindthegapps/system`）から
> `adb pull` して配置する。詳細は下記「GApps の ROM 内蔵」を参照。

## ビルド手順

```bash
# 1. 依存（Arch Linux）
sudo pacman -S --needed base-devel git repo rsync ccache gperf \
    jdk17-openjdk libxml2 schedtool

export JAVA_HOME=/usr/lib/jvm/java-17-openjdk

# 2. ソース取得
mkdir -p /mnt/build/los21 && cd /mnt/build/los21
repo init -u https://github.com/LineageOS/android.git -b lineage-21.0 --git-lfs
mkdir -p .repo/local_manifests
cp /mnt/build/x1q-los21-build/local_manifests/x1q.xml .repo/local_manifests/
repo sync -c -j$(nproc) --force-sync --no-clone-bundle

# 3. vendor blobs（端末または stock firmware から抽出）
cd device/samsung/x1q
./extract-files.sh

# 4. パッチ適用
cd /mnt/build/los21
for p in /mnt/build/x1q-los21-build/patches/*.patch; do
    ( cd "$(git -C . rev-parse --show-toplevel 2>/dev/null)" && git apply "$p" ) || patch -p1 < "$p"
done

# 5. ビルド
source build/envsetup.sh
breakfast x1q
mka bacon -j4          # 15GB RAM では -j4 推奨（OOM 回避）
```

生成物: `out/target/product/x1q/lineage-21.0-*.zip`

### フラッシュ（fastbootd 経由の例）
```bash
adb reboot fastboot
fastboot flash system system.img
fastboot flash product product.img
fastboot flash boot   boot.img
fastboot reboot
```
（`vbmeta` は環境により `vbmeta_samsung` 等の名前差異に注意）

---

## 知見（重要）

### 1. スピーカー無音 → カーネル音声修正で解決（パッチ0001）
- **症状**: スピーカーから一切音が出ない。`/proc/asound/cards` が `--- no soundcards ---`。
- **原因**: `kona-asoc-snd`（サウンドカード）が登録されない。`msm_asoc_machine_probe` が
  `ASoC: CODEC DAI cs35l41-pcm not registered` で失敗。理由は `kona.c` が CS35L41 アンプの
  デバイス名を **ハードコード**（`cs35l41-codec.0.auto` 等）しているのに、MFD の自動採番
  (`PLATFORM_DEVID_AUTO`) が環境により `.1.auto`/`.5.auto` を付与するため。
- **修正**: アンプを DT の `qcom,component-devs` から解決し **`of_node`** で `cs35l41_spk[]` /
  `cs35l41_conf[]` にバインド。オーディオポリシー復活 → サウンドカード登録。

### 2. 自発再起動 → 上記の音声修正で解消
- `system_server` のメインスレッドが音声ポリシー不良で
  **`AudioSystem::listAudioProductStrategies` に15秒ブロック** → フレームワーク watchdog 発火 → 再起動。
- 音声カード登録後は `system_server_pre_watchdog` が発生しなくなり、自発再起動も停止。

### 3. IMS/VoLTE・SMS
- AOSP(LOS21) に Samsung 独自 IMS (`com.sec.imsservice`) を載せるため、
  - **RRO**（`S20VoLTEImsOverlay.apk`）を **`/product/overlay`** に配置（`com.android.phone` の
    `config_ims_mmtel_package`/`config_ims_rcs_package` → `com.sec.imsservice`）。
  - `imsd`/`multiclientd` を動作させる（ROM直込みはパッチ0002、実績構成は Magisk モジュール）。
- **SMS(VoLTE SmsIP)**: 動作。
- **音声通話(VoLTE)**: **Magisk モジュール `s20volte_ims` 併用で成立**（デーモンを magisk ドメインで
  実行する構成が確実）。ROM 直込みのみでは AIDL ラジオブリッジ等の世代差で不安定。
  → 詳細・モジュールは `scg01-los21-toolkit` を参照。

### 4. 音量（1段で爆音）→ 解決
- 症状: デフォルトの音楽アプリ（Eleven）で音量1でも爆音、段階変化なし。YouTube は正常。
- 原因: Eleven は**圧縮オフロード再生パス**（`compressed_offload`, `AUDIO_OUTPUT_FLAG_COMPRESS_OFFLOAD|DIRECT`）を使う。
  Samsung ベンダー HAL はオフロード時に音量ステップを適用せず（`out_set_volume` は PCM で実質未対応）、
  AOSP 側もオフロードではソフト音量を掛けないため、固定の大音量になる。YouTube は通常の Mixer(PCM) パスなので正常。
- 対処: `audio.offload.disable=1`（パッチ0004）。全再生を Mixer パスに通し、AOSP のソフト音量を効かせる。
  検証: Eleven 再生中の Mixer スレッドで step1=−53dB → step15=0dB の段階変化を確認。
- 参考: デジタル出力自体は元々正常（step1=−64dB〜step15=−11dB）で、ソフト音量は機能していた。

### 5. GApps の ROM 内蔵（Play ストアが落ちる問題）→ 解決
- 症状: Play ストアが起動のたびにクラッシュ
  （`SecurityException: You either need MANAGE_USERS or CREATE_USERS permission to: query users`）。
- 原因: `product.img` を焼き直すと、実パーティション `/product` に入れていた MindTheGapps
  （`Phonesky`/`GmsCore` 等）が消え、特権アプリ扱いされず `MANAGE_USERS` が付与されない。
  控えの Magisk モジュール `mindthegapps` は `disable` されていた。
- 対処: MindTheGapps 14.0 を prebuilt として `device/samsung/x1q/gapps/system` に取り込み、
  `gapps.mk`（`PRODUCT_COPY_FILES`）で `product`/`system_ext` に同梱（パッチ0005）。
  privapp-permissions allowlist も同梱されるため特権権限が付与される。
  - `PRODUCT_COPY_FILES` は APK/ELF を拒否するため、`build/make/core/Makefile` に
    `BUILD_BROKEN_PREBUILT_APK_PRODUCT_COPY_FILES` バイパスを追加し、`BoardConfig.mk` で
    APK/ELF の BROKEN フラグを有効化（パッチ0006）。
  - `ro.control_privapp_permissions` を `log` に変更（`vendor/lineage/config/common.mk`、パッチ0006）。
- 手順（GApps バイナリの取り込み）:
  ```bash
  adb root
  adb shell su -c 'cp -r /data/adb/modules/mindthegapps/system /data/local/tmp/mtg_system'
  adb pull /data/local/tmp/mtg_system device/samsung/x1q/gapps/system
  ```
- 注意:
  - ROM 内蔵後は Magisk モジュール `mindthegapps` を無効化（`touch /data/adb/modules/mindthegapps/disable`）して重複を避ける。
  - フラッシュは `system`/`system_ext`/`product` のみ。`boot` は焼かない（Magisk root と `s20volte_ims` を維持）。
    - 手順: `adb reboot fastboot` → `fastboot flash system/system_ext/product` → `fastboot reboot`
  - 検証済み: `MANAGE_USERS: granted=true`、Play ストア起動クラッシュ0、`audio.offload.disable=1`、root 維持。

### 6. その他
- `persist.dbg.volte_avail_ovr=1` 等が必要。
- `system_app` は permissive 運用（`sepolicy/vendor/system_app.te`）。

### 7. 自発再起動バグ → 解決（`logcatd` クラッシュ）
- 症状: 数分おきに勝手に再起動。`persist.sys.boot.reason.history` に `reboot`（`shell`/`ota`/`recovery` 以外）。
- 原因: `persist.logd.logpersistd.size` が **`32M`**（`/data/property/persistent_properties` に手動設定）で、
  `logcatd` サービスの `-n ${logd.logpersistd.size}` に不正値（回転**ファイル数**）として渡され
  `logcat: Invalid -n '32M'` で即終了（status 1）。init が「updatable プロセスが4分間に4回クラッシュ」と判断 →
  `sys.init.updatable_crashing=1` → `flags_health_check UPDATABLE_CRASHING` → 再起動。
- 診断:
  ```bash
  adb shell getprop sys.init.updatable_crashing            # 1
  adb shell getprop sys.init.updatable_crashing_process_name  # logcatd
  adb shell logcat -b all -d | grep -E 'logcatd.*exited|Invalid -n'
  ```
- 対処: `setprop persist.logd.logpersistd.size 16`（`-r 2048`KB × 16 ≒ 32MB の意図に合わせる。既定は `256` ファイル）。
  persist プロパティのため再起動後も保持。`sys.init.updatable_crashing` は再起動でクリア。
- 検証済み: 再起動後 5 分以上安定、`logcatd` クラッシュ 0、`sys.init.updatable_crashing` 未設定。
- 備考: この値は ROM 既定（`logcatd.rc` の `:-256`）ではなく `/data` の persist 値が原因だったので、
  ROM 側の変更は不要（factory reset でも既定に戻る）。
- **ROM側の恒久対策（パッチ0007）**: `logcatd.sh` で `-n` の非数値値を `256` に補正。
  これにより、誰がどのような不正値を `persist.logd.logpersistd.size` に入れても `logcatd` は落ちず、再起動しない。
  （AOSPの `logd/README.property` が `.size` を “size in MB” と説明しているのが誤解の元。）

#### 7-b. もう一つの再起動要因: カーネルWDTバイト（RCUストール）
- ROM内蔵GApps化＋フラッシュ直後の高負荷時に、`reboot` が **約2〜3分間隔**で連続発生。
- `logcatd` 修正後も継続 → `SYSTEM_LAST_KMSG` に決定的ログ:
  ```
  rcu: INFO: rcu_preempt detected stalls on CPUs/tasks:
  rcu:     rcu_preempt kthread starved for 1140 jiffies!
  rcu: INFO: rcu_sched detected stalls on CPUs/tasks:
  rcu:     rcu_sched kthread starved for 1140 jiffies!
  ```
- `/proc/reset_summary`:
  ```
  UPLOAD CAUSE = 0xcafebabe = TZBSP_ERR_FATAL_NON_SECURE_WDT
  GCC_RESET_STATUS = SECURE_WATCHDOG | PMIC_RESIN
  ```
- つまり **RCUストール（CPUがカーネル内で長時間張り付き）→ セキュアモニタ経由のWDTバイト → リセット**。
  init の `updatable_crashing` とは別系統のカーネル要因。
- 観察: フラッシュ直後（GApps/各種ドライバ初期化で load平均 8〜15）に多発し、load が 3 前後に落ち着くと
  再起動が停止（15分以上安定、後に 35分以上安定）。過渡的な高負荷が引き金の可能性が高い。
- 現状: 安定化を確認。再発時は `SYSTEM_LAST_KMSG` / `/proc/reset_summary` を再取得して、
  スタックしたCPU/ドライバ（WiFi `dhd`、`i2c_pmic`、IMS `ISehRadioBridge` ポーリング等）を特定する。

#### 7-c. 再起動の有力な再現条件: **USB(充電)を外すと数分で再起動**
- 観察（ユーザ報告・再現性あり）:
  - **USB接続（充電中）では数時間安定**。
  - **USBを外す（バッテリー駆動）と数分で再起動**。
- 裏付け: 充電中はサスペンドしない（`/sys/power/suspend_stats/success = 0`、dmesg に `PM: suspend` なし）。
  → **バッテリー時に初めてサスペンド経路へ入り、そこでハング**している。
- ハングの痕跡（`SYSTEM_LAST_KMSG` / pstore）:
  - `rcu_preempt/rcu_sched kthread starved`（RCUストール）
  - `qsee_rpmh: Srcs Busy / Retrying RPMH message Send`（RPMh=AP↔RPM電源管理がbusy）
  - `vndbinder:... wait_for_shutdown_ack / sysmon_send_shutdown / mdm_subsys_shutdown`（モデム停止ACK待ちで固まる）
  - `kworker ... ufshcd_gate_work → ufs_qcom_set_bus_vote → rpmh_write_batch`（UFSの電源遷移もRPMhで停止）
  - `/proc/reset_summary`: `UPLOAD CAUSE = TZBSP_ERR_FATAL_NON_SECURE_WDT` / `SECURE_WATCHDOG | PMIC_RESIN`
- つまり **サスペンド時の電源管理(RPMh)・モデム停止のハング → セキュアWDT → リセット**。
  ソフト(ROM)より**カーネル/ファームウェア(電源管理・モデム)側**の要因。
- 実施済みの緩和: モデム `restart_level` を `SYSTEM`→`RELATED`（`init.x1q.rc`、パッチ0009）。
  ただし完全には止まらず（約2時間おきに再発）。
- 次の候補（未検証）:
  1. `dhd`(WiFi/Broadcom) の runtime-PM 無効化（ログで最も活発。PCIe/WiFiサスペンドハングの定番）。
  2. UFS runtime-PM（`ufshcd_gate_work`）無効化。
  3. モデム LPM/power-collapse 無効化、または `sysmon` 停止タイムアウト緩和。
  4. QCOM watchdog の bite-time 延長（過渡ハングでのリセット回避。恒久ハング時はフリーズ化のトレードオフ）。
  5. 切り分け: WiFi OFF / `s20volte_ims` OFF でバッテリー再起動が減るか。
- 診断用: Magisk `rebootlog` モジュールを導入済み。毎起動で pstore・`reset_summary`・
  `SYSTEM_LAST_KMSG`・永続logcat を `/data/local/tmp/rebootlogs/<ts>/` に保存する。

## メモ
- 初回 `repo sync` は約 100GB / 数十分〜。
- ビルドは 6 コア / 15GB RAM で **-j4 推奨**（-j6 は OOM）。swap を増やすと安定。
- `out/soong` の再解析が入ると 20〜30 分かかることがある。
