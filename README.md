# x1q (Galaxy S20 5G Snapdragon / SCG01) LineageOS 21 build

LineageOS 21 (Android 14) を Samsung Galaxy S20 5G Snapdragon (x1q / SCG01) 向けに
ビルドするための設定・パッチ置き場。

## 構成

```
x1q-los21-build/
├── README.md                 # この文書（ビルド手順）
├── local_manifests/x1q.xml   # LOS マニフェストに追加するリポジトリ
├── patches/                  # 当てるパッチ
└── scripts/build.sh          # ビルドスクリプト
```

## 使用リポジトリ

| path | repository | branch |
|---|---|---|
| device/samsung/x1q | Youras-Eutopia/android_device_samsung_x1q | lineage-21 |
| device/samsung/sm8250-common | Youras-Eutopia/android_device_samsung_sm8250-common | lineage-21 |
| kernel/samsung/sm8250 | Youras-Eutopia/android_kernel_samsung_sm8250 | lineage-21 |
| hardware/samsung | LineageOS/android_hardware_samsung | lineage-21.0 |

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
./extract-files.sh            # 端末接続時。firmware からは setup-makefiles.sh 併用

# 4. パッチ適用
cd /mnt/build/los21
for p in /mnt/build/x1q-los21-build/patches/*.patch; do
    git -C "$(dirname "$p")" apply "$p" 2>/dev/null || patch -p1 < "$p"
done

# 5. ビルド
source build/envsetup.sh
breakfast x1q
mka bacon -j$(nproc)
```

生成物: `out/target/product/x1q/lineage-21.0-*.zip`

## 既知の問題と対応

- **音量が1段で最大になる**: AOSP 側 HAL ラッパー (`StreamOut::setVolume`) は正規化ゲインを
  ベンダー HAL に渡すだけ。原因はベンダー `set_volume` 実装側の可能性が高い。`patches/` を参照。
- **たまに再起動**: A14 system × A11 vendor のミスマッチ由来。カーネル/ベンダー層。

## メモ

- 初回 `repo sync` は約 100GB / 数十分〜。
- ビルドは 6 コア / 15GB RAM で数時間。
