# frp 中转 SSH 工具包

> 说明：文档中的 `frps.example.com` 是占位符，请替换成你自己的 frps 公网地址；`192.168.1.10` 是内网服务器示例地址。

把一台**不能访问外网的内网服务器**的 SSH，通过一台**双网卡 Windows 电脑**中转，暴露到公网 frps，使环境 B（另一个网络）可以直接登录内网服务器。

## 拓扑

```text
环境B Windows ──ssh frps.example.com:<随机端口>──> frps v0.72.0
                                              │ frp 隧道
                                              ▼
双网卡 Windows (frpc v0.72.0) ──ssh 内网IP:22──> 内网服务器
```

- 公网 TCP 端口**每次启动随机选择一个未使用端口**（frps 校验可用，冲突自动重试），启动窗口会打印实际端口。
- 公网 TCP 路径：环境 B 不需要安装 frp，直接 `ssh -p <启动时显示的端口>`。
- STCP 路径：环境 B 运行 frpc visitor，本地监听 `127.0.0.1:60022`（固定本地端口），frps 不开放公网端口。
- 双网卡 Windows 使用**手动启动**：双击 `start-relay.cmd`，关闭窗口即停止。
- Windows 10/11 自带 PowerShell 5.1 和 OpenSSH 客户端，**不需要安装 Git Bash 或 WSL**。如果环境 B 没有 `ssh`，在“设置 → 应用 → 可选功能”中安装 OpenSSH 客户端。

## 目录

```text
deploy/relay/
├── MANUAL-zh.md              # 面向使用者的完整手册
├── QUICKSTART.txt            # 5 步快速上手
├── frpc.exe                  # 预置的 v0.72.0 Windows 客户端（gitignore）
├── templates/                # frpc / visitor 配置模板
├── setup-relay.ps1           # 交互生成配置
├── setup-relay.cmd           # 双击入口
├── start-relay.cmd           # 双击启动入口
├── start-relay.ps1           # 随机选端口、启动 frpc、打印 SSH 命令
├── status.ps1 / status.cmd   # 查询代理状态和当前随机端口
├── download-frpc.ps1         # 重新下载/校验 frpc.exe（备用）
├── visitor/                  # 环境 B 的 STCP visitor 目录
├── upgrade-frps/             # 服务器升级与回滚脚本
└── tools/                    # 兼容性与线上旁路验证脚本
```

## 一、双网卡 Windows 部署

1. 把整个 `deploy/relay` 目录复制到 Windows，例如 `C:\frp-relay`。
   确认目录中有 `frpc.exe`。如果没有，在该目录运行：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\download-frpc.ps1
   ```

2. 双击 `setup-relay.cmd`，按提示输入：
   - frps `auth.token`（见 frps 配置，不显示、不落盘到仓库）；
   - 内网服务器 IP；
   - 内网 SSH 端口（默认 22）；
   - 内网 SSH 用户（默认 root）。

   STCP 本地端口默认 60022，一般不需要改（可传 `-StcpBindPort`）。

   脚本会：
   - 检查 Windows → frps:7000、Windows → 内网 SSH 端口；
   - 生成 `frpc.toml`、`visitor\visitor.toml`、`connection-info.txt`、`relay-meta.json`；
   - 生成随机 STCP secret 和 frpc 管理 API 密码；
   - 把 `frpc.exe` 复制到 `visitor\`，方便整体拷贝到环境 B。

3. 双击 `start-relay.cmd`。frpc 启动后，窗口会打印本次随机选择的实际端口：

   ```text
   公网 SSH      : frps.example.com:54321   ← 每次启动都会变化
   TCP 连接命令  : ssh -p 54321 <用户>@frps.example.com
   转发目标      : <用户>@<内网IP>:22
   STCP 备用     : 在环境B运行 visitor\start-visitor.cmd 后
                   ssh -p 60022 <用户>@127.0.0.1
   ```

   保持这个窗口运行；按 `Ctrl+C` 停止。

4. 在环境 B 执行（端口用第 3 步窗口打印的值）：

   ```bat
   ssh -p <启动窗口显示的端口> <用户>@frps.example.com
   ```

   首次连接会提示确认内网服务器的 host key。之后运行 `status.cmd` 可随时查看当前端口。

## 二、STCP 方式（推荐，公网不开放端口）

1. 把中转端生成的 `visitor` 目录整体复制到环境 B（其中包含 `frpc.exe`、`visitor.toml`、`connection-info.txt`）。
2. 在环境 B 双击 `visitor\start-visitor.cmd`，保持窗口运行。
3. 再执行：

   ```bat
   ssh -p 60022 <用户>@127.0.0.1
   ```

STCP 需要 frps token 和 STCP secret，`visitor.toml` 属于敏感文件，不要外传。

## 三、SSH 配置示例

由于 TCP 公网端口每次启动都不同，**建议使用 `HostKeyAlias`**，这样只需要更新 `Port`，不会因为端口变化反复提示 host key：

```sshconfig
Host intranet-relay
    HostName frps.example.com
    Port <本次启动窗口显示的端口>
    User <用户>
    HostKeyAlias intranet-relay
    ServerAliveInterval 30
    ServerAliveCountMax 3
```

每次重启中转端后，把 `Port` 改成新端口，然后 `ssh intranet-relay`。

如果希望固定本地端口、不关心公网端口变化，使用 STCP：

```sshconfig
Host intranet-relay-stcp
    HostName 127.0.0.1
    Port 60022
    User <用户>
    HostKeyAlias intranet-relay
    ServerAliveInterval 30
    ServerAliveCountMax 3
```

之后先启动环境 B 的 `visitor\start-visitor.cmd`，再 `ssh intranet-relay-stcp`。

`HostKeyAlias` 让 known_hosts 只记录一个稳定别名，避免随机端口产生多条 host key。若已出现冲突：

```bat
ssh-keygen -R "intranet-relay"
```

## 四、状态检查

在双网卡 Windows 上双击 `status.cmd`，或运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\status.ps1
```

它会查询 frpc 管理 API（`127.0.0.1:7400`），显示每个代理的 `status`、`local_addr`、`remote_addr` 和错误信息，并重新打印连接命令。

## 五、故障排查

| 现象 | 处理 |
| --- | --- |
| frpc 日志 `authorization failed` | token 错误；重新运行 `setup-relay.cmd` 输入正确 token |
| 启动窗口一直不打印公网端口 | 查看 frpc 日志：token 错误、frps:7000 不通、内网服务不可达；也可运行 `status.cmd` |
| frpc 日志 `connect to local service error` | 内网 IP/端口错误、sshd 未启动或内网防火墙拦截 |
| 环境 B `Connection refused` | 确认使用的是**本次**启动窗口打印的端口，不是上次的；确认中转端仍在运行 |
| 环境 B 提示 host key 变化 | 建议使用 `HostKeyAlias`；必要时 `ssh-keygen -R "intranet-relay"` |
| 下载 frpc.exe 失败 | Windows 访问 GitHub 受限；直接用仓库里预置的 `frpc.exe` |
| PowerShell 提示执行策略 | 通过 `.cmd` 入口运行，已带 `-ExecutionPolicy Bypass` |
| 隧道突然断开 | 双网卡电脑休眠/睡眠或网络切换；关闭睡眠并重启 `start-relay.cmd` |

## 六、安全建议

- **优先使用 STCP**；TCP 方式每次启动随机端口，虽然降低了扫描概率，但仍然对公网开放，可能被 SSH 暴力尝试。
- 内网服务器建议只允许 SSH 密钥登录，关闭密码登录。
- frps token 目前较弱且被现有多个客户端共享；本次升级未改 token，避免断掉其他客户端。后续维护窗口可轮换 token 并同步所有客户端。
- `frpc.toml`、`visitor\visitor.toml`、`connection-info.txt`、`relay-meta.json` 已被 `.gitignore`，不要提交或外传；其中 `relay-meta.json` 含内网 IP 和 SSH 用户。
- 双网卡 Windows 只发起出站连接，不需要开放入站防火墙端口；如杀毒软件弹窗，请允许 `frpc.exe`。
- 手动模式下请保持电脑开机并关闭睡眠；如需开机自启，可自行添加计划任务：

  ```bat
  schtasks /create /tn "frp-relay" /tr "C:\frp-relay\frpc.exe -c C:\frp-relay\frpc.toml" /sc onlogon /rl highest
  ```

## 七、服务器升级记录（v0.57.0 → v0.72.0）

本次已将线上 frps 原地升级到 **v0.72.0**：

- 部署目录：`/home/project/frps`
- 容器：`1Panel-frps-Pjum`（`network_mode=host`）
- 旧镜像：`swr.cn-east-3.myhuaweicloud.com/intetech/frps:0.57.0`（保留）
- 新镜像：`swr.cn-east-3.myhuaweicloud.com/intetech/frps:0.72.0`
- 注意：新旧镜像都只存在于服务器本地，未推送到 SWR；不要删除新镜像，否则容器重建时需要重新构建。
- 备份：`/home/project/frps/backup/20261109-135111`
- 配置未改：token、面板账号、7000/7500/80/443 保持不变。

升级前用 frps v0.72.0 + frpc v0.57.0 在本地验证了 TCP、HTTP、STCP；升级后用 frpc v0.57.0（60021）和 v0.72.0（60022）做了线上旁路验证，并用 v0.72.0 客户端随机端口（56889）验证了公网访问。现有 8 个客户端、11 个 TCP、2 个 HTTP、27 个 HTTPS 代理均恢复 online。

> 验证时临时注册的 `livev57.live-v57`、`livev72.live-v72`、`relaytest.randomgw` 可能以 offline 形式短暂保留在面板，不占用端口和名称，可忽略。

### 再次升级

把新的 Linux `frps` 二进制放到 `/home/project/frps/upgrade/`，按需修改 `upgrade-frps.sh` 里的 `OLD_IMAGE` / `NEW_IMAGE` / `NEW_BIN`，然后：

```bash
bash /home/project/frps/upgrade/upgrade-frps.sh
```

脚本会备份、离线构建新镜像、切换 compose、健康检查；frps 自身不健康时自动回滚。

### 回滚

```bash
bash /home/project/frps/upgrade/rollback-frps.sh /home/project/frps/backup/20261109-135111
```

回滚使用本地保留的 0.57.0 镜像，不依赖外网。

## 八、已验证 / 待验证

已在本机验证：

- frps v0.72.0 + frpc v0.57.0：TCP、HTTP、STCP 全部通过；
- frps v0.72.0 + frpc v0.72.0：TCP、HTTP、STCP 全部通过；
- 线上 frpc v0.57.0 → 60021、frpc v0.72.0 → 60022 回显通过，测试端口已释放；
- 随机端口：本地连续两次启动分别使用 58992 / 59947，线上使用 56889，隧道回显均通过，停止后端口释放。

必须在目标环境验证：

- 双网卡 Windows 是否能访问内网服务器的 SSH 端口；
- `setup-relay.cmd` 在 Windows PowerShell 5.1 下的交互；
- Windows 防火墙/杀毒软件是否放行 `frpc.exe`；
- 环境 B 实际 `ssh -p <启动窗口显示的随机端口>` 登录内网服务器；
- STCP visitor 在环境 B 的实际连接。
