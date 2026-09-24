# Changelog

两种版本号互不相干：

- **DSH x.y.z** — 你自己装的 DSH。启动器只读它的入口和版本号，**永不修改它**；升级走官方方式。
- **Launcher vN** — 本启动器。只在代码或接口契约变化时 +1。

---

## Launcher v1.0.0 — 首个可发布版本

**针对 DSH `0.1.7-alpha.1` 完整实测。**

### 实现了什么

| 能力 | 实测结果 |
|---|---|
| 隐藏冷启动（不创建任何控制台） | `WScript.Shell.Run(cmd, 0, $false)`，路径 `-File` + `-WindowStyle Hidden` 双保险 |
| 捕获一次性 token 并以它开窗 | stdout 重定向到 `start-server.cmd` → 正则提取 → 用**带 token 的链接**开 `--app=` 窗口 |
| 幂等复击 | 服务在跑且会话有效 → **538 ms** 返回，不重启 |
| 会话续期判断 | 保存服务器换回的 cookie，下次运行先试探，避免无脑重启 |
| 安全重启 | 只在「自己的 pid + 相同 StartTime」双重校验通过时重启自己的服务 |
| 绝不误杀 | 模拟"用户在终端自己起的服务" + 删掉 cookie → **拒绝终止**，弹框给出手动步骤，进程存活 ✅ |
| 卸载安全 | `-Uninstall` 只删指向**本启动器**的 `.lnk`；对外来同名快捷方式 → **拒绝并保留**（实测） |
| 图标 | 7 尺寸 `.ico`（16/24/32/48/64/128/256），PNG 不参与 `IconLocation` |
| 编码 | `.ps1` 纯 ASCII（中文按码点构造）；生成的 `.cmd` 无 BOM |
| 空 PATH | 启动器不依赖当前终端环境 |

### 开发过程中被实测打回来的 5 个设计

这些是第一版就写错、靠真机测试才发现的问题，记下来免得回退：

1. **裸地址开窗 → 401。**
   `dsh web` 需要进程级 token，直接 `http://127.0.0.1:3080/` 返回
   `dsh web authentication required`。第一版就是这么写的。

2. **重定向写进 `/c` 参数 → 服务根本不启动。**
   `"...cmd.exe" /c ""node.exe" "bin.js" ..." 1> out.txt` 会让 cmd 把整个引号块当成程序名，
   不报错、不启动。必须把命令写进 `.cmd` 文件。

3. **`.cmd` 带 BOM → cmd 把首行读成 `off`。**
   `Set-Content -Encoding ASCII` 在 PS 5.1 下会加 BOM。改用
   `[System.IO.File]::WriteAllLines(..., [Text.Encoding]::ASCII)`。

4. **`Split-Path $MyInvocation.MyCommand.Path` 在函数里返回 `$null`。**
   函数内的 `$MyInvocation` 指向函数调用，不是脚本。改用 `$PSScriptRoot`。

5. **`Remove-Item` 删不掉 token 文件。**
   服务持有独占写句柄，`Remove-Item` 和 `SetLength(0)` 都会失败。
   → 诚实写进文档：服务运行期间 token 可能残留（同用户可读、进程结束即失效、`-CleanRuntime` 可清）。

### 一个必须记住的操作事故

用自定义 `-ShortcutName` 做安装测试后，`-Uninstall` 当时按默认名字删除，
误删了桌面上一个**同名的外来快捷方式**。已按记录的属性逐项重建（大小 1734 B、
目标/参数/工作目录/图标/窗口样式全部一致，功能复测通过），并修掉了根因：
现在删除前会校验 `.lnk` 的 `Arguments` 是否指向本启动器，不是就拒绝并保留。

### 已知限制

- 启动器版本与 DSH 版本**独立**；上游改 CLI 接口需按 README 第 8 节更新（CI 会先报警）。
- token 文件在服务运行期间可能无法删除（见上）。
- 只支持 Windows（PowerShell 5.1+）。
