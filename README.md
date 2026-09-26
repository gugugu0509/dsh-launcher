# DSH 桌面启动器

一个用于启动 / 停止 DeepSeek Harness（DSH）Web 界面的 Windows 桌面启动器。

## 文件

| 文件 | 说明 |
| --- | --- |
| `启动DSH.bat` | 双击运行入口（调用 `launcher.ps1`） |
| `launcher.ps1` | 启动器主程序（图形界面） |
| `安装桌面快捷方式.ps1` | 在桌面创建 `DSH 启动器.lnk` |
| `dsh.ico` | 图标（首次运行时自动生成） |
| `logs/` | DSH 运行日志（`dsh-web.log` / `dsh-web.err.log`） |
| `dsh.pid` | 记录本次启动的进程 ID（停止时使用） |

## 使用方法

1. **安装快捷方式**（可选，一次即可）：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File ".\安装桌面快捷方式.ps1"
   ```
2. **启动**：双击 `启动DSH.bat`（或桌面快捷方式），点击「启动」。
3. 服务就绪后会自动打开带 token 的地址 `http://127.0.0.1:3080/?token=...`。
4. **停止**：点击「停止」，会结束整个 DSH 进程树。
5. **关闭启动器窗口不会停止 DSH**，服务在后台继续运行。

## 配置

DSH 源码目录**自动检测**，无需手工配置。检测顺序：

1. 命令行参数 `-HarnessDir <路径>` 或环境变量 `DSH_HARNESS_DIR`
2. 正在运行的 DSH 进程命令行（最贴近实际）
3. 启动器所在目录向上逐级查找（含同级名字带 `harness` / `dsh` 的目录）

以上都找不到时，「启动」会提示需要显式指定目录。

需要手动指定时，可改 `启动DSH.bat` 里的调用方式：

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1" -HarnessDir "D:\my\dsh" -Port 3080
```

- `-HarnessDir`：DSH 源码目录（默认自动检测）
- `-Port`：Web 端口（默认 `3080`）

## 功能

| 功能 | 说明 |
| --- | --- |
| 启动 / 停止 | 一键启停 DSH Web；「停止」会结束整个 DSH 进程树 |
| 状态指示 | 未检测 / 启动中 / 运行中 / 已停止，自动刷新 |
| **用量面板** | 显示 DeepSeek 账户余额与 token 用量（输入 / 输出 / 缓存），每 10 秒刷新 |
| 日志窗口 | 内置日志窗口实时增量刷新；「日志」按钮可直接打开日志文件 |
| 自动开浏览器 | 服务就绪后自动打开**带 token 的地址** `http://127.0.0.1:3080/?token=...` |
| 桌面快捷方式 | 一键在桌面创建 `.lnk` |

## 说明

- 启动命令为 `pnpm dsh web --no-open`，由启动器负责打开浏览器（这样能带上 token 地址）。
- 若端口已被占用（DSH 已在运行），「启动」会直接返回，状态栏显示「运行中」。
- 关闭启动器窗口**不会**停止 DSH，服务在后台继续运行。
- 用量数据全程本地：余额走官方余额接口（用 `$DSH_HOME/.credentials.yaml` 里的 `DEEPSEEK_API_KEY`），token 用量从 `$DSH_HOME/sessions/` 的会话记录解压统计。

## 关于本项目

- 本项目由 **AI（DeepSeek Harness）生成**，人类负责需求定义与验收。代码未逐字复制任何第三方项目。
- 社区有多个同类 DSH 启动器；本项目的实现、界面与用量面板均为独立编写。

## License

MIT，见 [LICENSE](LICENSE)。
