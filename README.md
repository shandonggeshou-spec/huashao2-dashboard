# 花路人格局 · 站长数据看板

与公开测试网站完全分离的私人数据看板。公开测试站不显示本项目入口。

## 能看到什么

- 今日/近 3、7、14、30 天测试量与周期环比；
- 累计测试数、平均及中位完成耗时；
- 每日趋势、七种人格结果分布；
- 最近测试的时间、耗时、结果和匿名报告编号；
- 用户意见及处理状态；
- 自动生成的近几天运营摘要。

发布验收产生的 `HL-VERIFY...` 与 `HL-LIVE...` 记录会自动从统计中排除。

## 安全模型

- 登录使用 Supabase 邮箱一次性链接，无需设置密码；
- 只有 `dashboard_admins` 白名单邮箱可调用汇总函数；
- 前端仅包含可公开的 Publishable key，不包含 Secret/service_role key；
- 数据库函数先验证 Supabase 登录身份，再返回匿名统计；
- 未登录者和非白名单账号无法读取业务表或统计接口；
- 不读取或展示 IP、城市、姓名、联系方式等信息。

## 配置

1. 在原 `huashao2-personality` Supabase 项目执行 `dashboard.sql`。
2. 将 `dashboard.sql` 最后一行的示例邮箱替换成站长邮箱后执行；不要把真实邮箱提交到公开仓库。
3. Supabase Dashboard → Authentication → URL Configuration：
   - Site URL 填写数据看板正式网址；
   - Redirect URLs 添加数据看板正式网址及结尾通配形式。
4. 将本项目部署为独立 GitHub Pages 网站。
