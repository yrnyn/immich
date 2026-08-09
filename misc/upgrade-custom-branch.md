# 自定义时区修复分支升级脚本

`upgrade-custom-branch.ps1` 用于把 `tz-null-fix` 定制提交重放到新的 Immich 正式版 tag。

它采用“一个长期维护分支、一个不可变发布 tag”的方式：`tz-null-fix` 是可 rebase 的工作分支；每个已验证版本以 `vX.Y.Z-tz-null-fix` Git tag 和 Docker tag 发布。推送该 tag 会由同一个工作流依次完成镜像构建、发布该版本的 GitHub Release 及部署附件、把浮动的 `v3` 部署 tag 指向本次构建；每个版本各自归档一份部署 Compose，服务器端的固定下载地址始终指向最新一次成功发布。

## 当前补丁范围（v3.2.0）

上游业务代码仅保留 `server/src/services/metadata.service.ts` 的时间修复：无时区的日期按容器时区解释，并返回推断时区；无 EXIF 日期时保留正确的本地时间。部署环境应明确设置 `TZ`（例如 `Asia/Tokyo`）。

自定义版本检查及配套配置、测试已移除，`server/Dockerfile` 与官方版本一致。应用版本保持官方 `package.json` 中的 `3.2.0`，更新通知查询官方版本服务，关于页面恢复官方行为。自定义镜像是否可用以本仓库 Actions 结果及镜像 tag 为准；每个版本的 GitHub Release 会记录该次构建的镜像 digest，可用于追溯部署环境实际运行的构建。

本次从 v3.1.0 升级时已跳过版本检查定制提交，保留时间补丁及构建、部署文件。后续升级继续核对上游业务代码的差异是否仅限日期处理，避免重新引入版本检查定制。

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

随后创建并推送发布 tag。该 tag 会触发完整发布流程：构建镜像、发布该版本 Release 及部署附件、移动 `v3` 部署 tag：

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

浮动的 `v3` 部署 tag 由独立的 `promote` job 在 Release 发布成功后才移动，因此构建或发布失败都不会影响已部署环境。构建状态可在 [Actions 工作流页面](https://github.com/yrnyn/immich/actions/workflows/build-custom-server.yml) 查看；某一步失败时用 “Re-run failed jobs” 重跑即可，已成功的构建不会重来。

在 Actions 中手动运行该工作流只会产出带 commit sha 的不可变测试镜像，不会创建 Release，也不会移动 `v3`。

任意确认点输入 `n` 或直接回车时，脚本会在该节点停止，不会进行该节点之后的操作。

## GitHub Release 与部署附件

推送发布 tag 后，工作流会为该版本创建 GitHub Release 并上传两个附件，同时把它标记为 Latest。
服务器端使用固定下载地址，始终指向最新一次成功发布：

```text
https://github.com/yrnyn/immich/releases/latest/download/docker-compose.yml
https://github.com/yrnyn/immich/releases/latest/download/example.env
```

每个版本也有各自的下载地址，用于回溯或回退：

```text
https://github.com/yrnyn/immich/releases/download/v3.0.3-tz-null-fix/docker-compose.yml
```

附件来源如下，上传时改用官方文件名，服务器才能直接覆盖同名文件：

| 仓库文件 | Release 附件名 | 说明 |
| --- | --- | --- |
| `docker/docker-compose.custom.yml` | `docker-compose.yml` | 相对官方只差 immich-server 镜像仓库一行 |
| `docker/example.env` | `example.env` | 上游模板，仅供首次部署；不要覆盖服务器已有的 `.env` |

不再单独维护定制版 env 模板。上游的 `docker/example.env` 已经是 `IMMICH_VERSION=v3`，与本仓库 build 工作流
从 `server/package.json` 推导出的 major tag 自动一致，因此直接发布上游文件即可。

Release 说明由工作流自动生成，包含本次构建的镜像 digest。`v3` 是浮动 tag，要确认某次部署实际跑的是哪个
构建时，以 Release 记录的 digest 为准。

### 定制 Compose 的同步规则

`docker-compose.custom.yml` 是从官方 `docker-compose.yml` 复制出来的独立文件，rebase 不会把上游对官方
Compose 的改动带进来。因此规定：**两者只允许差 immich-server 镜像仓库一行。**

- 本地：`upgrade-custom-branch.ps1` 在 rebase 后自动按该规则重新生成并比对，不一致时展示差异并询问是否覆盖。
- CI：`release` job 发布前再校验一次，不一致直接失败，不会把过期的部署文件发出去。

想额外定制 Compose 时，优先考虑能否放进服务器端的 `docker-compose.override.yml`（见下节）。只有在 override
无法表达时才扩大仓库内的差异，并同时更新上述两处的同步规则。

## 部署端约定

服务器上只有三个文件，升级时各自的处理方式固定：

| 文件 | 来源 | 升级时 |
| --- | --- | --- |
| `docker-compose.yml` | Release 附件 | 整份覆盖，不手工编辑 |
| `.env` | 首次部署时从 `example.env` 复制 | 不动 |
| `docker-compose.override.yml` | 自己维护 | 不动 |

本机定制全部放在 `.env` 和 `docker-compose.override.yml` 里。Compose 会自动加载 override 文件，其中的
`volumes` 等列表与主文件**追加**合并，标量（如 `image`）则直接替换。

升级命令：

```bash
curl -fsSL -o docker-compose.yml https://github.com/yrnyn/immich/releases/latest/download/docker-compose.yml
docker compose pull && docker compose up -d
```

注意 Compose 中的 Valkey 与 Postgres 镜像是按 digest 固定的，只跑 `docker compose pull` 而不更新
`docker-compose.yml` 拉不到新的数据库与缓存镜像。上游偶尔会提升 Postgres 的 vectorchord 扩展版本，
那种情况下不覆盖 Compose 会导致迁移失败，所以覆盖 Compose 是升级流程的必要步骤。

### 临时回退到某个版本

不要改 `.env` 里的 `IMMICH_VERSION`：该变量同时决定官方 ML 镜像的 tag，填入 `vX.Y.Z-tz-null-fix`
会让 ML 拉取一个不存在的 tag。回退写在 override 里：

```yaml
services:
  immich-server:
    image: ghcr.io/yrnyn/immich-server:v3.0.2-tz-null-fix
```

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

日常部署使用浮动的 `v3` tag，它只在一次发布完全成功后才移动；需要固定到某次构建时，用 Release 记录的 digest 或带 commit sha 的不可变 tag。不要将可变的 `tz-null-fix` 分支名用作部署镜像 tag。

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

回退镜像写在服务器的 `docker-compose.override.yml` 里，不要改 `.env` 的 `IMMICH_VERSION`（见“临时回退到某个版本”）。对应的 Git tag 和各版本 Release 都会继续保留。数据库迁移后的降级不受此流程保证，升级前仍应备份数据库。
