# OpenSSH 上游包同步

自动跟踪 [boypt/openssh-deb](https://github.com/boypt/openssh-deb) 的 release，把上游 Ubuntu amd64 包重新打包成带本仓库 `universal-install.sh` 的 `.tgz`，并发布到本仓库的 GitHub Release。

## 目录结构

```
.
├── .github/workflows/sync-upstream.yml   # GitHub Actions 工作流
├── scripts/sync-upstream.sh              # 实际执行同步的脚本
├── universal-install.sh                  # 通用安装脚本（单一维护点）
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

上游 release 里的每个 `.tar.gz` 都会生成一个同名 `.tgz`，不区分 amd64/arm64 或 Ubuntu/Debian：

```
openssh-v10.6p2-1_b1-bionic-amd64.tgz
openssh-v10.6p2-1_b1-bionic-arm64.tgz
openssh-v10.6p2-1_b1-focal-amd64.tgz
openssh-v10.6p2-1_b1-jammy-amd64.tgz
openssh-v10.6p2-1_b1-noble-amd64.tgz
openssh-v10.6p2-1_b1-bookworm-amd64.tgz
openssh-v10.6p2-1_b1-bookworm-arm64.tgz
...
```

Release 还会附带 `SHA256SUMS`。每个 tgz 内包含：

- 5 个 deb
- 本仓库最新的 `universal-install.sh`（重命名为 `install.sh`）

目标机上解压后执行 `bash install.sh` 即可。

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

需要本机已安装并登录 `gh`：

```bash
gh auth status

TARGET_REPO=<owner>/<repo> \
UPSTREAM_REPO=boypt/openssh-deb \
bash scripts/sync-upstream.sh
```

脚本会：

1. 读取上游最新 tag（或 `UPSTREAM_TAG` 指定的 tag）。
2. 如果本仓库已存在同 tag 的 Release，直接跳过。
3. 下载 `openssh-v*-<codename>-amd64.tar.gz`。
4. 解压、只保留 5 个 deb、注入 `universal-install.sh`。
5. 重打成 `openssh-v*-<codename>-amd64.tgz`。
6. 生成 `SHA256SUMS` 和 release notes，发布 Release。

## 维护说明

- 修改安装逻辑时只改 `universal-install.sh`，提交后下次构建会自动注入。
- 上游 asset 是 `.tar.gz`，本仓库统一输出 `.tgz`。
- 默认处理上游 release 里的所有 `.tar.gz`，包括 amd64/arm64 和 Ubuntu/Debian 各 codename。
- `universal-install.sh` 目前只识别 Ubuntu `bionic` / `focal` / `jammy` / `noble`；Debian 包也会被注入脚本，但执行时会因 OS 检查退出。
- 只想处理部分资产时，手动触发并修改 `asset_pattern`，例如 `openssh-v*-jammy-amd64.tar.gz`。
- Release tag 与上游一致（如 `v10.6p2-1_b1`），已存在时跳过；需要重建时勾选 `force`。
