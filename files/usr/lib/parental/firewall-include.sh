#!/bin/sh

PATH=/usr/sbin:/usr/bin:/sbin:/bin
SCRIPT_PATH='/etc/config/firewall.parental'

find_section() {
	uci show firewall 2>/dev/null \
		| sed -n "s#^firewall\.\([^.]*\)\.path='$SCRIPT_PATH'\$#\1#p" \
		| head -n 1
}

reload_firewall() {
	[ -x /etc/init.d/firewall ] \
		&& /etc/init.d/firewall reload >/dev/null 2>&1 \
		|| true
}

add_include() {
	local section

	section=$(find_section)
	if [ -z "$section" ]; then
		section=$(uci add firewall include) || exit 1
		section=${section#firewall.}
	fi

	uci set "firewall.$section.type=script"
	uci set "firewall.$section.path=$SCRIPT_PATH"
	uci set "firewall.$section.enabled=1"
	uci set "firewall.$section.reload=1"
	uci commit firewall
	reload_firewall
}

remove_include() {
	local section

	section=$(find_section)
	while [ -n "$section" ]; do
		uci delete "firewall.$section" || break
		section=$(find_section)
	done

	uci commit firewall
	reload_firewall
}

case "$1" in
	add)
		add_include
		;;
	remove)
		remove_include
		;;
	*)
		echo "usage: $0 add|remove" >&2
		exit 1
		;;
esac
