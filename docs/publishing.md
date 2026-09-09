# 上传与发布说明

项目已存在 Git 历史，不需要重新 `git init`。以下说明介绍首次上传和后续分发所需的步骤。

本次构建、测试和素材检查结果见 [上传准备验证记录](github-preparation-validation.md)。

## 第一次上传

建议仓库名：`smartKey`。建议 About 描述：

> 为十年前的 3.5 mm 智键提供 macOS 适配：单击、双击、长按触发键盘、多媒体、脚本与快捷指令。

建议 Topics：`macos`、`swift`、`swiftui`、`smartkey`、`hid`、`automation`。

1. 在 GitHub 创建空仓库，按需要选择公开或私有，不额外初始化 README、LICENSE 或 `.gitignore`。
2. 在本地项目根目录检查 `git status` 和 `git diff`，然后提交准备好的文件：

   ```bash
   git add README.md README.en.md LICENSE CONTRIBUTING.md .gitignore .gitattributes .github docs
   git commit -m "docs: prepare smartKey for GitHub"
   ```

3. 使用 GitHub 显示的仓库地址配置 `origin`，再推送当前分支。下面命令会询问地址，避免把示例用户名误用为目标仓库：

   ```bash
   printf '粘贴你的 GitHub 仓库地址：'
   read -r smartkey_remote_url
   git remote add origin "$smartkey_remote_url"
   git push -u origin HEAD
   ```

   若已经配置 `origin`，先用 `git remote -v` 核对，勿重复添加。新建空仓库可避免与远端初始化提交冲突，无需强制推送。

4. 上传后检查 README 图片和 GIF，按需填写 About / Topics，并查看 Actions 首次运行结果。

保留历史上传会一并公开 Git 提交的作者姓名与邮箱；当前历史包含作者邮箱。修改以后的 Git 邮箱不会改变既有提交。本次未改写历史。

## 自动化与分发

[CI 工作流](../.github/workflows/ci.yml) 在 push、pull request 或手动触发时运行 `swift test` 和 `scripts/build-app.sh`，使用明确的 `macos-26` runner，避免 `macos-latest` 迁移造成系统版本漂移。该标签见 [GitHub 官方 runner 镜像列表](https://github.com/actions/runner-images#available-images)。工作流不安装或启动应用，不启用真实 HID 测试，不创建 Release。

源码上传不等于已有可供公众直接安装的正式发行包。当前打包是本机架构、ad-hoc 签名，无 Developer ID 公证。若后续提供二进制 Release，应说明构建版本、macOS 要求、CPU 架构与签名状态，并完成目标设备上的实际运行验证。当前版本信息在 [Info.plist](../packaging/Info.plist) 中为 `0.2.0`（构建号 `2`）。

## 文档与素材

- [中文 README](../README.md) 与[英文 README](../README.en.md) 面向首次访问者；英文文档保留中文界面名称以便对照，程序本身仅提供中文界面。[使用详解](usage.md) 保留完整配置语义，[贡献指南](../CONTRIBUTING.md) 说明开发与反馈方式。
- `assets/` 包含用户提供的 6 张 PNG 截图，以及由录屏转出的 GIF 和 MP4。README 使用仓库相对路径，无需上传图床。
- 原始 MOV 约 20 MB，留在本机，未复制进仓库；MP4 保留完整演示时长，去除源元数据，GIF 用于首页自动播放。
- 截图与演示中的 Notch Note / Codex 是个人动作配置，未把个人脚本或快捷指令打包进项目。
- B 站链接只作硬件背景参考，没有下载或转载该视频。
- `.build`、本地工具配置、环境文件和日志由 `.gitignore` 排除。应用运行时的个人配置不在仓库目录中。

历史产品规划和验证记录保留在 `docs/`，不作为当前功能承诺。许可证版权署名沿用仓库提交作者 `dtw7607`。
