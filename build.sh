#!/bin/bash

set -e -u

iso_arch=x86_64
iso_name=lucidsystems
iso_label="LUCIDSYSYEMS"
iso_version=$(date +%Y.%m.%d)
install_dir=lucidsystems
work_dir=work
out_dir=out

arch=$(uname -m)
verbose=""
pacman_conf=${work_dir}/pacman.conf
script_path=$(readlink -f ${0%/*})

_usage ()
{
    echo "usage ${0} [options]"
    echo
    echo " General options:"
    echo "    -A <iso_arch>      Set iso target architecture"
    echo "                        Default: ${iso_arch}"
    echo "    -N <iso_name>      Set an iso filename (prefix)"
    echo "                        Default: ${iso_name}"
    echo "    -V <iso_version>   Set an iso version (in filename)"
    echo "                        Default: ${iso_version}"
    echo "    -L <iso_label>     Set an iso label (disk label)"
    echo "                        Default: ${iso_label}"
    echo "    -D <install_dir>   Set an install_dir (directory inside iso)"
    echo "                        Default: ${install_dir}"
    echo "    -w <work_dir>      Set the working directory"
    echo "                        Default: ${work_dir}"
    echo "    -o <out_dir>       Set the output directory"
    echo "                        Default: ${out_dir}"
    echo "    -v                 Enable verbose output"
    echo "    -h                 This help message"
    exit ${1}
}

# Helper function to run make_*() only one time per architecture.
run_once() {
    if [[ ! -e ${work_dir}/build.${1}_${iso_arch} ]]; then
        $1
        touch ${work_dir}/build.${1}_${iso_arch}
    fi
}

# Setup custom pacman.conf with current cache directories.
make_pacman_conf() {
    local _cache_dirs
    _cache_dirs=($(pacman -v 2>&1 | grep '^Cache Dirs:' | sed 's/Cache Dirs:\s*//g'))
    if [[ ${iso_arch} == "x86_64" ]]; then
        sed -r "s|^#?\\s*CacheDir.+|CacheDir = $(echo -n ${_cache_dirs[@]})|g" ${script_path}/pacman.x86_64.conf > ${pacman_conf}
    else
        sed -r "s|^#?\\s*CacheDir.+|CacheDir = $(echo -n ${_cache_dirs[@]})|g" ${script_path}/pacman.i686.conf > ${pacman_conf}
    fi
}

# Base installation, plus needed packages (airootfs)
make_basefs() {
    setarch ${iso_arch} luicdmkiso ${verbose} -w "${work_dir}/${iso_arch}" -C "${pacman_conf}" -D "${install_dir}" init
    setarch ${iso_arch} lucidmkiso ${verbose} -w "${work_dir}/${iso_arch}" -C "${pacman_conf}" -D "${install_dir}" -p "memtest86+ mkinitcpio-nfs-utils nbd" install
}

# Additional packages (airootfs)
make_packages() {
    if [[ ${iso_arch} == x86_64 ]]; then
        # remove gcc-libs to avoid conflict with gcc-libs-multilib
        setarch ${iso_arch} lucidmkiso ${verbose} -w "${work_dir}/${iso_arch}" -C "${pacman_conf}" -D "${install_dir}" -r "pacman -Rdd --noconfirm gcc-libs" run
    fi
    setarch ${iso_arch} luicdmkiso ${verbose} -w "${work_dir}/${iso_arch}" -C "${pacman_conf}" -D "${install_dir}" -p "$(grep -h -v ^# ${script_path}/packages.{both,${iso_arch}})" install
}

# Copy mkinitcpio archiso hooks and build initramfs (airootfs)
make_setup_mkinitcpio() {
    local _hook
    for _hook in archiso archiso_shutdown archiso_pxe_common archiso_pxe_nbd archiso_pxe_http archiso_pxe_nfs archiso_loop_mnt; do
        cp /usr/lib/initcpio/hooks/${_hook} ${work_dir}/${iso_arch}/airootfs/usr/lib/initcpio/hooks
        cp /usr/lib/initcpio/install/${_hook} ${work_dir}/${iso_arch}/airootfs/usr/lib/initcpio/install
    done
    cp /usr/lib/initcpio/install/archiso_kms ${work_dir}/${iso_arch}/airootfs/usr/lib/initcpio/install
    cp /usr/lib/initcpio/archiso_shutdown ${work_dir}/${iso_arch}/airootfs/usr/lib/initcpio
    cp ${script_path}/mkinitcpio.conf ${work_dir}/${iso_arch}/airootfs/etc/mkinitcpio-archiso.conf
    setarch ${iso_arch} lucidmkiso ${verbose} -w "${work_dir}/${iso_arch}" -C "${pacman_conf}" -D "${install_dir}" -r 'mkinitcpio -c /etc/mkinitcpio-archiso.conf -k /boot/vmlinuz-linux -g /boot/archiso.img' run
}

# Customize installation (airootfs)
make_customize_airootfs() {
    cp -af ${script_path}/airootfs ${work_dir}/${iso_arch}

    if [[ ${iso_arch} == x86_64 ]]; then
        rm ${work_dir}/${iso_arch}/airootfs/etc/pacman.i686.conf
        mv ${work_dir}/${iso_arch}/airootfs/etc/pacman.x86_64.conf ${work_dir}/${iso_arch}/airootfs/etc/pacman.conf
    else
        rm ${work_dir}/${iso_arch}/airootfs/etc/pacman.x86_64.conf
        mv ${work_dir}/${iso_arch}/airootfs/etc/pacman.i686.conf ${work_dir}/${iso_arch}/airootfs/etc/pacman.conf
    fi

    wget -O ${work_dir}/${iso_arch}/airootfs/etc/pacman.d/mirrorlist 'https://www.archlinux.org/mirrorlist/?country=all&protocol=http&use_mirror_status=on'

    lynx -dump -nolist 'https://wiki.archlinux.org/index.php/Installation_Guide?action=render' >> ${work_dir}/${iso_arch}/airootfs/root/install.txt

    setarch ${iso_arch} luicdmkiso ${verbose} -w "${work_dir}/${iso_arch}" -C "${pacman_conf}" -D "${install_dir}" -r '/root/customize_airootfs.sh' run
    rm ${work_dir}/${iso_arch}/airootfs/root/customize_airootfs.sh
    
    setarch ${iso_arch} luicdmkiso ${verbose} -w "${work_dir}/${iso_arch}" -C "${pacman_conf}" -D "${install_dir}" -r 'python /root/customize_airootfs.py' run
    rm ${work_dir}/${iso_arch}/airootfs/root/customize_airootfs.py
}

# Prepare kernel/initramfs ${install_dir}/boot/
make_boot() {
    mkdir -p ${work_dir}/iso/${install_dir}/boot/${iso_arch}
    cp ${work_dir}/${iso_arch}/airootfs/boot/archiso.img ${work_dir}/iso/${install_dir}/boot/${iso_arch}/archiso.img
    cp ${work_dir}/${iso_arch}/airootfs/boot/vmlinuz-linux ${work_dir}/iso/${install_dir}/boot/${iso_arch}/vmlinuz
}

# Add other aditional/extra files to ${install_dir}/boot/
make_boot_extra() {
    cp ${work_dir}/${iso_arch}/airootfs/boot/memtest86+/memtest.bin ${work_dir}/iso/${install_dir}/boot/memtest
    cp ${work_dir}/${iso_arch}/airootfs/usr/share/licenses/common/GPL2/license.txt ${work_dir}/iso/${install_dir}/boot/memtest.COPYING
}

# Fetch packages for offline installation
make_pkgcache() {
    for pkg in $(grep -h -v ^# ${script_path}/pkgcache.{both,${iso_arch}})
    do
        rm -f /var/cache/pacman/pkg/${pkg}-*
        # Get the download link from pacman
		pkg_path=$(pacman -Sp ${pkg})
        # Download the package
		wget -P ${work_dir}/${iso_arch}/airootfs/var/cache/pacman/pkg ${pkg_path}
        # Download the signature file
		wget -P ${work_dir}/${iso_arch}/airootfs/var/cache/pacman/pkg ${pkg_path}.sig
    done
}

# Prepare /${install_dir}/boot/syslinux
make_syslinux() {
    mkdir -p ${work_dir}/iso/${install_dir}/boot/syslinux
    for _cfg in ${script_path}/syslinux/*.cfg; do
        sed "s|%ARCHISO_LABEL%|${iso_label}|g;
             s|%INSTALL_DIR%|${install_dir}|g;
			 s|%ARCH%|${iso_arch}|g" ${_cfg} > ${work_dir}/iso/${install_dir}/boot/syslinux/${_cfg##*/}
    done
    cp ${script_path}/syslinux/splash.png ${work_dir}/iso/${install_dir}/boot/syslinux
    cp ${work_dir}/${iso_arch}/airootfs/usr/lib/syslinux/bios/*.c32 ${work_dir}/iso/${install_dir}/boot/syslinux
    cp ${work_dir}/${iso_arch}/airootfs/usr/lib/syslinux/bios/lpxelinux.0 ${work_dir}/iso/${install_dir}/boot/syslinux
    cp ${work_dir}/${iso_arch}/airootfs/usr/lib/syslinux/bios/memdisk ${work_dir}/iso/${install_dir}/boot/syslinux
    mkdir -p ${work_dir}/iso/${install_dir}/boot/syslinux/hdt
    gzip -c -9 ${work_dir}/${iso_arch}/airootfs/usr/share/hwdata/pci.ids > ${work_dir}/iso/${install_dir}/boot/syslinux/hdt/pciids.gz
    gzip -c -9 ${work_dir}/${iso_arch}/airootfs/usr/lib/modules/*-ARCH/modules.alias > ${work_dir}/iso/${install_dir}/boot/syslinux/hdt/modalias.gz
}

# Prepare /isolinux
make_isolinux() {
    mkdir -p ${work_dir}/iso/isolinux
    sed "s|%INSTALL_DIR%|${install_dir}|g" ${script_path}/isolinux/isolinux.cfg > ${work_dir}/iso/isolinux/isolinux.cfg
    cp ${work_dir}/${iso_arch}/airootfs/usr/lib/syslinux/bios/isolinux.bin ${work_dir}/iso/isolinux/
    cp ${work_dir}/${iso_arch}/airootfs/usr/lib/syslinux/bios/isohdpfx.bin ${work_dir}/iso/isolinux/
    cp ${work_dir}/${iso_arch}/airootfs/usr/lib/syslinux/bios/ldlinux.c32 ${work_dir}/iso/isolinux/
}

# Prepare /EFI
make_efi() {
    mkdir -p ${work_dir}/iso/EFI/boot
    cp ${work_dir}/x86_64/airootfs/usr/lib/prebootloader/PreLoader.efi ${work_dir}/iso/EFI/boot/bootx64.efi
    cp ${work_dir}/x86_64/airootfs/usr/lib/prebootloader/HashTool.efi ${work_dir}/iso/EFI/boot/

    cp ${work_dir}/x86_64/airootfs/usr/lib/gummiboot/gummibootx64.efi ${work_dir}/iso/EFI/boot/loader.efi

    mkdir -p ${work_dir}/iso/loader/entries
    cp ${script_path}/efiboot/loader/loader.conf ${work_dir}/iso/loader/
    cp ${script_path}/efiboot/loader/entries/uefi-shell-v2-x86_64.conf ${work_dir}/iso/loader/entries/
    cp ${script_path}/efiboot/loader/entries/uefi-shell-v1-x86_64.conf ${work_dir}/iso/loader/entries/

    sed "s|%ARCHISO_LABEL%|${iso_label}|g;
         s|%INSTALL_DIR%|${install_dir}|g" \
        ${script_path}/efiboot/loader/entries/archiso-x86_64-usb.conf > ${work_dir}/iso/loader/entries/archiso-x86_64.conf

    # EFI Shell 2.0 for UEFI 2.3+ ( http://sourceforge.net/apps/mediawiki/tianocore/index.php?title=UEFI_Shell )
    curl -o ${work_dir}/iso/EFI/shellx64_v2.efi https://svn.code.sf.net/p/edk2/code/trunk/edk2/ShellBinPkg/UefiShell/X64/Shell.efi
    # EFI Shell 1.0 for non UEFI 2.3+ ( http://sourceforge.net/apps/mediawiki/tianocore/index.php?title=Efi-shell )
    curl -o ${work_dir}/iso/EFI/shellx64_v1.efi https://svn.code.sf.net/p/edk2/code/trunk/edk2/EdkShellBinPkg/FullShell/X64/Shell_Full.efi
}

# Prepare efiboot.img::/EFI for "El Torito" EFI boot mode
make_efiboot() {
    mkdir -p ${work_dir}/iso/EFI/archiso
    truncate -s 31M ${work_dir}/iso/EFI/archiso/efiboot.img
    mkfs.vfat -n ARCHISO_EFI ${work_dir}/iso/EFI/archiso/efiboot.img

    mkdir -p ${work_dir}/efiboot
    mount ${work_dir}/iso/EFI/archiso/efiboot.img ${work_dir}/efiboot

    mkdir -p ${work_dir}/efiboot/EFI/archiso
    cp ${work_dir}/iso/${install_dir}/boot/x86_64/vmlinuz ${work_dir}/efiboot/EFI/archiso/vmlinuz.efi
    cp ${work_dir}/iso/${install_dir}/boot/x86_64/archiso.img ${work_dir}/efiboot/EFI/archiso/archiso.img

    mkdir -p ${work_dir}/efiboot/EFI/boot
    cp ${work_dir}/x86_64/airootfs/usr/lib/prebootloader/PreLoader.efi ${work_dir}/efiboot/EFI/boot/bootx64.efi
    cp ${work_dir}/x86_64/airootfs/usr/lib/prebootloader/HashTool.efi ${work_dir}/efiboot/EFI/boot/

    cp ${work_dir}/x86_64/airootfs/usr/lib/gummiboot/gummibootx64.efi ${work_dir}/efiboot/EFI/boot/loader.efi

    mkdir -p ${work_dir}/efiboot/loader/entries
    cp ${script_path}/efiboot/loader/loader.conf ${work_dir}/efiboot/loader/
    cp ${script_path}/efiboot/loader/entries/uefi-shell-v2-x86_64.conf ${work_dir}/efiboot/loader/entries/
    cp ${script_path}/efiboot/loader/entries/uefi-shell-v1-x86_64.conf ${work_dir}/efiboot/loader/entries/

    sed "s|%ARCHISO_LABEL%|${iso_label}|g;
         s|%INSTALL_DIR%|${install_dir}|g" \
        ${script_path}/efiboot/loader/entries/archiso-x86_64-cd.conf > ${work_dir}/efiboot/loader/entries/archiso-x86_64.conf

    cp ${work_dir}/iso/EFI/shellx64_v2.efi ${work_dir}/efiboot/EFI/
    cp ${work_dir}/iso/EFI/shellx64_v1.efi ${work_dir}/efiboot/EFI/

    umount ${work_dir}/efiboot
}

# Build airootfs filesystem image
make_prepare() {
    cp -a -l -f ${work_dir}/${iso_arch}/airootfs ${work_dir}
    setarch ${iso_arch} luicdmkiso ${verbose} -w "${work_dir}" -D "${install_dir}" pkglist
    setarch ${iso_arch} luicdmkiso ${verbose} -w "${work_dir}" -D "${install_dir}" prepare
    rm -rf ${work_dir}/airootfs
}

# Build ISO
make_iso() {
    luicdmkiso ${verbose} -w "${work_dir}" -D "${install_dir}" -L "${iso_label}" -o "${out_dir}" iso "${iso_name}-${iso_version}-${iso_arch}.iso"
}

if [[ ${EUID} -ne 0 ]]; then
    echo "This script must be run as root."
    _usage 1
fi

if [[ ${iso_arch} != x86_64 ]]; then
    echo "This script needs to be run on x86_64"
    _usage 1
fi

while getopts 'A:N:V:L:D:w:o:vh' arg; do
    case "${arg}" in
		A) iso_arch="${OPTARG}" ;;
        N) iso_name="${OPTARG}" ;;
        V) iso_version="${OPTARG}" ;;
        L) iso_label="${OPTARG}" ;;
        D) install_dir="${OPTARG}" ;;
        w) work_dir="${OPTARG}" ;;
        o) out_dir="${OPTARG}" ;;
        v) verbose="-v" ;;
        h) _usage 0 ;;
        *)
           echo "Invalid argument '${arg}'"
           _usage 1
           ;;
    esac
done

mkdir -p ${work_dir}

run_once make_pacman_conf
run_once make_basefs
run_once make_packages
run_once make_setup_mkinitcpio
run_once make_customize_airootfs
run_once make_boot
run_once make_boot_extra
run_once make_pkgcache
run_once make_syslinux
run_once make_isolinux

if [[ ${iso_arch} == x86_64 ]]; then
    run_once make_efi
    run_once make_efiboot
fi

run_once make_prepare
run_once make_iso

# Remount pts with correct mode
mount -o remount,gid=5,mode=620 /dev/pts
