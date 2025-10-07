
## 关于仓库

[BILIBILIAS](https://github.com/1250422131/bilibilias)的开发者可使用此仓库的构建产物来构建APP，下载后需要手动解压至下面指出的文件夹中。


## 发布产物结构

```
ffmpeg/
├── arm64-v8a/lib/
├── armeabi-v7a/lib/
├── x86_64/lib/
├── include/
└── as-ffmpeg-version
```

开发者可前往Releases下载构建产物，下载后需手动解压至`BILIBILIAS\core\ffmpeg\src\main\cpp`中，注意cpp下需要有ffmpeg文件夹包裹。


## FFmpeg

本仓库采用FFmpeg官方源码直接构建，用于自身APP使用打包后的二进制产物，未对源码进行任何修改，如需使用请参照官方仓库指导。

This binary contains FFmpeg built from the unmodified official source:
https://github.com/FFmpeg/FFmpeg
Licensed under LGPL 2.1, see COPYING.LGPLv2.1