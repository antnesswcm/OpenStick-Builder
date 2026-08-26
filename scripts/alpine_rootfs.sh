#!/bin/sh -e

export CHROOT=${CHROOT=$(pwd)/rootfs}
export HOST_NAME=${HOST_NAME=openstick-alpine}
export RELEASE=${RELEASE=v3.24}
export PMOS_RELEASE=${PMOS_RELEASE=v25.12}
export MIRROR=${MIRROR=http://dl-cdn.alpinelinux.org/alpine}
export PMOS_MIRROR=${PMOS_MIRROR=http://mirror.postmarketos.org/postmarketos}
export APK_STATIC_URL=https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic/v3.0.6/x86_64/apk.static

rm -rf ${CHROOT}

mkdir -p ${CHROOT}/etc/apk
cat << EOF >  ${CHROOT}/etc/apk/repositories
${MIRROR}/${RELEASE}/main
${MIRROR}/${RELEASE}/community
@pmos ${PMOS_MIRROR}/${PMOS_RELEASE}
EOF

cp /etc/resolv.conf ${CHROOT}/etc/

mkdir -p ${CHROOT}/usr/bin
cp $(which qemu-aarch64-static) ${CHROOT}/usr/bin

[ -e apk.static ] || wget ${APK_STATIC_URL}; chmod a+x apk.static

./apk.static add -p ${CHROOT} --initdb -U --arch aarch64 --allow-untrusted alpine-base

# install apps
chroot ${CHROOT} ash -l -c "
apk add --allow-untrusted postmarketos-keys@pmos
apk add \
    bridge-utils \
    chrony \
    dropbear \
    dbus \
    eudev \
    gadget-tool \
    iptables \
    linux-postmarketos-qcom-msm8916@pmos \
    modemmanager \
    msm-firmware-loader@pmos \
    qmi-utils \
    openrc \
    rmtfs \
    shadow \
    sudo \
    udev-init-scripts \
    udev-init-scripts-openrc \
    wireguard-tools \
    wireguard-tools-wg-quick \
    wireless-regdb \
    iw

# clear
rm /etc/fstab
"

# extract NetworkManager from previous alpine version (v3.20)
scripts/extract_networkmanager.sh

# setup alpine
chroot ${CHROOT} ash -l -c "
echo user:1::::/home/user:/bin/ash | newusers

# update users used by chrooted apps
addgroup -S dnsmasq
adduser -S -D -H -h /dev/null -s /sbin/nologin -G dnsmasq -g dnsmasq dnsmasq

# sync
ln /etc/group    /usr/local/etc
ln /etc/passwd   /usr/local/etc
ln /etc/hostname /usr/local/etc

ln -sf /usr/local/etc/resolv.conf /etc

# add symlinks
for a in nm-online nmcli nmtui nmtui-connect nmtui-edit nmtui-hostname; do
    ln -s /usr/local/bin/chroot.sh /usr/bin/\${a};
done

rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add udev sysinit
rc-update add udev-trigger sysinit
rc-update add udev-settle sysinit
rc-update add udev-postmount default
rc-update add hwclock boot
rc-update add modules boot
rc-update add sysctl boot
rc-update add hostname boot
rc-update add bootmisc boot
rc-update add mount-ro shutdown
rc-update add killprocs shutdown
rc-update add savecache shutdown
rc-update add dropbear default
rc-update add rmtfs default
# NOTE: ModemManager is intentionally NOT added to boot (Plan B).
# - MM at boot mis-detects sim-missing (N958St Get Slot Status NotSupported) and
#   power-offs the modem. We let the modem boot unmanaged, activate the SIM via
#   qmicli (sim-activate.start), then start MM once the SIM is registered.
# - D-Bus activation is disabled too (see below), else NetworkManager probing
#   would auto-launch MM via org.freedesktop.ModemManager1.service.
rc-update add networkmanager default
rc-update add networkmanager-dispatcher default
rc-update add wpa_supplicant default
rc-update add local default
"

# ===== Everything below runs on the build host (outside the chroot) =====
# The local.d scripts and D-Bus edits MUST be outside the chroot "..." block:
# inside a double-quoted chroot block, shell would expand $VAR / $(...) in the
# heredocs and corrupt the scripts. Using ${CHROOT} paths directly avoids that.

# first-boot: expand rootfs to fill the partition (rootfs is shrunk with resize2fs -M)
mkdir -p ${CHROOT}/etc/local.d
cat > ${CHROOT}/etc/local.d/expand-rootfs.start << 'LOCALEOF'
#!/bin/sh
# expand rootfs to fill partition on first boot
# NOTE: util-linux findmnt is NOT installed on this image; parse /proc/mounts instead.
ROOTFS_DEV=$(awk '$2 == "/" { print $1; exit }' /proc/mounts)
if [ -b "$ROOTFS_DEV" ] && [ ! -f /var/lib/.rootfs-expanded ]; then
    resize2fs "$ROOTFS_DEV" 2>/dev/null
    touch /var/lib/.rootfs-expanded
fi
LOCALEOF
chmod +x ${CHROOT}/etc/local.d/expand-rootfs.start

# SIM activation (Plan B) + modem bring-up + NAT.
# Root cause: N958St modem UIM Get Slot Status returns NotSupported, so MM at
# boot always mis-reports "sim-missing" and power-offs the modem. Instead:
#   - MM is NOT auto-started and its D-Bus activation is disabled, so it never
#     touches the modem during boot;
#   - this script: waits for the QMI port, discovers the USIM AID from the card
#     (works for ANY operator SIM), provisions it until ready, enables RF
#     (CFUN=1), pushes registration, then starts MM.
# After MM starts, ModemManager + NetworkManager auto-create the data bearer and
# configure IP/route/DNS (verified). No manual IP config needed.
cat > ${CHROOT}/etc/local.d/sim-activate.start << 'LOCALEOF'
#!/bin/sh
# SP970 v4: auto SIM activation (Plan B) + bring up MM + NAT
LOG=/var/log/sim-activate.log
echo "[$(date)] === sim-activate start ===" >> $LOG
QMI_BIN="$(command -v qmicli || echo /tmp/qmicli)"
# qmicli needs root to open /dev/wwan0qmi0: use directly as root, else sudo.
if [ "$(id -u)" = "0" ]; then QMI="$QMI_BIN"; else QMI="sudo -n $QMI_BIN"; fi

# 1. udev settle + wait for QMI control port
udevadm trigger 2>/dev/null
udevadm settle 2>/dev/null
i=0
while [ ! -e /dev/wwan0qmi0 ] && [ $i -lt 60 ]; do sleep 1; i=$((i+1)); done
if [ -e /dev/wwan0qmi0 ]; then
    echo "[$(date)] QMI port ready (waited ${i}s)" >> $LOG
else
    echo "[$(date)] FAIL: no QMI port after 60s" >> $LOG
    exit 1
fi

# 2. discover USIM AID from card (retry up to 90s while USIM initializes at boot)
# NOTE: busybox awk breaks on `{f=1;next}`; use plain `/usim/{f=1}` flag instead.
i=0
while [ $i -lt 18 ]; do
    AID=$($QMI -d /dev/wwan0qmi0 --uim-get-card-status 2>/dev/null | \
          awk '/usim/{f=1} f&&/Application ID:/{getline; gsub(/[^0-9A-Fa-f]/,""); print; exit}')
    [ -n "$AID" ] && break
    sleep 5; i=$((i+1))
done
if [ -n "$AID" ]; then
    echo "[$(date)] AID=$AID (after ${i} tries)" >> $LOG
else
    echo "[$(date)] FAIL: USIM AID discovery failed (90s)" >> $LOG
    exit 1
fi

# 3. provision until USIM ready (up to 5 passes)
for i in 1 2 3 4 5; do
    $QMI -d /dev/wwan0qmi0 \
      --uim-change-provisioning-session="session-type=primary-gw-provisioning,activate=yes,slot=1,aid=$AID" \
      >/dev/null 2>&1
    sleep 5
    READY=$($QMI -d /dev/wwan0qmi0 --uim-get-card-status 2>/dev/null | grep -c "Application state: 'ready'")
    [ "$READY" -ge 1 ] && break
done
echo "[$(date)] provision done, USIM ready on pass $i" >> $LOG

# 4. enable RF
printf 'AT+CFUN=1\r' | timeout 8 microcom -t 6000 /dev/wwan0at0 >/dev/null 2>&1
echo "[$(date)] CFUN=1 sent" >> $LOG
sleep 5

# 5. push registration (repeat provision once)
$QMI -d /dev/wwan0qmi0 \
  --uim-change-provisioning-session="session-type=primary-gw-provisioning,activate=yes,slot=1,aid=$AID" \
  >/dev/null 2>&1

# 6. wait for network registration (max ~60s)
i=0
while [ $i -lt 12 ]; do
    REG=$($QMI -d /dev/wwan0qmi0 --nas-get-serving-system 2>/dev/null | grep -c "Registration state: 'registered'")
    [ "$REG" -ge 1 ] && break
    sleep 5; i=$((i+1))
done
echo "[$(date)] registration wait done (${i} iters, reg=${REG:-0})" >> $LOG

# 7. start MM once -> wait until a modem is actually visible, log real errors.
# (One rc-service call only; then poll mmcli - the modem appearing is the real
#  success signal. All rc-service output is logged for boot diagnostics.)
echo "[$(date)] mm-start: rc-service modemmanager start" >> $LOG
MM_OUT=$(rc-service modemmanager start 2>&1)
echo "[$(date)] mm-start rc-service: $(echo "$MM_OUT" | tr '\n' ' ')" >> $LOG
i=0
while [ $i -lt 12 ]; do
    if mmcli -L 2>/dev/null | grep -q "ModemManager1/Modem"; then
        echo "[$(date)] === sim-activate end (modem via mmcli, poll ${i}) ===" >> $LOG
        break
    fi
    sleep 5; i=$((i+1))
done
if ! mmcli -L 2>/dev/null | grep -q "ModemManager1/Modem"; then
    echo "[$(date)] WARN: no modem via mmcli after 60s" >> $LOG
    if pgrep -f "usr/sbin/ModemManager" >/dev/null 2>&1; then
        echo "[$(date)]   MM process present but no modem; mmcli -L: $(mmcli -L 2>&1 | tr '\n' ' ')" >> $LOG
    else
        echo "[$(date)]   MM process absent" >> $LOG
    fi
fi
LOCALEOF
chmod +x ${CHROOT}/etc/local.d/sim-activate.start

# Disable MM D-Bus activation: without this, NetworkManager probing the
# org.freedesktop.ModemManager1 name would auto-launch MM even though it is not
# in the boot runlevel, re-introducing the sim-missing power-off problem.
sed -i 's|Exec=/usr/sbin/ModemManager|Exec=/bin/false|' \
    ${CHROOT}/usr/share/dbus-1/system-services/org.freedesktop.ModemManager1.service 2>/dev/null || true

# Plan A: make /etc/init.d/local depend on dbus/polkit, so its local.d scripts
# (sim-activate) run only after dbus+polkit are up. ModemManager (needs both)
# then starts cleanly in a single rc-service call - no retry hammering.
# 'after *' already exists in the local service; we add explicit dbus/polkit.
sed -i '/^[[:space:]]*after \*/a\\tafter dbus polkit' \
    ${CHROOT}/etc/init.d/local 2>/dev/null || true

# WiFi(192.168.4.x) -> 4G(wwan0) NAT forwarding
cat > ${CHROOT}/etc/local.d/nat.start << 'LOCALEOF'
#!/bin/sh
# WiFi client -> 4G NAT (runs after sim-activate brings up wwan0)
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -C POSTROUTING -o wwan0 -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o wwan0 -j MASQUERADE
LOCALEOF
chmod +x ${CHROOT}/etc/local.d/nat.start

echo 'user ALL=(ALL:ALL) NOPASSWD: ALL' > ${CHROOT}/etc/sudoers.d/user

# add udev rules
cat << EOF > ${CHROOT}/etc/udev/rules.d/10-udc.rules
ACTION=="add", SUBSYSTEM=="udc", RUN+="/sbin/modprobe libcomposite", RUN+="/usr/local/bin/setup_ncm_gadget.sh"
EOF

cat << EOF > ${CHROOT}/etc/udev/rules.d/99-nm-usb0.rules
SUBSYSTEM=="net", ACTION=="add|change|move", ENV{DEVTYPE}=="gadget", ENV{NM_UNMANAGED}="0"
EOF

# enable autologin on console
sed -i '/^tty/ s/^/#/' ${CHROOT}/etc/inittab
echo 'ttyMSM0::respawn:/bin/sh' >> ${CHROOT}/etc/inittab

echo ${HOST_NAME} > ${CHROOT}/etc/hostname
sed -i "/localhost/ s/$/ ${HOST_NAME}/" ${CHROOT}/etc/hosts

# setup NetworkManager
cp configs/*.nmconnection ${CHROOT}/usr/local/etc/NetworkManager/system-connections
chmod 0600 ${CHROOT}/usr/local/etc/NetworkManager/system-connections/*
ln -s ../usr/local/etc/NetworkManager ${CHROOT}/etc/NetworkManager

mkdir -p ${CHROOT}/boot/extlinux
cp configs/extlinux.conf ${CHROOT}/boot/extlinux

# copy custom dtb's
cp dtbs/* ${CHROOT}/boot/dtbs/qcom

# copy WCNSS firmware and NV calibration (SP970)
# Proprietary blobs committed to firmware/<board>/ for self-contained build.
# Source: stock firmware (NON-HLOS.bin + persist partition).
if [ -d firmware/sp970 ]; then
    mkdir -p ${CHROOT}/lib/firmware/wlan/prima
    for f in firmware/sp970/WCNSS.B* firmware/sp970/WCNSS.MDT; do
        [ -e "$f" ] || continue
        # lower-case filename (wcnss.b00 ... wcnss.mdt) as expected by wcnss-pil
        name=$(basename "$f" | tr 'A-Z' 'a-z')
        cp "$f" ${CHROOT}/lib/firmware/$name
    done
    # NV calibration -> /lib/firmware/wlan/prima/
    [ -e firmware/sp970/WCNSS_qcom_wlan_nv.bin ] && \
        cp firmware/sp970/WCNSS_qcom_wlan_nv.bin ${CHROOT}/lib/firmware/wlan/prima/
fi

# copy modem firmware (SP970) to /lib/firmware/
# mss-pil loads mba.mbn, then modem.mdt (with modem.bXX segments).
# Without these the modem remoteproc stays offline (Boot failed: -2).
if [ -d firmware/modem/sp970 ]; then
    mkdir -p ${CHROOT}/lib/firmware
    cp firmware/modem/sp970/mba.mbn ${CHROOT}/lib/firmware/
    cp firmware/modem/sp970/modem.mbn ${CHROOT}/lib/firmware/
    cp firmware/modem/sp970/modem.mdt ${CHROOT}/lib/firmware/
    cp firmware/modem/sp970/modem.b* ${CHROOT}/lib/firmware/
fi

# update fstab
echo "/dev/mmcblk0p14\t/boot\text2\tdefaults\t0 2" >> ${CHROOT}/etc/fstab

# copy gadget-tool templates and script
cp -a configs/templates ${CHROOT}/etc/gt
cp scripts/setup_ncm_gadget.sh ${CHROOT}/usr/local/bin

# write firmware version identifier for quick boot-time identification
# /etc/openstick-version: "v4.0.0 (2026-08-25, commit ff25894c1a2b...)"  [full hash for exact verification]
# /etc/openstick-changelog.md: 随固件打包的变更日志
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIRMWARE_VERSION="$(cat "${REPO_ROOT}/VERSION" 2>/dev/null || echo 0.0.0)"
FIRMWARE_HASH="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
FIRMWARE_HASH_SHORT="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
FIRMWARE_DATE="$(date +%Y-%m-%d)"
echo "v${FIRMWARE_VERSION} (${FIRMWARE_DATE}, commit ${FIRMWARE_HASH_SHORT} ${FIRMWARE_HASH})" \
    > ${CHROOT}/etc/openstick-version
chmod 644 ${CHROOT}/etc/openstick-version
# include changelog in firmware (if present in repo)
if [ -f "${REPO_ROOT}/CHANGELOG.md" ]; then
    cp "${REPO_ROOT}/CHANGELOG.md" ${CHROOT}/etc/openstick-changelog.md
    chmod 644 ${CHROOT}/etc/openstick-changelog.md
fi

# backup rootfs
rm -f alpine_rootfs.tgz
tar cpzf alpine_rootfs.tgz \
    --exclude="root/*" \
    --exclude="newroot" \
    --exclude="usr/bin/qemu-aarch64-static" \
    -C rootfs .
