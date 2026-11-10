[English](../../en/deployment/02-updates-and-backup.md) · **简体中文**

# 更新与备份

让 Docker 部署保持最新、保护 SQLite 数据卷，并用声明式配置让安装可复现。

- [升级容器](#升级容器)
- [从上游镜像切换](#从上游镜像切换)
- [仪表盘更新检查器（#635 / #703）](#仪表盘更新检查器635--703)
- [备份 SQLite 数据卷](#备份-sqlite-数据卷)
- [声明式配置与目录控制项（#f4cd7b4）](#声明式配置与目录控制项f4cd7b4)

## 升级容器

`docker-compose.yml` 运行 `ghcr.io/yuktastv/freellmapi:${FREELLMAPI_IMAGE_TAG}`。该标签是必填的（没有默认值），并且应当是不可变的 `sha-<commit>` 标签。升级步骤：

1. 备份数据卷（见[备份 SQLite 数据卷](#备份-sqlite-数据卷)）。迁移只会向前执行，没有自动降级，所以这份备份就是你的回滚手段。
2. 在 `.env` 中把 `FREELLMAPI_IMAGE_TAG` 改成新的 `sha-<commit>` 标签。
3. 在新镜像上重建容器：

```bash
docker compose pull && docker compose up -d
```

任何升级都要守住三条不变量：

1. **保持同一个 `.env` 的 `ENCRYPTION_KEY`。** 提供方密钥是静态加密的；换了密钥，所有已存密钥都无法解密。见 [../env/02-security-and-keys.md](../env/02-security-and-keys.md)。
2. **保持同一个数据卷**（`freellmapi-data`，位于 `/app/server/data`）**以及同一个 Compose 项目名**（默认是目录名，除非你传了 `-p`）。数据卷名为 `<项目名>_freellmapi-data`，换了项目名就会从一个空数据库开始。迁移在每次启动时幂等地执行。
3. **只向前升级。** 绝不要让一个安装运行比上一次操作其数据库的镜像更旧的镜像（见下一节）。

对于 Docker 安装，仪表盘的更新对话框会打印一条命令：只有当 `.env` 已经写明新标签时，它才会拉取并重启。它会读取 `.env`，但绝不修改它，因为 `.env` 里保存着 `ENCRYPTION_KEY`。

## 从上游镜像切换

一直在运行上游镜像（`ghcr.io/tashfeenahmed/freellmapi`）的安装，在确认数据库兼容之前，不能切换到本 fork。迁移运行器会执行它认识的迁移，并且**会悄悄忽略它不认识的已应用迁移**。如果上游镜像比本 fork 更新，它可能已经以本 fork 代码预料不到的方式改了表结构，而且不会有任何提示。系统没有自动降级。

在更换镜像之前，按顺序完成下面所有步骤：

1. **查出当前运行的镜像和版本。**

   ```bash
   CID="$(docker ps -q --filter label=com.docker.compose.service=freellmapi)"
   docker inspect --format '{{.Config.Image}} version={{ index .Config.Labels "org.opencontainers.image.version" }} revision={{ index .Config.Labels "org.opencontainers.image.revision" }}' "$CID"
   ```

   仪表盘的设置页也会显示当前运行的版本。本 fork 的版本是 [`desktop/package.json`](../../../desktop/package.json) 里的 `version`。如果你正在运行的镜像版本比它更新，就停下：不要切换。

2. **确认数据库兼容性。** 列出你的数据库已经应用的迁移，并与本 fork 自带的迁移比较（在你本地的本 fork 检出目录里运行）：

   ```bash
   docker exec "$CID" node -e "const D=require('better-sqlite3');const d=new D(process.env.FREEAPI_DB_PATH||'/app/server/data/freeapi.db',{readonly:true});for(const r of d.prepare('SELECT filename FROM migrations ORDER BY filename').all())console.log(r.filename)" > applied-migrations.txt
   ls server/src/db/migrations | grep '\.ts$' | sort > fork-migrations.txt
   comm -23 applied-migrations.txt fork-migrations.txt
   ```

   数据库以只读方式打开。**没有任何输出表示兼容。** 只要打印出任何一行，就说明你的数据库已经有一个本 fork 不认识的迁移：不要切换。

3. **备份持久化数据卷和 `.env`。** 先停止容器，让 SQLite 处于一致状态，然后打包数据卷，并保留一份 `.env` 副本（里面有 `ENCRYPTION_KEY`；没有它，备份里的提供方密钥无法解密）。把两者存放在只有你能访问的地方。

   ```bash
   VOLUME="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/app/server/data"}}{{.Name}}{{end}}{{end}}' "$CID")"
   docker stop "$CID"
   docker run --rm -v "$VOLUME":/data:ro -v "$PWD":/backup alpine tar czf /backup/freellmapi-data-backup.tgz -C /data .
   cp -p .env .env.backup && chmod 600 .env.backup
   ```

4. **切换。** 在同一个目录里使用本 fork 的 `docker-compose.yml`，这样项目名和数据卷都保持不变。保留你的 `ENCRYPTION_KEY`，把 `FREELLMAPI_IMAGE_TAG` 设为本 fork 的 `sha-<commit>` 标签，然后运行 `docker compose pull && docker compose up -d`。用 `docker compose images freellmapi` 确认它现在运行的是 `ghcr.io/yuktastv/freellmapi`。

如需回滚：停止容器，把备份包恢复到数据卷里，再启动你之前运行的那个镜像。绝不要让旧镜像去操作一个已经被新镜像迁移过的数据库。

## 仪表盘更新检查器（#635 / #703）

设置页承载唯一的更新入口：它报告当前运行的版本、列出近期提交，并且——当安装方式是 Docker 时——打印一条升级命令：当 `.env` 中的 `FREELLMAPI_IMAGE_TAG` 已经写明新的 `sha-<commit>` 标签时，它会运行 `docker compose pull && docker compose up -d`。相关的控制项：

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `FREELLMAPI_UPDATE_CHECK` | 启用 | 设为 `off` 可把检查器从设置页隐藏，并阻止 Git 发现和对外发出的更新检查请求。这也会一并关掉自动版本提醒——一个独立的仪表盘设置项（设置 > 通用），在被打开之前始终保持关闭。 |
| `FREELLMAPI_UPDATE_GITHUB_TOKEN` | 空（匿名检查） | 仅用于对 GitHub 做更新检查的可选令牌。只有在需要更高限额时才使用窄权限令牌；通用的 `GITHUB_TOKEN` 值会被有意忽略。 |

两个构建层面的事实支撑着版本显示：`FREELLMAPI_INSTALL_METHOD=docker` 告诉服务器该建议哪条升级路径；runtime 镜像还会复制 `desktop/package.json` ——发布版本号就住在那里，因为 `server/package.json` 跟踪的是工作区版本——作为一个约 400 字节的清单，让容器安装能报出自己的版本（#703）。

## 备份 SQLite 数据卷

要紧的东西都集中在一个地方：命名卷 `freellmapi-data`，挂载于 `/app/server/data`，里面有 SQLite 数据库（`freeapi.db`，或 `FREEAPI_DB_PATH` 指向的位置）、它的 `-wal`/`-shm` 边车文件，以及开发式安装的 `.encryption-key` 文件。把它们作为整体一起备份，并妥善保管配套的 `ENCRYPTION_KEY`——没有它，备份下来的提供方密钥只是无法解密的密文。

内置加密备份（推荐，零停机）。FreeLLMAPI 可以按计划推送活动数据库的加密备份：

```env
FREEAPI_DB_BACKUP_PATH=/app/server/data/freellmapi.db.backup
# 或者：
FREEAPI_DB_BACKUP_URL=https://example.com/freellmapi.db.backup
FREEAPI_DB_BACKUP_TOKEN=optional-bearer-token
FREEAPI_DB_BACKUP_KEY=64-char-hex-backup-key        # 默认取 ENCRYPTION_KEY
FREEAPI_DB_BACKUP_INTERVAL_MS=300000
```

恢复语义：启动时若配置的数据库文件缺失，FreeLLMAPI 会在迁移运行之前恢复备份；服务器运行期间则定期上传新的加密备份。在临时磁盘的主机上，这是主要的保护手段。

卷快照（纯 Docker 做法）。标准模式原样适用：

```bash
docker run --rm -v freellmapi-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/freellmapi-data.tar.gz -C /data .
```

由于服务器一直持有数据库（WAL 模式），建议在容器停止时执行（`docker compose stop`），拿到一份静止的拷贝之后再 `docker compose start`。

## 声明式配置与目录控制项（#f4cd7b4）

对需要可复现的 Docker/服务器安装，FreeLLMAPI 可以在每次启动时应用一份 JSON 配置。设置 `FREEAPI_CONFIG_PATH=/path/to/freellmapi.config.json`，或者把同样的 JSON 内联进 `FREEAPI_CONFIG_JSON`。应用过程是幂等的：已有的密钥、自定义提供方、模型编辑、回退行和路由设置都会被更新而不是重复添加，且发生在每次启动的迁移之后。

```json
{
  "keys": [
    { "platform": "groq", "key": "gsk_...", "label": "main" },
    { "platform": "google", "key": "AIza...", "enabled": true }
  ],
  "customProviders": [
    {
      "baseUrl": "http://host.docker.internal:11434/v1",
      "label": "Ollama",
      "models": [
        { "model": "llama3.1:8b", "displayName": "Local Llama", "supportsTools": true }
      ]
    }
  ],
  "models": [
    {
      "platform": "groq",
      "modelId": "llama-3.3-70b-versatile",
      "displayName": "Llama 3.3 70B",
      "supportsTools": true,
      "fallbackEnabled": true
    }
  ],
  "routing": { "strategy": "balanced" }
}
```

如果两个自定义端点提供同一个模型 id，就在 `models` 或 `fallback` 条目里加上 `"endpoint"` 说明你指的是哪一个——端点的 URL，或者仪表盘显示在它旁边的短名。缺省时，匹配到多个端点的条目会被拒绝，而不是随便应用到其中某一个：

```json
{
  "models": [
    { "platform": "custom", "modelId": "deepseek-v3.1", "endpoint": "https://relay-b.example.com/v1", "enabled": false }
  ]
}
```

目录方面：安装会从经过签名的目录订阅源保持模型名册最新（完整目录见 freellmapi.co/models），所以升级之外无需手工维护名册。
