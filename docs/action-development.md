# 动作扩展与脚本运行约定

`SmartKeyActions` 是独立 SwiftPM library，负责动作定义、注册、分发、存储和执行。它不依赖 HID、SwiftUI 视图或提示气泡。

## 新增动作类型

1. 实现 `@MainActor ActionProvider`，设置稳定的 `typeID`（建议使用自己的域名前缀）。
2. 声明 `supportedVersions` 和 `capabilities(for:)`，实现纯参数/权限检查的 `validate`。
3. 在 `execute` 中执行动作；耗时工作移出主线程，支持取消时响应 Task cancellation。
4. 在 `ActionCoordinator` 的组装处注册 Provider。扩展设置选择器和参数表单即可加入产品 UI，无需修改 HID 或气泡。

```swift
import SmartKeyActions

@MainActor
final class ExampleProvider: ActionProvider {
    let typeID = "example.status"

    func capabilities(for action: ActionDefinition) -> ActionCapabilities {
        ActionCapabilities(canVerifyResult: true)
    }

    func validate(_ action: ActionDefinition, context: ActionContext) throws {
        guard action.parameters["message"] != nil else {
            throw ActionError("请填写消息。")
        }
    }

    func execute(_ action: ActionDefinition, context: ActionContext) async throws -> ActionResult {
        try Task.checkCancellation()
        return ActionResult(action.parameters["message"]!, verified: true)
    }
}

let registry = ActionRegistry()
registry.register(ExampleProvider())
let dispatcher = ActionDispatcher(registry: registry)
let action = ActionDefinition(typeID: "example.status", name: "查看状态", parameters: ["message": "就绪"])
let execution = dispatcher.run(action, context: ActionContext(source: .test))
```

名称必须是 1–12 个计数单位（中文占 2 个单位），且没有首尾空格或控制字符。动作类型和参数版本未知时配置保留，执行失败，不推断其他行为。当前 registry 按类型 ID 注册一个 Provider；重复注册用于显式替换实现。

物理事件有低频冷却，试运行绕过该冷却；空动作不进入执行器。所有执行均产生 `ActionExecution`，包含开始/结束时间、结果、状态与取消入口。`verified=false` 表示命令已发送，不能宣称目标业务已完成。脚本退出码非零进入失败状态。

后续宏可以通过该服务组合子动作，但需要自行定义循环引用、顺序、失败和取消语义。首版没有动态插件加载或宏编辑 UI。

## 配置与文件

用户目录为 `~/Library/Application Support/smartKey/`：

- `actions.json` 是动作、绑定与脚本元信息的权威来源，带 schemaVersion。
- `actions.previous.json` 保存上一有效版本；恢复后再次保存会保留损坏文件副本。
- `smartKey.conf` 保留现有手势、外观等配置，`doubleClickEnabled` 由双击绑定自动管理，写作 `0/1`。手动写该字段与绑定冲突会被纠正。
- `Scripts/<UUID>/script.sh` 是由默认应用打开的托管副本。重命名只更新元信息，不改变文件路径。

动作设置通过 UI 写入后立即生效。手动更改 `actions.json` 需重启；conf 保持原有热更新。跨文件保存不能天然原子化：权威记录先落盘，派生 conf 同步失败会提示并在刷新/重启后重试。

## 脚本内容、环境与快照

导入复制文件，不改原文件。界面提供只读源码预览，通过“使用默认应用打开”编辑托管副本；智键不提供源码编辑器，也不改变系统关联。编辑器按纯文本类型关联查找，找不到时回退到 TextEdit。名称、说明和运行设置在智键内显式保存；信息草稿在本次设置会话中保留。

试运行和物理触发每次读取磁盘上最新保存的 UTF-8 内容，不读取外部编辑器的未保存草稿。源码上限 1 MiB，不接受 NUL；读取会检测常见的原地修改和原子替换。文件监听只刷新状态，不决定实际执行内容。脚本包保存名称、说明、解释器和内容，不导出环境变量，不打包外部依赖。

执行通过 `/bin/zsh -c <本次源码> <原路径>` 或 `/bin/bash -c ...`，源码作为独立参数，不拼接到包装 shell 命令中；因此本次执行不会被随后保存改写。`$0` 是托管源路径，`SMARTKEY_SCRIPT_PATH` 和 `SMARTKEY_SCRIPT_DIR` 明确提供原路径。使用 bash 的 `BASH_SOURCE`、zsh 的特殊来源变量或源码行号追踪时，不应假设与解释器直接读取文件完全相同。脚本与环境变量的合计长度还受系统 ARG_MAX 限制；超限会拒绝启动并报告原因。

工作目录默认托管文件所在目录，可指定绝对路径。依赖原项目相邻文件的脚本需配置工作目录；相对路径不会自动指向导入来源。若脚本以 `$0` 或 `SMARTKEY_SCRIPT_DIR` 定位同目录依赖，仅修改工作目录也不会改变该路径，需要调整脚本中的依赖路径或自行放置依赖文件。默认 PATH 为 `/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin`，界面可覆盖环境变量。shell 非登录、非交互运行，仍遵循所选 shell 的标准启动行为；不自动加载用户交互终端环境或安装依赖。stdin 为 `/dev/null`。

同时最多一个脚本执行，重复触发不排队。超时默认 30 秒，支持 1–3600 秒。取消/超时先 TERM，再对仍存活的受管进程组 KILL；正常退出也清理同组后台子进程。主动脱离进程组的守护进程不在保证范围，首版不提供常驻服务管理。执行以当前用户权限进行，无自动提权，停止不撤销已经发生的外部副作用。

stdout/stderr 分别最多保留 256 KiB，超出仍排空管道并标记截断。结果在本次应用会话中保留最多 100 条，重启不保留详细输出；不自动上传诊断或脚本内容。

## 构建与验证

常规：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`。

在禁止嵌套 sandbox 的运行环境中，可使用 `swift test --disable-sandbox`，并把 `CLANG_MODULE_CACHE_PATH` 与 `SWIFTPM_MODULECACHE_OVERRIDE` 指向可写临时目录。

`./scripts/build-app.sh` 只生成 `.build/release-app/smartKey.app`，不安装、不启动、不抢占硬件。它是本机 ad-hoc 签名构建，不是 Developer ID 公证分发包。

开发预览：运行构建产物并传 `--settings-preview`，使用独立临时配置，不启动 HID/音频管理/登录项。可通过 `SMARTKEY_PREVIEW_DIRECTORY` 指定预览数据目录。预览中的测试按钮仍会真实执行选定动作。

## 快捷指令动作

`ShortcutActionProvider` 使用 `typeID = "shortcut"`、参数版本 1。`parameters` 包含 `shortcutID`（UUID）、`shortcutName`（完整名称快照）和 `timeout`（1–3600 秒的字符串，缺省 300）。动作自身 `name` 是独立的短显示名称。沿用 schemaVersion 1；配置载入不依赖系统列表，未知参数版本保留但拒绝执行。

`ShortcutCatalog` 异步执行 `/usr/bin/shortcuts list --show-identifiers`，按末尾 UUID 解析，支持名称中空格、括号和换行。同名条目在选择器中附加短 ID；列表无结构化输出，无法识别或截断时明确报错，并保留上次成功缓存。加载超时 15 秒，标准输出最多 2 MiB。每次展开选择列表时异步重新枚举；物理触发直接执行保存的 ID，无名称回退。

`ShortcutCommandRunning` 是内部可注入边界，正式实现调用 `ManagedProcess`，测试使用模拟执行器，不执行用户已有快捷指令。命令固定为 `/usr/bin/shortcuts`，使用独立 argv：`run <UUID>` / `list --show-identifiers`，不经过 shell。首版无输入参数与输出文件管理；运行输出分别最多 256 KiB，仅保留会话记录。

`ManagedProcess` 从脚本执行器提取，接收可执行路径、参数、工作目录、环境与超时，保持脚本在后台读取本次源码快照的行为。统一错误为 `ActionRunError`，旧名称 `ScriptRunError` 保留为类型别名。快捷指令执行与脚本各有一个并发槽，重复触发不排队；dispatcher 的 `runningTasks` 用于退出处理，原 `runningScript` 继续用于脚本删除保护。

退出码 0 表示系统报告运行成功，不进一步验证指令内部的业务副作用。快捷指令的取消文案是「停止等待」，超时和取消的结果 `verified=false`。CLI 的受管进程组可回收，但 Shortcuts 系统服务及已经发生的副作用不在该进程组内，不能保证取消整个指令。首次授权、交互输入、真实指令重命名后运行和系统端取消行为仍需本机手动验收。


执行输出展示：`ProcessOutput` 在后台严格识别 UTF-8 文本，二进制/PDF 返回说明，不把图片字节替换解码后交给文本排版。遇到捕获上限截断时可移除最多 3 个残缺 UTF-8 尾字节。`ExecutionOutputView` 仅展开时创建预览，限制前 4096 个 Unicode 码点和 160 码点单行，使用固定高度纵向滚动，避免图片数据、超长单行或组合字符序列堵塞主线程。当前不提供图片预览或保存原始二进制输出；需在快捷指令本身保存/查看图片。

快捷指令表单不提供搜索或手动刷新按钮。选择列表使用弹出面板，展开期间显示缓存并异步更新，关闭后取消读取，重新展开会重新读取。打开按钮通过 NSWorkspace 启动系统 App，不执行 `shortcuts view`，也不依赖当前选择。
