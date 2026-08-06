# > getbootdisk
# mmcblk0
_getbootdisk()
{
	local rootpart="`grep -Fm1 ' - squashfs /dev/root ' /proc/self/mountinfo | cut -d' ' -f3`"
	[ -z "$rootpart" ] && return 1
	local devpath="`readlink /sys/dev/block/$rootpart`"
	[ -z "$devpath" ] && return 1
	rootpart="${devpath##*/}"
	devpath="${devpath%%/$rootpart}"
	local rootdisk="${devpath##*/}"
	echo "$rootdisk"
}

# > getbootdisk_lvm
# dm-0
_getbootdisk_lvm()
{
	local rootpart
	if [ -e /rom/note ]; then
		rootpart="`grep -Fm1 ' / / ' /proc/self/mountinfo | grep -F ' - squashfs ' | cut -d' ' -f3`"
	else
		rootpart="`grep -Fm1 ' / /rom ' /proc/self/mountinfo | grep -F ' - squashfs ' | cut -d' ' -f3`"
	fi
	[ -z "$rootpart" ] && return 1
	local major=${rootpart%%:*}
	local minor=${rootpart##*:}
	minor="$(( $minor & 0xfffc ))"
	local devpath="`readlink /sys/dev/block/$major:$minor`"
	[ -z "$devpath" ] && return 1
	local rootdisk="${devpath##*/}"
	echo "$rootdisk"
}

# > getpartofdisk sda 3
# sda3
# > getpartofdisk mmcblk0 3
# mmcblk0p3
_getpartofdisk()
{
	local disk="$1" offset="$2" part
	if [[ "$offset" = 0 ]]; then
		echo "$disk"
	else
		part="$disk"
		echo "$part" | grep -q '^.*[0-9]$' && part="${part}p"
		part="${part}"$(( ${offset} ))
		if [ ! -b "/dev/$part" ]; then
			# lvm
			local line
			local MAJOR MINOR DEVNAME DEVTYPE
			while read line; do
				export -n "$line"
			done < "/sys/block/$disk/uevent"
			local devpath="`readlink /sys/dev/block/$MAJOR:$(($MINOR + $offset))`"
			if [ -n "$devpath" ]; then
				part="${devpath##*/}"
			fi
		fi
		echo "$part"
	fi
	return 0
}

_get_overlay_partition_default()
{
	local bootdisk="`_getbootdisk`"
	[ -z "$bootdisk" ] && {
		log "getbootdisk failed, try lvm"
		bootdisk="`_getbootdisk_lvm`"
	}
	[ -z "$bootdisk" ] && {
		log "getbootdisk_lvm failed"
		return 1
	}
	if [ ! -e "/sys/block/$bootdisk/uevent" ]; then
		log "/sys/block/$bootdisk/uevent does not exist"
		return 1
	fi
	if [ -e /rom/note ]; then
		# we are in mount_root if /rom/note exists
		cat "/sys/block/$bootdisk/uevent" > /tmp/.bootdisk
	fi
	local overlay_dev="`_getpartofdisk $bootdisk 3`"
	[ -z "$overlay_dev" ] && {
		log "getpartofdisk $bootdisk 3 failed"
		return 1
	}
	OVERLAY_DEV="/dev/$overlay_dev"
	return 0
}

_get_overlay_partition_fallback()
{
	log "get_overlay_partition_fallback"
	rm -f /tmp/.bootdisk >/dev/null 2>&1
	local overlay_dev=$(
		. /lib/functions.sh
		. /lib/upgrade/common.sh
		export_bootdevice && export_partdevice overlay_dev 3 && echo $overlay_dev
	)
	[ -z "$overlay_dev" ] && return 1
	OVERLAY_DEV="/dev/$overlay_dev"
	return 0
}

# 标准 OpenWrt 方式：使用 rootfs 分区内 squashfs 之后的剩余空间作为 overlay。
# 对 JDCloud RE-SS-01（rootfs=2048MB 分区表）overlay 约 2GB，且不依赖第 3 分区，
# 避免 p3 是 0.2MB 的 BOOTCONFIG1 导致 overlay 写满、只读。
_get_overlay_partition_loop()
{
	local rootdev bytes_used off loopdev devsize
	rootdev=`block info | grep -Fw 'MOUNT="/"' | sed -E 's/^([^:]+):.*/\1/'`
	[ -z "$rootdev" ] && {
		log "get_overlay_partition_loop: root device not found"
		return 1
	}
	# squashfs 超级块 bytes_used 位于偏移 40（小端 u64）
	bytes_used=`dd if="$rootdev" bs=1 skip=40 count=8 2>/dev/null | od -An -tu8 | tr -d ' '`
	[ -z "$bytes_used" -o "$bytes_used" = "0" ] && {
		log "get_overlay_partition_loop: cannot read squashfs size"
		return 1
	}
	off=$(( (bytes_used + 4095) / 4096 * 4096 ))
	devsize=`blockdev --getsize64 "$rootdev" 2>/dev/null`
	[ -z "$devsize" ] && return 1
	# 剩余空间小于 16MB 时放弃 loop 方式
	[ $(( devsize - off )) -lt 16777216 ] && {
		log "get_overlay_partition_loop: free space too small"
		return 1
	}
	loopdev=`losetup -f 2>/dev/null`
	[ -z "$loopdev" ] && return 1
	losetup -o "$off" "$loopdev" "$rootdev" 2>/dev/null || return 1
	OVERLAY_DEV="$loopdev"
	log "get_overlay_partition_loop: using $loopdev (offset $off)"
	return 0
}

_get_overlay_partition_rootfs_data()
{
	local dev
	dev=`blkid -t PARTLABEL=rootfs_data -o device 2>/dev/null`
	[ -z "$dev" ] && return 1
	OVERLAY_DEV="$dev"
	log "get_overlay_partition_rootfs_data: using $dev"
	return 0
}

get_overlay_partition()
{
	[ -e /.dockerenv ] && {
		log "No overlay partition in Docker"
		return 1
	}
	_get_overlay_partition_loop || _get_overlay_partition_rootfs_data || _get_overlay_partition_default || _get_overlay_partition_fallback || {
		log "Unable to determine overlay partition"
		return 1
	}
	return 0
}
