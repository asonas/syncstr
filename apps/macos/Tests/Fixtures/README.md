# 音源fixture

`untagged.mp3`、`untagged.flac`、`untagged.m4a` は、ffmpeg 9.0.1で生成した440Hz、0.1秒の正弦波です。購入した音源は含みません。

```sh
ffmpeg -f lavfi -i 'sine=frequency=440:duration=0.1' -map_metadata -1 -y untagged.flac
```

他の形式も出力拡張子だけを変更して生成しています。
