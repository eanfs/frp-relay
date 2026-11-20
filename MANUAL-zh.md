# frp 中转 SSH 使用手册

- 工具包版本：v1.0.0
- frp 版本：v0.72.0（frps / frpc 一致）
- 更新日期：2026-11-09
- 适用环境：双网卡 Windows 10/11 + 内网服务器 + 公网 frps `frps.example.com`

---

## 1. 这套工具做什么

把一台**不能访问外网的内网服务器**的 SSH，通过一台**双网卡 Windows 电脑**中转，暴露到公网 frps，使环境 B（另一个网络）可以直接登录内网服务器。

```text
环境B Windows ──ssh frps.example.com:<随机端口>──> frps v0.72.0
                                              │ frp 隧道
                                              ▼
双网卡 Windows (frpc v0.72.0) ──ssh 内网IP:22──> 内网服务器
```

特点：

- 公网 TCP 端口**每次启动随机选择**（50000–59999，避开上一次端口，被占用会自动重试）；
- 启动窗口会打印本次实际端口和完整 `ssh` 命令；
- 同时提供 STCP 备用方式，STCP 在环境 B 本地固定使用 `60022`；
- 双网卡 Windows 使用**手动启动**，关闭窗口即停止；
- Windows 10/11 自带 PowerShell 和 OpenSSH，不需要 Git Bash 或 WSL。

---

## 2. 准备工作

在双网卡 Windows 上确认：

1. 能访问内网服务器的 SSH 端口（通常是 `22`）；
2. 能访问公网 `frps.example.com:7000`；
3. 知道内网服务器的 IP、SSH 端口、SSH 用户；
4. 拿到 frps 的 `auth.token`（在服务器 `/home/project/frps/data/frps.toml` 中，**不要外传**）。

在环境 B 上确认有 `ssh` 客户端。如果没有，在 Windows“设置 → 应用 → 可选功能”中安装 **OpenSSH 客户端**。

---

## 3. 第一次部署（5 步）

### 第 1 步：解压

把 release 包解压到 Windows 的简单路径，例如：

```text
C:\frp-relay
```

确认目录中有 `frpc.exe`、`setup-relay.cmd`、`start-relay.cmd`、`status.cmd`。

### 第 2 步：生成配置

双击 `setup-relay.cmd`，按提示输入：

1. frps `auth.token`；
2. 内网服务器 IP；
3. 内网 SSH 端口（直接回车默认 `22`）；
4. 内网 SSH 用户（直接回车默认 `root`）。

脚本会检查网络，生成：

```text
frpc.toml            中转端配置（含 token，勿外传）
frpc.runtime.toml    每次启动时的运行配置（自动生成）
relay-meta.json      内网 IP/SSH 用户等展示信息（勿外传）
connection-info.txt  最近一次启动的连接信息
visitor\             环境 B 的 STCP 客户端目录
```

### 第 3 步：启动中转

双击 `start-relay.cmd`，等待窗口打印，例如：

```text
第 1 次尝试，随机端口: 56889

frp 中转启动信息
====================
frps 控制地址 : frps.example.com
公网 SSH      : frps.example.com:56889
TCP 连接命令  : ssh -p 56889 root@frps.example.com
转发目标      : root@192.168.1.10:22
STCP 备用     : 在环境B运行 visitor\start-visitor.cmd 后执行
                ssh -p 60022 root@127.0.0.1
====================
frpc 正在运行，按 Ctrl+C 停止。
```

**本次端口以窗口打印为准**。窗口保持运行，按 `Ctrl+C` 停止。

### 第 4 步：在环境 B 登录

把上一步的端口替换到命令中：

```bat
ssh -p <本次随机端口> <内网SSH用户>@frps.example.com
```

例如：

```bat
ssh -p 56889 root@frps.example.com
```

首次连接会提示确认内网服务器的 host key，输入 `yes`。

### 第 5 步：停止

在中转端窗口按 `Ctrl+C`，frpc 退出，公网端口释放。

---

## 4. 每次使用

1. 双击 `start-relay.cmd`；
2. 看窗口打印的**本次随机端口**；
3. 环境 B 使用该端口登录；
4. 停止时按 `Ctrl+C`。

注意：

- **每次启动端口都会变**，不要沿用上一次的命令；
- 随时双击 `status.cmd` 可查看当前端口和在线状态；
- 不要同时打开多个 `start-relay.cmd`，否则本地管理端口 `7400` 会冲突；
- 双网卡电脑休眠/睡眠会导致隧道断开，请关闭睡眠。

---

## 5. 环境 B 的两种连接方式

### 5.1 TCP 直连（无需安装 frp）

使用启动窗口打印的端口：

```bat
ssh -p <本次随机端口> <内网SSH用户>@frps.example.com
```

### 5.2 STCP（推荐，公网不开放端口）

1. 把中转端的 `visitor` 目录整体复制到环境 B（其中应包含 `frpc.exe`、`visitor.toml`、`connection-info.txt`）；
2. 在环境 B 双击 `visitor\start-visitor.cmd`，保持窗口运行；
3. 再执行：

```bat
ssh -p 60022 <内网SSH用户>@127.0.0.1
```

STCP 的 `60022` 是环境 B 的**本地固定端口**，不受公网随机端口影响。`visitor.toml` 含 frps token 和 STCP secret，属于敏感文件，不要外传。

---

## 6. SSH 配置示例

由于 TCP 公网端口每次变化，建议使用 `HostKeyAlias`，这样只需要更新 `Port`，不会反复提示 host key。

环境 B 的 `%USERPROFILE%\.ssh\config`：

```sshconfig
Host intranet-relay
    HostName frps.example.com
    Port <本次启动窗口显示的端口>
    User <内网SSH用户>
    HostKeyAlias intranet-relay
    ServerAliveInterval 30
    ServerAliveCountMax 3
```

每次重启中转端后，把 `Port` 改成新端口，然后：

```bat
ssh intranet-relay
```

如果希望固定本地端口，使用 STCP：

```sshconfig
Host intranet-relay-stcp
    HostName 127.0.0.1
    Port 60022
    User <内网SSH用户>
    HostKeyAlias intranet-relay
    ServerAliveInterval 30
    ServerAliveCountMax 3
```

先启动环境 B 的 `visitor\start-visitor.cmd`，再 `ssh intranet-relay-stcp`。

若 host key 冲突：

```bat
ssh-keygen -R "intranet-relay"
```

---

## 7. 状态检查

在中转端双击 `status.cmd`，或运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\status.ps1
```

会显示：

```text
frpc 代理状态
====================
[stcp] ssh-gw-stcp  status=running
  local : 192.168.1.10:22
[tcp] ssh-gw  status=running
  local : 192.168.1.10:22
  remote: frps.example.com:56889

当前公网 SSH: frps.example.com:56889
连接命令: ssh -p 56889 root@frps.example.com
```

---

## 8. 常见问题

| 现象 | 处理 |
| --- | --- |
| `authorization failed` | frps token 错误；重新运行 `setup-relay.cmd` |
| 窗口一直不打印端口 | 查看 frpc 日志：frps:7000 是否可达、token 是否正确、内网服务是否可达 |
| 随机端口被占用并重试 | 正常现象，脚本会自动换端口；连续 5 次失败请检查 frps 端口范围 |
| `connect to local service error` | 内网 IP/端口错误、sshd 未启动或内网防火墙拦截 |
| 环境 B `Connection refused` | 确认使用的是**本次**窗口打印的端口，且中转端窗口仍在运行 |
| 环境 B 提示 host key 变化 | 建议配置 `HostKeyAlias`；必要时 `ssh-keygen -R "intranet-relay"` |
| 下载 frpc.exe 失败 | Windows 访问 GitHub 受限；直接使用包内预置的 `frpc.exe` |
| PowerShell 执行策略报错 | 通过 `.cmd` 入口运行，已带 `-ExecutionPolicy Bypass` |
| 同时启动多个中转端 | 会争用本地 `7400` 端口；先关闭旧窗口 |
| 隧道突然断开 | 双网卡电脑休眠/睡眠或网络切换；关闭睡眠并重启 `start-relay.cmd` |

---

## 9. 安全注意事项

- **优先使用 STCP**；TCP 方式虽然每次随机端口，但仍然对公网开放，可能被 SSH 暴力尝试。
- 内网服务器建议只允许 SSH 密钥登录，关闭密码登录。
- frps token 目前较弱且被多个客户端共享；本次未改 token，避免断掉其他客户端。后续维护窗口可轮换并同步所有客户端。
- `frpc.toml`、`frpc.runtime.toml`、`visitor\visitor.toml`、`connection-info.txt`、`relay-meta.json`、`relay-state.json` 均为敏感或本机状态文件，不要提交、外传或截图泄露。
- 双网卡 Windows 只发起出站连接，不需要开放入站防火墙端口；如杀毒软件弹窗，请允许 `frpc.exe`。
- 手动模式下保持电脑开机并关闭睡眠；如需开机自启，可自行添加计划任务：

```bat
schtasks /create /tn "frp-relay" /tr "C:\frp-relay\start-relay.cmd" /sc onlogon /rl highest
```

---

## 10. 维护与升级

- 线上 frps 已升级到 **v0.72.0**；容器 `1Panel-frps-Pjum`，配置未改（token、面板、7000/7500/80/443）。
- 升级备份：`/home/project/frps/backup/20261109-135111`
- 旧镜像 `:0.57.0` 和新镜像 `:0.72.0` 都保留在服务器本地，不要删除。
- 回滚命令（在服务器执行）：

```bash
bash /home/project/frps/upgrade/rollback-frps.sh /home/project/frps/backup/20261109-135111
```

`upgrade-frps/` 和 `tools/` 目录是管理员维护工具，普通使用不需要运行。

---

## 11. 验证记录

- 本地 frps v0.72.0 + frpc v0.57.0 / v0.72.0：TCP、HTTP、STCP 全部通过；
- 本地连续两次启动随机端口：`58992`、`59947`，隧道回显正常；
- 线上随机端口：`56889`，公网回显正常，停止后端口释放；
- 线上现有 8 个客户端、11 TCP / 2 HTTP / 27 HTTPS 代理未受影响。

---

## 附录 A：文件说明

| 文件/目录 | 用途 |
| --- | --- |
| `setup-relay.cmd` / `.ps1` | 第一次使用时生成配置 |
| `start-relay.cmd` / `.ps1` | 每次启动，随机选端口并打印 SSH 命令 |
| `status.cmd` / `.ps1` | 查看当前代理状态和端口 |
| `download-frpc.ps1` | 重新下载并校验 frpc.exe（备用） |
| `frpc.exe` | frp v0.72.0 Windows 客户端 |
| `templates/` | frpc / visitor 配置模板 |
| `visitor/` | 环境 B 的 STCP 客户端目录 |
| `upgrade-frps/` | 服务器升级/回滚脚本（管理员） |
| `tools/` | 本地兼容性和线上验证脚本（管理员） |
| `frpc.toml` 等 | 运行时生成，含敏感信息，勿外传 |

## 附录 B：端口说明

| 端口 | 位置 | 说明 |
| --- | --- | --- |
| `7000` | frps | frp 控制端口 |
| `7500` | frps | 面板 |
| `80` / `443` | frps | HTTP/HTTPS 代理 |
| `50000–59999` | frps | 每次启动随机选择的 SSH 公网端口 |
| `60022` | 环境 B | STCP 本地固定端口 |
| `7400` | 双网卡 Windows | frpc 管理 API，仅本地访问 |
