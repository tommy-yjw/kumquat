# 金桔 / Kumquat

常驻屏幕一角的**悬浮投递气泡**:把文件拖上去,气泡附近弹出**径向动作菜单**,选一个动作即完成转换。**拖文件时按住 Shift**,指针处直接弹出**投放轮盘**,投到扇区即执行(Tangerine 签名手势,免辅助功能权限实现)。纯本地运行,不上传任何文件。灵感来自 [Tangerine](https://tangerineformac.com/),是它的开源复刻。本文件是面向开发者的**详细技术文档**;安装与使用说明见仓库根 [README](../README.md)。

- 纯 Swift(AppKit + SwiftUI + PDFKit + ImageIO),无 Xcode 工程、无网络组件
- 引擎全部系统能力:图片 `sips`/ImageIO、PDF `PDFKit`、归档 `ditto`/`tar`、文档 `textutil`
- 可选引擎自动探测,装了才显示对应动作:视频/音频 `ffmpeg`、文档转换 `pandoc`
- 转换结果保存在**源文件同目录**,完成后发系统通知(点击可在 Finder 中显示)

## 构建与运行

```bash
cd kumquat/app
./build.sh          # 一条命令:swiftc 编译 → 组装 Kumquat.app → ad-hoc 签名
open build/Kumquat.app
```

- 依赖:仅 Xcode **Command Line Tools**(`swiftc`);按 `uname -m` 自动选择 arm64/x86_64,最低系统 macOS 13.0
- 调试钩子:`KUMQUAT_DEBUG=1` 输出拖拽链路日志;`KUMQUAT_PREVIEW_MENU=1` 启动后 0.8s 直接弹径向菜单(不走真实拖拽)

## 两种触发方式

| 方式 | 操作 | 适合 |
|---|---|---|
| 投递气泡 | 把文件拖到橙色气泡上 → 弹径向菜单 → 点扇区执行 | 精确、新手 |
| **Shift 手势**(v2) | 拖着文件**按住 Shift** → 指针处弹出投放轮盘 → **投到扇区即执行** | 快手流,全系统任意位置 |

- Shift 手势实现(免权限):`CGEventSource.flagsState` 读修饰键 + 轮询 `NSPasteboard.changeCount` 感知拖拽开始 + `.statusBar` 层级面板让拖拽会话重定向进来。**不需要辅助功能/输入监控授权**
- 轮盘消失:松开 Shift 且无悬停 / 投放完成 / 点按 / 15 秒超时;菜单栏可开关(默认开)
- 支持输入:图片 `jpg/jpeg/png/heic/gif/bmp/webp/avif/jp2`、PDF、文档 `md/txt/html/rtf/doc/docx/epub…`、归档 `zip/tar.gz/tgz`、文件夹、音视频 `mov/mp4/mkv/mp3/m4a/wav/flac…`(需 ffmpeg)

## 动作清单(v2)

**图片(系统 sips / ImageIO,始终可用)**

| 动作 | 实际执行 |
|---|---|
| 转为 JPG / PNG / HEIC / TIFF | `sips -s format`(源已是该格式不进菜单) |
| 转为 WebP | ImageIO 重编码(**运行时探测,本机 macOS 26.6 实测不可写,自动隐藏**) |
| 压缩 | `sips` JPEG 质量 60 |
| 去 EXIF | ImageIO 空属性字典重写(sips 无法去元数据,已实测) |
| 顺/逆时针 90°、水平/垂直翻转 | `sips -r` / `sips -f` |
| 缩放 50%、长边 1920 | `sips --resampleWidth/Height` |
| 灰度 | `sips --matchTo` 系统 Gray Profile |
| 拼贴(≥2 图) | CoreGraphics 网格合成,2 图横排 / 3-4 图 2×2 / 5-6 图 3×2 / 7-9 图 3×3,带透明出 PNG 否则 JPEG |
| 合成 PDF | PDFKit 每图一页 |

**PDF(PDFKit,始终可用)**

| 动作 | 实际执行 |
|---|---|
| 合并 PDF(≥2 个) | 按选择顺序串接 |
| 拆分 PDF | 每页一个 PDF("原名 页N.pdf") |
| 压缩 PDF | 逐页位图化 150dpi 重写(**有损**,矢量文本会转位图;截图/扫描件压缩收益明显) |
| 转为图片 | 每页 2× PNG |
| 顺/逆时针 90°(工具轮盘) | `PDFPage.rotation` 重写 |

**视频/音频(需 ffmpeg,未装自动隐藏;`brew install ffmpeg`)**

- 互转 MP4 / MOV / MKV / WEBM / GIF(12fps、最长边 720)、音频 MP3 / M4A / WAV / FLAC、视频提取音轨
- 变速 0.5× / 1.5× / 2×(`setpts` + `atempo`);抽帧 PNG(1s 处)——工具轮盘
- ffmpeg 分支参数未经真实运行验证(本机未装,README 如实记录)

**文档(pandoc 检测到才出现;.doc 用系统 textutil 兜底)**

- pandoc:DOCX / EPUB / HTML / MD / TXT 互转(读取 md/txt/html/docx/epub/rst/org/tex)
- textutil:.doc → DOCX / RTF / HTML / TXT(系统自带,始终可用)

**归档(系统 ditto / tar,始终可用)**

- 压缩为 ZIP:任何选择(含文件夹、混合类型);多来源经暂存目录合并压入(ditto -c 单来源限制,已实测绕过)
- 解压:zip → `ditto -x -k`;tar/tar.gz/tgz → `tar -xf`,输出到"原名 解压"目录

## 任务进度窗(v2)

右下角自动弹出:每个任务一行(转圈/✓/✗ + 文件名 + 输出),进行中的任务可**逐个取消**(取消通过 CancelToken 传导到子进程 terminate);全部结束 2.5 秒后自动收起。

## 键盘操作(v2)

径向菜单每个扇区带数字角标:**按数字键 1-9 直接触发对应动作**,Esc 取消。

## 输出规则(与 Tangerine 一致)

- 副本保存在源文件同目录,源文件不动;转换 = `原名.新扩展名`,动作 = `原名 动作后缀`,重名加 " 2"
- 完成后发系统通知;首次转换时询问通知权限

## 与 Tangerine 的差距(v2 后)

| 维度 | Tangerine($15 买断) | 金桔 v2 |
|---|---|---|
| 核心交互 | 拖拽中按 Shift 出轮盘,投放执行 | **已实现**(免权限方案);另有气泡入口 |
| 格式覆盖 | 宣称 190 种 | 图片 9 动作 + PDF 6 + 音视频 11(需 ffmpeg)+ 文档 5-6 + 归档 2,共 30+ 动作 |
| 文件工具 | 宣称 25 种(涂黑、拼贴、裁剪、变速、Merge PDF…) | 拼贴/变速/合并/旋转/缩放/灰度已实现;**自由裁剪、涂黑、标注需要画布 UI,未做** |
| 批量 | 多文件混合、进度窗可取消 | **已实现**(进度窗 + 逐任务取消) |
| Office→PDF | 宣称支持 | **未做**(系统无免费转换路径,需 MS Office 或 LibreOffice 才能高质量转换) |
| WebP 输出 | 宣称支持 | 本机 ImageIO 不可写(实测),自动隐藏 |
| 引擎 | 未公开(宣称全本地) | sips/ImageIO/PDFKit/ditto/tar/textutil + 可选 ffmpeg/pandoc |
| 分发 | Mac App Store | 源码 + build.sh 自行构建,ad-hoc 签名 |
| 隐私 | "never uploads, no server" | 同底线:纯本地、无任何网络组件 |

## 明确没做的(v3 候选)

自由裁剪/涂黑/标注的画布 UI(需要交互式编辑窗口)、Office→PDF(依赖 Office/LibreOffice 安装)、全局 Shift 手势的"拖拽进行中跟随指针"微调、视频剪短的时间范围选择 UI。
