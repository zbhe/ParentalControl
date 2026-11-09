local m, s
local nixio = require "nixio"
local fs = require "nixio.fs"
local util = require "luci.util"
local sys = require "luci.sys"

local render_slot_helpers
local slot_helpers_emitted = false

local DAYS = {
    "Monday", "Tuesday", "Wednesday", "Thursday",
    "Friday", "Saturday", "Sunday"
}
local DAY_LABELS = {
    Monday = "周一", Tuesday = "周二", Wednesday = "周三",
    Thursday = "周四", Friday = "周五", Saturday = "周六",
    Sunday = "周日"
}
local DAY_SET = {}
for _, day in ipairs(DAYS) do
    DAY_SET[day] = true
end

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function read_openwrt_release()
    local file = io.open("/etc/openwrt_release", "r")
    if not file then
        return nil
    end

    local release = {}
    for line in file:lines() do
        local key, value = line:match("^([%w_]+)='(.*)'$")
        if key then
            release[key] = value
        end
    end
    file:close()
    return release
end

local function command_path(name, candidates)
    local path = trim(sys.exec("command -v " .. name .. " 2>/dev/null"))
    if path ~= "" then
        return path
    end

    for _, candidate in ipairs(candidates) do
        if fs.stat(candidate) then
            return candidate
        end
    end
    return ""
end

local function find_parental_include()
    local ok, cursor = pcall(function()
        return require("luci.model.uci").cursor()
    end)
    if not ok or not cursor then
        return nil, "无法初始化 UCI"
    end

    local found
    local read_ok, err = pcall(function()
        cursor:foreach("firewall", "include", function(section)
            if section.path == "/etc/config/firewall.parental" then
                found = section
            end
        end)
    end)
    if not read_ok then
        return nil, tostring(err)
    end
    return found
end

local function valid_time(value)
    local hour, minute = tostring(value or ""):match("^(%d%d):(%d%d)$")
    if not hour then
        return false
    end
    return tonumber(hour) <= 23 and tonumber(minute) <= 59
end

local function normalize_days(raw)
    raw = trim(raw)
    if raw == "" or raw == "*" then
        return "*"
    end

    local days = {}
    local seen = {}
    for day in raw:gmatch("[^,%s]+") do
        if DAY_SET[day] and not seen[day] then
            seen[day] = true
            days[#days + 1] = day
        end
    end

    if #days == 0 or #days == #DAYS then
        return "*"
    end
    return table.concat(days, " ")
end

local function parse_slots(raw)
    local slots = {}
    for item in tostring(raw or ""):gmatch("[^;]+") do
        local start_time, stop_time, days =
            item:match("^([^|]+)|([^|]+)|(.*)$")
        start_time = trim(start_time)
        stop_time = trim(stop_time)

        if valid_time(start_time) and valid_time(stop_time)
            and start_time ~= stop_time then
            slots[#slots + 1] = {
                start = start_time,
                stop = stop_time,
                days = normalize_days(days)
            }
        end
    end
    return slots
end

local function legacy_slots(section)
    local slots = {}
    local days = normalize_days(m:get(section, "weekdays"))

    local function add_slot(start_time, stop_time)
        start_time, stop_time = trim(start_time), trim(stop_time)
        if valid_time(start_time) and valid_time(stop_time)
            and start_time ~= stop_time then
            slots[#slots + 1] = {
                start = start_time,
                stop = stop_time,
                days = days
            }
        end
    end

    add_slot(m:get(section, "start_time_am"), m:get(section, "stop_time_am"))
    add_slot(m:get(section, "start_time_pm"), m:get(section, "stop_time_pm"))
    return slots
end

local function get_slots(section)
    local raw = m:get(section, "timeslots")
    if trim(raw) == "" then
        return legacy_slots(section)
    end
    return parse_slots(raw)
end

local function serialize_slots(slots)
    local result = {}
    for _, slot in ipairs(slots) do
        result[#result + 1] = string.format(
            "%s|%s|%s", slot.start, slot.stop, slot.days
        )
    end
    if #result == 0 then
        return "none"
    end
    return table.concat(result, ";")
end

local function format_days(days)
    if not days or days == "*" then
        return "每天"
    end

    local labels = {}
    for day in days:gmatch("%S+") do
        labels[#labels + 1] = DAY_LABELS[day] or day
    end
    return #labels > 0 and table.concat(labels, "、") or "每天"
end

local function format_slots(slots)
    local result = {}
    for _, slot in ipairs(slots) do
        local range = slot.start .. "-" .. slot.stop
        if slot.start > slot.stop then
            range = slot.start .. "-次日" .. slot.stop
        end
        result[#result + 1] = string.format(
            "%s（%s）", range, format_days(slot.days)
        )
    end
    return table.concat(result, "；")
end

-- 创建 Map (仅保留全局总开关)
m = Map("parental", "", "")
m.title = ""
m.description = ""

local function render_compat()
    local warnings = {}
    local critical = false

    local function warn(message, is_critical)
        warnings[#warnings + 1] = message
        if is_critical then
            critical = true
        end
    end

    local release = read_openwrt_release()
    local platform = "未识别"
    local release_version
    if release then
        local system_id = release.DISTRIB_ID or "OpenWrt"
        local version = release.DISTRIB_RELEASE
            or release.DISTRIB_DESCRIPTION or "未知版本"
        platform = system_id .. " " .. version
        release_version = release.DISTRIB_RELEASE
    else
        warn("未找到 /etc/openwrt_release，无法确认 OpenWrt 版本")
    end

    local nft_path = command_path("nft", {
        "/usr/sbin/nft", "/sbin/nft", "/usr/bin/nft", "/bin/nft"
    })
    local has_nft = nft_path ~= ""
    local nft_version = ""
    if has_nft then
        nft_version = trim(sys.exec(nft_path .. " --version 2>/dev/null"))
    else
        warn("未检测到 nft 命令，无法注入 nftables 规则", true)
    end

    local fw4_path = command_path("fw4", {
        "/usr/sbin/fw4", "/sbin/fw4"
    })
    local has_fw4 = fw4_path ~= ""
    if not has_fw4 then
        warn("未检测到 firewall4 (fw4)，当前系统可能不是 nftables 防火墙", true)
    end

    local table_ok = false
    if has_nft then
        local table_status = sys.call(
            nft_path .. " list table inet fw4 >/dev/null 2>&1"
        )
        table_ok = (table_status == 0 or table_status == true)
        if not table_ok then
            warn("未检测到 inet fw4 表，firewall4 可能未启动", true)
        end
    end

    local release_major, release_minor
    if release_version then
        local major, minor = release_version:match("^(%d+)%.(%d+)")
        release_major, release_minor = tonumber(major), tonumber(minor)
    end
    if release_major and release_minor and not has_fw4
        and (release_major < 22
            or (release_major == 22 and release_minor < 3)) then
        warn("OpenWrt 版本低于 22.03，且未检测到 firewall4", true)
    end

    local script_exists = fs.stat("/etc/config/firewall.parental") ~= nil
    if not script_exists then
        warn("未找到 /etc/config/firewall.parental", true)
    end

    local include, include_error = find_parental_include()
    local include_desc = "未找到"
    if include_error then
        include_desc = "读取失败"
        warn("无法读取 /etc/config/firewall: " .. tostring(include_error))
    elseif not include then
        warn("未在 /etc/config/firewall 中找到指向 /etc/config/firewall.parental 的 include", true)
    else
        include_desc = "已配置"
        if include.enabled == "0" then
            include_desc = "已禁用"
            warn("防火墙 include 已禁用", true)
        end
        if include.type and include.type ~= "script" then
            warn("防火墙 include 的 type 不是 script", true)
        end
        if include.reload ~= "1" then
            include_desc = include_desc .. "，reload 未开启"
            warn("防火墙 include 未设置 reload='1'，fw4 reload 时可能不会执行脚本", true)
        else
            include_desc = include_desc .. "，reload=1"
        end
    end

    local enabled = m:get("settings", "enabled") == "1"
    local details = {
        "系统: " .. platform,
        "防火墙: " .. (has_fw4 and fw4_path or "未找到 fw4"),
        "nftables: " .. (has_nft
            and (nft_version ~= "" and nft_version or nft_path)
            or "未找到"),
        "inet fw4: " .. (table_ok and "正常" or "未找到"),
        "规则脚本: " .. (script_exists and "存在" or "缺失"),
        "防火墙 include: " .. include_desc,
        "全局开关: " .. (enabled and "开启" or "关闭")
    }

    local detail_html = {}
    for _, line in ipairs(details) do
        detail_html[#detail_html + 1] = util.pcdata(line)
    end

    local color, background, title
    if #warnings == 0 then
        color, background = "#2b7a3d", "#f0fff4"
        title = "兼容性检查通过"
    elseif critical then
        color, background = "#b42318", "#fff1f0"
        title = "检测到严重兼容性问题，规则可能无法生效"
    else
        color, background = "#a15c00", "#fff8e1"
        title = "检测到兼容性风险"
    end

    local html = {
        '<div style="margin:0 0 12px;padding:10px 12px;border-left:4px solid '
            .. color .. ';background:' .. background .. ';border-radius:6px;">',
        '<div style="font-weight:bold;color:' .. color .. ';">'
            .. title .. '</div>',
        '<div style="font-size:12px;color:#444;margin-top:6px;line-height:1.6;">'
            .. table.concat(detail_html, '<br>') .. '</div>'
    }

    if #warnings > 0 then
        html[#html + 1] =
            '<ul style="margin:8px 0 0 18px;padding:0;color:#333;font-size:12px;">'
        for _, warning in ipairs(warnings) do
            html[#html + 1] = '<li>' .. util.pcdata(warning) .. '</li>'
        end
        html[#html + 1] = '</ul>'
    end

    html[#html + 1] = '</div>'
    return table.concat(html)
end

local settings_section = m:section(NamedSection, "settings", "globals", "全局设置")
settings_section.anonymous = true
s = settings_section

local compat_view = s:option(DummyValue, "_compat", "系统兼容性")
compat_view.rawhtml = true
local compat_ok, compat_html = pcall(render_compat)
if compat_ok then
    compat_view.value = compat_html
else
    compat_view.value = '<div style="padding:10px;color:#b42318;background:#fff1f0;">'
        .. "兼容性检测失败: " .. util.pcdata(tostring(compat_html)) .. '</div>'
end

local enabled = s:option(Flag, "enabled", "启用家长控制系统")
enabled.rmempty = false

local devices = {}
local leases_file = io.open("/tmp/dhcp.leases", "r")
if leases_file then
    for line in leases_file:lines() do
        local expiry, mac, ip, name = line:match("^(%d+)%s+([%w:]+)%s+([%d%.]+)%s+([^%s]+)")
        if mac and mac ~= "*" then
            mac = mac:upper()
            local clean_name = (name and name ~= "*" and name ~= "") and name or "未知设备"
            devices[mac] = { ip = ip, name = clean_name, online = false }
        end
    end
    leases_file:close()
end

local arp_file = io.open("/proc/net/arp", "r")
if arp_file then
    for line in arp_file:lines() do
        local ip, flags, mac = line:match("^([%d%.]+)%s+%w+%s+(0x%x+)%s+([%w:]+)")
        if mac and mac ~= "00:00:00:00:00:00" then
            mac = mac:upper()
            local is_active = (flags and flags ~= "0x0")
            if is_active then
                if devices[mac] then
                    devices[mac].ip = ip
                    devices[mac].online = true
                else
                    devices[mac] = { ip = ip, name = "静态IP设备", online = true }
                end
            end
        end
    end
    arp_file:close()
end

local sorted_macs = {}
for mac in pairs(devices) do
    table.insert(sorted_macs, mac)
end

table.sort(sorted_macs, function(a, b)
    local dev_a, dev_b = devices[a], devices[b]
    local function get_weight(dev)
        if dev.online then
            return (dev.name ~= "未知设备" and dev.name ~= "静态IP设备") and 1 or 2
        else
            return 3
        end
    end
    local w_a, w_b = get_weight(dev_a), get_weight(dev_b)
    if w_a ~= w_b then return w_a < w_b end
    return dev_a.ip < dev_b.ip
end)


-- =========================================================
-- 主表格
-- =========================================================
s = m:section(TypedSection, "device", "受控设备列表", "点击“管理时段”可添加、修改或删除该设备的管控时间。")
s.anonymous = true
s.addremove = true
s.template = "cbi/tblsection"

-- 1. 启用管控
local enable = s:option(Flag, "enable", "启用")
enable.rmempty = false
enable.default = "1"

-- 2. 设备状态
local status = s:option(DummyValue, "_status", "状态 / IP")
function status.cfgvalue(self, section)
    local mac = m:get(section, "mac")
    if mac and mac ~= "" then
        mac = mac:upper()
        local dev = devices[mac]
        if dev then
            local icon = dev.online and "<span style='color:#2bc158;font-weight:bold;'>🟢 在线</span>" or "<span style='color:#888;'>⚪ 离线</span>"
            return string.format("%s | %s", icon, dev.ip)
        end
    end
    return "<span style='color:#888;'>⚪ 未知 / 离线</span>"
end
status.rawhtml = true

-- 3. MAC 地址
local mac_option = s:option(Value, "mac", "MAC 地址")
mac_option.datatype = "macaddr"
mac_option.rmempty = false
for _, mac in ipairs(sorted_macs) do
    local info = devices[mac]
    local icon = info.online and "🟢" or "⚪"
    local label = string.format("%s %s | %s (%s)", icon, mac, info.name, info.ip)
    mac_option:value(mac, label)
end

-- 4. 别名
local alias = s:option(Value, "name", "设备备注")
alias.placeholder = "例：小明的 iPad"
alias.rmempty = true
function alias.cfgvalue(self, section)
    local val = Value.cfgvalue(self, section)
    if val and val ~= "" then return val end
    local mac_val = m:get(section, "mac")
    if mac_val and devices[mac_val:upper()] then
        return devices[mac_val:upper()].name
    end
    return ""
end

-- 5. 当前配置的时间摘要展示
local time_summary = s:option(DummyValue, "_time_summary", "管控时段")
function time_summary.cfgvalue(self, section)
    local slots = get_slots(section)
    if #slots == 0 then
        return "<span style='color:#999;'>未配置（全天不限制）</span>"
    end

    return string.format(
        "<span>%s</span>",
        util.pcdata(format_slots(slots))
    )
end
time_summary.rawhtml = true

-- 6. 操作按钮
local time_detail = s:option(DummyValue, "_config_action", "操作")
function time_detail.cfgvalue(self, section)
    local html = string.format(
        '<button type="button" class="cbi-button cbi-button-apply" '
        .. 'style="padding: 2px 8px; font-size: 12px;" '
        .. 'onclick="if (window.parentalOpenSlots) { parentalOpenSlots(\'%s\'); } '
        .. 'else { alert(\'时段编辑器脚本未加载，请刷新页面\'); }">'
        .. '⚙️ 管理时段</button>',
        section
    )

    if not slot_helpers_emitted and render_slot_helpers then
        slot_helpers_emitted = true
        html = html .. render_slot_helpers()
    end

    return html
end
time_detail.rawhtml = true

-- 7. 内部序列化字段。格式：
--    start|stop|weekdays;start|stop|weekdays
--    weekdays 使用空格分隔，* 表示每天。
local slots_value = s:option(Value, "timeslots", "")
slots_value.widget = "hidden"
slots_value.rmempty = true
slots_value.default = "none"
slots_value.placeholder = "08:00|11:50|Monday Tuesday;14:00|22:00|Saturday Sunday"
function slots_value.cfgvalue(self, section)
    local stored = trim(m:get(section, "timeslots"))
    if stored ~= "" then
        return serialize_slots(parse_slots(stored))
    end
    return serialize_slots(get_slots(section))
end


-----------------------
-- 专属日志回显控件
-----------------------
local function render_fw_log()
    local config_file = "/etc/config/parental"
    local config_mtime_str = "未知"
    local stat_info = fs.stat(config_file)
    if stat_info and stat_info.mtime then
        config_mtime_str = os.date("%Y-%m-%d %H:%M:%S", stat_info.mtime)
    end

    local nft_cmd = "nft list chain inet fw4 parental_block 2>&1"
    local nft_pipe = io.popen(nft_cmd)
    local nft_output = ""
    if nft_pipe then
        nft_output = nft_pipe:read("*a")
        nft_pipe:close()
    end

    if not nft_output or nft_output == "" or nft_output:find("No such file") then
        nft_output = "⚠️ 当前未检测到 parental_block 规则链（可能家长控制未启用或未生效）。"
    end

    local total_output = string.format([[
========================================================================
 [当前规则] nftables (nft list chain inet fw4 parental_block)
 配置文件修改时间: %s
========================================================================
%s]], config_mtime_str, nft_output)

    local escaped_output = util.pcdata(total_output)
    return string.format([[
<div style="margin-top: 2px;">
    <pre style="background: #1c1c1e; color: #f2f2f7; padding: 15px; border-radius: 6px; font-family: monospace; font-size: 13px; text-align: left; max-height: 400px; overflow-y: auto; white-space: pre-wrap; word-wrap: break-word; line-height: 1.5; border: 1px solid #2c2c2e; margin: 0;">%s</pre>
</div>
    ]], escaped_output)
end

local log_cache = render_fw_log()

local log_section = m:section(TypedSection, "globals", "当前防火墙规则")
log_section.addremove = false

local log_view = log_section:option(DummyValue, "_fw_log", " ")
log_view.rawhtml = true
log_view.value = log_cache
function log_view.cfgvalue(self, section)
    if section ~= "settings" then
        return ""
    end
    return log_cache
end

render_slot_helpers = function()
    return [=[
<div id="parental-slot-helper-root">
<style>
#parental-slot-helper-root { display: none; }
input[name$=".timeslots"], textarea[name$=".timeslots"], select[name$=".timeslots"] { display: none !important; }
</style>
<div id="parental-slot-modal" style="display:none; position:fixed; z-index:10000; left:0; top:0; width:100%; height:100%; background:rgba(0,0,0,.45);">
    <div style="background:#fff; color:#222; width:min(680px,92vw); max-height:88vh; overflow:auto; margin:5vh auto; padding:18px; border-radius:10px; box-shadow:0 10px 40px rgba(0,0,0,.35);">
        <div style="font-size:16px; font-weight:bold; margin-bottom:8px;">管理管控时段</div>
        <div style="font-size:12px; color:#666; margin-bottom:12px; line-height:1.5;">
            每个时段独立设置生效星期。结束时间早于开始时间时按跨午夜处理；点击“确定”后，还需要点击页面底部的“保存并应用”。
        </div>
        <div id="parental-slot-rows"></div>
        <div style="margin:10px 0 6px;">
            <button type="button" class="cbi-button" onclick="parentalAddSlotRow()">+ 添加时段</button>
        </div>
        <div id="parental-slot-error" style="color:#c00; font-size:12px; min-height:18px;"></div>
        <div style="text-align:right; margin-top:8px;">
            <button type="button" class="cbi-button" onclick="parentalCloseSlots(false)">取消</button>
            <button type="button" class="cbi-button cbi-button-apply" onclick="parentalCloseSlots(true)">确定</button>
        </div>
    </div>
</div>
<script>
(function() {
    var DAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    var DAY_LABELS = {
        Monday: '周一', Tuesday: '周二', Wednesday: '周三', Thursday: '周四',
        Friday: '周五', Saturday: '周六', Sunday: '周日'
    };

    function trim(value) {
        return String(value || '').replace(/^\s+|\s+$/g, '');
    }

    function isValidTime(value) {
        return /^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(value);
    }

    function allDays() {
        return DAYS.slice(0);
    }

    function parseDays(raw) {
        raw = trim(raw);
        if (!raw || raw === '*') {
            return allDays();
        }

        var days = [];
        raw.split(/[,\s]+/).forEach(function(day) {
            if (DAY_LABELS[day] && days.indexOf(day) === -1) {
                days.push(day);
            }
        });
        return days.length ? days : allDays();
    }

    function parseSlots(raw) {
        var slots = [];
        String(raw || '').split(';').forEach(function(item) {
            var fields = item.split('|');
            if (fields.length < 2) {
                return;
            }

            var start = trim(fields[0]);
            var stop = trim(fields[1]);
            if (!isValidTime(start) || !isValidTime(stop) || start === stop) {
                return;
            }

            slots.push({
                start: start,
                stop: stop,
                days: parseDays(fields[2] || '')
            });
        });
        return slots;
    }

    function slotInput(section) {
        return document.querySelector(
            'input[name="cbid.parental.' + section + '.timeslots"]'
        ) || document.querySelector(
            'textarea[name="cbid.parental.' + section + '.timeslots"]'
        );
    }

    function setError(message) {
        document.getElementById('parental-slot-error').textContent = message || '';
    }

    function slotRows() {
        return document.getElementById('parental-slot-rows');
    }

    window.parentalAddSlotRow = function(slot) {
        var row = document.createElement('div');
        row.className = 'parental-slot-row';
        row.style.cssText = 'border:1px solid #ddd;border-radius:6px;padding:10px;margin-bottom:8px;background:#fafafa;';
        row.innerHTML =
            '<div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap;">' +
                '<label style="font-size:12px;">开始 <input type="time" class="parental-slot-start" step="60" style="padding:2px;"></label>' +
                '<label style="font-size:12px;">结束 <input type="time" class="parental-slot-stop" step="60" style="padding:2px;"></label>' +
                '<button type="button" class="cbi-button" style="margin-left:auto;padding:2px 8px;font-size:11px;">删除</button>' +
            '</div>' +
            '<div class="parental-slot-days" style="display:flex;flex-wrap:wrap;gap:8px;margin-top:8px;font-size:12px;"></div>';

        var current = slot || { start: '', stop: '', days: allDays() };
        var selectedDays = current.days || allDays();
        row.querySelector('.parental-slot-start').value = current.start || '';
        row.querySelector('.parental-slot-stop').value = current.stop || '';

        var daysBox = row.querySelector('.parental-slot-days');
        DAYS.forEach(function(day) {
            var label = document.createElement('label');
            label.style.cssText = 'cursor:pointer;';
            var checkbox = document.createElement('input');
            checkbox.type = 'checkbox';
            checkbox.className = 'parental-slot-day';
            checkbox.value = day;
            checkbox.checked = selectedDays.indexOf(day) !== -1;
            label.appendChild(checkbox);
            label.appendChild(document.createTextNode(' ' + DAY_LABELS[day]));
            daysBox.appendChild(label);
        });

        row.querySelector('button').onclick = function() {
            row.parentNode.removeChild(row);
        };
        slotRows().appendChild(row);
    };

    function readSlots() {
        var rows = document.querySelectorAll('#parental-slot-rows .parental-slot-row');
        var slots = [];

        for (var i = 0; i < rows.length; i++) {
            var row = rows[i];
            var start = trim(row.querySelector('.parental-slot-start').value);
            var stop = trim(row.querySelector('.parental-slot-stop').value);

            if (!start && !stop) {
                continue;
            }
            if (!isValidTime(start) || !isValidTime(stop)) {
                return { error: '时间格式必须为 HH:MM，例如 08:00。' };
            }
            if (start === stop) {
                return { error: '开始时间和结束时间不能相同。' };
            }

            var days = [];
            row.querySelectorAll('.parental-slot-day').forEach(function(checkbox) {
                if (checkbox.checked) {
                    days.push(checkbox.value);
                }
            });
            if (days.length === 0) {
                return { error: '每个时段至少选择一个生效日期。' };
            }

            slots.push({ start: start, stop: stop, days: days });
        }

        return { slots: slots };
    }

    window.parentalOpenSlots = function(section) {
        window.parentalSlotSection = section;
        var input = slotInput(section);
        var slots = parseSlots(input ? input.value : '');
        var container = slotRows();
        container.innerHTML = '';

        if (slots.length === 0) {
            window.parentalAddSlotRow();
        } else {
            slots.forEach(window.parentalAddSlotRow);
        }

        setError('');
        window.parentalHideInternalFields();
        document.getElementById('parental-slot-modal').style.display = 'block';
    };

    window.parentalCloseSlots = function(save) {
        if (save) {
            var result = readSlots();
            if (result.error) {
                setError(result.error);
                return;
            }

            var input = slotInput(window.parentalSlotSection);
            if (input) {
                input.value = result.slots.length
                    ? result.slots.map(function(slot) {
                        var days = slot.days.length === DAYS.length ? '*' : slot.days.join(' ');
                        return slot.start + '|' + slot.stop + '|' + days;
                    }).join(';')
                    : 'none';
            }
        }

        document.getElementById('parental-slot-modal').style.display = 'none';
    };

    window.parentalHideInternalFields = function() {
        var inputs = document.querySelectorAll(
            'input[name$=".timeslots"], textarea[name$=".timeslots"]'
        );
        inputs.forEach(function(input) {
            var td = input.closest('td');
            if (!td) {
                input.style.display = 'none';
                return;
            }

            td.style.display = 'none';
            var tr = td.parentNode;
            var table = tr && tr.closest ? tr.closest('table') : null;
            if (table && tr) {
                var index = Array.prototype.indexOf.call(tr.children, td);
                var headers = table.querySelectorAll('th');
                if (index !== -1 && headers[index]) {
                    headers[index].style.display = 'none';
                }
            }
        });
    };

    var modal = document.getElementById('parental-slot-modal');
    if (modal) {
        modal.addEventListener('keydown', function(event) {
            if (event.key === 'Enter') {
                event.preventDefault();
            }
        });
    }

    var helperRoot = document.getElementById('parental-slot-helper-root');
    if (modal && document.body) {
        document.body.appendChild(modal);
    }
    if (helperRoot) {
        helperRoot.style.display = 'none';
    }

    window.parentalHideInternalFields();
    window.addEventListener('load', window.parentalHideInternalFields);
    document.addEventListener('DOMContentLoaded', window.parentalHideInternalFields);
    setTimeout(window.parentalHideInternalFields, 0);
    setTimeout(window.parentalHideInternalFields, 300);
    if (window.MutationObserver) {
        new MutationObserver(window.parentalHideInternalFields).observe(
            document.body, { childList: true, subtree: true }
        );
    }
})();
</script>
</div>
    ]=]
end

function m.on_after_commit(self)
    local uci = require("luci.model.uci").cursor()
    uci:commit("parental")
    os.execute("fw4 reload >/dev/null 2>&1 || /etc/init.d/firewall restart >/dev/null 2>&1")
    nixio.nanosleep(0, 400000000)
    log_cache = render_fw_log()
    log_view.value = log_cache
end

return m
