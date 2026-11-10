# 功能缺陷审查

## 审查范围

本次审查基于以下运行文件和打包文件：

- `files/usr/lib/lua/luci/controller/parental.lua`
- `files/usr/lib/lua/luci/model/cbi/parental_script.lua`
- `files/etc/config/parental`
- `files/etc/config/firewall.parental`
- `Makefile`
- `scripts/build-ipk.sh`

已完成：

- Shell 语法检查通过。
- 两个 Lua 文件分别通过 Lua 语法解析。
- 弹窗 JavaScript 通过 Node 语法检查。
- 使用本机无头 Chrome 验证了日期选项对齐和浅色/深色主题渲染。
- 使用模拟的 UCI/nft 命令验证了多时段、旧配置兼容和跨午夜规则生成。

未完成：

- 没有在目标 OpenWrt 设备上执行 `fw4 reload`。
- 没有在真实 LuCI 页面中验证弹窗、动态行和主题兼容性。
- 没有用真实客户端验证 nftables 规则的实际命中时间。

## 优先级汇总

| ID | 级别 | 状态 | 问题 |
| --- | --- | --- | --- |
| P0-01 | 高 | 确认 | 当前规则同时阻断经过路由器的内网和外网流量，不符合“只禁外网”的目标 |
| P0-02 | 高 | 待验证 | Passwall TRANSPARENT/TUN 改写可能早于家长控制规则，导致外网流量绕过 |
| P0-03 | 高 | 待实现 | 允许内网后，受控设备可直连 Passwall 显式代理端口绕过限制 |
| P1-01 | 高 | 确认 | 已配置但当前不在 DHCP/ARP 中的设备无法正常从 UI 选择，存在配置丢失风险 |
| P1-02 | 高 | 确认 | 防火墙重载或 nftables 命令失败时，页面仍可能表现为保存成功 |
| P1-03 | 高 | 待验证 | 动态时段依赖隐藏的 `timeslots` 字段，需确认 CBI 提交和旧配置迁移行为 |
| P1-04 | 高 | 待验证 | flow offload 可能让管控开始前建立的连接继续运行 |
| P1-05 | 高 | 确认 | OpenWrt 23.05+ 缺少 `luci-compat`/`luci-lua-runtime` 依赖，页面可能无法加载 |
| P2-01 | 中 | 待验证 | 时段编辑完全依赖内联 JavaScript，主题、动态新增行和无 JS 环境需要实测 |
| P2-02 | 中 | 待验证 | 跨午夜规则使用 `23:59` 分段，且 `23:59 -> 00:00` 会生成零长度规则 |
| P2-03 | 中 | 确认 | `timeslots` 为空时会回退旧字段，手工编辑时可能意外恢复旧时段 |
| P2-04 | 中 | 确认 | 序列化字符串是内部格式，手工查看和编辑不友好 |
| P2-05 | 低 | 确认 | “在线”状态只依据 ARP 表，可能是过期数据 |
| P2-06 | 低 | 确认 | 没有计数、命中日志或页面诊断 |
| P3-01 | 低 | 已完成 | 已补充 Makefile、uci-defaults、postinst/prerm 和 include 辅助脚本 |

## 已完成的改动

本轮已把固定的上午/下午两个时段改为设备内动态时段：

- 每个设备可有任意数量的时间段。
- 每个时间段独立保存开始时间、结束时间和生效星期。
- 页面改为“管理时段”弹窗，可新增、删除和编辑多个时段。
- 空星期不再依赖隐式语义：新时段默认勾选七天，用户取消全部日期时会阻止保存。
- 开始时间晚于结束时间时按跨午夜处理，星期自动顺延到次日。
- 旧配置的 `start_time_am`、`stop_time_am`、`start_time_pm`、
  `stop_time_pm`、`weekdays` 仍可读取。
- 全局关闭时删除规则链；没有有效规则时保留空链，便于诊断。
- 显式加载 `nixio` 和 `luci.util`，并收紧了 CBI 控件变量作用域。
- 时段弹窗的日期选项改为独立胶囊布局，修复复选框和文字对齐问题。
- 时段弹窗会跟随 LuCI 浅色/深色主题切换。
- 系统兼容性改为默认收起，只显示通过/不通过状态，展开后查看详细信息。

## P0-01：当前规则无法实现“允许内网、禁止外网”

**位置**

- 规则链创建：`files/etc/config/firewall.parental` 中的
  `create_parental_chain()`
- 规则生成：`files/etc/config/firewall.parental` 中的 `add_rule()`

**现象**

当前 `parental_block` 链挂在 `inet fw4` 的 `prerouting` hook。
命中受控 MAC、时间和星期后直接执行 `drop`，规则没有判断目标属于内网还是外网。

**影响**

- 受控设备无法访问路由器管理页、DHCP 和 DNS。
- 经过路由器转发的跨 VLAN、跨网段内网流量也会被阻断。
- 同一二层网桥内的直接通信不经过该 hook，仍然可以访问。

**建议**

- 明确区分“当前行为”和“目标行为”，在实现前不要把允许内网写成已完成。
- 目标规则只阻断外网目标，不阻断路由器本机和允许的内网网段。
- 必须同时覆盖 IPv4 和 IPv6。

## P0-02：Passwall 的透明代理和 TUN 模式可能改变匹配结果

**现象**

Passwall 可能通过 REDIRECT、TPROXY 或 TUN 在 `prerouting` 阶段改写流量：

- REDIRECT/TPROXY 可能把公网目标改成路由器本地代理端口。
- TUN 模式可能把流量转发到虚拟接口。
- 真正连接代理服务器的是路由器本机进程，源 MAC 已不再属于受控设备。

因此，只把规则移动到 `forward` 链并匹配 WAN 输出接口，无法保证拦截这些流量。
当前全量 `prerouting drop` 是否能拦住 Passwall，取决于家长控制链和 Passwall
规则的实际执行顺序，尚未在目标机验证。

**建议**

- 保留按 MAC、时间和星期识别的能力，但改为在 Passwall 改写前判断原始目标。
- 生成明确的路由器本机与内网允许集合，外网目标在代理分流前丢弃。
- 检查完整 `nft list ruleset`，确认家长控制规则早于 Passwall 的
  REDIRECT/TPROXY/TUN 分流。
- 不要将 WAN 接口名写死为 `wan`，需兼容 PPPoE、多 WAN、VPN 和 IPv6。

## P0-03：显式代理端口可形成绕过路径

**现象**

如果客户端的 HTTP/SOCKS 代理直接配置为路由器内网地址和 Passwall 端口：

```text
受控设备 -> 路由器内网 IP:Passwall 端口 -> 外网
```

目标规则如果使用“内网目标均允许”的策略，会把这条连接视为内网访问。

**影响**

- 受控设备可在管控时段继续通过显式代理访问外网。
- 仅限制 WAN 转发出口无法解决该问题。

**建议**

- 在管控时段禁止受控 MAC 访问 Passwall 的 HTTP/SOCKS 监听端口。
- 或者使用 Passwall 自身访问控制，并确保其状态能与家长控制时段同步。
- 允许内网代理、NAS 代理等设备时，需要评估它们能否替受控设备访问外网。

## P1-04：flow offload 可能保留管控前的连接

**现象**

受控设备在管控时段开始前建立的连接可能已经进入软件或硬件 flowtable。
后续报文可能不再逐包经过 `parental_block` 链，连接会持续到流过期。

**影响**

即使静态 nftables 规则正确，视频、游戏或下载连接也可能在管控开始后继续。

**建议**

- 在目标机分别关闭和开启 flow offload 验证。
- 如需保证时段边界立即生效，应清理相关 conntrack/flow，或明确要求关闭相关
  流卸载功能。

## P1-05：OpenWrt 23.05+ 缺少 LuCI Lua 兼容依赖

**位置**

- `Makefile` 中的 `DEPENDS`
- `scripts/build-ipk.sh` 生成的 `Depends` 字段

**现象**

插件使用旧式 Lua Controller/CBI。OpenWrt 22.03 的 `luci-base` 自带 Lua
运行时，但 23.05 及更新版本改为 ucode，旧式 CBI 由 `luci-compat` 提供，
并进一步依赖 `luci-lua-runtime`。

当前 Makefile 和直接生成的 ipk 都只声明 `luci-base`、`firewall4` 和
`nftables`，没有声明兼容运行时。

**影响**

- 包可能可以安装，但页面的 Controller/CBI 无法正常加载。
- `require "nixio"` 或旧式 CBI 模板可能加载失败。

**建议**

- 明确目标 OpenWrt 版本范围。
- 对 23.05 及更新版本显式声明 `luci-compat` 或对应 Lua 运行时依赖。
- 在目标版本上验证菜单加载、页面提交和 `nixio` 可用性。

## P1-01：离线设备无法从 UI 正常添加或保留

**位置**

- 设备发现：`parental_script.lua` 中读取 `/tmp/dhcp.leases` 和
  `/proc/net/arp` 的逻辑
- MAC 下拉选项：`parental_script.lua` 中的 `mac_option`

**现象**

页面只把 `/tmp/dhcp.leases` 和 `/proc/net/arp` 中出现的 MAC 加入候选列表。
如果设备断电、租约过期、使用静态 IP 且当前不在 ARP 表中，页面通常没有
办法输入一个未发现的 MAC。

**影响**

- 不能提前给一台离线设备配置家长控制。
- 已配置设备在租约过期后再次打开页面时，原 MAC 可能不在下拉选项中。
- 如果 CBI 的 `Value` 控件在提交时只能提交候选项，已有设备记录存在被空值
  覆盖的风险。这个具体保存行为需要在目标机上实测。

**建议**

- 增加“手动输入 MAC”入口，或把 MAC 字段改成可编辑输入框。
- 把已存在于 `/etc/config/parental` 的 MAC 始终追加到候选列表。
- 增加持久化设备清单，而不是只依赖瞬时 DHCP/ARP 数据。

## P1-02：规则应用失败不会反馈到页面

**位置**

- 重载命令：`parental_script.lua` 中的 `m.on_after_commit()`
- 链创建：`firewall.parental` 中的 `create_parental_chain()`
- 规则追加：`firewall.parental` 中的 `add_rule()`

**现象**

`os.execute("fw4 reload ...")` 的返回值没有被检查。Shell 脚本虽然会记录
`nft create` 和 `nft add rule` 的失败，但函数返回值和整体结果没有传回 LuCI。

因此以下情况仍可能被页面表现为“保存成功”：

- `nft` 不存在或版本不支持 `meta hour`。
- `inet fw4` 表不存在。
- 某个时段生成了无效规则。
- `/etc/config/firewall` 中 include 被禁用。
- `fw4 reload` 失败，备用 firewall 重启也失败。

**建议**

- `os.execute` 后检查退出状态并提示。
- Shell 脚本记录并汇总失败规则数。
- 成功保存后重新读取链，并校验期望设备数和规则数。
- 在页面上明确展示“配置已保存，但规则应用失败”。

## P1-03：动态时段依赖隐藏字段，需验证 CBI 提交行为

**位置**

- 隐藏字段：`parental_script.lua` 中的 `slots_value`
- 弹窗写回：`parental_script.lua` 中的 `parentalCloseSlots()`

**现象**

弹窗编辑的结果会序列化为：

```text
开始时间|结束时间|生效星期;开始时间|结束时间|生效星期
```

然后写入隐藏的 CBI `timeslots` 输入框。该字段没有 `wpatt`，由弹窗负责校验。

需要在目标机确认：

- 输入框名称确实是 `cbid.parental.<section>.timeslots`。
- 动态新增设备行后，隐藏字段仍能被 CBI 正确提交。
- 旧配置在首次保存时能把旧字段迁移为 `timeslots`。
- 清空所有时段后保存的是内部标记 `none`，而不是空字符串。

**影响**

如果字段名称或 CBI 提交流程不一致，页面会显示成功但数据没有写入，或者旧
配置无法迁移。这是本轮改动最需要优先验证的功能点。

## P2-01：时段编辑器依赖内联 JavaScript

**位置**

- 弹窗和脚本：`parental_script.lua` 中的 `render_slot_helpers`

**现象**

“管理时段”按钮、弹窗、时间校验和隐藏字段写回都依赖内联 JavaScript。

需要验证：

- 没有设备时新增第一行后，按钮和弹窗是否正常。
- CBI 动态新增行时，是否还能找到对应的隐藏字段。
- LuCI Bootstrap/Material 等主题下，弹窗是否正常显示。
- 浏览器禁用内联脚本时，页面是否完全无法编辑时段。

**建议**

如果目标环境存在主题兼容问题，可以把弹窗改造成 LuCI 标准弹窗组件，或增加
一个文本输入降级入口。

## P2-02：跨午夜分段边界需要目标机验证

**位置**

- 跨午夜拆分：`firewall.parental` 中的 `add_slot()`

**现象**

例如周五 `22:00-06:00` 会生成两条规则：

```text
22:00-23:59 Friday
00:00-06:00 Saturday
```

这里使用 `23:59` 作为当天结束边界。需要确认目标 nftables 是否把
`22:00-23:59` 解释为覆盖 23:59 这一分钟，否则可能留下一个极短的时间缺口。

此外，用户配置 `23:59 -> 00:00` 时当前算法会拆成
`23:59-23:59` 和 `00:00-00:00`。两者在逻辑上应覆盖一分钟，但实际生成了
零长度时间范围，可能失败或完全不生效。

**建议**

在目标机用 `22:00-06:00` 规则实际测试 23:59:30 和 00:00:10 两个时间点。

## P2-03：`timeslots` 为空会回退旧配置

**位置**

- 回退逻辑：`firewall.parental` 中的 `handle_device()`
- Lua 回退逻辑：`parental_script.lua` 中的 `get_slots()`

**现象**

为了兼容旧版本，`timeslots` 缺失或为空时会读取旧的上午/下午字段。

正常通过新版页面清空所有时段时，页面会写入 `timeslots 'none'`，不会触发
回退。但如果手工把 `timeslots` 删掉或写成空字符串，而旧字段仍然存在，
旧时段可能重新生效。

**建议**

- 文档明确说明手工配置使用 `none` 表示无时段。
- 后续版本可以在首次迁移后删除旧字段，减少歧义。

## P2-04：序列化配置不便于手工维护

**位置**

- `README.md` 配置模型示例

**现象**

当前配置示例为：

```uci
option timeslots '08:00|11:50|Saturday Sunday;14:00|22:00|Saturday Sunday'
```

这是可解析的内部格式，但不像 UCI 列表那样直观。手工编辑时要严格保持
`|` 和 `;` 的分隔结构。

**建议**

后续可以考虑改成多个 `config timeslot` 节点，或使用 UCI list；本轮为了
减少 CBI 动态列表的兼容风险，暂时使用单字段序列化。

## P2-05：在线状态可能过期

**位置**

- `parental_script.lua` 中的在线状态 `cfgvalue`

**现象**

设备在线状态来自 `/proc/net/arp`。ARP 表项不一定会立即消失，因此页面可能
把已经离线的设备显示为在线。

这只是展示准确性问题，不影响底层 MAC 规则本身。

## P2-06：缺少命中统计和失败诊断

当前只能看到规则文本，无法看到：

- 某设备今天是否命中过规则。
- 某个时间段是否实际阻断过连接。
- 哪条规则应用失败。
- `fw4 reload` 的完整错误输出。

建议后续增加 counter 规则、日志记录或页面诊断区。

## P3-01：软件包工程

已补充 `Makefile`、`uci-defaults`、`postinst/prerm` 和
`files/usr/lib/parental/firewall-include.sh`。后续需要在目标 buildroot 中
实际编译安装包并做升级/卸载回归。

## 已验证项

- `sh -n files/etc/config/firewall.parental` 通过。
- `luac -p` 检查两个 Lua 文件通过。
- 弹窗 JavaScript 通过 `node --check`。
- `scripts/build-ipk.sh` 使用 `bsdtar --format ar` 生成了有效的
  `dist/luci-app-parental_1.0.0-1_all.ipk`。
- 模拟 nft 命令验证：
  - 多时段会生成多条规则。
  - 每个时段使用自己的星期。
  - `22:00-06:00 Friday` 会生成周五晚和周六凌晨两条规则。
  - 旧配置没有 `timeslots` 时仍能生成原来的两段规则。
  - 星期中的逗号、连续空格可以被规范化。

## 目标机验证清单

1. 构建并安装 `luci-app-parental`，执行 `fw4 reload`。
2. 在 LuCI 中添加多个时段并保存，执行 `uci show parental` 检查 `timeslots`。
3. 打开两个不同设备，确认弹窗只修改当前设备。
4. 清空某个设备的所有时段，确认保存为 `none` 且该设备没有规则。
5. 删除 `timeslots` 但保留旧字段，验证旧配置兼容。
6. 设置 `22:00-06:00`，在 22:30、23:59、00:00、05:30 分别测试。
7. 禁用全局开关，确认 `parental_block` 被删除。
8. 重启防火墙并重复 reload，确认没有重复规则。
9. 在管控时段验证受控设备仍可访问路由器管理页、DHCP、DNS 和跨 VLAN 内网资源。
10. 使用 Passwall REDIRECT/TPROXY 模式验证外网目标在代理改写前被阻断。
11. 使用 Passwall TUN 模式验证外网目标不会被虚拟接口绕过。
12. 将受控设备显式配置为 Passwall HTTP/SOCKS 代理，确认管控时段无法使用。
13. 对比关闭和开启 flow offload 时，管控前已建立连接是否仍可继续。
14. 执行 `nft list ruleset`，记录家长控制链与 Passwall 链的实际先后顺序。
