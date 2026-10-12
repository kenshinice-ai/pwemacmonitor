# PWE Monitor · 交接

这份文件只放在等人的事和排着要做的事。项目怎么工作，看 `README.md` 和 `docs/`；发版用 `pwe-release` skill。

## 等 Lee

- **[动手] 在 M3 iMac 和 M5 Max Mac Studio 上各跑一次诊断命令，把输出贴回来** — 命令在下面「两台机器上看不到 CPU 和 ANE 功耗」一节 · 不跑就不知道那两颗芯片的功耗通道叫什么，修不了 · 自 2026-10-12

## 两台机器上看不到 CPU 和 ANE 功耗（2026-10-12，未修）

现象：1.7.0 在 M3（8 GB，双风扇）和 M5 Max（Mac Studio）上，功耗条只有 GPU 一段。

已知（读代码）：macOS 27 上 CPU 功耗只来自名为 `EACC*`、`PACC*`、`MACC*` 的 PMP 直方图。ANE 要等证人，证人也要这组直方图。没有直方图，两条轨都不显示。这条路只在 M4 Max 上实测过。

未核实：那两颗芯片上直方图是不存在，还是换了名字。原因：手边没有那两台机器的通道清单。

在每台机器的终端里粘贴运行，约 45 秒：

```bash
sw_vers -productVersion; sysctl -n machdep.cpu.brand_string hw.model
ioreg -l -w0 -r -c AppleCLPC | grep -m1 -o '"CFBundleIdentifier" = "[^"]*"'
ioreg -l -w0 | grep IOReportLegend | grep -o '{[^{}]*"IOReportGroupName"="PMP"[^{}]*{[^{}]*}[^{}]*}' | grep '"IOReportSubGroupName"="Energy"' | grep -o ',"[^"]*")' | tr -d ',")' | sort | paste -sd, -
"/Applications/PWE Monitor.app/Contents/MacOS/pwemon" --probe --samples 40 | grep Power | tail -2
```

期望输出（M4 Max，2026-10-12 实测）：第 4 行是 `AGX,AGX AFR,EACC0,EACC0 SRAM,PACC0,PACC0 SRAM,PACC1,PACC1 SRAM`，最后两行带 `cpu … [pmp_histogram]` 和 `ane … [clpc]`。

同一批截图里还看到两处阈值问题，也未修：`Snapshot.powerEnvelope` 对 Max 写的是 140 W，M5 Max 台式机读到 167 W；基础芯片写的是 38 W，iMac 的读数含屏幕，37 W 就转琥珀。

## 排着要做的

- **pwe-house 的 Monitor 案例图还是 1.5 的面板。** 1.6.0 改了网络卡片，并把负载挪到核心条下面（2026-10-10）。那张图在 paradise-production 仓库，由那边的会话重拍；`docs/dashboard-*.png` 已是新图。
- **产品页的循环和短片录的是 1.5.2 的面板。** 和 1.6.0 相比，核心条下面少一个「负载」读数；网络卡片在片子里本来就隐藏。差别很小。下次因为别的原因重录时一起更新，不为这一处单独重录。

## 已定

- `--panel-window` 留在源码里（Lee 2026-10-10）。它把面板放进一个不抢焦点、不会自己关的窗口，录片用；app 里没有入口。
- 短片 Lee 看过（2026-10-10）。页面循环已上 pwestudio.site/macmonitor。短片本身还没发到任何地方。
- 1.6.0（2026-10-10）：结论在 95 °C 附近来回跳的问题已加迟滞，回落到 92 °C 才放开；产品页「负载上来，外侧的羽毛先转琥珀」已改成按热量说。记录在 `docs/thermal-verdict.md`。
- 1.6.0 修掉的端口泄漏、三处读数不准和实测占用，记录在 `docs/sampling.md`。发版脚本会先跑 `pwemon --portcheck`。
- 1.6.0 于 2026-10-10 发布：GitHub release、cask、pwestudio.site 的安装包与更新端点都是 1.6.0，发布后的安装包回下核对过校验和与 Gatekeeper 结论。
- 1.7.0（2026-10-12）把 32 号和 33 号方案合在一起做了（Lee：1.7 和 1.8 一起做）。内存只认系统的三态，已用比例不再触发任何颜色（Lee 定）；CPU 功耗保留直方图，GPU 保留 Energy Model，CLPC 只用来恢复 ANE，并带证人——依据是当晚和 `powermetrics` 的两次对照，记录在 `docs/power-rails.md` 和 `docs/thermal-verdict.md`。
- 每次 macOS 更新后照 `docs/power-rails.md` 的「After a macOS update」三步核对 CLPC 的表。不核对也不会出错：证人会让 ANE 自己消失，回到 1.6.0 的样子。
- Swap 换出速率没有在真实内存压力下验证过（换入验证了，峰值 166 MB/s）。两者是同一对计数器、同一种算法。
