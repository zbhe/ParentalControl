module("luci.controller.parental", package.seeall)

function index()
    -- 创建菜单，点击后直接调用后面我们要写的那个表单
    entry({"admin", "network", "parental_script"}, cbi("parental_script"), _("家长控制"), 60).dependent = true
end
