#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#

# Modify default IP
sed -i 's/192.168.1.1/192.168.11.1/g' package/base-files/files/bin/config_generate
#sed -i 's/KERNEL_PATCHVER:=5.15/KERNEL_PATCHVER:=6.1/g' target/linux/x86/Makefile
#sed -i "s/.*PKG_VERSION:=.*/PKG_VERSION:=4.3.9_v1.2.14/" package/lean/qBittorrent-static/Makefile
#sed -i "s/.*PKG_VERSION:=.*/PKG_VERSION:=5.0.0-stable/" package/libs/wolfssl/Makefile

# 1. 替换 Luci 的默认核心主题依赖
sed -i 's/luci-theme-bootstrap/luci-theme-design/g' feeds/luci/collections/luci/Makefile
# 2. 移除 Lean 源码中硬编码对 Argon 的默认指向
sed -i 's/luci-theme-argon/luci-theme-design/g' feeds/luci/collections/luci/Makefile
# 3. 强行修改底层默认设置脚本中的初始开机 UI 路径
sed -i 's/luci-static\/argon/luci-static\/design/g' package/lean/default-settings/files/zzz-default-settings

# TTYD 免登录
# sed -i 's|/bin/login|/bin/login -f root|g' feeds/packages/utils/ttyd/files/ttyd.config
# TTYD 拒绝链接问题
sed -i 's/\${interface:+-i $interface}/\# ${interface:+-i $interface}/g' feeds/packages/utils/ttyd/files/ttyd.init

# 修改升级检测
sed -i 's|/Lenyu2020/Actions-OpenWrt-x86|/Zero-ZY/Actions-OpenWrt-x86|g' files/usr/share/Check_Update.sh
sed -i 's|/Lenyu2020/Actions-OpenWrt-x86|/Zero-ZY/Actions-OpenWrt-x86|g' files/usr/share/Lenyu-auto.sh
sed -i 's|/Lenyu2020/Actions-OpenWrt-x86|/Zero-ZY/Actions-OpenWrt-x86|g' files/usr/share/Lenyu-version.sh
sed -i 's|/Lenyu2020/Actions-OpenWrt-x86|/Zero-ZY/Actions-OpenWrt-x86|g' files/usr/share/Lenyu-pw.sh

# 清空原有的发行版软件源，并写入指定的中科大镜像源
echo 'src/gz openwrt_core https://mirrors.ustc.edu.cn/openwrt/releases/24.10.7/targets/x86/64/packages' > package/base-files/files/etc/opkg/distfeeds.conf
echo 'src/gz openwrt_base https://mirrors.ustc.edu.cn/openwrt/releases/24.10.7/packages/x86_64/base' >> package/base-files/files/etc/opkg/distfeeds.conf
echo 'src/gz openwrt_luci https://mirrors.ustc.edu.cn/openwrt/releases/24.10.7/packages/x86_64/luci' >> package/base-files/files/etc/opkg/distfeeds.conf
echo 'src/gz openwrt_packages https://mirrors.ustc.edu.cn/openwrt/releases/24.10.7/packages/x86_64/packages' >> package/base-files/files/etc/opkg/distfeeds.conf
echo 'src/gz openwrt_routing https://mirrors.ustc.edu.cn/openwrt/releases/24.10.7/packages/x86_64/routing' >> package/base-files/files/etc/opkg/distfeeds.conf
echo 'src/gz openwrt_telephony https://mirrors.ustc.edu.cn/openwrt/releases/24.10.7/packages/x86_64/telephony' >> package/base-files/files/etc/opkg/distfeeds.conf

# ====================================================================================
# 【自定义注入】开机5分钟网络检测与PPPoE精准重拨/限额重启脚本
# ====================================================================================

# 1. 创建固件内置文件所需的目录结构
mkdir -p files/root
mkdir -p files/etc/uci-defaults

# ====================================================================================
# 核心部分 A：动态生成网络检测 Shell 脚本，存放在固件的 /root/check_network.sh
# ====================================================================================
cat << 'EOF' > files/root/check_network.sh
#!/bin/sh

# ------------ 基础变量定义 ------------
INTERFACE="wan"                               # 需要进行重拨操作的物理/虚拟 WAN 接口名称
LOG_FILE="/tmp/network_check.log"             # 脚本运行产生的临时日志文件路径（存放在内存，重启后自动清空）
REBOOT_LIMIT_FILE="/etc/network_reboot_count" # 存储每日系统重启次数的本地持久化文件（常驻闪存/Overlay中）

# ------------ 日志调试机制 ------------
# 只要脚本启动，无论网络好坏，立刻强写一行日志，方便使用 tail -f 调试观察
echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] 开机5分钟定时已到，脚本成功触发检查..." >> $LOG_FILE

# ------------ 【免维护核心】时间同步安全防护机制（物理时间定位法） ------------
# 【彻底修复】放弃读取易产生格式误判的 openwrt_release 文本。
# 直接读取系统核心守护进程文件 /etc/init.d/cron 的文件修改年份。
# 每次通过 GitHub Actions 编译固件时，该物理文件的生成年份必然是编译当年的真实年份。
BUILD_YEAR=$(date -r /etc/init.d/cron +%Y 2>/dev/null)

# 如果读取失败（极端精简固件），使用当前时间点的前一年 2025 作为绝对安全的时空历史基准线
[ -z "$BUILD_YEAR" ] && BUILD_YEAR=2025

# 读取当前路由器正在运行的系统年份
CURRENT_YEAR=$(date +%Y)

# 逻辑拦截：如果当前年份小于固件编译年份，说明时间必然尚未同步（处于1970年等初始状态）
if [ "$CURRENT_YEAR" -lt "$BUILD_YEAR" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] NTP时间未同步(当前:$CURRENT_YEAR < 基准:$BUILD_YEAR)，跳过检测以防计数器误清零。" >> $LOG_FILE
    exit 0
fi

# ------------ 跨天计数器自动清零与限制机制 ------------
TODAY=$(date +%Y-%m-%d)

if [ -f "$REBOOT_LIMIT_FILE" ]; then
    # 分别精准读取文件第一行的“历史日期”和第二行的“重启次数”
    SAVED_DATE=$(head -n 1 "$REBOOT_LIMIT_FILE")
    REBOOT_COUNT=$(tail -n 1 "$REBOOT_LIMIT_FILE")
    
    # 如果文件里记录的日期不是今天（说明已经到了新的一天），则重置计数器，并初始化写入新日期的 0 次记录
    if [ "$SAVED_DATE" != "$TODAY" ]; then
        echo -e "${TODAY}\n0" > "$REBOOT_LIMIT_FILE"
        REBOOT_COUNT=0
    fi
else
    # 如果文件不存在，初始化写入今日日期的 0 次记录
    echo -e "${TODAY}\n0" > "$REBOOT_LIMIT_FILE"
    REBOOT_COUNT=0
fi

# ------------ 三重网络联通性检测函数 ------------
# 完美修正百度域名检测语法，彻底移除任何非法的协议头或残留字符
check_ping() {
    if ping -c 5 -W 3 119.29.29.29 >/dev/null 2>&1; then return 0; fi
    if ping -c 5 -W 3 114.114.114.114 >/dev/null 2>&1; then return 0; fi
    if ping -c 5 -W 3 www.baidu.com >/dev/null 2>&1; then return 0; fi
    return 1 # 若上述三个地址连续 15 次 ping 全部失败，则确认为断网状态
}

# ------------ 核心策略控制主逻辑 ------------
if check_ping; then
    # 网络正常，记录成功日志，结束脚本
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] 网络联通性检测正常，脚本退出。" >> $LOG_FILE
    exit 0
else
    # 网络断开，进入多级修复流程
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ALERT] 开机检测到网络断开，开始触发修复流程..." >> $LOG_FILE
    
    # 启动循环：尝试重启 PPPoE 拨号，最多重试 5 次
    RETRY=1
    while [ $RETRY -le 5 ]; do
        echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] 正在尝试第 $RETRY 次重启 PPPoE 连接..." >> $LOG_FILE
        
        # 【PPPoE精准重拨命令】
        # 使用 pkill -f 代替 killall，确保在没有任何额外工具包的精简版固件中依旧百分之百能强制释放拨号进程
        ifdown "$INTERFACE"
        pkill -f pppd 2>/dev/null
        sleep 2
        ifup "$INTERFACE"
        
        # 强制等待 15 秒，给光猫与运营商机房留出充足的时间
        sleep 15
        
        # 重新进行网络联通性复检
        if check_ping; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') [SUCCESS] 第 $RETRY 次重启拨号后网络恢复正常！" >> $LOG_FILE
            exit 0 # 网络恢复，大功告成，退出脚本
        fi
        
        RETRY=$((RETRY + 1)) # 复检失败，进入下一次循环
    done
    
    # ------------ 5次拨号均失败，触发整机安全重启与额度控流机制 ------------
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] 5次重启拨号后依旧无法上网。" >> $LOG_FILE
    
    # 安全拦截：判断今天已经触发的系统重启次数是否小于 2 次
    if [ "$REBOOT_COUNT" -lt 2 ]; then
        # 额度未满，次数自增 1，更新并保存最新的限额数据（严格保留换行符格式）
        REBOOT_COUNT=$((REBOOT_COUNT + 1))
        echo -e "${TODAY}\n${REBOOT_COUNT}" > "$REBOOT_LIMIT_FILE"
        
        echo "$(date '+%Y-%m-%d %H:%M:%S') [CRITICAL] 触发系统重启！(今日第 $REBOOT_COUNT 次)" >> $LOG_FILE
        
        # 在重启前强制将缓存数据同步写入闪存介质，延迟3秒后实施整机软重启
        sync
        sleep 3
        reboot
    else
        # 额度已满：拒绝继续重启，保护设备闪存寿命，防止极端硬件损坏下的死循环
        echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] 达到每日重启上限(2次)，拒绝执行重启系统！" >> $LOG_FILE
    fi
fi
EOF

# 在编译构建阶段，赋予生成的脚本文件初始的可执行权限
chmod +x files/root/check_network.sh


# ====================================================================================
# 核心部分 B：动态生成 uci-defaults 脚本，将启动命令安全注入到 /etc/rc.local 中
# ====================================================================================
cat << 'EOF' > files/etc/uci-defaults/99-custom-network-cron
#!/bin/sh

# 再次确保脚本可执行
chmod +x /root/check_network.sh

RC_LOCAL="/etc/rc.local"
touch "$RC_LOCAL"

# 【安全无毒重组挂载机制】
# 检查 rc.local 中是否已存在该脚本。如果没有，则将其注入到末尾的 `exit 0` 之前。
# 注意：末尾的 `&` 极其重要，它能让倒计时在后台挂起异步运行，绝对不会卡住系统的正常开机引导流程。
if ! grep -q "check_network.sh" "$RC_LOCAL"; then
    # 读取原有内容，过滤掉结尾可能存在的 exit 0 或 return 0，存入临时文件
    grep -v -E "exit 0|return 0" "$RC_LOCAL" > /tmp/rc.local.tmp 2>/dev/null
    
    # 向临时文件追加我们的后台异步5分钟检测逻辑
    echo "" >> /tmp/rc.local.tmp
    echo "# 开机延时5分钟后在后台异步执行网络检测修复脚本" >> /tmp/rc.local.tmp
    echo "(sleep 300 && /root/check_network.sh) &" >> /tmp/rc.local.tmp
    echo "exit 0" >> /tmp/rc.local.tmp
    echo "" >> /tmp/rc.local.tmp
    
    # 【完美修正】避免 cat 变量嵌套解析冲突，直接将标准整洁的内容写回系统原文件并清空临时缓存
    cat /tmp/rc.local.tmp > /etc/rc.local
    rm -f /tmp/rc.local.tmp
fi

exit 0
EOF

# 赋予初始化脚本执行权限
chmod +x files/etc/uci-defaults/99-custom-network-cron
# ====================================================================================
