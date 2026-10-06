# 金桔 / Kumquat

[![CI](https://github.com/tommy-yjw/kumquat/actions/workflows/ci.yml/badge.svg)](https://github.com/tommy-yjw/kumquat/actions/workflows/ci.yml)
![License](https://img.shields.io/badge/license-MIT-green)
![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)

**常驻屏幕一角的拖拽转换工具**——把文件拖到悬浮气泡上弹出径向动作菜单;或者**拖着文件直接按住 Shift**,指针位置弹出投放轮盘,投到扇区即完成转换。全程本地处理,不上传任何文件,应用内不含任何网络组件。

灵感来自 [Tangerine](https://tangerineformac.com/),是其交互与功能的开源复刻(功能级实现,未使用其任何代码或资源)。

## 功能

**图片**(系统 sips / ImageIO,零依赖):JPG / PNG / HEIC / TIFF 互转、压缩、去 EXIF、旋转、翻转、缩放、灰度、多图拼贴、合成 PDF,以及内置编辑器(裁剪 / 涂黑 / 标注)

**PDF**(PDFKit):合并、拆分、压缩、转图片、旋转

**视频 / 音频**(需自行安装 [ffmpeg](https://formulae.brew.sh/formula/ffmpeg)):MP4 / MOV / MKV / WebM / GIF 互转、抽音轨、变速、抽帧、剪短、涂黑;音频归一化、声道转换、波形图

**Office → PDF**(需 [LibreOffice](https://www.libreoffice.org/)):docx / xlsx / pptx 无头转换

**文档**(需 [pandoc](https://pandoc.org/)):md / docx / epub / html 互转;.doc 由系统 textutil 兜底

**归档**:打包 ZIP(系统 ditto)、解压 zip / tar.gz

可选引擎会在运行时探测:装了才显示对应动作,不装不影响其他功能。

## 安装

**方式一:下载**

从 [Releases](https://github.com/tommy-yjw/kumquat/releases) 页下载 `Kumquat-*.zip`,解压后拖入「应用程序」。

> 应用为 ad-hoc 签名(未公证),首次打开请**右键点击 → 打开**;若仍被拦,可在终端执行 `xattr -cr /Applications/Kumquat.app` 后再开。

**方式二:源码构建**

```bash
git clone https://github.com/tommy-yjw/kumquat.git
cd kumquat/app
./build.sh          # swiftc 编译 → 组装 Kumquat.app → ad-hoc 签名
open build/Kumquat.app
```

仅需 Xcode Command Line Tools(`xcode-select --install`),不需要完整 Xcode。

## 使用

| 方式 | 操作 |
|---|---|
| 投递气泡 | 把文件拖到屏幕一角的橙色气泡上 → 弹出径向菜单 → 点扇区执行 |
| Shift 手势 | 拖着文件**按住 Shift** → 指针处弹出投放轮盘 → **投到扇区上松手即执行** |

- 径向菜单扇区带数字角标,**按数字键 1-9 直接触发**;Esc 取消
- 图片编辑器:裁剪(可拖移/把手调整)、涂黑(实色/模糊/像素化)、标注(箭头/方框/文字)、缩放;支持选中/移动/删除,`Cmd+S` 保存
- 视频编辑器:双滑块剪短 + 涂黑模式
- 多文件批量处理,右下角进度窗可逐任务取消
- 菜单栏 🍊 可开关手势/气泡、查看引擎状态

转换副本保存在**源文件同目录**,完成后发系统通知(首次使用会请求通知权限)。

## 隐私

纯本地:全部转换由系统工具与本地子进程完成,应用**不含任何网络代码**,不上传、不遥测。

## 开发

- 纯 Swift(AppKit + SwiftUI + PDFKit + ImageIO),无第三方依赖,详见 [app/README.md](app/README.md)
- 测试:`cd app && ./run-tests.sh`(两阶段:CLI 纯逻辑 + App 宿主引擎自测,真实子进程)
- CI:GitHub Actions(macOS runner)自动构建并跑同一套测试

## 系统要求

- macOS 13.0+(Apple Silicon / Intel)
- Xcode Command Line Tools(仅构建需要)

## 已知限制

- 图片导出格式受系统 ImageIO 能力限制(部分机器不可写 WebP,运行时自动隐藏对应动作)
- 不支持 RAR 解压(专有格式)
- 视频涂黑当前为整段实色,不支持模糊样式与时间段限定

## 致谢

- [Tangerine](https://tangerineformac.com/) —— 交互与产品形态的灵感来源
- 系统工具链:sips、ImageIO、PDFKit、AVFoundation、ditto、tar、textutil;可选引擎 ffmpeg、pandoc、LibreOffice

## License

[MIT](LICENSE)
