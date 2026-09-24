# 给 DSH 做一个双击就能打开的快捷方式

这份文件教你：**把下面那段提示词复制给 AI，让它给你生成一个 DSH 的桌面快捷方式**。
以后双击这个快捷方式就能打开 DSH，不用再去开命令行、敲命令。

> 整件事你只需要准备一样东西：**一张图片**（当图标用）。
> DSH 的启动参数、安装位置、认证方式，提示词里已经全部写好了。

---

## 一、你需要准备什么

| # | 准备什么 | 要求 | 没有怎么办 |
|---|---|---|---|
| 1 | **一张图片** | `.png` 或 `.jpg`，正方形最好（长方形会被压扁） | 随便找一张你喜欢的图，头像、表情包、壁纸都行 |
| 2 | **电脑上装好 DSH** | 平时能打开 DSH 就行 | 先按你平时的方式把 DSH 跑起来一次 |

其他什么都不用准备。端口、启动参数、DSH 装在哪，提示词里都写好了。

---

## 二、使用步骤

### 第 1 步：把图片放到一个好找的位置

放桌面最省事。假设图片叫 `logo.png`，那它的路径就是
`C:\Users\你的用户名\Desktop\logo.png`。

> 路径里尽量别有中文和空格，省得后面麻烦。

### 第 2 步：复制提示词

往下翻到 **[三、提示词正文](#三提示词正文)**，把标记出来的那一整块**全部复制**
（从「你是 Windows 桌面集成工程师」开始，到「复制到这里结束」上面那条线为止）。

### 第 3 步：发给 AI

打开 AI 对话窗口，**先粘贴提示词，再补一句**：

```
我的图标图片在这里：C:\Users\我的用户名\Desktop\logo.png
```

> 把路径换成你自己图片的真实路径。
> 不知道路径的话：右键图片 → 属性 → 位置，然后把「位置」和「文件名」拼起来。

### 第 4 步：收下 AI 给你的东西

AI 会给你三样东西：

1. 一个 `.ps1` 文件 —— 启动器
2. 一张 `.ico` 文件 —— 转换好的图标
3. 一个转换脚本

把前两个**放在同一个文件夹里**，比如新建一个 `DSH快捷方式` 文件夹丢进去。

### 第 5 步：先体检，再试跑

在这个文件夹里，按住 `Shift` + 右键空白处 → 选「在此处打开 PowerShell 窗口」，
然后输入（把文件名换成你的）：

```powershell
powershell -ExecutionPolicy Bypass -File .\启动器.ps1 -SelfTest
```

会打印一张表，告诉你 node 找到没有、DSH 找到没有。都正常的话再试跑：

```powershell
powershell -ExecutionPolicy Bypass -File .\启动器.ps1
```

能打开 DSH 的界面就成功了。

### 第 6 步：建桌面快捷方式

```powershell
powershell -ExecutionPolicy Bypass -File .\启动器.ps1 -MakeShortcut
```

桌面上会出现一个图标，以后**双击它就等于打开 DSH**。

### 出问题了怎么办

把 `-SelfTest` 打印出来的那张表**整段复制**，连同你的问题一起发回给 AI，让它改。

> 不要自己手动改代码，很容易改出新问题。

---

## 三、提示词正文

**👇 从下面这条线开始复制，到「复制到这里结束」为止 👇**

════════════════════════════════════════════════════════════════

你是 Windows 桌面集成工程师。请为我生成一个 DSH（DeepSeek Harness）的启动器：
双击快捷方式 → DSH 服务在完全不出现控制台窗口的情况下启动 →
用无地址栏的浏览器应用窗口打开 Web UI。

我给你的输入只有一样：**一张图标图片的路径**（我补在下面）。
其余信息全部由你在代码里动态探测，不要向我追问 DSH 装在哪里、版本多少。

════════════ 一、目标程序的确切信息 ════════════

DSH 是 Node.js 程序，通过 npx 安装。Web UI 的启动方式：

    node "<ENTRY>" --profile web --port <PORT> --no-open

**入口 ENTRY 必须动态探测，按以下优先级，命中即返回：**

    1) $env:npm_config_cache\_npx\*\node_modules\@deepseek-ai\dsh\lib\bin.js
    2) (npm config get cache)\_npx\*\node_modules\@deepseek-ai\dsh\lib\bin.js
    3) %LOCALAPPDATA%\npm-cache 和 %APPDATA%\npm-cache 下的同样结构
    4) (npm config get prefix)\node_modules\@deepseek-ai\dsh\lib\bin.js
    5) %USERPROFILE%\.dsh\bin.js

要点：
- `_npx` 下面那一级目录名是**内容哈希**（例如 c5eaa57ce271602a），会随 DSH 版本变化，
  **绝对不允许写死**，必须用 Get-ChildItem 遍历取第一个命中的。
- 用户的 npm cache / prefix 可能被 `.npmrc` 改到别的盘，所以第 1、2 级不能省。
- node.exe 依次在这些位置找：%ProgramFiles%\nodejs\node.exe、
  %ProgramFiles(x86)%\nodejs\node.exe、%LOCALAPPDATA%\Programs\nodejs\node.exe、
  %APPDATA%\nvm\node.exe，最后回退到 PATH 上的 node.exe。
- 找不到 node 或找不到 ENTRY 时，不要尝试安装任何东西，
  弹窗告诉用户缺少什么，并给出手动命令：npx @deepseek-ai/dsh@latest web

════════════ 二、DSH 的认证机制（这条做错就是白屏） ════════════

`dsh web` 启动后会向 stdout 打印一行带一次性 token 的访问链接，格式为：

    dsh web: http://127.0.0.1:<PORT>/?token=<base64url>

- 直接访问裸地址 `http://127.0.0.1:<PORT>/` 返回 **HTTP 401**，
  响应体是 "dsh web authentication required; reopen the URL printed by dsh web."
- 必须访问**那一行带 token 的链接**：服务器会下发签名 cookie（名称前缀 `dsh-auth-`）
  并 302 重定向到干净地址，之后浏览器会话持续有效。
- 该 token 是**进程级**的，只存在内存中，进程一换即失效。

因此你必须：
1. 把服务 stdout 重定向到一个临时文件，放在自己的运行目录里，不要放系统临时目录。
2. 轮询该文件，用正则提取链接：
   `https?://127\.0\.0\.1:\d+/\?token=[A-Za-z0-9_\-]+`
3. 用**提取到的这条链接**打开浏览器窗口，而不是裸地址。
4. 自己用 HTTP 访问一次该链接，把 Set-Cookie 里的 `dsh-auth-*` 值保存到运行目录；
   下次启动前用这个 cookie 试探端口，判断浏览器是否还有有效会话，
   避免每次都重启服务。
5. 诚实处理清理：服务运行期间 cmd.exe 的重定向句柄会**独占锁定**该文件，
   Remove-Item 与 FileStream.SetLength(0) 都会失败。不要假装删掉了，
   在注释和文档里写明：残留位置、仅本机当前用户可读、进程结束即失效、
   下次启动前会先尝试清空。

轮询超时仍拿不到链接时，区分两种情况弹窗：
服务根本没起来（附依赖清单和手动重试命令）／服务起来了但没打印链接（附捕获到的原始输出）。

════════════ 三、技术硬约束 ════════════

【窗口】
- 启动服务必须用 `(New-Object -ComObject WScript.Shell).Run($cmd, 0, $false)`。
  第二个参数 0 = SW_HIDE，**根本不创建控制台**；第三个参数 $false = 不等待。
- 禁止用 Start-Process 启动服务（会创建可见控制台）。
- 禁止只依赖 -WindowStyle Hidden：它只隐藏启动器自身，node 子进程仍会开窗口。
- 启动器自身由 `powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File` 拉起。

【命令行拼装】
- 需要重定向时，**不要**把重定向写进被引号包裹的 `/c` 参数里，
  那会让 cmd 把整个引号块当成程序名，结果是不报错、不启动。
  正确做法：把命令写进一个临时 .cmd 文件，再 Run 这个 .cmd。
- 生成的 .cmd **不要带 BOM**，用
  `[System.IO.File]::WriteAllLines($path, $lines, [System.Text.Encoding]::ASCII)`。
  因为 PowerShell 5.1 的 `Set-Content -Encoding ASCII` 会写入 BOM，
  带 BOM 时 cmd 会把首行读成 "off" 并报错。

【编码】
- 目标环境是 Windows 10/11 自带的 Windows PowerShell 5.1（没有 pwsh 7）。
- PowerShell 5.1 读取 .ps1 时，**没有 UTF-8 BOM 就按系统 ANSI 解析**，
  会导致中文乱码并报出无关的语法错误。
- 因此源码**全 ASCII**，中文用码点构造：
  `function CN([int[]]$c){ -join ($c | ForEach-Object { [char]$_ }) }`
- 不使用任何需要预装的模块（PowerShellGet / PSGallery / 第三方模块）。

【图标】
- `IconLocation` 只接受 `.ico`、`.exe`、`.dll`。给 `.png` **不会报错**，
  但快捷方式会显示成白纸通用图标 —— 必须避免。
- 我给你的图片是 png/jpg，请你转换：非方形先**居中裁成正方形**，
  再生成内嵌 16/24/32/48/64/128/256 多尺寸的 .ico。
- 请把转换脚本一并给我（PowerShell + System.Drawing 实现即可），并给出验证代码：

      Add-Type -AssemblyName System.Drawing
      foreach ($s in 16,32,48,128,256) {
        $i = New-Object System.Drawing.Icon($ico, (New-Object System.Drawing.Size($s,$s)))
        "ico $s -> $($i.Width)x$($i.Height)"; $i.Dispose()
      }

  注意 System.Drawing.Icon 加载 256 时可能回退到 128，这不代表 .ico 里没有 256；
  确认真实尺寸要解析 ICO 目录（第 i 个项目偏移 6+i*16，宽高各 1 字节，0 表示 256）。

【路径】
- 定位脚本自身用 `$PSScriptRoot`。
  **不要**用 `Split-Path $MyInvocation.MyCommand.Path` —— 在函数内部
  $MyInvocation 指向函数调用，会静默返回 $null。
- 所有路径用 Join-Path 拼接，含空格的路径在拼命令行时加引号。

【运行时行为】
- 启动前先用 TcpClient + BeginConnect + 700ms 超时探测端口，已在监听则不重复启动。
- 端口被占用要区分两种情况：DSH 已经在跑（直接开窗）／被别的程序占用（提示换端口）。
- 服务启动等待上限 45 秒，超时后弹窗给出诊断信息：
  依赖路径、端口、已等待秒数、手动重试命令。

════════════ 四、浏览器窗口 ════════════
- 优先 Microsoft Edge：%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe，
  其次 %ProgramFiles%\Microsoft\Edge\Application\msedge.exe，
  再其次 Chrome 的常见位置；都找不到则回退 `Start-Process <url>` 用默认浏览器。
- 用 `--app=<url>` 打开，得到无地址栏、无标签栏的应用窗口。
  不要用 `--new-window`，那仍然有地址栏。

════════════ 五、安全边界（不可协商） ════════════
- **不安装、不升级、不降级、不修改、不删除 DSH。**
  缺什么就报什么，给出手动命令，把选择权留给用户。
- **不修改用户的任何数据**：`%USERPROFILE%\.dsh` 下的 sessions、profiles、
  credentials、storages 一律不碰。`.credentials.yaml` 绝对不要读取内容。
- **不终止不是自己启动的进程。**
  需要重启服务时，必须用「pid + 进程 StartTime」双重校验确认是自己拉起的子进程；
  对不上就放弃，改为弹窗提示用户手动关闭那个 DSH 窗口。
- 只允许写两个位置：自己的运行目录 `%LOCALAPPDATA%\dsh-launcher\`
  和桌面快捷方式（仅在建快捷方式时）。
- 删除快捷方式前必须校验该 .lnk 的 Arguments 是否指向本启动器，否则拒绝删除。
- 在脚本头部注释里写明：本脚本会写哪些文件、写在哪里、怎么清理。

════════════ 六、交付物 ════════════
1. 单个 .ps1 启动器，支持以下参数（也可用同名环境变量覆盖）：
   -Port（默认 3080）、-BrowserPath、-NoAppWindow、-NoBrowser、
   -WaitSeconds（默认 45）、-SelfTest、-MakeShortcut、-CleanRuntime、-Uninstall。
   -SelfTest 只做体检、不启动任何东西，输出一张表格：运行目录、端口、node 路径、
   DSH 入口路径、DSH 版本、浏览器路径、图标路径、服务是否在监听、是否由本启动器启动、
   会话 cookie 是否存在、PowerShell 版本、系统版本、桌面路径。
   -MakeShortcut 在桌面生成一个 .lnk；若已存在同名且指向本启动器的，则覆盖。
   -Uninstall 只删除桌面快捷方式和自己运行目录里的文件。
2. 图标转换脚本。
3. 故障排查表：症状 → 真因 → 处理办法。至少覆盖：什么都没发生、闪黑框、
   出现两个窗口、图标变白纸、中文乱码或语法错、找不到 DSH 入口、401 或白屏、
   端口冲突、升级 DSH 后失效。

════════════ 七、交付前自检（请在回答里逐条声明结论） ════════════
- [ ] 启动 DSH 时确实不会出现控制台窗口（用的是 SW_HIDE，而不是 -WindowStyle Hidden 顶替）
- [ ] 没有写死任何哈希目录、DSH 版本号或绝对路径
- [ ] 捕获了 dsh web 打印的 token 链接，并用它打开窗口（不是裸地址）
- [ ] 生成的 .cmd 不带 BOM
- [ ] 源码全 ASCII，或说明保存为 UTF-8 with BOM
- [ ] 图标是内嵌多尺寸的 .ico，PNG 没有参与 IconLocation
- [ ] 定位自身用的是 $PSScriptRoot
- [ ] 端口已监听时不重复启动，并区分「DSH 在跑」和「端口被占用」
- [ ] 失败时有含诊断信息的弹窗，不是静默退出
- [ ] -SelfTest 能在空 PATH 下运行：$env:PATH='C:\Windows\System32;C:\Windows'
- [ ] 只写自己的运行目录和桌面快捷方式
- [ ] 不安装/升级/删除 DSH，不杀非自己启动的进程
- [ ] 删除快捷方式前校验了它是否指向本启动器

如果某条约束在这台机器上确实无法满足，直接说明原因和替代方案。
不要静默降级 —— 我最怕的是你以为做不到就悄悄放松了要求，却告诉我「已完成」。

════════════════════════════════════════════════════════════════

**👆 复制到这里结束 👆**

---

## 四、几点说明

- 提示词是写给 AI 看的，里面的技术细节（SW_HIDE、ANSI 编码、token 机制）**你不需要理解**。
- DSH 的安装位置由启动器自己探测，所以你不用告诉 AI 你的 DSH 装在哪、什么版本。
- 以后 DSH 升级如果启动器失效了，把 `-SelfTest` 的输出发回给 AI，让它更新就行。
