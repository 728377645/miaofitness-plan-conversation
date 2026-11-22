# 喵喵健身（Miao Fitness）

一个离线优先的个人健身与体测管理应用。界面为单文件 HTML，iOS 侧提供 Xcode 原生壳工程，Android 侧提供 WebView 壳与构建脚本。仓库内的档案与体重默认值均为通用空模板，原始个人数据未包含。

## 功能

### 训练与打卡
- 今日动作清单：按训练日展示动作，支持逐项完成、一键勾选全部、临时添加当天动作
- 训练方案管理：可新增（D / E / F …）、编辑、删除方案，每周安排可任意选择已建方案
- 训练日安排：休息 / 方案 A / 方案 B / 方案 C 及自定义方案，内容可编辑
- 连续训练天数与本周计划完成进度

### 动作库
- 内置标准动作库，支持按分类筛选、按名称或动作要点搜索、分组折叠浏览
- 添加动作时可多选、全选/清空，并统一设置组数次数；库里没有的动作可临时自定义
- 动作库可自行编辑，每行 `动作 | 要点 | 分类`，标准动作自动归类，自定义动作归入「其他」

### 体测与体重
- 身体成分速览：BMI、体脂率、腰臀比、骨骼肌等指标
- 个人档案：身高、年龄、起始/目标体重、体脂目标、腰臀比目标、基础代谢、健康评分，均可编辑
- 快速记体重、体重趋势图、历史记录修改/删除与撤销
- 拍照识别导入体测报告：AI 识别后先确认再写入，不会直接覆盖已有数据

### 饮食与计划
- 根据体测数据生成的饮食建议（高蛋白优先、粗细粮搭配、三餐加餐、训练后补充等），可自行编辑
- AI 给出的计划修改建议可勾选应用，应用前自动保存快照，支持一键撤销
- 一键填写到各板块：按档案、饮食、训练等分组勾选建议值，支持分组全选/全不选、手动添加字段、从分析文字离线提取，应用后可整体撤销

### AI 教练
- 基于体测数据、体重趋势、训练打卡和当前计划生成分析，也可附加自定义问题
- 支持 DeepSeek、硅基流动 SiliconFlow、自定义接口
- 填好 API Key 后可自动从 `/models` 拉取模型列表，再手动选择文字模型与视觉模型；支持测试连接和手动输入兜底
- 分析结果可复制、存入历史；历史记录支持一键载入对应的填写建议

### 数据管理
- 档案、计划、饮食、体重和历史记录全部保存在设备本地
- iOS 端每次保存都会把完整数据同步备份到 App 沙盒文件，页面加载前自动回填；本地服务器使用固定端口，保证页面来源稳定，退出重进不会丢数据
- JSON 备份导出/导入、体重 CSV 导出/导入、撤销上次导入/重置、恢复默认数据
- 页面不会在运行时自动清理用户数据，只需自行填写一次即可长期保留
- API Key 仅保存在本机浏览器或应用中，不写入分享链接；AI 分析时数据只发送给你选择的服务商

## 目录结构

```
.
├── README.md
├── conversation-data.json        # 脱敏后的会话导出记录
├── .github/workflows/
│   └── build-ios.yml             # macOS runner 自动构建 IPA
├── android/
│   ├── AndroidManifest.xml
│   ├── src/                      # WebView 壳 Activity
│   ├── res/                      # 应用名称
│   ├── assets/index.html         # 单文件应用界面（已脱敏）
│   └── build_apk.py              # APK 构建脚本
└── ios/
    ├── FitnessPlan.xcodeproj/    # Xcode 工程
    ├── FitnessPlan/              # Swift 原生壳与内嵌 HTML
    ├── preview.html              # 可直接在浏览器打开的界面预览
    ├── miaomiao-fitness.ipa      # 已构建的 iOS 安装包（ad-hoc 签名）
    ├── build_ipa.sh              # iOS 出包脚本
    └── install_xcode.sh
```

## 安装

### iOS
使用仓库内的 `ios/miaomiao-fitness.ipa`（arm64，ad-hoc 签名），或从 Releases 下载最新安装包。`ios/` 目录同时提供完整 Xcode 工程，可在 macOS + Xcode 下打开 `ios/FitnessPlan.xcodeproj` 编译，或运行 `ios/build_ipa.sh` 出包。

ad-hoc 签名包不能直接安装到未越狱 iPhone：可用 Sideloadly / AltStore 配合免费 Apple ID 重签名，或用 Xcode 登录免费账号后直接 ▶ Run。

### Android
运行 `python android/build_apk.py` 自行构建 APK，在 Android 5.0（API 21）及以上设备安装。首次安装需允许安装未知来源应用。

## 从源码构建

- Android：需要 JDK 21、Android SDK（platform android-34、build-tools 35.0.0）。按本机环境设置 `ANDROID_SDK_ROOT` / `JAVA_HOME` 后运行 `python android/build_apk.py`。
- iOS：macOS + Xcode，运行 `ios/build_ipa.sh`。

## GitHub Actions 自动出包

`.github/workflows/build-ios.yml` 在 `macos-latest` runner 上运行 `ios/build_ipa.sh`，生成 `FitnessPlan.ipa` 并上传为 artifact。可在 Actions 页手动触发，也会随 `ios/` 变更自动执行。当前账号下 `macos-14` 标签会因无法分配 runner 而立即取消，工作流统一使用 `macos-latest`。

## 隐私说明

仓库与安装包中的档案、体重等默认值为通用空模板，原始个人数据未包含。页面不会在运行时自动清理数据，所有内容只保留用户自己填写的结果。使用 AI 功能需要你自行配置 API Key，分析请求会发送到你选择的服务商。AI 建议仅供参考，不能替代医生或专业教练的诊断。
