# OpenSSH 上游包同步

自动跟踪 [boypt/openssh-deb](https://github.com/boypt/openssh-deb) 的 release，把上游 release 里的所有 `.tar.gz` 包（amd64/arm64、Ubuntu/Debian）重新打包成带本仓库 `universal-install.sh` 的 `.tgz`，并发布到本仓库的 GitHub Release。

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

## 工作流触发方式

- **定时**：每天 UTC 02:00（北京时间 10:00）检查上游 `releases/latest`。
- **手动**：Actions → `Sync upstream OpenSSH packages` → Run workflow。

手动触发参数：

| 参数 | 说明 | 默认 |
|---|---|---|
| `upstream_tag` | 上游 release tag，留空表示 latest | 空 |
| `asset_pattern` | 要处理的 asset 通配符 | `openssh-v*-*.tar.gz` |
| `force` | 本仓库已存在同 tag release 时也重新构建并覆盖 | `false` |

## 输出资产

每个上游 `.tar.gz` 资产都会生成一个同名 `.tgz`，命名规则固定为：

```
<upstream-asset-name>.tgz
```

例如上游的 `openssh-v<version>-<codename>-<arch>.tar.gz` 会生成
`openssh-v<version>-<codename>-<arch>.tgz`。版本号、codename、架构都以当前
Release 的实际资产为准，README 不固定具体版本。

支持的 codename、架构和版本以最新 Release 的实际资产为准：

https://github.com/tttrove/openssh-deb-repack/releases/latest

Release 还会附带 `SHA256SUMS`。每个 tgz 内包含：

- 上游包内的全部 deb
- 本仓库最新的 `universal-install.sh`（重命名为 `install.sh`）

Ubuntu `bionic` / `focal` / `jammy` / `noble` 目标机解压后执行 `bash install.sh` 即可。Debian 包目前只做打包存档，安装脚本会因 OS 检查退出。

## 脚本会修改的 SSH 配置

`universal-install.sh` 在安装完成后会恢复升级前的 `sshd_config`，然后做以下策略校正：

| 配置 | 作用 |
|---|---|
| `PermitRootLogin yes` | 避免新版本默认 `prohibit-password` 导致 root 无法登录，保证生产环境远程运维通道 |
| `UsePAM yes` | 保持 PAM 账户与会话管理 |
| `HostKeyAlgorithms +ssh-rsa` | 在默认算法基础上附加 `ssh-rsa`，兼容旧客户端；`+` 表示附加，不替换默认算法 |

同时会删除旧的 `KexAlgorithms`、`GSSAPIKexAlgorithms`、`HostKeyAlgorithms` 行，避免旧算法清单覆盖新版默认算法集。

这些是生产环境的运维兜底策略，不是密码、密钥或账号凭据。脚本不包含任何主机地址、用户名或密码。使用前建议先在测试机验证，确认符合你的 SSH 安全策略。

> 本项目不是 boypt/openssh-deb 的官方项目，只是基于其 release 重新打包并注入安装脚本。

## 首次使用

1. 在 GitHub 创建仓库，把本目录推上去：

   ```bash
   git init
   git add .
   git commit -m "Add OpenSSH upstream sync workflow"
   git branch -M main
   git remote add origin git@github.com:<owner>/<repo>.git
   git push -u origin main
   ```

2. 仓库 **Settings → Actions → General → Workflow permissions** 选择 **Read and write permissions**，否则 `GITHUB_TOKEN` 无法创建 Release。

3. 在 Actions 页面手动运行一次，或等定时任务触发。

工作流使用仓库自带的 `GITHUB_TOKEN`，不需要额外配置 secret。

## 本地测试

需要本机已安装并登录 `gh`。先用 `DRY_RUN=true` 只构建不发布：

```bash
gh auth status

DRY_RUN=true \
TARGET_REPO=<owner>/<repo> \
UPSTREAM_REPO=boypt/openssh-deb \
bash scripts/sync-upstream.sh
```

确认 `dist/` 里的产物无误后，去掉 `DRY_RUN=true` 再执行一次才会发布 Release。也可以用 `ASSET_PATTERN` 只处理部分资产，例如 `ASSET_PATTERN='openssh-v*-jammy-amd64.tar.gz'`。

脚本会：

1. 读取上游最新 tag（或 `UPSTREAM_TAG` 指定的 tag）。
2. 如果本仓库已存在同 tag 的 Release，直接跳过。
3. 下载所有匹配 `ASSET_PATTERN` 的 `.tar.gz`（默认全部）。
4. 解压、只保留 deb、注入 `universal-install.sh`。
5. 重打成同名 `.tgz`。
6. 生成 `SHA256SUMS` 和 release notes；`DRY_RUN=true` 时到此为止，否则发布 Release。

## 维护说明

- 修改安装逻辑时只改 `universal-install.sh`，提交后下次构建会自动注入。
- 上游 asset 是 `.tar.gz`，本仓库统一输出 `.tgz`。
- 默认处理上游 release 里的所有 `.tar.gz` 资产，不筛选架构或 codename。
- `universal-install.sh` 目前只识别 Ubuntu `bionic` / `focal` / `jammy` / `noble`；Debian 包也会被注入脚本，但执行时会因 OS 检查退出。
- 只想处理部分资产时，手动触发并修改 `asset_pattern`，例如 `openssh-v*-jammy-amd64.tar.gz`。
- Release tag 与上游一致，已存在时跳过；需要重建时勾选 `force`。
