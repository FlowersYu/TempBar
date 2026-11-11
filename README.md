# TempBar —— 温度计桌面小组件

把办公室里的温湿度计数据，直接放到每台 Mac 的桌面上。

- **官网 / 下载**：<http://36.111.167.161:8888/tempbar/>
- **要求**：macOS 13+，Apple Silicon
- **直接下载**：<http://36.111.167.161:8888/tempbar/TempBar.zip>（解压后右键「打开」一次）

---

## 为什么这么做

温湿度计刷了 pvvx 固件后，会通过蓝牙低功耗（BLE）**广播**温湿度，格式是 BTHome v2。

关键在于「广播」这件事：设备不是在跟某一台电脑「连接」，而是在持续地喊「我现在 23.5 度、33% 湿度」。任何在范围内的设备都可以收到数据，无需配对，也不占用温度计的电池。

所以架构很简单：**每台 Mac 自己听广播**。没有服务器、没有网关、不用配置、装上就能用。

```
温湿度计 ──BLE 广播──> 每台 Mac（独立接收）──> 菜单栏 / 桌面小组件 / 通知
```

代价是 Mac 必须在蓝牙范围内（10 米内，同办公室够用）。

---

## 用了什么，为什么

| 部分 | 选择 | 原因 |
|---|---|---|
| 蓝牙 | CoreBluetooth 被动扫描 | `allowDuplicates=true`，否则只能收到第一次广播 |
| 界面 | AppKit 手写 | 不需要 Xcode 工程，`swiftc` 一条命令出成品 |
| 小组件 | 桌面层 NSPanel | **不是 WidgetKit**，见下 |
| 分发 | ad-hoc 签名 + zip | 同事右键打开一次即可，零成本 |

### 小组件为什么不用 WidgetKit

两个硬限制：

1. **刷新太慢**。WidgetKit 组件由系统进程渲染，靠 Timeline 请求刷新，最短也是分钟级。温度每 10 秒广播一次，用 WidgetKit 你看到的永远是个几分钟前的旧数字。
2. **需要付费账号**。WidgetKit 要用 App Group 共享数据，免费证书签不出来。

改用桌面层浮动面板：压在壁纸上、在普通窗口之下，能秒级更新，零权限要求。

### macOS 蓝牙的坑（踩过）

命令行直接跑二进制访问 CoreBluetooth 会**被系统 SIGABRT 杀掉**，连授权弹窗都不出现。因为进程没有 bundle，系统读不到 `Info.plist` 里的 `NSBluetoothAlwaysUsageDescription`。

必须满足三个条件：
1. 打成 `.app` bundle
2. `Info.plist` 里有蓝牙用途说明
3. 用 `codesign` 签名（ad-hoc 即可）

所以有 `build.sh` 这套打包流程。

---

## 开发时踩到并修掉的问题

| 问题 | 现象 | 修法 |
|---|---|---|
| 界面时序 | 首条广播到达时面板视图未加载，崩溃 | `refresh()` 加 `isViewLoaded` 判断 |
| 初始化顺序 | `widget` 还是 nil 时 onChange 触发 | 先建 UI 再开数据源 |
| 防抖饿死 | 广播比延迟密，节流写入被无限取消，一次都存不进 | 加 15 秒兜底强制写盘 |
| 曲线压扁 | 阈值线在 28°，读数 23°，曲线挤成一条缝 | 阈值线离数据太远时不纳入视野 |
| 文字截断 | "湿度"被图表挤掉 | 左侧列设 required 压缩阻力，图表改弹性宽度 |
| 深色模式 | labelColor 调透明度变成脏灰 | 绘制时按 effectiveAppearance 解析 |

---

## 文件

```
TempBar/
├── Sources/
│   ├── App.swift          入口、菜单栏、生命周期
│   ├── Decode.swift       BTHome v2 + ATC1441 解码（有断言测试）
│   ├── Model.swift        数据中枢、历史存储、采样策略
│   ├── Scanner.swift      蓝牙扫描 + 阈值通知
│   ├── Views.swift        曲线、卡片等基础控件
│   ├── WidgetPanel.swift  桌面小组件
│   ├── StatusPanel.swift  菜单栏弹出面板
│   ├── Settings.swift     设置窗口
│   └── SelfTest.swift     离屏渲染自检（TEMPBAR_SELFTEST=1）
├── build.sh               编译 + 签名
├── package.sh             打 zip 分发
└── dist/                  给同事的成品
```

## 常用命令

```sh
./build.sh                       # 编译
./package.sh                     # 打分发 zip

# 界面自检（不需要真实设备，渲染 PNG 到 /tmp）
TEMPBAR_SELFTEST=1 TEMPBAR_SELFTEST_DIR=/tmp/shots ./build/TempBar.app/Contents/MacOS/TempBar

# 演示模式（伪造数据，验证链路）
defaults write local.tempbar.app tempbar.demo -bool true
open build/TempBar.app
# 关闭
defaults delete local.tempbar.app tempbar.demo
```

## 数据位置

`~/Library/Application Support/TempBar/state.json`，保留 7 天。

采样策略：最短 30 秒一个点；超出 30 秒必记；不足 30 秒时只有变化 >0.5°C 或 >3% 才提前记。这样既能抓住空调启停，又不会让文件膨胀。

---

## 已知限制

- **温度计固件必须广播温湿度**。如果刷机时在 BTHome 配置页没勾选温湿度，广播里只有电压和包序号，读不到温度。在刷机页面重新配置即可。
- 同一时间只显示一台温度计（多台可在面板里切换）。
- 只在 Apple Silicon 上编译过；Intel Mac 需要改 `build.sh` 里的 target 再 lipo 合并。
