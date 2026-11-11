# AA 记账（Spliit）

[Spliit](https://github.com/spliit-app/spliit)（Splitwise 的开源替代，MIT）的云吞插件：聚餐、合租、旅行后 AA 分账——建一个群，谁付了钱记一笔，谁欠谁多少、最后怎么转账最省事，自动算清。

图标来自上游标志，来源与许可见 [NOTICE](NOTICE)；Spliit 是 Spliit 项目的商标。

## 使用

装好后打开插件网页：新建群组（选币种、加成员），把群组链接发给同行的人，大家打开链接就能进群记账。

- **登录**：应用没有账号体系，网页在云吞网关后面，家里人在云吞里打开即用；群组列表存在各自浏览器里。云吞外的人（同行的朋友）用云吞的好友分享把插件分享给他，他凭群组链接进群。
- **数据**：全在本机插件数据目录的 Postgres 数据库（`${WONTON_APP_DATA}/postgres`），随插件卸载删除（选择保留数据则保留）。
- **出网**：插件容器不出网。汇率换算由你设备的浏览器向公开汇率接口（frankfurter.dev）查询。收据识别（要 OpenAI）和群组删除（要定时任务）按上游默认关闭。
- **备份**：数据库在插件数据目录里，随核心的数据备份一起走。

通用流程见[插件开发指南](https://github.com/wontonapp/wonton-docs/blob/main/develop.md)，字段与权限规则见[插件规范](https://github.com/wontonapp/wonton-docs/blob/main/plugin-spec.md)。
