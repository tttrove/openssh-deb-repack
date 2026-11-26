# OpenSSH 上游包同步

跟踪 [boypt/openssh-deb](https://github.com/boypt/openssh-deb) 的 release，把上游的 `.tar.gz` 包重新打包成带本仓库 `universal-install.sh` 的 `.tgz`，发布到本仓库的 GitHub Release。amd64/arm64、Ubuntu/Debian 都处理。

## 目录结构

```
.
├── .github/workflows/sync-upstream.yml   # GitHub Actions 工作流
├── scripts/sync-upstream.sh              # 实际执行同步的脚本
├── universal-install.sh                  # 通用安装脚本（单一维护点）
├── .gitattributes                        # 强制 LF 行尾
├── .gitignore                            # 忽略构建产物
└── README.md
```

## 工作流

- 每天 UTC 02:00（北京时间 10:00）检查上游 latest release。
- 也可在 Actions 里手动运行 `Sync upstream OpenSSH packages`。

手动参数：

| 参数 | 说明 | 默认 |
|---|---|---|
| `upstream_tag` | 上游 release tag，留空表示 latest | 空 |
| `asset_pattern` | 要处理的 asset 通配符 | `openssh-v*-*.tar.gz` |
| `force` | 本仓库已有同 tag release 时也重新构建并覆盖 | `false` |

## 输出资产

每个上游 `.tar.gz` 生成一个同名 `.tgz`：

```
<upstream-asset-name>.tgz
```

例如 `openssh-v<version>-<codename>-<arch>.tar.gz` 对应 `openssh-v<version>-<codename>-<arch>.tgz`。具体版本、codename 和架构以最新 Release 为准：

https://github.com/tttrove/openssh-deb-repack/releases/latest

Release 附带 `SHA256SUMS`。每个 tgz 包含上游的全部 deb 和本仓库最新的 `universal-install.sh`（重命名为 `install.sh`）。

Ubuntu `bionic` / `focal` / `jammy` / `noble` 解压后执行 `bash install.sh`。Debian 包只做打包存档，脚本会因 OS 检查退出。

## 脚本修改的 SSH 配置

安装完成后，脚本恢复升级前的 `sshd_config`，再做几项校正：

| 配置 | 作用 |
|---|---|
| `PermitRootLogin yes` | 避免新版本默认 `prohibit-password` 导致 root 无法登录，保证远程运维通道 |
| `UsePAM yes` | 保持 PAM 账户与会话管理 |
| `HostKeyAlgorithms +ssh-rsa` | 在默认算法上附加 `ssh-rsa`，兼容旧客户端；`+` 表示附加，不替换默认算法 |

同时删除旧的 `KexAlgorithms`、`GSSAPIKexAlgorithms`、`HostKeyAlgorithms` 行，避免旧算法清单覆盖新版默认值。

这些是运维兜底策略，不是密码、密钥或账号凭据；脚本里没有主机地址、用户名或密码。建议先在测试机验证。

> 本项目不是 boypt/openssh-deb 的官方项目，只是基于其 release 重新打包。

## 首次使用

1. 创建 GitHub 仓库，推上去：

   ```bash
   git init
   git add .
   git commit -m "Add OpenSSH upstream sync workflow"
   git branch -M main
   git remote add origin git@github.com:<owner>/<repo>.git
   git push -u origin main
   ```

2. 在 Settings → Actions → General → Workflow permissions 选择 Read and write permissions，否则 `GITHUB_TOKEN` 无法创建 Release。

3. 在 Actions 里手动运行一次，或等定时任务。

工作流使用自带的 `GITHUB_TOKEN`，不需要额外 secret。

## 本地测试

需要已登录 `gh`。先只构建、不发布：

```bash
gh auth status

DRY_RUN=true \
TARGET_REPO=<owner>/<repo> \
UPSTREAM_REPO=boypt/openssh-deb \
bash scripts/sync-upstream.sh
```

确认 `dist/` 里的文件没问题后，去掉 `DRY_RUN=true` 再运行一次，才会发布 Release。也可以用 `ASSET_PATTERN` 只处理部分资产，例如 `ASSET_PATTERN='openssh-v*-jammy-amd64.tar.gz'`。

脚本流程：

1. 读取上游最新 tag（或 `UPSTREAM_TAG` 指定的 tag）。
2. 本仓库已有同 tag 的 Release 时跳过。
3. 下载匹配 `ASSET_PATTERN` 的 `.tar.gz`，默认全部。
4. 解压，只留 deb，注入 `universal-install.sh`。
5. 重打成同名 `.tgz`。
6. 生成 `SHA256SUMS` 和 release notes；`DRY_RUN=true` 时停止，否则发布 Release。

## 维护

- 安装逻辑只改 `universal-install.sh`，下次构建自动注入。
- `universal-install.sh` 目前只识别 Ubuntu `bionic` / `focal` / `jammy` / `noble`。Debian 包会注入脚本，但执行时因 OS 检查退出。
- 只处理部分资产时，手动触发并改 `asset_pattern`，例如 `openssh-v*-jammy-amd64.tar.gz`。
- Release tag 与上游一致，已存在时跳过；要重建时勾选 `force`。
