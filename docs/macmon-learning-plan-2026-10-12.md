# PWE Monitor：参考 macmon 的能力补齐方案

日期：2026-10-12（Australia/Melbourne）  
性质：源码阅读与方案；本轮只新增本文档。  
建议方向：先让读数更可信，再让用户更容易定位问题，最后按实际需求扩展机器接口。

## 1. 结论与建议顺序

PWE Monitor 已经有成熟的菜单栏产品形态，底层也是 macmon 的 Swift 移植。继续学习 macmon，价值最大的不是再加一排仪表，而是跟进它在硬件适配、数据语义和诊断能力上的进展。

建议先做三件事：

1. **统一“读不到、尚未采到、过期、真实为零”的表达。** 当前面板有部分降级处理，但 JSON、摘要、健康结论与各条功耗轨还没有统一的数据可用状态。
2. **验证 CLPC 功耗通道，争取在 macOS 27 恢复 ANE，并改善 CPU 功耗来源。** 保留现有 PMP 直方图回退；不能因上游实现存在，就宣布在 PWE 的支持机器上准确。
3. **将固定两层 CPU 模型改成可变层级。** 优先纠正当前新芯片标签及频率映射的风险，再覆盖上游已经处理的三层拓扑。

随后补进程 CPU／内存排序、PID 身份校验、带时间戳的历史统计，以及可控的 CLI 采样。进程 GPU／功耗、HTTP／Prometheus 放到后续独立范围。

保持已有产品主线：一个自包含 App、无需 sudo、无需 Homebrew 或常驻辅助进程；五根羽翼表达五个通道；颜色服务于状态判断。新能力优先进入现有卡片、悬停说明、设置或开发工具。

## 2. 阅读基线与证据边界

| 项目 | 本轮核对结果 |
|---|---|
| PWE 仓库 | `kenshinice-ai/pwemacmonitor`，本工作目录 |
| 本地分支／提交 | `main` / `ce2b7699d463841f39e3749ef5d79199956894aa` |
| 远端 main | `git ls-remote origin refs/heads/main` 与本地提交相同 |
| 阅读前工作区 | `git status --short` 无输出，干净 |
| 代码版本 | `Resources/Info.plist`：1.6.0，build 12，arm64，macOS 14+ |
| 构建方式 | `build.sh` 直接调用 `swiftc -O -swift-version 5`；没有 SwiftPM／Xcode 项目 |
| macmon 参考提交 | `main` / `afdd572b12c9c301183569230a476bd4267b638b` |
| 上游版本边界 | `Cargo.toml` 仍写 0.9.0；changelog 的 v0.9.0 日期为 2026-10-07；本轮查到 v0.9.0 tag，未查到 v0.10.* tag。本文同时阅读了 0.9.0 之后的 main 能力，不能一概视为已发布版本 |
| 上游最新提交 | 2026-10-12，`feat: start without IOReport hardware counters (#99)` |
| 实际执行 | 阅读源码、文档、CI／发布脚本、现有截图；远端引用核对；将上游只读参考 checkout 放在 `/tmp` |
| 未执行 | 本轮未重建 App、运行压测或 powermetrics、验证实机读数、检查最新 CI 结果、修改设置、提交、发布或部署 |

本文所说“已有”，表示**当前源码已实现，本轮未做实机验收**。仓库中的 1.6.0 测量和发布记录是历史证据，不是本轮重新验证的结果。截图只用于理解已有布局，也不是实时运行证明。

### 既有决定

- [HANDOFF.md](../HANDOFF.md) 明确：32 号内存方案仍等 Lee 决定，未决定前 1.7.0 不动工。本文不改变其着色、压力状态命名、Swap 行或版本安排。
- HANDOFF 引用的 `00 PLANNING 2026/32-…` 文件不在当前 checkout 中；本轮只确认交接里的摘要，未核对该方案全文。
- `--panel-window` 已决定保留为录片工具，App 没有入口。不能把“增加常驻窗口”作为缺失功能直接实施。
- README 明确 App 不具备结束进程的能力。macmon 的 kill 功能不纳入本方案推荐范围。
- [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md) 已记录 macmon 的 MIT 来源。未来移植新逻辑继续保留来源、许可和参考提交。

## 3. 当前项目地图：哪些不需要重复建设

| 层／能力 | 当前状态及限制 | 主要证据 |
|---|---|---|
| 底层读取 | IOReport、SMC、IOHID；动态加载私有接口；无 root 依赖 | `Sources/Core/IOReport.swift`、`SMC.swift`、`IOHID.swift` |
| CPU／GPU | 逐核驻留率、频率加权占用、raw active、GPU 频率；CPU 数据仍按高／低两组组织 | `SocInfo.swift:5–64`、`Sampler.swift:168–205,571–633` |
| 功耗 | CPU／GPU／ANE／DRAM、整机功耗；macOS 27 的 CPU 直方图回退及批次尖峰拒绝 | `Sampler.swift:85–91,436–456,595–622,767–806`；[power-rails.md](power-rails.md) |
| 温度／风扇 | CPU 均温与峰值、GPU、SSD、电池；按需完整传感器列表；风扇及上限 | `Sampler.swift:479–569,636–736` |
| 内存／磁盘／网络／电池 | 已用／压缩／wired／cache／swap／压力；磁盘容量与吞吐；物理网口吞吐；电池健康等 | `SystemStats.swift`；[sampling.md](sampling.md) |
| 进程 | libproc 增量 CPU 与 physical footprint；采集 CPU 前八名，面板固定显示六行 | `SystemStats.swift:253–308`、`Sampler.swift:707–720`、`DashboardView.swift:483–515` |
| 历史 | CPU／GPU／整机功耗／温度／内存／网络的 89 点内存缓冲，部分用于曲线；没有点级时间戳 | `Monitor.swift:56–58,193–203,246–251`、`Theme.swift:12` |
| 交互 | 三种菜单栏显示；动态卡片配对；刷新间隔 1／2／3／5 秒；中英文；小屏滚动；减少动态效果；VoiceOver | `Sources/App/`；[panel-height.md](panel-height.md)、[localisation.md](localisation.md) |
| 健康判断 | 五通道羽翼、热状态、低电量／低电量模式等解释；温度与功耗幅度最多琥珀；迟滞防闪烁 | `Sampler.swift:17–83,230–435`；[thermal-verdict.md](thermal-verdict.md) |
| CLI／诊断 | `--probe`、`--json --loop`、复制诊断信息；CLI 固定约一秒、总是读完整传感器 | `App.swift:422–446,473–510` |
| 验证／交付 | thresholds、loccheck、bench、portcheck、快照与真实 popover 检查；本地签名公证发布；CI 构建检查 | `Tools/`、`build.sh`、`.github/workflows/build.yml` |

PWE 在电池、SSD、网络、轻量采样、中文体验和健康状态表达上已经有自己的价值。不能仅因为上游换了实现，就整体替换这些路径。

## 4. macmon 差异矩阵

上游证据链接固定到本轮提交，避免 main 后续变化使方案失去依据。U1–U9 的链接见文末。

| 可借鉴能力 | macmon 当前证据 | PWE 差异 | 推荐优先级 |
|---|---|---|---|
| 不可用温度用 Optional／JSON null | U1；0.9.0 changelog | PWE 数值多以 0 占位；面板部分显示 `—`，JSON 仍输出 0 | **P0：统一数据质量** |
| CLPC CPU／GPU／ANE 能量计数器 | U2；0.9.0 已记录功耗恢复 | PWE 未订阅 CLPC；CPU 用 PMP，ANE／DRAM 可用性绑在一起 | **P0：实验，验证后接入** |
| 动态 CPU tiers 与标签 | U1、U3；当前 main 有三层测试 | PWE 只有 `isP`、两套频率表／核数；忽略中间 perflevel | **P1：硬件适配** |
| 进程排序／过滤／身份 | U4、U5 | PWE 只能 CPU 排序；基线仅以 PID 关联 | **P1：诊断体验及正确性** |
| active／scaled 视图 | U1、U6；0.8.1 已记录切换 | PWE 已采到两种值，但界面只用 scaled，JSON 只输出部分 active | **P1：解释口径，P2：可选切换** |
| 历史均值／最大值 | U6 | PWE 有曲线，无窗口统计；改变刷新间隔后旧点被按新间隔解释 | **P1：时间轴与统计** |
| 有限样本、指定间隔、debug | U7、U8 | PWE 有输出，但不能直接控制样本数／间隔／采样内容，诊断缺来源状态 | **P1：机器接口** |
| CPU／GPU／ANE 独立或脉冲负载验证 | U7、U8 | PWE 有 CPU 对照脚本与 benchmark，无对应的完整场景工具 | **P1：开发验证工具** |
| 硬件数据源缺失时部分运行 | U1、U3；main 最新 #99 | PWE IOReport 可为空，但 `SocInfo.load()` 仍强制依赖 pmgr 与两张 CPU 表 | **P1：按源降级，VM 后置** |
| 每进程 GPU／W | U4 | PWE ProcessStat 只有 CPU 与内存 | **P2：实验证据充分后加入** |
| HTTP／Prometheus／launchd | U9；0.7.0 已记录 | PWE 已有 JSON，可先服务本地脚本；尚无网络服务 | **P3：出现使用需求后独立做** |
| 杀进程、进程详情／文件等 | 当前 main `tui/kill.rs`、`info.rs`、`fds.rs` | 超出 PWE 已确定的观察工具定位 | **不纳入当前范围** |

上游也有边界：当前 main 的缺源回退仍会把部分功耗／频率写成 0；温度 TUI 会对缺失读数做趋势补值；某些跨用户进程内存来自 RSS；三层 CPU 的中间层频率映射仍有未实机确认的假设。应学习实现方法，不能直接继承其所有显示语义。

## 5. P0：先补数据可信度

### 5.1 单项指标的可用状态与来源

**要解决的实际问题**

- `Snapshot` 中大量指标默认 0，首个 IOReport 调用只建立基线：此时不能断言 CPU 真为 0%。
- `aneDramReadable` 同时管理两条轨；CLPC 若只恢复 ANE，现有模型无法单独表达。
- JSON 的 `power.cpu_source` 和 `rails_readable` 已经是良好起点，但 GPU、温度、整机功耗没有相同的粒度。
- `s.sysPower = max(s.sysPower, s.allPower)` 会让 SMC 缺失时的计算轨合计进入“整机功耗”字段；即使有 SMC 读数，也可能被合计覆盖。应区分原始系统读数、计算小计与用于展示的回退值。
- `CLI.summary()` 仍可能把不可读 ANE／DRAM 打印成 `0.0 W`；`Snapshot.headline()` 没有独立的缺源条件，全默认值仍可能组成“五个通道均平稳”。这是静态路径判断，未在本轮故障注入复现。

**落地设计**

在 Core 引入简单的值类型，例如 `MetricReading<Value>`，包含可选值、单位、来源、采样时间及状态。状态至少区分 `warmingUp`、`valid`、`stale`、`unavailable`；硬件不存在作为能力状态另行记录。值为 0 且状态 valid 才是真正的零。

先覆盖功耗和温度，再扩至 CPU／GPU、内存读取失败等路径；不用一口气把全项目泛型化。健康等级和读取状态分开，未知不是新的“红色故障”。

- 每条轨独立判定；保留整体 coverage，说明这个“电源轨小计”覆盖了哪些项。
- 有效、测得的零可以显示；缺失项显示 `—` 或在固定高度的轨图中省略，说明原因。
- 缓存值明确标记 stale，不让上一秒 ANE 自动变成这一秒的实测值。
- 未知来源用中性提示；缺少关键输入时结论改为“部分读数不可用”，不能仍保证五通道平稳。
- 不用预测或平滑值替代原始遥测数据；展示平滑如果需要，应是独立派生层。
- 保留原始 SMC 整机功耗；计算轨合计另存。回退显示应说明来源，不能拿它算“其余系统耗电”。

**JSON 兼容策略**

保留现有 `--json` 默认字段及数值类型，在 v1 增加质量／来源元数据；需要 null、传感器数组、tiers 等完整语义时提供显式 v2，例如拟议的 `--schema 2`。新消费端以 v2 为准，旧消费端继续可用，并写清 v1 的 0 占位限制。不要在一次补齐里静默改变旧字段含义。

现有 `sensors` 按 name 生成字典，同名只保留首项，而 HID 可以有多个同名服务。v2 改成包含稳定 id、name、source、value、status 的数组；id 必须来自服务／键身份，不能把每次排序位置当作身份。v1 字典作为明确有损的兼容视图保留。

**验收**

用合成 fixture 覆盖首个样本、合法零、无源、读取失败、恢复、stale 超时、计数器倒退、NaN／无穷、重复传感器名称；UI／摘要／JSON 不互相矛盾，卡片不因单次失败变高变矮，Unknown 不被当成 calm。真实风扇 0 RPM 应保留，不能通用地用 `value > 0` 判断全部指标有效。

预计主要文件：`Sampler.swift`、`App.swift`、`DashboardView.swift`，新增小型 Core 质量模型；沿用已有 threshold／快照工具验证相关状态。

### 5.2 CLPC：先验证，再接到功耗来源选择器

**上游方法与价值**

macmon 根据 AppleCLPC 服务的 `CFBundleIdentifier` 和系统版本，选取已知 CPU／GPU／ANE 报告 ID，再用实时 IORegistry `DriverID` 构造 IOReport 通道描述；以 nJ 增量除实际经过时间得到 W。订阅时还会按 driver 与低位 counter identity 去重，防止别名重复计数。详见 U2、U3。

上游静态映射说明覆盖 macOS 27.0／27.0.1；运行代码的门槛是 major 27。**静态提取 ID 不能证明权限、单位和实机精度**，这一点上游文档也明确写出。

**推荐实现步骤**

1. 在开发工具里输出 AppleCLPC driver bundle、OS 版本与 build、选中 ID、单位、原始累计值及差值。
2. 建立带证据的映射表，明确参考提交、已验证系统 build 与机器；未知 driver／OS 不猜 ID，不按芯片营销名直接套表。
3. 将 CLPC 通道构造／去重放在 IOReport 层，功耗来源选择留在 Sampler；不引入 Rust runtime、不在 App 启动时下载固件或扫描 kernelcache。
4. 已验证的 CLPC 成为 CPU 首选；无效则退到现有可信 Energy Model／PMP。GPU 保留当前有效 Energy Model，只有 CLPC 更适合且经过对照后才调整优先级。
5. ANE 独立恢复，DRAM 独立不可用。上游 `clpc.rs` 没有 DRAM 映射，不能宣称“四轨都恢复”。ANE 瓦数也不能改称 ANE 使用率。
6. 检查能量单调性、真实 interval、负差值／无效哨兵、睡眠／唤醒重建基线、多 die 聚合、重复别名。Ultra 已聚合计数器不能再乘 die 数。
7. 保留现有 PMP 冷启动校准与批次尖峰防护；CLPC 缺失不能导致整个 App 失效。

**实机实验设计**

- 先跑没有 powermetrics 的 idle → CPU → GPU → ANE → mixed → idle 场景，保存时间边界、原始差分、来源切换与恢复过程。ANE 场景必须确认工作负载实际执行，不能凭模型名称或 Core ML 偏好就断言用了 ANE。
- 再跑开启 powermetrics 的对照，按重叠时间窗比较均值／能量积分，保存 CPU／GPU／ANE 各自偏差。它与 App 同时读取相近底层数据，对照只能说明一致性；不把它当成独立墙插功耗证明。
- 最后关掉 powermetrics 再观察；现有 [power-rails.md](power-rails.md) 已记录它会让 legacy Energy Model 恢复更新，因此“对照时看起来好了”不能证明 rootless 路径成立。
- 批次问题至少观察 20 分钟，覆盖旧文档最长约 14 分钟的间隔；这只是实验窗设计，不保证覆盖所有机器的批次周期。
- 初始验收候选：稳定负载且参考均值 ≥ 2 W 时，重叠 30 秒窗均值相差 ≤ 10%；低负载另报告绝对 W 偏差及分辨率，不用百分比失真。阈值是拟议工程门槛，必须随实测证据审定，不能先写成准确率承诺。

**证据与放行**

至少取得当前支持机器的一组 rootless 实测及一组对照，再考虑默认接入；未验证的机器只做能力探测与安全回退。需要 Ultra／旧系统／不同 CLPC driver 的独立证据才能扩展兼容声明。App 继续无 sudo；仅开发对照由操作人员运行 Apple 工具。无需照搬上游关闭 SIP 的追踪研究。

预计主要文件：`IOReport.swift`、`Sampler.swift`，新增 `CLPC.swift`；扩展已有对照工具与 `power-rails.md`。先交实验记录，再决定默认切源；失败时也交明确的缺失原因和回退结果。

## 6. P1：硬件适配、定位问题和可复现诊断

### 6.1 动态 CPU 拓扑

**当前源码风险**：`SocInfo.load()` 只读最高和最低 perflevel；所有非旧命名芯片统一标为 P／S。Sampler 将 MCPU 和 ECPU 都归入 `isP == false`，使用同一频率表。对上游描述的三层配置，中间层的核数／频率／百分比可能不正确；两层基础款也有标签误判风险。本轮未在对应硬件验证。

借鉴 U1、U3：

- 用 `[CpuTierInfo]` 保存层级 id、显示标签、核数、频率表；CoreMetric 改用 tierID，加 dieID／clusterID／coreID，而非一个 `isP`。
- 优先读 `hw.perflevelN.name`，再结合 `acc-clusters` 及明确的 channel 规则；未知层级如实显示未知，不仅靠 M5／M6 字符串猜测。
- 频率表查找跟进上游对 `pmgr`／`pmgr-child` 节点的兼容，空壳节点不能覆盖已经读到的表；PWE 目前只找名字恰为 `pmgr` 的节点。
- 三层需要逐层 DVFS 表；不能仅将原来的最低／最高两套表扩展成三个数组位置。
- 聚合分母使用完整硬件核数，缺失的休眠核不能从分母消失。稳定核身份避免两颗 die 的 CPU0 合并。
- `ecpu_*`／`pcpu_*` 保留兼容定义；新 `cpu.tiers` 提供所有层级。CLI summary 也改为动态标签，当前硬写 E／P 的输出需要同时处理。
- 新结构驱动芯片摘要、核心条分组、tooltip 和总核数；CPU 羽毛仍是一根，不随 tier 数增加。

尤其要保留上游自己的不确定性：`sources.rs::cpu_tier_infos` 当前让最低层用 E-complex 表，其余层共用 P-complex 表，注释明确说三层配置的中间层实际频率尚未与对应机器的 powermetrics 确认。PWE 可以参考层级结构，但频率映射必须有独立依据；若确实共享表，应记录验证证据，不能把这个假设隐藏在“支持三层”里。

fixture 至少覆盖：M1–M4 双层、上游描述的 M5 基础与 Pro／Max 两种标签组合、三层、双 die、没有 perflevel name、乱序 channel、只报告活跃核、未知 tier。三层／新机型须明确区分 fixture 通过和实机支持，不依据上游测试就给 PWE 的 README 扩大支持声明。

预计文件：`SocInfo.swift`、`Sampler.swift`、`DashboardView.swift`、`App.swift`；纯拓扑／驻留率工具进入 CI，硬件读取留在设备验收。

### 6.2 进程：先加内存排序，再补身份安全

**用户收益**：CPU 前六名解决“谁在忙”，内存前六名解决“谁占空间”。大型应用可能 CPU 很低，当前列表会看不到它。

第一轮保持现有六行高度，在标题附近或设置里增加 CPU／内存排序，并明确当前排序。必须先对完整可读取进程集合排序，再截断；不能把 CPU 前八名拿来重排成内存排行榜。

基线键由 PID 升级为 PID + start time，必要时加可读取的执行身份，防止 PID 复用或 exec 后差分串联。新进程、倒退计数和身份变化先建立基线。固定同值排序规则，避免相同数据时名单来回抖动；保留“一核 100%”口径，允许多线程 > 100%。

搜索／排除过滤放第二步：有需求时做展开的进程详情，按 name／PID 搜索；只有拿到过滤需要的完整名字集合后才声称搜索覆盖全部进程。否则只能叫“筛选当前列表”。不把搜索框永久塞进 377 pt 主面板。

上游跨用户进程会使用 `ps` 回退并带 RSS／footprint 差异；PWE 第一轮可保持 libproc 的可读集合，标明权限覆盖，不混入无法比较的数字。是否为更广覆盖调用子进程，先评估代价再决定。

**验收**：低 CPU 大内存进程能出现在内存榜；PID 复用无错误尖峰；进程退出不串号；首次样本有明确基线语义；切换排序、少于六项、中英文及小屏下高度稳定。关闭面板仍延续当前稀疏采样策略。

预计文件：`SystemStats.swift`、`Monitor.swift`、`DashboardView.swift`、本地化表；复用 `Tools/bench` 比较开关面板的真实采样成本。

### 6.3 历史：真实时间轴、窗口均值与峰值

上游已有窗口统计，但其统计窗也是样本数。PWE 应借鉴“当前／均值／最大值”的信息层次，同时解决自己的时间语义。

当前 history 为纯 `[Double]`，刷新间隔改变时保留旧样本；ControlBar 按 `89 × 当前 interval` 标窗口。过去按 1 秒采的点，切到 5 秒后不该被解释成每点 5 秒。

建议保存 `{timestamp, value, status}`；保留 89 个绘图位置，但以真实时间戳决定覆盖时长，设置变化不改写旧时间。先将当前混合间隔显示正确，再按需要加入固定“最近 3 分钟”等时间窗，不为产品增加多个难懂选项。

- 当前值继续在 hero；悬停给同一可见窗口的均值／最大值／覆盖时间，VoiceOver 能读取。
- 功耗均值用有效时间加权；不规则 interval 下不能只除样本个数；Wh 用有效功率区间积分，先在 CLI／诊断提供。
- 缺失值不算零；stale 不无限延伸；睡眠段显示断档；记录覆盖率，不把只测到的局部窗口说成完整统计。
- 用单调时钟算差分，墙上时间用于报告；系统时间调整不能造成功率尖峰。
- CPU／GPU 在明确口径下比较；内存的已用比例曲线不自动成为压力结论。

**验收**：1→5→2 秒切换后真实窗长正确；纯合成序列的均值、最大值和 Wh 可人工复算；缺失／睡眠／时钟调整不造假峰；图与 tooltip 窗口一致。

预计文件：`Monitor.swift`、历史小型值类型、`DashboardView.swift`；不引入数据库或长期日志。

### 6.4 CPU 指标口径：先解释，再考虑切换

PWE 已采 `cpuActive`、`gpuActive` 和逐核 active。先将这些完整导出到 v2，并在 CPU 悬停解释：

- active：采样时间里有多少时间在工作。
- scaled：按实际频率与硬件最大频率加权的占用。
- 进程 CPU：一核时间百分比，不能拿它与整机 scaled 直接对齐。

若再加 active／scaled 设置，所有受影响的 hero、核心条、曲线、tooltip 必须同步，且保存两套历史；不能只切当前数字、历史仍是 scaled。缺失 DVFS 而以 Mach ticks 回退时，应标明来源／口径，不宣称得到硬件 scaled 值。默认维持现有 scaled；高占用仍不自动变成健康故障。

### 6.5 CLI 与复制诊断信息

借鉴 macmon 的有限采样和分层 debug，让用户可直接提供一段可复现证据。

拟议接口（尚未实现）：

```sh
pwemon --json --samples 60 --interval 2 --schema 2
pwemon --probe --debug
pwemon --json --loop --sensors all
```

需求：

- 有限样本包括明确定义的预热；支持间隔、数量、Ctrl-C、参数错误退出码。保留当前 `--probe` 与 `--json --loop` 兼容调用。
- v1 保持原有全传感器行为；新的轻量 v2 默认核心数据，完整传感器通过显式选项开启，避免悄悄删旧消费者期待的数据。
- 共用 Snapshot／encoder，GUI、CLI 使用同一公式；CLI 不创建 NSApplication、菜单栏、更新检查或安装流程。
- stdout 仅数据，诊断与错误走 stderr；JSON 增加 schema version、App 版本、实际采样区间、来源／有效性、动态 tier、热状态等。
- `--probe --debug` 分源报告初始化错误、可选通道数量与映射匹配，不因某一源失败而中断全部诊断。
- 复制诊断信息包含源状态、OS build、App 版本、最后成功采样时间；默认维持当前不含完整进程路径／局域网地址的简洁摘要。详细进程内容由用户显式选择并预览。
- 重复传感器数组沿用 5.1 的无损设计，新增接口说明文档及解析示例。

**验收**：N 条 NDJSON 确实是 N 条；每行可解析；选定间隔按实际时间记录；中文 UI 不改变机器字段；零／未知／过期可区分；旧调用和字段类型保持兼容。

### 6.6 分源降级与验证工具

上游 main 的 #99 刚加入缺少硬件计数器仍可运行的路径。PWE 的 `IOReport?` 已经可选，值得完善的是 SoC 初始化、错误信息和状态显示，不需要照搬一整套 VM 产品。

- 静态机器识别与 DVFS 获取分离；内存／网络等不应因为缺少频率表一起失效。
- 保留硬件能力与临时读取失败的区别：桌面无电池的卡片永久省略，传感器暂时失败的现有行保持高度并显示不可用。
- 无硬件频率时可用 Mach ticks 给整机 active 回退，但不能猜每颗 cpuN 属于哪个 tier；没有依据时不伪造逐层 scaled／MHz。
- 多层 CPU 的 ticks 回退限制要单独设计；上游当前只用于单层，不能把该路径视为通用拓扑方案。
- 原有 Apple Silicon 产品边界维持；Intel 支持不随部分降级自动开放，VM 是之后可选验收场景。

开发工具方面，复用现有 bench／thresholds／portcheck／对照脚本，增加有时限、可取消的 CPU／GPU／ANE 场景 runner。负载工具放在 Tools，不在 GUI 自动启动。未来停止负载只作用于 runner 自己创建的任务；不能杀用户的其他进程。

CI 加入与硬件无关的解析／差分／schema fixtures；不能把可选硬件 probe 的成功或空结果当成完整实机验收。App 发布继续走原本签名、公证、本地 release 路径，不为参考项目改发布权限。

## 7. P2：每进程 GPU 与功耗，先做实验

上游 U4 读取 `rusage_info_v6.ri_energy_nj` 差分得到 W，并从 GPU user clients 累计运行时间获取 GPU 时间占比。它还处理 v6→v4 回退、进程身份、跨用户缺权限等情形。

这能帮助定位“CPU 不忙但哪个程序让 GPU 忙”与持续耗电进程，但直接增加两列会让现有面板变拥挤。

建议先做 `Tools/processprobe` 验证：v6 布局与 SDK、单位、是否持续更新、CPU／GPU workload 是否有合理响应、用户权限覆盖、多 client 重复计数、client 退出导致累计值倒退等。保留数据来源及 unavailable 状态。

通过后，在进程详情或排序模式增加 GPU／功耗，一次只突出当前诊断需要的指标，主卡仍六行。不可读 W 显示 `—`，不能归为零并参与排序。

这些是按进程归属的测量，不能承诺相加等于 SMC 整机 W；GPU 时间占比也不是该进程独占了多少物理 GPU 核心，多个 client／队列可能有重叠。CPU、GPU、功耗的时间窗应对齐，并在帮助中解释口径。

应用分组先后置：可参考 macmon 按过滤词聚合的体验，但按名称子串相加不等于可靠的 App 家族归属；重叠过滤、共享内存、其他用户 RSS 都可能让合计误导。先把单进程测量做好。

## 8. P3：可选 HTTP／Prometheus

macmon 的 `serve` 提供 `/json`、`/metrics`，并有 launchd 安装。适合远程 Mac、持续观察和外部图表；PWE 当前 JSON 已可支撑一次性的本地脚本，暂不需要为功能对齐维护一套服务器。

若确认有“在另一台机器看这台 Mac”的需求，单独做如下范围：

- 显式启用，默认只监听 `127.0.0.1`；不照搬上游默认 `0.0.0.0`。
- 若服务在 GUI 进程内运行，共用现有采样器与最近 Snapshot，不能让每个 HTTP 请求重新采样。
- 指标本身不默认包含进程名称、PID、地址、路径等明细；Prometheus 不可用项省略，并提供源可用性与样本 age 指标。
- 需要限长、超时和并发约束，首个样本未就绪返回 503；导出计量的单位／counter／gauge 正确。
- 跨机访问方式、访问控制与持续运行周期是产品决定；退出 App 是否停服务必须明确。独立 launchd 服务会改变“无后台辅助进程”的承诺，另立范围，不顺手加。

这是推荐设计，未启用监听、未创建 launchd、未发布任何数据。

## 9. 哪些做法不建议照搬

| 做法 | 判断 |
|---|---|
| 重写成 Rust 或捆绑 macmon 可执行文件 | 现有 Swift Core 足以承接算法；增加 runtime／进程与两份采样逻辑，收益不足 |
| 仿制整个 TUI 仪表布局 | 菜单栏面板的宽度、阅读距离与目的不同；保留已建立的信息层级 |
| 更快刷新当作默认升级 | 先测真实 CPU／唤醒成本；现有默认 2 秒与按需采样有证据支持 |
| 把 watt 高／CPU 高直接染成红色 | 违反已有“幅度和系统判定分开”的策略；沿用真实热状态、既定迟滞 |
| 给 ANE／DRAM 增加新的羽毛 | 五通道品牌结构不变；它们属于 PWR 的解释层 |
| 缺读数时趋势补值当成实测 | 原始输出保留缺失与 age；图形平滑和采样值分层 |
| 上游有 M6 fixture 就宣称 PWE 支持 M6 | 上游代码覆盖、PWE fixture 通过与 PWE 实机验证是三层证据 |
| 复制固件研究中的 SIP／boot-args 操作 | 不属于用户产品或本方案必要流程；只学习已知映射与验证方法 |
| 自动 kill／重启占用高的程序 | 当前工具定位是观察、解释及打开活动监视器；保持已有决定 |

## 10. 实施顺序与验收清单

以下是未来执行范围，不是本轮已经开始的实施；不指定 1.7.0 或下一版本号，也不替代 32 号内存方案。

| 阶段 | 交付物 | 依赖／通过条件 |
|---|---|---|
| A：质量地基 | 单项状态／来源、无损 v2 输出、诊断增强 | 合成缺源与零值检查通过；v1 不破坏；五通道不对未知数据作平稳保证 |
| B：CLPC 实验 | 映射证据表、原始日志、无 root 与对照报告 | 有可复现的来源／单位／精度证据；实验失败也须交付明确结论，不能默认接入 |
| C：CLPC 接入与拓扑 | 独立 ANE／DRAM 可用性、CPU 回退选择器、动态 tiers | A；B 对指定机器通过；拓扑 fixtures；实机声明有对应证据 |
| D：用户诊断 | CPU／内存进程榜、身份校验、历史时间轴和均值／峰值 | A；榜单完整排序；窗口口径一致；当前设备 UI 验收 |
| E：可复现工具 | CLI 采样选项、场景 runner、CI fixtures | A；stdout 稳定；可取消；源缺失不阻断其他诊断 |
| F：高级选项 | 进程 GPU／W、active 切换、按源降级扩展 | 单项探针通过；开销与口径明确；不要捆成首轮必须全部完成 |
| G：联网能力 | localhost exporter／可选远程方案 | 有实际使用需求及产品边界决定，另立范围 |

### 对下一轮执行的具体完成定义

1. **源码与接口**：覆盖状态、身份、拓扑及时间差分的 fixtures；新旧 JSON 兼容有可运行消费者证明；上游移植来源记录完整。
2. **功耗实机**：每条轨写明源、单位、OS build、driver、机器、采样窗和对照偏差；无 root 的路径独立运行成功；不把 DRAM 仍缺失隐去。
3. **UI**：中英文／浅深色、笔记本／桌面／无风扇布局；377 pt 宽、小屏滚动；首开、缺源、恢复、排序切换不跳高；实际 NSPopover 而非仅 hosting view 尺寸。
4. **行为**：睡眠／唤醒、修改 interval、进程启动退出／PID 复用、暂时读取失败；无异常尖峰、没有旧值冒充新值。
5. **开销**：同设备同场景对比改前／改后，区分 panel closed／open／all sensors；测 `.utility` 采样 CPU 时间、App 整体 CPU／RSS、Mach ports。可把无新增功能的 closed 路径 CPU 平均增长 ≤ 10% 作为初始工程门槛；先复测基线，不能将旧 README 数字当新机器承诺。
6. **交付状态**：实施、测试、设备验收、打包、发布分别记录。只有未来任务明确授权发布时，才继续 release；本方案的文档完成不等于这些后续步骤完成。

### 可以直接进入后续执行的范围

质量模型、诊断信息、拓扑 fixtures、进程身份修正、CPU／内存排序、时间戳历史和 CLI 有限采样可以按本文细化为任务。CLPC 默认接入要等实验通过；新增远程访问、独立服务、结束进程或重做内存判定不属于此范围。

## 11. 文档中需要同步修正的事实

这些是未来文档修订项，本轮只记录：

- README Credits 的“if you want … on Intel, use macmon”与上游 Apple Silicon 定位不一致，应该移除 Intel 引导；不要将按源降级误称完整 Intel 支持。
- `THIRD-PARTY-NOTICES.md` 提到私有接口变化时“App 降级为 —”；现状实际上是部分 UI 为 `—`，而 CLI／JSON 仍有 0 占位。按 A 阶段结果写准确的接口差异。
- 待 CLPC 通过后更新 [power-rails.md](power-rails.md) 的当前方案，并保留直方图／批次研究为历史记录；不能删掉旧适配与校准依据。
- 为 macmon 跟进记录一个“上游参考提交／本地移植点／验证设备／暂不移植理由”表，放在现有功耗／采样文档附近。无需另起长期监控服务。

## 12. 固定提交参考

本文通过 Git 获取并阅读固定提交源码；部分 GitHub 固定 blob 页面在网页读取工具中返回 cache miss，不影响已读到的 Git 内容。以下为可直接定位的源文件链接。

- **U1：模型、聚合、缺源回退** — [src/metrics.rs](https://github.com/vladkens/macmon/blob/afdd572b12c9c301183569230a476bd4267b638b/src/metrics.rs)，`PowerSources`、`TempMetrics`、`CpuTierMetrics`、`aggregate_ioreport_metrics`、`uses_cpu_ticks`、`Sampler::get_metrics`。
- **U2：CLPC 映射与提取边界** — [src/clpc.rs](https://github.com/vladkens/macmon/blob/afdd572b12c9c301183569230a476bd4267b638b/src/clpc.rs)、[docs/clpc-discovery.md](https://github.com/vladkens/macmon/blob/afdd572b12c9c301183569230a476bd4267b638b/docs/clpc-discovery.md)。
- **U3：硬件与通道构造** — [src/sources.rs](https://github.com/vladkens/macmon/blob/afdd572b12c9c301183569230a476bd4267b638b/src/sources.rs)，`tiers_from_perflevels`、`cpu_tier_infos`、`cfio_add_clpc_channels`、`cfio_append_clpc_channels`；[src/shared.rs](https://github.com/vladkens/macmon/blob/afdd572b12c9c301183569230a476bd4267b638b/src/shared.rs) 的订阅规则。
- **U4：进程计量及身份** — [src/app/procs.rs](https://github.com/vladkens/macmon/blob/afdd572b12c9c301183569230a476bd4267b638b/src/app/procs.rs)，`Counters`、`usage`、`ProcSampler::sample`、rusage v6 与 GPU clients。
- **U5：排序、过滤与聚合** — [src/app/tui/proc_view.rs](https://github.com/vladkens/macmon/blob/afdd572b12c9c301183569230a476bd4267b638b/src/app/tui/proc_view.rs)、[src/app/config.rs](https://github.com/vladkens/macmon/blob/afdd572b12c9c301183569230a476bd4267b638b/src/app/config.rs)。
- **U6：历史与指标口径** — [src/app/tui/store.rs](https://github.com/vladkens/macmon/blob/afdd572b12c9c301183569230a476bd4267b638b/src/app/tui/store.rs)，`FreqStore`、`PowerStore`、`TempStore`；config 中的 `RatioMode`。
- **U7：CLI 能力与发布边界** — [src/app/main.rs](https://github.com/vladkens/macmon/blob/afdd572b12c9c301183569230a476bd4267b638b/src/app/main.rs)、[changelog.md](https://github.com/vladkens/macmon/blob/afdd572b12c9c301183569230a476bd4267b638b/changelog.md)、[Cargo.toml](https://github.com/vladkens/macmon/blob/afdd572b12c9c301183569230a476bd4267b638b/Cargo.toml)。
- **U8：诊断与验证工具** — [src/diagnostics.rs](https://github.com/vladkens/macmon/blob/afdd572b12c9c301183569230a476bd4267b638b/src/diagnostics.rs)、[src/app/find_clpc.rs](https://github.com/vladkens/macmon/blob/afdd572b12c9c301183569230a476bd4267b638b/src/app/find_clpc.rs)、[src/app/stress.rs](https://github.com/vladkens/macmon/blob/afdd572b12c9c301183569230a476bd4267b638b/src/app/stress.rs)。
- **U9：HTTP 与 Prometheus** — [src/app/serve.rs](https://github.com/vladkens/macmon/blob/afdd572b12c9c301183569230a476bd4267b638b/src/app/serve.rs)、[examples/grafana](https://github.com/vladkens/macmon/tree/afdd572b12c9c301183569230a476bd4267b638b/examples/grafana)。
- **上游原始入口** — [macmon README](https://github.com/vladkens/macmon)、[v0.9.0 tag](https://github.com/vladkens/macmon/tree/v0.9.0)。后续实际移植前重新核对上游状态；本文固定提交保留作为方案依据。
