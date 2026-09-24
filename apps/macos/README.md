# syncstr macOS

マウント済みの音楽フォルダからMP3を選んで再生する、最小のmacOSアプリです。
曲一覧、再生、一時停止、フォルダ再読み込みに対応します。
選択したフォルダの直下を読み、音源やメタデータへは書き込みません。
再生する1曲をメモリへ読み込むため、小規模な試聴向けです。

## 起動

Command Line ToolsのSwiftとmacOS SDKを使用します。

```sh
sh apps/macos/build.sh
open apps/macos/.build/Syncstr.app
```

「フォルダを選択…」からMP3のあるフォルダを開き、曲名を押すと再生します。
フォルダ選択はCommand-Oでも開けます。
共有を切断した場合は、接続し直して「再読み込み」を押してください。

## 試聴用NASの接続

この接続操作にはMacの管理者権限が必要です。

```sh
mkdir -p /private/tmp/syncstr-nas-music
sudo /sbin/mount_nfs -o ro,resvport,nfsvers=3 nas:/mnt/data/syncstr/music /private/tmp/syncstr-nas-music
```

アプリで `/private/tmp/syncstr-nas-music/ARN0014_01` を選択します。
接続の終了時は `sudo /sbin/umount /private/tmp/syncstr-nas-music` を実行します。
NFS接続の成否は実際のネットワークと共有設定に依存します。

## 試聴用9曲の検証

```sh
xcrun swiftc -parse-as-library -module-cache-path apps/macos/.build/module-cache -o apps/macos/.build/playback-check apps/macos/MusicFiles.swift apps/macos/PlaybackCheck.swift
apps/macos/.build/playback-check /private/tmp/syncstr-nas-music/ARN0014_01
```

ファイルの抽出・順番・デコード・再生クロック・一時停止・再開を確認します。
この検査は無音です。実際に音が聞こえることはアプリで確認してください。
