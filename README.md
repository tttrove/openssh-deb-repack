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

当前上游覆盖的发行版和架构：

| 发行版 | codename | 架构 |
| :--- | :--- | :---: |
| Ubuntu 18.04 / 20.04 / 22.04 / 24.04 | bionic / focal / jammy / noble | amd64 / arm64 |
| Debian 10 / 11 / 12 / 13 | buster / bullseye / bookworm / trixie | amd64 / arm64 |

Release 还会附带 `SHA256SUMS`。每个 tgz 内包含：

- 5 个 deb（当前上游结构）
- 本仓库最新的 `universal-install.sh`（重命名为 `install.sh`）

Ubuntu `bionic` / `focal` / `jammy` / `noble` 目标机解压后执行 `bash install.sh` 即可。Debian 包目前只做打包存档，安装脚本会因 OS 检查退出。

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
- 默认处理上游 release 里的所有 `.tar.gz`，包括 amd64/arm64 和 Ubuntu/Debian 各 codename。
- `universal-install.sh` 目前只识别 Ubuntu `bionic` / `focal` / `jammy` / `noble`；Debian 包也会被注入脚本，但执行时会因 OS 检查退出。
- 只想处理部分资产时，手动触发并修改 `asset_pattern`，例如 `openssh-v*-jammy-amd64.tar.gz`。
- Release tag 与上游一致，已存在时跳过；需要重建时勾选 `force`。
