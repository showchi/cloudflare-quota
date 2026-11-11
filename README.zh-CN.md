# Cloudflare Quota

[英文](README.md) | 中文

非官方 macOS 菜单栏应用，与 Cloudflare, Inc. 无关。查看多个 Cloudflare 免费账号当天的 Workers / Pages Functions 请求量，并标出还没用到切换线、剩余最多的账号。

免费计划每天 100,000 次，Workers 和 Pages Functions 共用，午夜 UTC 重置。纯静态 Pages 不计。应用合计 Workers 和 Pages Functions 两套 GraphQL Analytics 采样统计，不是账单数字；跨数据集覆盖范围仍须与实际账号控制台核对，不能仅凭脚本同名判断调用重复。默认在显示用量到 75% 时不再建议这个账号。

应用不切换流量。调用方读取本机状态文件，自己选择对应账号的地址。

## 准备 Token

每个 Cloudflare 登录单独建一个 API Token：

1. 打开 My Profile → API Tokens → Create Token → Create Custom Token。
2. 权限只加 **Account → Account Analytics → Read**。
3. 账号范围选这一个账号。
4. 复制 Token。Account ID 在 Workers & Pages 右侧栏，也可以留空。Token 只能看到一个账号时，应用会自己填上。

不要把 API Token 贴到 Issue、Pull Request 或日志里。Token 只保存在本机。

## 运行

需要 macOS 15 和 Swift 6。如果 `xcode-select -p` 指向 Command Line Tools，把 `DEVELOPER_DIR` 指向完整 Xcode，例如：

```bash
export DEVELOPER_DIR="$(ls -d /Applications/Xcode*.app/Contents/Developer | head -1)"
```

```bash
swift test
swift run QuotaBar
```

打包需要 Python 3 和 Pillow，建议使用虚拟环境：

```bash
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r scripts/requirements.txt
scripts/package-dmg.sh
```

得到 `dist/CloudflareQuota.dmg`。打开后把左边的应用拖到右边的「应用程序」。应用使用本机临时签名，未经 Apple 公证。仅在确认下载来源可信且应用未被篡改时继续。如果首次启动被 macOS 拦截，先尝试从「应用程序」打开应用，再进入「系统设置 → 隐私与安全性 → 仍要打开」，并确认「打开」。参见 [Apple 操作说明](https://support.apple.com/zh-cn/102445)。

菜单栏显示当前最满账号的百分比。某个账号刷新失败或状态发布失败时显示 `!`。启动后按设定的间隔自动刷新，不用点开菜单；多账号并行查询。菜单面板在点面板外或按 Esc 时关闭，刷新时间和重置倒计时会随时间自动更新，点脚本用量行可以展开完整脚本列表。首次启动且还没有账号时，主窗口会自动打开。点「管理账号」打开主窗口，每行有编辑、停用和删除按钮，可以添加、编辑、删除账号，切换中文或英文、明亮、暗黑或跟随系统，也可以关掉菜单栏图标。账号编辑里可以先点「验证 Token」检查 Token 是否有效，验证会自动填入只有一个账号时的 Account ID，旁边也有创建 Token 的链接。窗口底部显示版本号和 build。应用平时没有程序坞图标。关掉菜单栏图标后，再从「应用程序」打开一次就能回到主窗口。

Token 在 `~/Library/Application Support/CloudflareQuota/tokens.json`，文件权限是仅当前用户可读。账号名称和限额在同一目录的 `accounts.json`，里面没有 Token。

状态文件在：

`~/.cloudflare-quota/status.json`

`suggestedAccountID` 是当前建议使用的本地账号 id。文件里没有 Token。

配置加载或事务恢复失败时，应用会发布无推荐、空账号列表的状态。任何状态发布失败（包括删除、停用账号或刷新发现账号不可用后），都会尝试删除旧状态文件；撤销失败时明确告警。发布错误会持续显示在菜单面板和管理窗口中，不会被其他操作错误掩盖。状态发布失败不会回滚已成功保存的账号操作，也不会通过默认配置覆盖原文件。

状态发布使用独立重试：从 1 秒开始退避，最长间隔 60 秒；每次按最新配置、用量和 UTC 日期生成状态，不重复请求 Cloudflare。发布成功后取消重试。

调用方应将状态文件缺失、无法解析或过期视为不可用；至少检查 `generatedAt` 属于当前 UTC 日且当前时间早于 `resetsAt`，并设置最大可接受陈旧时间，不能无限期缓存上次的推荐。`generatedAt` 是状态生成时刻，用量的新鲜度还应检查 `accounts[].usage.fetchedAt`。

当查询结果达到条数上限时，应用会按不重叠的时间窗口补查，只有所有子窗口均完整才合计。单次刷新每账号最多查询 31 次；如果一秒窗口仍满页、超过查询预算或任何子查询失败，应用会报告失败并暂停推荐该账号，不会把部分统计当作完整用量。此补查沿用已有时间过滤条件，不使用 cursor，也不按脚本名去重。

排查面板点击事件时，可在终端运行 `QUOTA_DEBUG_EVENTS=1 swift run QuotaBar`，并在 Console 中筛选 `QuotaPanel`。日志默认关闭，开启后只记录事件来源、类型、时间、窗口编号、鼠标位置和面板显隐，不记录账号名称或 Token。依次验证首次点击打开、再次点击关闭、面板内滚动与按钮、外部点击关闭，以及面板打开时自动刷新。该日志用于确认事件实际路由与回调顺序，不能替代原生界面复现。

账号编辑会在配置目录中临时创建 `.accounts.json.pending` 恢复记录，权限与 Token 文件一样为 0600；其中包含恢复所需的配置和凭据，成功后会删除。保存中断后，下次启动会先恢复旧状态或完成已提交的状态；恢复失败时暂停加载和写入，保留记录供修复权限后重试。此机制面向单个应用实例的进程中断，不承诺多个进程并发写入或硬件断电时的事务保证。

## 许可证

[MIT](LICENSE)
