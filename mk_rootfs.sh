#!/bin/bash

set -euo pipefail

SCRIPT_NAME="${0##*/}"
WORKSPACE_PATH="${PWD}"
# SCRIPT_PATH=$(cd "$(dirname "$0")"; pwd)
# SCRIPT_PATH=`S=\`readlink "$0"\`; [ -z "$S" ] && S=$0; dirname $S`
SCRIPT_PATH="$(dirname "$(readlink -f "$0")")"

# ========= Load Common =========
if [ -f "${SCRIPT_PATH}/common.sh" ]; then
	source "${SCRIPT_PATH}/common.sh"
else
	echo "Missing common.sh script!"
	exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
	echo_error "Please run script with root!"
	exit 1
fi

init() {
	source "${SCRIPT_PATH}/env/common/${SCRIPT_NAME}"

	HOST_ARCH="$(uname -m)"
	XZ_DEFAULTS="-T 0"
	MIRROR_URL="http://mirrors.ustc.edu.cn/debian/"
	TARGET_FS=${WORKSPACE_PATH}/debian_${TARGET_VERSION}
	# LC_ALL=en_US.UTF-8
	# LANGUAGE=en_US.UTF-8
	# LANG=en_US.UTF-8
	export DEBIAN_FRONTEND=noninteractive
	export DEBCONF_NONINTERACTIVE_SEEN=true

	if ! [[ ("$HOST_ARCH" == "aarch64" && "$ARCH" == "arm64") || ("${HOST_ARCH:0:3}" == "arm" && "$ARCH" == "arm") ]]; then
		PKG_LIST+=" qemu-user-static"
	fi
}

build_info() {
	echo_title "================ Build Info ================"
	echo_item "ARCH" "${ARCH}"
	echo_item "TARGET_ARCH" "${TARGET_ARCH}"
	echo_item "TARGET_VERSION" "${TARGET_VERSION}"
	echo_item "TARGET_ROOTFS" "${TARGET_FS}"
	echo_item "MIRROR_URL" "${MIRROR_URL}"
}

umount_proc() {
	umount -l "${TARGET_FS}/dev/pts" 2>/dev/null || true
	umount -l "${TARGET_FS}/dev" 2>/dev/null || true
	umount -l "${TARGET_FS}/sys" 2>/dev/null || true
	umount -l "${TARGET_FS}/proc" 2>/dev/null || true
}

mount_proc() {
	umount_proc
	mount -t proc /proc "${TARGET_FS}/proc"
	mount -t sysfs /sys "${TARGET_FS}/sys"
	mount --bind /dev "${TARGET_FS}/dev"
	mount --bind /dev/pts "${TARGET_FS}/dev/pts"
}

create_base_fs() {
	trap umount_proc EXIT
	check_dependency "${DEPENDENCY_LIST}"

	if [[ -e "${TARGET_FS}" ]]; then
		echo_error "Directory already exists: ${TARGET_FS}"
		return 1
	fi

	echo_info "Creating rootfs directory: ${TARGET_FS}"
	mkdir -p "${TARGET_FS}"

	echo_info "Stage 1: debootstrap (foreign)"
	debootstrap --arch="${ARCH}" --foreign "${TARGET_VERSION}" "${TARGET_FS}" "${MIRROR_URL}"

	QEMU_BIN=qemu-${ARCH}-static

	if [[ ("$HOST_ARCH" == "aarch64" && "$ARCH" == "arm64") || ("${HOST_ARCH:0:3}" == "arm" && "${ARCH:0:3}" == "arm") ]]; then
		echo_info "QEMU not needed on native arch"
	else
		echo_info "Copying QEMU binary: ${QEMU_BIN}"
		cp "/usr/bin/${QEMU_BIN}" "${TARGET_FS}/usr/bin/"
	fi

	echo_info "Stage 2: second-stage debootstrap"
	cat >"${TARGET_FS}/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
	chmod +x "${TARGET_FS}/usr/sbin/policy-rc.d"
	mount_proc
	chroot "${TARGET_FS}" /debootstrap/debootstrap --second-stage
	chroot "${TARGET_FS}" apt update
	chroot "${TARGET_FS}" apt install -y debian-archive-keyring

	echo_info "Configuring base system"
	chroot "${TARGET_FS}" dpkg --configure -a

	echo_info "Installing basic packages"
	chroot "${TARGET_FS}" apt install -y sudo vim openssh-server bash-completion ca-certificates htop locales wget curl xz-utils bsdextrautils binutils file
	# chroot ${TARGET_FS} apt install -y net-tools network-manager systemd-timesyncd wireless-regdb wpasupplicant iw wireless-tools zram-tools man-db
	# chroot ${TARGET_FS} apt install -y network-manager modemmanager qrtr-tools rmtfs firmware-qcom-soc # For Qualcomm Device
	# dpkg-reconfigure locales
	umount_proc
	rm "${TARGET_FS}/usr/sbin/policy-rc.d"

	echo_info "Base rootfs build completed"
}

chroot_fs() {
	trap umount_proc EXIT
	check_dependency "${DEPENDENCY_LIST}"

	if [[ ! -d "${TARGET_FS}" ]]; then
		echo_error "Rootfs directory not found: ${TARGET_FS}"
		return 1
	fi

	mount_proc
	cat >"${TARGET_FS}/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
	chmod +x "${TARGET_FS}/usr/sbin/policy-rc.d"
	chroot "${TARGET_FS}" /bin/bash
	umount_proc
	rm "${TARGET_FS}/usr/sbin/policy-rc.d"
}

archive_fs() {
	if [[ ! -d "${TARGET_FS}" ]]; then
		echo_error "Rootfs directory not found: ${TARGET_FS}"
		return 1
	fi

	local pack_date="$(date +%Y%m%d_%H%M)"
	local pack_name="${TARGET_FS}_${pack_date}.tar.xz"

	echo_info "Archiving ${TARGET_FS} => ${pack_name}"
	tar cJfp "${pack_name}" \
		--numeric-owner --xattrs --acls \
		--exclude="usr/bin/qemu-${TARGET_ARCH}-static" \
		-C "$(dirname "${TARGET_FS}")" "$(basename "${TARGET_FS}")"
	echo_info "Archive completed"
}

copy_fs() {
	if [[ ! -d "${TARGET_FS}" ]]; then
		echo_error "Rootfs directory not found: ${TARGET_FS}"
		return 1
	fi

	read -rp "Enter target path (e.g., /mnt/tf): " TF_PATH
	if [[ ! -d "${TF_PATH}" ]]; then
		echo_error "Target path does not exist: ${TF_PATH}"
		return 1
	fi

	echo_info "Copying files to ${TF_PATH}..."
	cp -a "${TARGET_FS}/." "${TF_PATH}/"
	sync
	echo_info "Copy completed"
}

show_menu() {
	echo_title "================ Menu Options ================"
	echo_menu 0 "Install Required Packages"
	echo_menu 1 "Create Base ROOTFS"
	echo_menu 2 "Chroot into ROOTFS"
	echo_menu 3 "Archive ROOTFS"
	echo_menu 4 "Copy ROOTFS to Destination"

	read -rp "Please Select: >> " OPT
	case "${OPT}" in
	0) install_pkg "${PKG_LIST}" ;;
	1) create_base_fs ;;
	2) chroot_fs ;;
	3) archive_fs ;;
	4) copy_fs ;;
	*) echo_error "Invalid option: [${OPT}]" ;;
	esac
}

main() {
	trap umount_proc EXIT
	init
	build_info
	show_menu
}

main
