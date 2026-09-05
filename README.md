# 花路人格局 · 站长数据看板

与公开测试网站完全分离的私人数据看板。公开测试站不显示本项目入口。

## 能看到什么

- 今日测试量及 DoD、今日平均耗时及 DoD；
- 累计测试数、待查看/累计/已处理意见数；
- 测试趋势支持所选日期的 0–23 点小时分布、截至所选日期的最近 10 个自然日、每 7 日和自然月聚合；当天尚未到达的小时留空；人格结果分布支持“总计 / 按日”切换，按日模式可独立选择日期；
- 可分页查看全部测试的时间、耗时、结果和匿名报告编号；
- 可按反馈类别筛选并分页查看全部用户意见及处理状态；
- 自动生成的近几天运营摘要。

发布验收产生的 `HL-VERIFY...`、`HL-LIVE...`、`HL-DEMO...` 记录及自动化回归反馈会自动从统计中排除。

## 安全模型

- 登录使用 Supabase 邮箱一次性链接，无需设置密码；
- 只有 `dashboard_admins` 白名单邮箱可调用汇总函数；
- 前端仅包含可公开的 Publishable key，不包含 Secret/service_role key；
- 数据库函数先验证 Supabase 登录身份，再返回匿名统计；
- 未登录者和非白名单账号无法读取业务表或统计接口；
- 不读取或展示 IP、城市、姓名、联系方式等信息。

## 配置

1. 首次安装时，在原 `huashao2-personality` Supabase 项目执行 `dashboard.sql`；无论首次还是已有看板，最后都执行最新版 `trend-granularity.sql` 和 `profile-distribution.sql`，启用趋势历史日期及总计/按日人格分布。已有看板需补充执行最新版 `pagination.sql` 和 `feedback-pagination.sql`，启用完整记录分页与意见类别服务端筛选。
2. 将 `dashboard.sql` 最后一行的示例邮箱替换成站长邮箱后执行；不要把真实邮箱提交到公开仓库。
3. Supabase Dashboard → Authentication → URL Configuration：
   - Site URL 填写数据看板正式网址；
   - Redirect URLs 添加数据看板正式网址及结尾通配形式。
4. 将本项目部署为独立 GitHub Pages 网站。
