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

该插件执行的是设备级断网，不是网址分类、域名过滤或内容审查。

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

- OpenWrt 22.03 或更新版本
- LuCI
- UCI
- firewall4
- nftables
- 包含 `meta hour` 和 `meta day` 支持的 nft 版本

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

如果暂时没有 OpenWrt SDK/buildroot，也可以在当前 Linux 主机直接组装
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
`accept`，仅命中规则的报文会被丢弃。

## 页面使用

1. 打开“网络 -> 家长控制”。
2. 先查看顶部“系统兼容性”提示，确认没有严重兼容性问题。
3. 打开全局开关。
4. 在受控设备列表中添加设备，选择 MAC 并填写备注。
5. 点击“管理时段”，在弹窗中添加一个或多个时间段。
6. 为每个时间段勾选生效星期，然后点击弹窗“确定”。
7. 点击页面底部的“保存并应用”。
8. 在页面底部“当前防火墙规则”中查看 `parental_block` 规则。

注意：这里的“生效日期”按星期几处理，不是具体日历日期。

页面顶部的“系统兼容性”面板会检查 OpenWrt 版本、`fw4`、`nft`、
`inet fw4` 表、防火墙 include 的 `enabled/reload/type` 以及规则脚本是否存在。
检测到严重问题时会在保存前给出红色提示。

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
logread -e parental
```

如需确认规则是否实际生效，应使用受控设备在配置时段内验证网络访问，而不仅是
检查规则是否存在。

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
- 命中规则会阻断该设备的全部流量，包括访问路由器管理页和局域网服务。
- 跨午夜时段会拆成两条 nftables 规则，星期会顺延到次日。
- `23:59` 边界依赖目标 nftables 对 `meta hour` 结束时间的解释，需要在目标机验证。
- 时间按路由器本地时区解释，页面没有时区提示或校验。
- 不提供域名、应用或内容级别的访问控制。
- 跨午夜结束边界和浏览器时间控件仍需在目标 OpenWrt 版本上回归验证。

具体缺陷和待验证项见 `docs/BUG_ANALYSIS.md`。
