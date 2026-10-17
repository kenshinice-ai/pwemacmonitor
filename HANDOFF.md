# PWE Monitor · 交接

这份文件只放在等人的事和排着要做的事。项目怎么工作，看 `README.md` 和 `docs/`；发版用 `pwe-release` skill。

## 等 Lee

没有。

## 排着要做的

- **pwe-house 的 Monitor 案例图还是 1.5 的面板。** 1.6.0 改了网络卡片，并把负载挪到核心条下面（2026-10-10）。那张图在 paradise-production 仓库，由那边的会话重拍；`docs/dashboard-*.png` 已是新图。
- **产品页的循环和短片录的是 1.5.2 的面板。** 和 1.6.0 相比，核心条下面少一个「负载」读数；网络卡片在片子里本来就隐藏。差别很小。下次因为别的原因重录时一起更新，不为这一处单独重录。

## 1.7.1（2026-10-14 发布）

内容和依据在 `docs/power-rails.md` 最后一节。

在 M3 iMac 和 M5 Max Mac Studio 上各做一次核对，负责人 Lee：

1. 用 Homebrew 或 app 内更新装上 1.7.1。期望：`pwemon --probe` 第一行之前没有报错，关于窗口写 1.7.1。
2. 让 GPU 忙 1 分钟以上（M5 Max 上跑 LM Studio 即可）。
3. GPU 还忙着的时候，运行 `"/Applications/PWE Monitor.app/Contents/MacOS/pwemon" --probe --samples 45 | grep Power | tail -3`，约 45 秒。
   期望：最后几行出现 `cpu … [clpc]` 和 `ane … [clpc]`。
   如果是 `[clpc_pending]`：这 45 秒里 GPU 的 30 秒平均没到 1.5 W，证人没有判。
   如果是 `[clpc_refused]`：证人判了，两个 GPU 计数器对不上。
   只跑 3 个样本不够：新进程要自己看满 30 秒才判，除非菜单栏里的 app 已经判过并记住。
4. 如果仍是 `cpu — [none]`，运行 `pwemon --channels`，把输出贴回来。
   这说明 GPU 证人在那颗芯片上没通过；面板和 1.7.0 一样，没有显示错的数。

未核实：CLPC 的 CPU 读数在 M3 和 M5 Max 上的准确度。原因：没有在那两台上和 `powermetrics` 对照。M4 Max 上它满载偏高 5.7 %。

同一批截图里看到、这一版没有动的：

- `Snapshot.powerEnvelope` 对 Max 写的是 140 W，M5 Max 台式机在负载起来的那一秒读到 167 W，结论行于是写「Power warm · 86% to its limit」。86 % 是画法的封顶值，不是量出来的比例。稳定负载时读 102 W，不触发。
- M5 Max 上整机 102 W、GPU 51 W、CPU 占用 2 %，中间约 50 W 没有对应的电源轨。未核实是哪一部分。

## 已定

- 支持与致谢跟 PWE Lumen Bar 的决定一致（Lee 2026-10-14，见 Lumen Bar `HANDOVER.md` §六）：所有免费 PWE 工具共用 `pwestudio.site/support`；app 里只有菜单一个入口，不弹窗、不计天数、不锁功能；`FUNDING.yml` 指向同一页。GitHub Sponsors 整个 PWE 共用一个，开通后加到支持页，由 Lumen Bar 的「等 Lee」跟踪，这里不重复。

- `--panel-window` 留在源码里（Lee 2026-10-10）。它把面板放进一个不抢焦点、不会自己关的窗口，录片用；app 里没有入口。
- 短片 Lee 看过（2026-10-10）。页面循环已上 pwestudio.site/macmonitor。短片本身还没发到任何地方。
- 1.6.0（2026-10-10）：结论在 95 °C 附近来回跳的问题已加迟滞，回落到 92 °C 才放开；产品页「负载上来，外侧的羽毛先转琥珀」已改成按热量说。记录在 `docs/thermal-verdict.md`。
- 1.6.0 修掉的端口泄漏、三处读数不准和实测占用，记录在 `docs/sampling.md`。发版脚本会先跑 `pwemon --portcheck`。
- 1.6.0 于 2026-10-10 发布：GitHub release、cask、pwestudio.site 的安装包与更新端点都是 1.6.0，发布后的安装包回下核对过校验和与 Gatekeeper 结论。
- 发版流程 2026-10-18 起：`build.sh --dmg` 先公证、装订 app 本身，再做 DMG；`Tools/release.sh` 在打 tag 前要求 DMG 里的 app 带票据、`../ship-check.sh` 通过，并把检查摘要放进 release 说明。用 1.7.6 的代码实跑过一遍（未发布）。之前装上的副本没有票据，下次发版后才有。
- 1.7.6 于 2026-10-16 发布：修 1.7.5 的进程卡片标题在面板打开时出现蓝色焦点框；CPU / GPU 过热时结论行报温度，不再报封顶的「86% to its limit」。GitHub release、cask、站点安装包与更新端点都是 1.7.6，回下核对过校验和（`85175879…3d6faa2`）与 Gatekeeper 结论。
- 1.7.5 于 2026-10-14 发布：点进程卡片标题在 CPU / 内存排序间切换，选择保持到内存压力级别变化（Lee 要求）。GitHub release、cask、站点安装包与更新端点都是 1.7.5，回下核对过校验和（`566a029c…88bd6d6e`）与 Gatekeeper 结论。
- 1.7.4 于 2026-10-14 发布：菜单里的「支持 PWE…」；`FUNDING.yml`；产品页的支持按钮，以及更正「没有更新检查」那句。GitHub release、cask、站点安装包与更新端点都是 1.7.4，回下核对过校验和（`881bbb3f…779a32aca`）与 Gatekeeper 结论。`pwemacmonitor` 和 `pwepcmonitor` 的 Sponsorships 开关已打开（Lee 2026-10-14），Sponsor 按钮指向支持页。PC MONITOR 的支持入口已推送，CI 编译通过（运行 38560046515），下次发版带上。
- 1.7.3 于 2026-10-14 发布：GPU 证人允许 CLPC 偏高（依据是 M3 上的 `powermetrics` 对照，CLPC 的 CPU 读数与之逐秒吻合）。GitHub release、cask、站点安装包与更新端点都是 1.7.3，回下核对过校验和（`12cccc42…3737ec741`）与 Gatekeeper 结论。
- 1.7.2 于 2026-10-14 发布：`--probe` 和 `--json` 印出 CLPC 读数与证人状态；功耗结论报瓦数；台式机不再当成有电池。GitHub release、cask、站点安装包与更新端点都是 1.7.2，回下核对过校验和（`c4b05bf2…f447cbe1`）与 Gatekeeper 结论。
- M5 Max Mac Studio 上 1.7.1 的 GPU 证人已通过（2026-10-14）：CPU 8.7 W、ANE 都读 CLPC。
- M3 iMac 上 1.7.3 的 GPU 证人已通过（2026-10-14）：`GPU pair: CLPC 1.79 W, Energy Model 1.11 W — agrees`，CPU 6.3 W 读 CLPC。三台机器（M4 Max、M5 Max、M3）现在都显示 CPU 和 ANE 功耗。
- 1.7.1 于 2026-10-14 发布：GitHub release、cask、pwestudio.site 的安装包与更新端点都是 1.7.1，回下核对过校验和（`f232354f…19450d60`）与 Gatekeeper 结论。
- 1.7.0（2026-10-12）把 32 号和 33 号方案合在一起做了（Lee：1.7 和 1.8 一起做）。内存只认系统的三态，已用比例不再触发任何颜色（Lee 定）；CPU 功耗保留直方图，GPU 保留 Energy Model，CLPC 只用来恢复 ANE，并带证人——依据是当晚和 `powermetrics` 的两次对照，记录在 `docs/power-rails.md` 和 `docs/thermal-verdict.md`。
- 每次 macOS 更新后照 `docs/power-rails.md` 的「After a macOS update」三步核对 CLPC 的表。不核对也不会出错：证人会让 ANE 自己消失，回到 1.6.0 的样子。
- Swap 换出速率没有在真实内存压力下验证过（换入验证了，峰值 166 MB/s）。两者是同一对计数器、同一种算法。
