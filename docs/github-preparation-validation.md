# GitHub 上传准备验证记录

日期：2026-09-09。基于提交 `cdeac05`，应用版本 `0.2.0`（构建号 `2`）。本次改动仅涉及文档、媒体与仓库配置，未修改应用源码。

## 测试与构建

环境：macOS 26.6.2、Xcode 26.6（17F113）。

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

命令退出码为 0。XCTest 6 项通过；Swift Testing 报告 95 项，其中 94 项执行通过，1 项真实 HID 测试默认跳过。合计 **100 项通过、1 项跳过、0 项失败**。

首次在受限文件系统沙箱内运行时，系统默认文本编辑器查找测试返回空值而失败。正常系统权限下完整复测通过；没有修改或跳过该测试来规避问题。

release 构建使用：

```bash
CLANG_MODULE_CACHE_PATH=/tmp/smartkey-publish-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/smartkey-publish-module-cache \
SMARTKEY_SWIFT_DISABLE_SANDBOX=1 ./scripts/build-app.sh
```

命令退出码为 0，生成 `.build/release-app/smartKey.app`，打包脚本中的 `codesign --verify --strict` 通过。这是本机 ad-hoc 签名，不是公证验证。本次未运行安装脚本，未覆盖 `/Applications` 中的应用。

本机日志位于 `/tmp/smartkey-publish-review/tests-system.log` 和 `/tmp/smartkey-publish-review/build.log`，不纳入仓库。

## 首次 CI 后的测试修正

首次上传后的 [GitHub Actions 运行](https://github.com/DTW7607/smartKey/actions/runs/34301687477) 暴露了 `secondScriptRunFailsBusyUntilFirstCompletes` 的计时依赖：第一个脚本固定休眠 3 秒，在较慢 runner 上可能在测试恢复调度前退出，导致第二次运行被正常接受而误报失败。

测试改为等待脚本启动标记，并让第一个脚本持续运行到主动取消（保留 30 秒超时兜底），同时验证忙碌时拒绝重复运行、取消成功、取消后可以再次运行。未修改应用执行器行为。修正后本地完整测试退出码为 0，仍为 100 项通过、1 项真实 HID 测试跳过；日志位于 `/tmp/smartkey-publish-review/tests-ci-fix.log`。

## 文档与仓库检查

- 中英文 README、贡献指南与 `docs/` 下 Markdown 的本地链接和图片引用均可解析到现有文件；中英文 README 的素材引用和 Shell 命令一致。
- 工作流与 Issue 模板 YAML 解析通过；工作流权限仅为 `contents: read`。
- 构建、安装脚本的 `bash -n` 检查通过，应用 Info.plist 的 `plutil -lint` 检查通过。
- `git diff --check` 通过。
- 已提供 6 张原始截图，录屏转换为 1440 × 932 H.264 MP4 和循环 GIF，素材合计约 10 MB。原始 MOV 未加入仓库。
- 当前项目文本的常见令牌、私钥和个人绝对路径模式检查未发现匹配；这不是完整的 Git 历史秘密审计。既有提交包含作者邮箱，保留原历史。

## 未执行的验证

未重新进行实体按键、设备插拔、音频路由、系统授权、锁屏和睡眠唤醒验证；这些不由默认自动化测试覆盖。本记录仅包含上传前的本地验证；上传后的 GitHub runner 结果请查看仓库 Actions。B 站页面无法通过当前网页工具读取，README 保留用户提供的视频标题与链接作为背景参考，未声称观看或转述视频内容。
