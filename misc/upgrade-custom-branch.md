# 自定义时区修复分支升级脚本

`upgrade-custom-branch.ps1` 用于把 `tz-null-fix` 定制提交重放到新的 Immich 正式版 tag。

它采用“一个长期维护分支、一个不可变发布 tag”的方式：`tz-null-fix` 是可 rebase 的工作分支；每个已验证版本以 `vX.Y.Z-tz-null-fix` Git tag 和 Docker tag 发布。GitHub Release 中的部署附件是单独维护的 `v3` 通用部署接口，不是每个版本各自归档的一份 Compose 文件。旧的 `v3.0.2-tz-null-fix` 分支只保留作历史参考。

## 前置条件

- 在本仓库的根目录或任意子目录中运行 PowerShell。
- 当前分支必须是 `tz-null-fix`。
- 工作区必须干净：先提交、暂存或清除其他修改。
- 已配置远端：`origin` 指向自己的 fork，`upstream` 指向 `immich-app/immich`。
- 目标 tag 已由官方发布，且版本号高于当前分支的基础 tag。

检查远端配置：

```powershell
git remote -v
```

如缺少官方远端，只需配置一次：

```powershell
git remote add upstream https://github.com/immich-app/immich.git
```

## 使用方法

假设当前 `tz-null-fix` 基于 `v3.0.2`，升级到 `v3.0.3`：

```powershell
.\misc\upgrade-custom-branch.ps1 -TargetTag v3.0.3
```

脚本会在本地重写 `tz-null-fix` 的历史，但不会推送。完成测试后推送更新后的维护分支：

```powershell
git push --force-with-lease -u origin tz-null-fix
```

随后创建并推送发布 tag。该 tag 会触发自定义 server 镜像构建；它不会自动创建或更新 GitHub Release 部署附件：

```powershell
git tag -a v3.0.3-tz-null-fix -m "Release v3.0.3-tz-null-fix"
git push origin v3.0.3-tz-null-fix
```

也可让脚本在 rebase 后立即提示 force-push；这会跳过 rebase 后的本地验证步骤，通常不建议使用：

```powershell
.\misc\upgrade-custom-branch.ps1 -TargetTag v3.0.3 -Push
```

## 脚本流程与确认点

脚本会识别当前维护分支已包含的最高官方 tag，获取更高的目标 tag，并列出待重放提交。之后有两个确认点：

1. 确认后将 `tz-null-fix` 原地 rebase 到目标官方 tag。
2. 仅在传入 `-Push` 时，确认是否以 `--force-with-lease` 推送重写后的维护分支。

脚本不会创建 Git tag。测试完成后，发布 tag 由目标官方版本加固定后缀决定，例如 `v3.0.3-tz-null-fix`。工作流验证 tag 必须与 `server/package.json` 的官方版本对应，随后构建：

- `ghcr.io/yrnyn/immich-server:v3.0.3-tz-null-fix`；
- `ghcr.io/yrnyn/immich-server:v3.0.3-tz-null-fix-<commit-sha>`。

构建成功后，镜像 tag 为版本固定的 `vX.Y.Z-tz-null-fix`，并同时更新浮动的 `v3` 镜像 tag。构建状态可在 [Actions 工作流页面](https://github.com/yrnyn/immich/actions/workflows/build-custom-server.yml) 查看。GitHub Release 部署附件需按下面的“v3 通用部署接口”流程单独更新。

任意确认点输入 `n` 或直接回车时，脚本会在该节点停止，不会进行该节点之后的操作。

## GitHub Release 部署接口

GitHub Release 的手动上传不是版本归档，而是给服务器提供稳定的 v3 通用下载入口：

```text
https://github.com/yrnyn/immich/releases/latest/download/docker-compose.yml
https://github.com/yrnyn/immich/releases/latest/download/example.env
```

当前自用部署接口 Release 是 `v3.0.2-tz-null-fix`。发布新的 v3.x 定制镜像后，应原地更新这个既有 Release 的附件，不要为了部署 YAML 新建 `v3.1.0-tz-null-fix` 等版本 Release，也不要修改接口中的 `IMMICH_VERSION=v3`。

附件来源和上传名称如下；每次只替换实际发生变化的附件：

| 仓库文件 | Release 附件名 |
| --- | --- |
| `docker/docker-compose.custom.yml` | `docker-compose.yml`；本次 v3.1.0 需要替换 |
| `docker/example.custom.env` | `example.env`；仅在模板内容变化时替换 |

在 GitHub Actions 中选择 `tz-null-fix` 分支，手动运行 `Publish Docker deployment files` workflow，并将 `release_tag` 保持为现有部署接口 Release tag（当前为 `v3.0.2-tz-null-fix`）。该 workflow 会使用 `--clobber` 原地覆盖附件。不要把版本镜像 tag `v3.1.0-tz-null-fix` 填入这里；版本 tag 只用于 Git 和 Docker 镜像发布。

服务器如果保存了旧的 `docker-compose.yml`，也必须用更新后的 Release 附件替换。此次 v3.1.0 只需同步 Compose 中的 Valkey 镜像 digest；`IMMICH_VERSION` 继续使用 `v3`，`example.env` 内容没有变化，因此不需要替换该附件。服务器实际使用的 `.env` 更不应被 Release 的示例模板覆盖。

## 升级后检查

建议在推送或部署前检查定制差异：

```powershell
git diff --check v3.0.3...HEAD
git diff --stat v3.0.3...HEAD
git diff v3.0.3...HEAD -- server/src/services/metadata.service.ts
```

预期差异包括：

- `server/src/services/metadata.service.ts` 的无时区 EXIF / 无 EXIF 日期处理；
- `server/package.json` 保持目标官方版本号；
- 部署配置的 ML、Postgres 和 Valkey 镜像来自目标官方 release 的 compose 文件。

部署时固定 server 的完整自建镜像 tag 或 digest，同时保留目标官方 compose 中对应版本的 ML、Postgres 和 Valkey 镜像。不要将可变的 `tz-null-fix` 分支名用作部署镜像 tag。

## 发生 rebase 冲突时

脚本会保留 Git 的冲突处理状态，不会自动继续或推送。先检查冲突：

```powershell
git status
```

如需保留本次升级，解决冲突后执行：

```powershell
git add <已解决的文件>
git rebase --continue
```

此时脚本已退出。完成 rebase 后继续执行前述测试、维护分支推送与发布 tag 命令；或者放弃本次尝试后重新运行脚本：

```powershell
git rebase --abort
git switch tz-null-fix
.\misc\upgrade-custom-branch.ps1 -TargetTag v3.0.3 -Push
```

## 回滚

维护分支会随 rebase 重写，但发布 tag 不会变。若新版本需要回退，直接在部署环境中改回旧的发布镜像 tag，例如：

```text
ghcr.io/yrnyn/immich-server:v3.0.2-tz-null-fix
```

对应的 Git tag 会继续保留；v3 通用部署接口 Release 则按接口用途原地维护。数据库迁移后的降级不受此流程保证，升级前仍应备份数据库。
