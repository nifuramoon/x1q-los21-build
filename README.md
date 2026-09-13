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

### 4. その他
- `persist.dbg.volte_avail_ovr=1` 等が必要。
- `system_app` は permissive 運用（`sepolicy/vendor/system_app.te`）。
- 音量バグ（1段で大音量）はベンダー HAL の `set_volume`/acdb 側の残課題。

## メモ
- 初回 `repo sync` は約 100GB / 数十分〜。
- ビルドは 6 コア / 15GB RAM で **-j4 推奨**（-j6 は OOM）。swap を増やすと安定。
- `out/soong` の再解析が入ると 20〜30 分かかることがある。
