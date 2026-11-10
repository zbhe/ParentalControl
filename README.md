# OpenWrt 家长控制插件

## 项目说明

本目录是完整的 OpenWrt 插件开发目录，采用 OpenWrt package 的 `files/`
安装布局，并包含 Makefile、安装时防火墙 include 注入脚本和卸载清理逻辑。

当前实现提供以下能力：

- 在 LuCI 中维护全局开关。
- 按 MAC 地址维护受控设备。
- 为每个设备动态添加、修改和删除多个禁止联网时段。
- 为每个时段独立配置生效星期。
- 支持开始时间晚于结束时间的跨午夜时段。
- 页面加载时检查 OpenWrt/firewall4/nftables、防火墙 include 和规则脚本状态。
- 保存后重新加载防火墙，并展示当前 nftables 规则链。
- 时段编辑弹窗会跟随 LuCI 浅色/深色主题切换。

该插件执行的是设备级网络管控，不是网址分类、域名过滤或内容审查。

## 当前行为与目标行为

当前版本在匹配到管控时段后，会按设备源 MAC 在
`inet fw4 parental_block` 链中丢弃报文。该链目前位于 `prerouting`，
因此在管控时段内，经过路由器的内网访问和外网访问都会被阻断。

后续目标行为是：

- 允许受控设备访问路由器本机服务和内网资源。
- 禁止受控设备访问 WAN、VPN 等外网出口。
- 兼容 Passwall 的透明代理、TUN 和显式代理模式。

目标行为尚未实现。阅读当前配置和验证结果时，不要把目标行为与现有代码行为
混为一谈。

## 当前管控范围

| 流量路径 | 当前行为 | 目标行为 |
| --- | --- | --- |
| 路由器管理页、DHCP、DNS | 管控时段阻断 | 允许 |
| 同一二层网桥内的设备直连通信 | 完全不经过该规则 | 允许 |
| 跨 VLAN 或跨网段、经路由器转发的内网流量 | 管控时段阻断 | 允许 |
| 直接经 WAN 转发的外网流量 | 管控时段阻断 | 阻断 |
| Passwall 透明代理或 TUN 转发 | 取决于家长控制链与 Passwall 的执行顺序 | 在代理分流前阻断外网目标 |
| 受控设备显式连接 Passwall 的 HTTP/SOCKS 端口 | 当前全量丢弃时通常会被阻断 | 需要单独限制代理监听端口 |

同一二层网桥内的设备通信由交换机直接转发，不经过 `inet fw4` 的
`prerouting` hook，因此该规则无法拦截这类流量。

## 目录结构

```text
.
├── Makefile
├── README.md
├── docs
│   └── BUG_ANALYSIS.md
├── scripts
│   └── build-ipk.sh
└── files
    ├── etc
    │   ├── config
    │   │   ├── firewall.parental   # firewall4 include 脚本
    │   │   └── parental            # 插件 UCI 配置
    │   └── uci-defaults
    │       └── 90-parental         # 安装/首次启动时添加 include
    └── usr
        └── lib
            ├── lua
            │   └── luci
            │       ├── controller
            │       │   └── parental.lua
            │       └── model
            │           └── cbi
            │               └── parental_script.lua
            └── parental
                └── firewall-include.sh
```

`files/` 下的路径是软件包源码布局；安装到目标机时去掉 `files/` 前缀。

| 文件 | 作用 |
| --- | --- |
| `Makefile` | OpenWrt package 构建和安装定义 |
| `scripts/build-ipk.sh` | 无 SDK 时直接组装 all-arch ipk |
| `files/usr/lib/lua/luci/controller/parental.lua` | 注册 LuCI 菜单和 CBI 页面入口 |
| `files/usr/lib/lua/luci/model/cbi/parental_script.lua` | 设备列表、动态时段编辑、配置保存和规则展示 |
| `files/etc/config/parental` | 全局开关及受控设备配置，作为 conffile 保留 |
| `files/etc/config/firewall.parental` | 读取 UCI 配置并创建 nftables 规则 |
| `files/etc/uci-defaults/90-parental` | 首次启动时幂等添加 firewall include |
| `files/usr/lib/parental/firewall-include.sh` | 添加/移除 include 的公共脚本 |

## 运行依赖

- 设计目标：OpenWrt 22.03 或更新版本
- LuCI Lua/CBI 运行时
- UCI
- firewall4
- nftables
- 包含 `meta hour` 和 `meta day` 支持的 nft 版本

OpenWrt 22.03 的 `luci-base` 自带 Lua 运行时。23.05 及更新版本改为 ucode
运行时，旧式 Lua CBI 由 `luci-compat`/`luci-lua-runtime` 提供。当前 Makefile
只声明了 `luci-base` 依赖，因此在 23.05 及更新版本上安装后，页面可能无法加载。

## 防火墙接线

软件包安装后会自动把以下 include 写入 `/etc/config/firewall`，不需要用户
手工编辑：

```uci
config include
	option type 'script'
	option path '/etc/config/firewall.parental'
	option enabled '1'
	option reload '1'
```

`reload '1'` 用于确保执行 `fw4 reload` 时也会重新运行该脚本。

安装脚本会按 `path` 查找已有 include，避免重复添加；卸载时会删除该 include。
如果手工部署，也可以自行添加同样的配置，然后执行：

```sh
uci commit firewall
fw4 reload
```

## 构建与安装

将本目录作为 OpenWrt package 源码目录使用，例如放到 buildroot 的
`package/luci-app-parental`，然后执行：

```sh
make package/luci-app-parental/compile V=s
```

生成的安装包类似：

```text
bin/packages/<arch>/base/luci-app-parental_1.0.0-1_all.ipk
```

安装到目标机：

```sh
opkg install luci-app-parental_1.0.0-1_all.ipk
```

如果目标系统使用 `apk` 包管理器，则按对应版本的 `apk add` 方式安装。

如果暂时没有 OpenWrt SDK/buildroot，也可以在 Linux 或 macOS 主机直接组装
`all` 架构 ipk：

```sh
./scripts/build-ipk.sh
```

脚本会生成：

```text
dist/luci-app-parental_1.0.0-1_all.ipk
```

该方式只负责按 OpenWrt ipk 结构打包，不包含 SDK 的依赖检查和目标架构编译；
正式发布仍建议使用 OpenWrt buildroot 构建。

脚本优先使用 `bsdtar --format ar` 生成标准 ipk；没有 `bsdtar` 时回退到系统
`ar`。macOS 使用系统 `ar` 生成的归档不能作为有效 ipk，因此 macOS 主机需要
安装 `bsdtar`。

安装流程：

- `/etc/config/parental` 作为 conffile 安装，升级时保留用户配置。
- `/etc/config/firewall.parental` 以可执行脚本安装。
- `90-parental` 在首次启动时幂等添加 firewall include。
- `postinst` 在运行中的系统安装时立即执行相同操作并重载防火墙。
- `prerm` 卸载时删除 include 并重载防火墙。

## 配置模型

软件包默认安装的配置为全局关闭状态，首次使用需要在页面中启用并添加设备。
示例：

```uci
config globals 'settings'
	option enabled '1'

config device
	option enable '1'
	option mac '9e:d2:d9:76:9d:99'
	option name 'iPadPro'
	option timeslots '08:00|11:50|Saturday Sunday;14:00|22:00|Saturday Sunday'
```

字段说明：

| 字段 | 含义 |
| --- | --- |
| `globals.settings.enabled` | 全局总开关，`0` 时不生成阻断规则 |
| `device.enable` | 单设备开关 |
| `device.mac` | 受控设备 MAC，脚本会转为小写 |
| `device.name` | 备注，仅用于展示 |
| `device.timeslots` | 动态时段列表，内部格式见下文 |

`timeslots` 的格式为：

```text
开始时间|结束时间|生效星期;开始时间|结束时间|生效星期
```

例如：

```text
08:00|11:50|Saturday Sunday;22:00|06:00|Friday
```

表示：

- 每周六、周日 `08:00-11:50` 禁止联网。
- 每周五 `22:00` 到次日（周六）`06:00` 禁止联网。

星期的值为英文名称，空格分隔；`*` 或空值表示每天。没有时段时使用内部标记
`none`，避免误回退到旧配置。页面会自动生成该格式，通常不需要手工编辑。

旧版本的 `start_time_am`、`stop_time_am`、`start_time_pm`、
`stop_time_pm`、`weekdays` 仍可被读取。新版页面保存时预期把旧值迁移到
`timeslots`，该保存行为需要在目标机确认。

## 运行流程

```text
LuCI 页面
  -> 保存 /etc/config/parental
  -> m.on_after_commit()
  -> fw4 reload
  -> 执行 /etc/config/firewall.parental
  -> 删除并重建 inet fw4 parental_block 链
  -> 按设备追加 nftables drop 规则
  -> LuCI 重新读取 parental_block 链并展示
```

生成的规则形式类似：

```text
ether saddr <mac> meta hour <start>-<stop> meta day { <weekdays> } drop
```

规则链挂在 `inet fw4` 的 `prerouting`、`priority mangle` 位置，策略为
`accept`，仅命中该 MAC、时间与星期条件的报文会被丢弃。该条件没有区分内网
和外网目标，因此会同时阻断经过路由器的内网访问。

## 目标方案：允许内网、禁止外网

目标方案不能只把规则移动到 `forward` 链并匹配 WAN 出口。该做法在普通 NAT
场景下可能有效，但无法覆盖 Passwall 的原目标改写和显式代理连接。

实现时需要遵循以下约束：

1. 在 Passwall 改写目标或转发到本地代理端口之前识别受控设备的原始目标。
2. 始终允许路由器本机地址、LAN 接口地址和全部内网网段。
3. 阻断不属于允许集合的 IPv4、IPv6 目标。
4. 不要只依赖 RFC1918 私网地址列表，应结合当前路由、接口和配置生成允许集合。
5. 需要兼容动态 WAN、PPPoE、多 WAN、VPN 和 IPv6，不能写死单个 WAN 接口名。
6. 规则执行顺序必须早于 Passwall 的 REDIRECT、TPROXY 或 TUN 分流。

允许访问路由器随后也意味着受控设备可能打开 LuCI 登录页，管理员密码必须足够强。
如果内网中的 NAS、代理或其他服务能够代替设备访问外网，也可能形成绕过路径。

### Passwall 兼容性约束

Passwall 常见的流量改写方式包括：

- REDIRECT/TPROXY：受控设备发往公网目标的报文先被转发到路由器本地代理端口。
- TUN：报文被转发到虚拟网络接口，而不是直接使用 WAN 接口。
- 显式代理：设备直接连接路由器内网 IP 上的 HTTP/SOCKS 监听端口。

仅匹配最终 WAN 输出接口无法可靠识别前两种情况，因为真正连接代理服务器的是
路由器本机进程，报文源 MAC 已不再属于受控设备。显式代理连接的目标本身又是
内网地址，因此还需要禁止受控设备在管控时段访问 Passwall 的监听端口。

在目标机上必须检查完整 nftables 规则顺序。如果 Passwall 已经先把公网目标改写为
本地代理端口，后续规则只能看到本地端口，无法再判断原始外网目标。

### 流卸载与已建立连接

软件或硬件 flow offload 可能让管控时间前已经建立的连接绕过后续 nftables
检查。即使新流量规则正确，流表内的现有连接也可能继续运行直至过期。目标实现
需要决定是否在时段边界清理相关 conntrack/flow，或者明确要求关闭相关流卸载。

## 页面使用

1. 打开“网络 -> 家长控制”。
2. 先确认顶部“系统兼容性”显示绿色“兼容性检查通过”；如有问题可展开查看详情。
3. 打开全局开关。
4. 在受控设备列表中添加设备，选择 MAC 并填写备注。
5. 点击“管理时段”，在弹窗中添加一个或多个时间段。
6. 为每个时间段勾选生效星期，然后点击弹窗“确定”。
7. 点击页面底部的“保存并应用”。
8. 在页面底部“当前防火墙规则”中查看 `parental_block` 规则。

注意：这里的“生效日期”按星期几处理，不是具体日历日期。

页面顶部的“系统兼容性”面板会检查 OpenWrt 版本、`fw4`、`nft`、
`inet fw4` 表、防火墙 include 的 `enabled/reload/type` 以及规则脚本是否存在。
状态默认收起，只显示绿色“兼容性检查通过”或红色“兼容性检查不通过”；
点击状态可以展开系统信息和具体问题列表。

页面中的设备列表来自：

- `/tmp/dhcp.leases`：DHCP 租约设备。
- `/proc/net/arp`：当前 ARP 表中的设备。

这两个来源只用于展示和选择，不是完整的设备资产库。

## 验证命令

在目标 OpenWrt 设备上执行：

```sh
uci show parental
uci show firewall | grep -B2 -A5 firewall.parental
fw4 check
fw4 reload
nft list chain inet fw4 parental_block
nft list ruleset
logread -e parental
```

如需确认规则是否实际生效，应使用受控设备在配置时段内验证网络访问，而不仅是
检查规则是否存在。涉及 Passwall 时，还要验证 `nft list ruleset` 中家长控制链
与 Passwall REDIRECT/TPROXY/TUN 链的先后顺序。

## 升级、卸载与回滚

- 升级时 `/etc/config/parental` 作为 conffile 保留，代码文件和防火墙脚本更新。
- 升级或重新安装会重新执行 include 检查，不会重复添加 include。
- 卸载会删除 include 并重载防火墙，但保留 `/etc/config/parental` 用户配置。

```sh
opkg remove luci-app-parental
```

如需彻底清理用户配置，再手工删除：

```sh
rm -f /etc/config/parental
```

手动回滚时至少需要恢复代码文件、`/etc/config/firewall.parental` 和
`/etc/config/firewall`，然后执行：

```sh
uci commit parental
uci commit firewall
fw4 reload
```

## 当前限制

- 仅按 MAC 地址识别设备，修改或随机化 MAC 可以绕过。
- 当前包依赖未包含 `luci-compat`/`luci-lua-runtime`，在 OpenWrt 23.05
  及更新版本上页面可能无法加载。
- 当前命中规则会阻断经过路由器的全部 IP 流量，包括路由器管理页和跨网段
  局域网访问。
- 同一二层网桥内的设备直连流量不经过 `inet fw4`，不会被当前规则阻断。
- “允许内网、禁止外网”的目标行为尚未实现。
- 当前规则与 Passwall 的执行顺序未在目标机验证，透明代理和 TUN 流量是否会被
  当前规则阻断取决于实际链路顺序。
- 面向 Passwall 的目标方案不能在代理改写之后再按 WAN 出口判断，还需要阻止
  受控设备直接访问 Passwall 的显式代理端口。
- flow offload 可能让管控开始前建立的连接继续运行，需要在目标机验证并制定清理
  策略。
- 跨午夜时段会拆成两条 nftables 规则，星期会顺延到次日。
- `23:59` 边界依赖目标 nftables 对 `meta hour` 结束时间的解释，需要在目标机验证。
- 时间按路由器本地时区解释，页面没有时区提示或校验。
- 不提供域名、应用或内容级别的访问控制。
- 跨午夜结束边界和浏览器时间控件仍需在目标 OpenWrt 版本上回归验证。

具体缺陷和待验证项见 `docs/BUG_ANALYSIS.md`。
