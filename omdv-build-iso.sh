#!/bin/bash
#set -x
# OpenMandriva Association 2012
# Original author: Bernhard Rosenkraenzer <bero@lindev.ch>
# Modified on 2014 by: Tomasz Paweł Gajc <tpgxyz@gmail.com>

# This tool is licensed under GPL license
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, write to the Free Software
#    Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
#

# This tools is specified to build OpenMandriva Lx distribution ISO

usage_help() {
    echo ""
    echo "Please run script with arguments."
    echo ""
    echo "usage $0 [options]"
    echo ""
    echo " general options:"
    echo " --arch= Architecture of packages: i586, x86_64"
    echo " --tree= Branch of software repository: cooker, openmandriva2014.0"
    echo " --version= Version for software repository: 2015.0, 2014.1, 2014.0"
    echo " --release_id= Release identifer: alpha, beta, rc, final"
    echo " --type= User environment type on ISO: kde4, mate, lxqt, minimal, icewm, hawaii, xfce4"
    echo " --displaymanager= Display Manager used in desktop environemt: kdm, gdm, lightdm, sddm, xdm"
    echo " --debug Enable debug output"
    echo ""
    echo "Exiting."
    exit 1
}

# use only allowed arguments
if [ $# -ge 1 ]; then
    for k in "$@"; do
	case "$k" in
		--arch=*)
        	    EXTARCH=${k#*=}
        	    shift
        	    ;;
    		--tree=*)
        	    TREE=${k#*=}
        	    shift
        	    ;;
		--version=*)
        	    VERSION=${k#*=}
        	    if [[ "${VERSION,,}" == "cooker" ]]
        	    then
        		VERSION="`date +%Y.0`"
        	    fi
        	    shift
        	    ;;
    		--release_id=*)
        	    RELEASE_ID=${k#*=}
        	    shift
        	    ;;
		--type=*)
        	    TYPE=${k#*=}
        	    shift
        	    ;;
    		--displaymanager=*)
        	    DISPLAYMANAGER=${k#*=}
        	    shift
        	    ;;
    		--debug)
        	    DEBUG=debug
        	    shift
        	    ;;
        	--help)
        	    usage_help
        	    ;;
    		*)
		    usage_help
        	    ;;
	    esac
	shift
    done
else
    usage_help
fi

# run only when root
if [ "`id -u`" != "0" ]; then
    # We need to be root for umount and friends to work...
    exec sudo $0 "$@"
    echo Run me as root.
    exit 1
fi

# check whether script is executed inside ABF (www.abf.io)
if echo $(realpath $(dirname $0)) | grep -q /home/vagrant; then
    ABF=1
    OURDIR=$(realpath $(dirname $0))
else
    OURDIR="/usr/share/omdv-build-iso"
	# generate build id if runningoutside ABF
	BUILD_ID=$(($RANDOM%9999+1000))
fi

# default definitions
DIST=omdv
[ -z "$EXTARCH" ] && EXTARCH=`uname -m`
[ -z "${TREE}" ] && TREE=cooker
[ -z "${VERSION}" ] && VERSION="`date +%Y.0`"
[ -z "${RELEASE_ID}" ] && RELEASE_ID=alpha
[ -z "${TYPE}" ] && TYPE=kde4
[ -z "${DISPLAYMANAGER}" ] && DISPLAYMANAGER="kdm"
[ -z "${DEBUG}" ] && DEBUG="nodebug"

# always build free ISO
FREE=1

SUDO=sudo
[ "`id -u`" = "0" ] && SUDO=""
LOGDIR="."
# set up main chroot
ROOTNAME="`mktemp -d /tmp/liverootXXXXXX`"
[ -z "$ROOTNAME" ] && ROOTNAME=/tmp/liveroot.$$
CHROOTNAME="$ROOTNAME"/BASE
ISOROOTNAME="$ROOTNAME"/ISO
ISO_DATE="`echo $(date -u +%Y-%m-%d-%H-%M-%S-00) | sed -e s/-//g`"
# in case when i386 is passed, fall back to i586
[ "$EXTARCH" = "i386" ] && EXTARCH=i586

# ISO name logic
if [ "${RELEASE_ID,,}" == "final" ]; then
    PRODUCT_ID="OpenMandrivaLx.$VERSION-$TYPE"
else
    if [[ "${RELEASE_ID,,}" == "alpha" ]]; then
	RELEASE_ID="$RELEASE_ID.`date +%Y%m%d`"
    fi
    PRODUCT_ID="OpenMandrivaLx.$VERSION-$RELEASE_ID-$TYPE"
fi

LABEL="OMVLX"
#[ `echo $LABEL | wc -m` -gt 32 ] && LABEL="OpenMandrivaLx_$VERSION"
#[ `echo $LABEL | wc -m` -gt 32 ] && LABEL="`echo $LABEL |cut -b1-32`"

# start functions

umountAll() {
    echo "Umounting all."
    unset KERNEL_ISO
    $SUDO umount -l "$1"/proc || :
    $SUDO umount -l "$1"/sys || :
    $SUDO umount -l "$1"/dev/pts || :
    $SUDO umount -l "$1"/dev || :
}

error() {
    echo "Something went wrong. Exiting"
    unset KERNEL_ISO
    unset UEFI
    unset MIRRORLIST
    umountAll "$CHROOTNAME"
    $SUDO rm -rf "$ROOTNAME"
    exit 1
}

# Don't leave potentially dangerous stuff if we had to error out...
trap error ERR

updateSystem() {
    #Force update of critical packages
	if [ "$ABF" = "1" ]; then
	    echo "We are inside ABF (www.abf.io)"
	    urpmq --list-url
	    urpmi.update -ff updates
    # inside ABF, lxc-container which is used to run this script is based
    # on Rosa2012 which does not have cdrtools
	    urpmi --no-verify-rpm perl-URPM dosfstools grub2 xorriso syslinux squashfs-tools 
	else
	    echo "Building in user custom environment"
	    urpmi --no-verify-rpm perl-URPM dosfstools grub2 xorriso syslinux grub2 squashfs-tools
	fi
}

getPkgList() {

    #Support for building released isos
    if [ ${TREE,,} = "cooker" ]; then
        BRANCH=cooker
    else
        BRANCH="$TREE$VERSION"
    fi

    # update iso-pkg-lists from ABF if missing
    if [ ! -d $OURDIR/iso-pkg-lists-$BRANCH ]; then
	echo "Could not find $OURDIR/iso-pkg-lists-$BRANCH. Downloading from ABF."
	# download iso packages lists from www.abf.io
	PKGLIST="https://abf.io/openmandriva/iso-pkg-lists/archive/iso-pkg-lists-$BRANCH.tar.gz"
	$SUDO wget --tries=10 -O iso-pkg-lists-$BRANCH.tar.gz --content-disposition $PKGLIST
	$SUDO tar -xf iso-pkg-lists-$BRANCH.tar.gz
	# Why not retain the unique list name it will help when people want their own spins ?
	$SUDO rm -f iso-pkg-lists-$BRANCH.tar.gz
    fi

    # export file list
    FILELISTS="$OURDIR/iso-pkg-lists-$BRANCH/$DIST-$TYPE.lst"

    if [ ! -e "$FILELISTS" ]; then
	echo "$FILELISTS does not exists. Exiting"
	error
    fi
}

showInfo() {
	echo $'###\n'
	echo "Building ISO with arguments:"
	echo "Distribution is $DIST"
	echo "Architecture is $EXTARCH"
	echo "Tree is $TREE"
	echo "Version is $VERSION"
	echo "Release ID is $RELEASE_ID"
	echo "Type is ${TYPE^^}"
    if [ "${TYPE,,}" = "minimal" ]; then
	echo "No display manager for minimal ISO."
    else
	echo "Display Manager is ${DISPLAYMANAGER,,}"
    fi
	echo "ISO label is $LABEL"
	echo "Build ID is $BUILD_ID"
	echo $'###\n'
}

# Usage: parsePkgList xyz.lst
# Shows the list of packages in the package list file (including any packages
# mentioned by other package list files being %include-d)
parsePkgList() {
	LINE=0
	cat "$1" | while read r; do
		LINE=$((LINE+1))
		SANITIZED="`echo $r | sed -e 's,	, ,g;s,  *, ,g;s,^ ,,;s, $,,;s,#.*,,'`"
		[ -z "$SANITIZED" ] && continue
		if [ "`echo $SANITIZED | cut -b1-9`" = "%include " ]; then
			INC="$(dirname "$1")/`echo $SANITIZED | cut -b10- | sed -e 's/^\..*\///g'`"
			if ! [ -e "$INC" ]; then
				echo "ERROR: Package list doesn't exist: $INC (included from $1 line $LINE)" >&2
				error
			fi

			parsePkgList $(dirname "$1")/"`echo $SANITIZED | cut -b10- | sed -e 's/^\..*\///g'`"
			continue
		fi
		echo $SANITIZED
	done
}

# Usage: createChroot packages.lst /target/dir
# Creates a chroot environment with all packages in the packages.lst
# file and their dependencies in /target/dir
createChroot() {
	# path to repository
	if [ "${TREE,,}" == "cooker" ]; then
		REPOPATH="http://abf-downloads.abf.io/$TREE/repository/$EXTARCH/"
	else
		REPOPATH="http://abf-downloads.abf.io/$TREE$VERSION/repository/$EXTARCH/"
	fi

	echo "Creating chroot $CHROOTNAME"
	# Make sure /proc, /sys and friends are mounted so %post scripts can use them
	$SUDO mkdir -p "$CHROOTNAME"/proc "$CHROOTNAME"/sys "$CHROOTNAME"/dev "$CHROOTNAME"/dev/pts

	echo "Adding urpmi repository $REPOPATH into $CHROOTNAME"

	if [ "$FREE" = "0" ]; then
		$SUDO urpmi.addmedia --urpmi-root "$CHROOTNAME" --distrib $REPOPATH
	else
		$SUDO urpmi.addmedia --urpmi-root "$CHROOTNAME" "Main" $REPOPATH/main/release
		$SUDO urpmi.addmedia --urpmi-root "$CHROOTNAME" "Contrib" $REPOPATH/contrib/release
		# this one is needed to grab firmwares
		$SUDO urpmi.addmedia --urpmi-root "$CHROOTNAME" "Non-free" $REPOPATH/non-free/release

		if [ "${TREE,,}" != "cooker" ]; then
			$SUDO urpmi.addmedia --urpmi-root "$CHROOTNAME" "MainUpdates" $REPOPATH/main/updates
			$SUDO urpmi.addmedia --urpmi-root "$CHROOTNAME" "ContribUpdates" $REPOPATH/contrib/updates
			# this one is needed to grab firmwares
			$SUDO urpmi.addmedia --urpmi-root "$CHROOTNAME" "Non-freeUpdates" $REPOPATH/non-free/updates
		fi
	fi

	# update medias
	$SUDO urpmi.update -a -c -ff --wget --urpmi-root "$CHROOTNAME" main
	if [ "${TREE,,}" != "cooker" ]; then
		echo "Updating urpmi repositories in $CHROOTNAME"
		$SUDO urpmi.update -a -c -ff --wget --urpmi-root "$CHROOTNAME" updates
	fi

	$SUDO mount --bind /proc "$CHROOTNAME"/proc
	$SUDO mount --bind /sys "$CHROOTNAME"/sys
	$SUDO mount --bind /dev "$CHROOTNAME"/dev
	$SUDO mount --bind /dev/pts "$CHROOTNAME"/dev/pts

	# start rpm packages installation
	echo "Start installing packages in $CHROOTNAME"
	parsePkgList "$FILELISTS" | xargs $SUDO urpmi --urpmi-root "$CHROOTNAME" --download-all --no-suggests --no-verify-rpm --fastunsafe --ignoresize --nolock --auto

	if [[ $? != 0 ]] && [ ${TREE,,} != "cooker" ]; then
	    echo "Can not install packages from $FILELISTS";
	    error
	fi

	if [ ! -e "$CHROOTNAME"/usr/lib/syslinux/isolinux.bin ]; then
		echo "Syslinux is missing in chroot. Installing it."
		$SUDO urpmi --urpmi-root "$CHROOTNAME" --no-suggests --no-verify-rpm --fastunsafe --ignoresize --nolock --auto syslinux
	fi

	# check CHROOT
	if [ ! -d  "$CHROOTNAME"/lib/modules ]; then
		echo "Broken chroot installation. Exiting"
		error
	fi

	# this will be needed in future
	pushd "$CHROOTNAME"/lib/modules
	    KERNEL_ISO=`ls -d --sort=time [0-9]* |head -n1 | sed -e 's,/$,,'`
	    export KERNEL_ISO
	popd

}

createInitrd() {

	# check if dracut is installed
	if [ ! -f "$CHROOTNAME"/usr/sbin/dracut ]; then
		echo "dracut is not insalled inside chroot. Exiting."
		error
	fi

	# build initrd for syslinux
	echo "Building liveinitrd-$KERNEL_ISO for syslinux"
	if [ ! -f $OURDIR/extraconfig/etc/dracut.conf.d/60-dracut-isobuild.conf ]; then
		echo "Missing $OURDIR/extraconfig/etc/dracut.conf.d/60-dracut-isobuild.conf . Exiting."
		error
	fi
	$SUDO cp -rfT $OURDIR/extraconfig/etc/dracut.conf.d/60-dracut-isobuild.conf "$CHROOTNAME"/etc/dracut.conf.d/60-dracut-isobuild.conf

	if [ ! -d "$CHROOTNAME"/usr/lib/dracut/modules.d/90liveiso ]; then
	    echo "Dracut is missing 90liveiso module. Installing it."

	    if [ ! -d $OURDIR/dracut/90liveiso ]; then
		echo "Cant find 90liveiso dracut module in $OURDIR/dracut. Exiting."
		error
	    fi

	    $SUDO cp -a -f $OURDIR/dracut/90liveiso "$CHROOTNAME"/usr/lib/dracut/modules.d/
	    $SUDO chmod 0755 "$CHROOTNAME"/usr/lib/dracut/modules.d/90liveiso
	    $SUDO chmod 0755 "$CHROOTNAME"/usr/lib/dracut/modules.d/90liveiso/*.sh
	fi

	# fugly hack to get /dev/disk/by-label
	$SUDO sed -i -e '/KERNEL!="sr\*\", IMPORT{builtin}="blkid"/s/sr/none/g' -e '/TEST=="whole_disk", GOTO="persistent_storage_end"/s/TEST/# TEST/g' "$CHROOTNAME"/lib/udev/rules.d/60-persistent-storage.rules

	if [ -f "$CHROOTNAME"/boot/liveinitrd.img ]; then
	    $SUDO rm -rf "$CHROOTNAME"/boot/liveinitrd.img
	fi

	$SUDO chroot "$CHROOTNAME" /usr/sbin/dracut -N -f --no-early-microcode --nofscks --noprelink  /boot/liveinitrd.img --conf /etc/dracut.conf.d/60-dracut-isobuild.conf $KERNEL_ISO

	if [ ! -f "$CHROOTNAME"/boot/liveinitrd.img ]; then
	    echo "File "$CHROOTNAME"/boot/liveinitrd.img does not exist. Exiting."
	    error
	fi

	echo "Building initrd-$KERNEL_ISO inside chroot"
	# remove old initrd
	$SUDO rm -rf "$CHROOTNAME"/boot/initrd-$KERNEL_ISO.img
	$SUDO rm -rf "$CHROOTNAME"/boot/initrd0.img

	# remove config for liveinitrd
	$SUDO rm -rf "$CHROOTNAME"/etc/dracut.conf.d/60-dracut-isobuild.conf
	$SUDO rm -rf "$CHROOTNAME"/usr/lib/dracut/modules.d/90liveiso

	$SUDO chroot "$CHROOTNAME" /usr/sbin/dracut -N -f /boot/initrd-$KERNEL_ISO.img $KERNEL_ISO
	$SUDO ln -s ../boot/initrd-$KERNEL_ISO.img "$CHROOTNAME"/boot/initrd0.img

}

# Usage: setupGrub2 /target/dir
# Sets up grub2 to boot /target/dir
setupGrub2() {
	if [ ! -e "$1"/usr/bin/grub2-mkimage ]; then
		echo "Missing grub2-mkimage in installation."
		error
	fi
	grub2_lib="/usr/lib/grub/i386-pc"
	core_img=$(mktemp)

	echo "TODO - add grub2 support"
	mkdir -p "$2"/boot/grub2 "$2"/boot/grub2/themes "2"/boot/grub2/locale
	for i in "$1"$grub2_lib/*.mod "$1"$grub2_lib/*.lst "$1"$grub2_lib/efiemu*.o "$1"/usr/share/grub/*.pf2; do
	    $SUDO cp -f $i "$2"/boot/grub2 ;
	done
	$SUDO chroot "$1" /usr/bin/grub2-mkimage -p /boot/grub2 -d "$1"$grub2_lib -o ${core_img} -O i386-pc biosdisk iso9660
	$SUDO cat "$1"/usr/lib/grub/i386-pc/boot.img ${core_img} > "$2"/boot/grub2/grub_eltorito
	XORRISO_OPTIONS="${XORRISO_OPTIONS} -b boot/grub2/grub_eltorito -J"
	echo "End grub2."
}

# Usage: setupSysLinux /target/dir
# Sets up syslinux to boot /target/dir
setupSyslinux() {
	echo "Starting syslinux setup."
	# default options for xorriso
	XORRISO_OPTIONS=" -b boot/syslinux/isolinux.bin -no-emul-boot -boot-info-table -boot-load-size 4 -boot-info-table -c boot/syslinux/boot.cat"

	$SUDO mkdir -p "$2"/boot/syslinux "$2"/boot/syslinux/hdt
	$SUDO chmod 1777 "$2"/boot/syslinux
	# install syslinux programs
	echo "Installing syslinux programs."
        for i in isolinux.bin vesamenu.c32 hdt.c32 poweroff.com chain.c32 isohdpfx.bin memdisk; do
    	    if [ ! -f "$1"/usr/lib/syslinux/$i ]; then
		echo "$i does not exists. Exiting."
		error
	    fi
    	    $SUDO cp -f "$1"/usr/lib/syslinux/$i "$2"/boot/syslinux ;
        done
	# install pci.ids
	$SUDO gzip -c -9 "$1"/usr/share/pci.ids > "$2"/boot/syslinux/hdt/pciids.gz
	$SUDO gzip -c -9 "$1"/lib/modules/*/modules.alias > "$2"/boot/syslinux/hdt/modalias.gz

	$SUDO mkdir -p "$2"/LiveOS

	echo "Installing liveinitrd inside syslinux"
	$SUDO cp -a "$1"/boot/vmlinuz-$KERNEL_ISO "$2"/boot/syslinux/vmlinuz0
	$SUDO cp -a "$1"/boot/liveinitrd.img "$2"/boot/syslinux/liveinitrd.img

	if [ ! -f "$2"/boot/syslinux/liveinitrd.img ]; then
	    echo "Missing /boot/syslinux/liveinitrd.img. Exiting."
	    error
	else
	    $SUDO rm -rf "$1"/boot/liveinitrd.img
	fi

	echo "Copy various syslinux settings"
	# copy boot menu background
        $SUDO cp -rfT $OURDIR/extraconfig/syslinux/background.png "$2"/boot/syslinux/background.png
        # copy memtest
        $SUDO cp -rfT $OURDIR/extraconfig/memtest "$2"/boot/syslinux/memtest
        $SUDO chmod +x "$2"/boot/syslinux/memtest
        # copy SuperGrub iso
        $SUDO cp -rfT $OURDIR/extraconfig/super_grub2_disk_i386_pc_2.00s2.iso "$2"/boot/syslinux/sgb.iso

	# UEFI support
	if [ -f "$1"/boot/efi/EFI/openmandriva/grub.efi ] && [ "$EXTARCH" = "x86_64" ]; then
		export UEFI=1
		$SUDO mkdir -m 0755 -p "$2"/EFI/BOOT "$2"/EFI/BOOT/fonts "$2"/EFI/BOOT/themes "$2"/EFI/BOOT/locale
#		$SUDO cp -f "$1"/boot/efi/EFI/openmandriva/grub.efi "$2"/EFI/BOOT/grub.efi
		#For bootable iso's we may need grub.efi as BOOTX64.efi
		$SUDO cp -f "$1"/boot/efi/EFI/openmandriva/grub.efi "$2"/EFI/BOOT/BOOTX64.efi
#		$SUDO chroot "$1" /usr/bin/grub2-mkstandalone  --directory="/usr/lib/grub/x86_64-efi/" --format="x86_64-efi" --compress=xz --output="$1"/EFI/BOOT/BOOTX64.efi /EFI/BOOT/grub.cfg
#		$SUDO mv -f "$1"/EFI/BOOT/BOOTX64.efi "$2"/EFI/BOOT/BOOTX64.efi
		$SUDO cp -f $OURDIR/EFI/grub.cfg "$2"/EFI/BOOT/BOOTX64.cfg
#		$SUDO cp -f $OURDIR/EFI/grub.cfg "$2"/EFI/BOOT/grub.cfg
		$SUDO sed -i -e "s,@VERSION@,$VERSION,g" "$2"/EFI/BOOT/*.cfg
		$SUDO sed -i -e "s,@LABEL@,$LABEL,g" "$2"/EFI/BOOT/*.cfg
		$SUDO cp -a -f "$1"/boot/grub2/themes "$2"/EFI/BOOT/
		$SUDO cp -a -f "$1"/boot/grub2/locale "$2"/EFI/BOOT/
		# (tpg) looks like fonts are in themes dir for 2015.0
		# need to adapt this for n < 2015.0
		#for i in dejavu_sans_bold_14.pf2 dejavu_sans_mono_11.pf2 terminal_font_11.pf2 unicode.pf2; do
		#	$SUDO cp -f "$1"/boot/grub2/themes/*/$i "$2"/EFI/BOOT/fonts/$i
		#done
		# EFI options for xorriso
		XORRISO_OPTIONS="${XORRISO_OPTIONS} -isohybrid-mbr "$2"/boot/syslinux/isohdpfx.bin -partition_offset 16  -eltorito-alt-boot -e EFI/BOOT/BOOTX64.efi -no-emul-boot -isohybrid-gpt-basdat -append_partition 2 0xef "$ISOROOTNAME"/EFI/BOOT/BOOTX64.efi"
	fi

	echo "Create syslinux menu"
	# kernel/initrd filenames referenced below are the ISO9660 names.
	# syslinux doesn't support Rock Ridge.
	$SUDO cp -rfT $OURDIR/extraconfig/syslinux/syslinux.cfg "$2"/boot/syslinux/syslinux.cfg

	# adjust syslinux config
	sed -i -e "s/%VERSION%/$VERSION/g" -e "s/%EXTARCH%/${EXTARCH}/g" -e "s/%TYPE%/${TYPE}/g" -e "s/%BUILD_ID%/BUILD ID: ${BUILD_ID}/g" -e "s/%LABEL%/${LABEL}/g" "$2"/boot/syslinux/syslinux.cfg

	$SUDO chmod 0755 "$2"/boot/syslinux

	echo "syslinux setup completed"
}

# Usage: setupBootloader
# Sets up grub2/syslinux to boot /target/dir
setupBootloader() {
	setupSyslinux "$CHROOTNAME" "$ISOROOTNAME"

}

setupISOenv() {

	# clear root password
	$SUDO chroot "$CHROOTNAME" /usr/bin/passwd -f -d root

	# set up default timezone
	echo "Setting default timezone"
	$SUDO ln -s ../usr/share/zoneinfo/Universal "$CHROOTNAME"/etc/localtime

	# try harder with systemd-nspawn
	# version 215 and never has then --share-system option
	if (( `rpm -qa systemd --queryformat '%{VERSION} \n'` >= "215" )); then
	    $SUDO systemd-nspawn --share-system -D "$CHROOTNAME" /usr/bin/timedatectl set-timezone UTC
	    # set default locale
	    echo "Setting default localization"
	    $SUDO systemd-nspawn --share-system -D "$CHROOTNAME" /usr/bin/localectl set-locale LANG=en_US.UTF-8 LANGUAGE=en_US.UTF-8:en_US:en
	else
	    echo "systemd-nspawn does not exists."
	fi

	# create /etc/minsysreqs
	echo "Creating /etc/minsysreqs"

	if [ "${TYPE,,}" = "minimal" ]; then
	    echo "ram = 512" >> "$CHROOTNAME"/etc/minsysreqs
	    echo "hdd = 5" >> "$CHROOTNAME"/etc/minsysreqs
	elif [ "$EXTARCH" = "x86_64" ]; then
		echo "ram = 1536" >> "$CHROOTNAME"/etc/minsysreqs
		echo "hdd = 10" >> "$CHROOTNAME"/etc/minsysreqs
	else
	    echo "ram = 1024" >> "$CHROOTNAME"/etc/minsysreqs
	    echo "hdd = 10" >> "$CHROOTNAME"/etc/minsysreqs
	fi

	# count imagesize and put in in /etc/minsysreqs
	$SUDO echo "imagesize = $(du -a -x -b -P "$CHROOTNAME" | tail -1 | awk '{print $1}')" >> "$CHROOTNAME"/etc/minsysreqs

	# set up displaymanager
	if [ "${TYPE,,}" != "minimal" ]; then
		$SUDO chroot "$CHROOTNAME" systemctl enable ${DISPLAYMANAGER,,}.service 2> /dev/null || :

	    # Set reasonable defaults
	    if  [ -e "$CHROOTNAME"/etc/sysconfig/desktop ]; then
		rm -rf "$CHROOTNAME"/etc/sysconfig/desktop
	    fi

	    # create very important desktop file
	    cat >"$CHROOTNAME"/etc/sysconfig/desktop <<EOF
DISPLAYMANAGER=${DISPLAYMANAGER,,}
DESKTOP=${TYPE^^}
EOF

	fi

	# copy some extra config files
	$SUDO cp -rfT $OURDIR/extraconfig/etc "$CHROOTNAME"/etc/
	$SUDO cp -rfT $OURDIR/extraconfig/usr "$CHROOTNAME"/usr/

	# set up live user
	$SUDO chroot "$CHROOTNAME" /usr/sbin/adduser live
	$SUDO chroot "$CHROOTNAME" /usr/bin/passwd -d live
	$SUDO chroot "$CHROOTNAME" /bin/mkdir -p /home/live
	$SUDO chroot "$CHROOTNAME" /bin/cp -rfT /etc/skel /home/live/
	$SUDO chroot "$CHROOTNAME" /bin/chown -R live:live /home/live
	$SUDO chroot "$CHROOTNAME" /bin/mkdir /home/live/Desktop
	$SUDO chroot "$CHROOTNAME" /bin/chown -R live:live /home/live/Desktop
	$SUDO cp -rfT $OURDIR/extraconfig/etc/skel "$CHROOTNAME"/home/live/
	$SUDO chroot "$CHROOTNAME" chown -R 500:500 /home/live/
	$SUDO chroot "$CHROOTNAME" chmod -R 0777 /home/live/.local
	$SUDO mkdir -p "$CHROOTNAME"/home/live/.cache
	$SUDO chroot "$CHROOTNAME" chown 500:500 /home/live/.cache

	# KDE4 related settings
	if [ "${TYPE,,}" = "kde4" ]; then
		$SUDO mkdir -p "$CHROOTNAME"/home/live/.kde4/env
		echo "export KDEVARTMP=/tmp" > "$CHROOTNAME"/home/live/.kde4/env/00-live.sh
		echo "export KDETMP=/tmp" >> "$CHROOTNAME"/home/live/.kde4/env/00-live.sh
		$SUDO chroot "$CHROOTNAME" chmod -R 0777 /home/live/.kde4
	else
    	$SUDO rm -rf "$CHROOTNAME"/home/live/.kde4
    fi

	$SUDO pushd "$CHROOTNAME"/etc/sysconfig/network-scripts
	for iface in eth0 wlan0; do
	cat > ifcfg-$iface << EOF
DEVICE=$iface
ONBOOT=yes
NM_CONTROLLED=yes
EOF
	done
	$SUDO popd

	echo "Starting services setup."
	#enable services
	SERVICES_ENABLE=(systemd-networkd systemd-networkd-wait-online systemd-resolved systemd-timesyncd systemd-timedated NetworkManager sshd.socket cups chronyd acpid alsa atd avahi-daemon irqbalance netfs resolvconf rpcbind sound udev-post mandrake_everytime crond accounts-daemon tuned)
	# disable services
	SERVICES_DISABLE=(pptp pppoe ntpd iptables ip6tables shorewall nfs-server mysqld abrtd mysql postfix)

	for i in "${SERVICES_ENABLE[@]}"; do
	    if [[ $i  =~ ^.*socket$|^.*path$|^.*target$|^.*timer$ ]]; then
		if [ -e "$CHROOTNAME"/lib/systemd/system/$i ]; then
		    echo "Enabling $i"
		    ln -sf ../lib/systemd/system/$i "$CHROOTNAME"/etc/systemd/system/multi-user.target.wants/$i
		else
		    echo "Special service $i does not exist. Skipping."
		fi
	    elif [[ ! $i  =~ ^.*socket$|^.*path$|^.*target$|^.*timer$ ]]; then
		if [ -e "$CHROOTNAME"/lib/systemd/system/$i.service ]; then
		    echo "Enabling $i.service"
		    ln -sf ../lib/systemd/system/$i.service "$CHROOTNAME"/etc/systemd/system/multi-user.target.wants/$i.service
		else
		    echo "Service $i does not exist. Skipping."
		fi

	    else
		echo "Wrong service match."
	    fi
	done

	for i in "${SERVICES_DISABLE[@]}"; do
	    if [[ $i  =~ ^.*socket$|^.*path$|^.*target$|^.*timer$ ]]; then
		if [ -e "$CHROOTNAME"/lib/systemd/system/$i ]; then
		    echo "Disabling $i"
		    $SUDO rm -rf "$CHROOTNAME"/etc/systemd/system/multi-user.target.wants/$i
		else
		    echo "Special service $i does not exist. Skipping."
		fi
	    elif [[ ! $i  =~ ^.*socket$|^.*path$|^.*target$|^.*timer$ ]]; then
		if [ -e "$CHROOTNAME"/lib/systemd/system/$i.service ]; then
		    echo "Disabling $i.service"
		    $SUDO rm -rf "$CHROOTNAME"/etc/systemd/system/multi-user.target.wants/$i.service
		else
		    echo "Service $i does not exist. Skipping."
		fi

	    else
		echo "Wrong service match."
	    fi
	done

	# add urpmi medias inside chroot
	echo "Removing old urpmi repositories."
	$SUDO urpmi.removemedia -a --urpmi-root "$CHROOTNAME"

	echo "Adding new urpmi repositories."
	if [ "${TREE,,}" = "cooker" ]; then
		MIRRORLIST="http://downloads.openmandriva.org/mirrors/cooker.$EXTARCH.list"

		$SUDO urpmi.addmedia --urpmi-root "$CHROOTNAME" --wget --no-md5sum --mirrorlist "$MIRRORLIST" 'Main' 'media/main/release'
		$SUDO urpmi.addmedia --urpmi-root "$CHROOTNAME" --wget --no-md5sum --mirrorlist "$MIRRORLIST" 'Contrib' 'media/contrib/release'
		# this one is needed to grab firmwares
		$SUDO urpmi.addmedia --urpmi-root "$CHROOTNAME" --wget --no-md5sum --mirrorlist "$MIRRORLIST" 'Non-free' 'media/non-free/release'
	else
		MIRRORLIST="http://downloads.openmandriva.org/mirrors/$TREE.$VERSION.$EXTARCH.list"
		$SUDO urpmi.addmedia --urpmi-root "$CHROOTNAME" --wget --no-md5sum --distrib --mirrorlist $MIRRORLIST
	fi


	# add 32-bit medias only for x86_64 arch
	if [ "$EXTARCH" = "x86_64" ]; then
		echo "Adding 32-bit media repository."

		# use previous MIRRORLIST declaration but with i586 arch in link name
		MIRRORLIST="`echo $MIRRORLIST | sed -e "s/x86_64/i586/g"`"
		$SUDO urpmi.addmedia --urpmi-root "$CHROOTNAME" --wget --no-md5sum --mirrorlist "$MIRRORLIST" 'Main32' 'media/main/release'

		if [ "${TREE,,}" != "cooker" ]; then
		    $SUDO urpmi.addmedia --urpmi-root "$CHROOTNAME" --wget --no-md5sum --mirrorlist "$MIRRORLIST" 'Main32Updates' 'media/main/updates'

		    if [[ $? != 0 ]]; then
			echo "Adding urpmi 32-bit media FAILED. Exiting";
			error
		    fi
		fi

	else
		echo "urpmi 32-bit media repository not needed"

	fi

	#update urpmi medias
	echo "Updating urpmi repositories"
	$SUDO urpmi.update --urpmi-root "$CHROOTNAME" -a -ff --wget --force-key

	# get back to real /etc/resolv.conf
	$SUDO rm -f "$CHROOTNAME"/etc/resolv.conf
	if [ "`cat /etc/release | grep -o 2014.0`" \< "2015.0" ]; then
	    $SUDO ln -sf ../run/resolvconf/resolv.conf "$CHROOTNAME"/etc/resolv.conf
	else
	    $SUDO ln -sf ../run/systemd/resolve/resolv.conf "$CHROOTNAME"/etc/resolv.conf
	fi

	# ldetect stuff
	$SUDO chroot "$CHROOTNAME" /usr/sbin/update-ldetect-lst

	#remove rpm db files to save some space
	$SUDO chroot "$CHROOTNAME" rm -f /var/lib/rpm/__db.*
}

createSquash() {
    echo "Starting squashfs image build."

    if [ -f "$ISOROOTNAME"/LiveOS/squashfs.img ]; then
	$SUDO rm -rf "$ISOROOTNAME"/LiveOS/squashfs.img
    fi

    mkdir -p "$ISOROOTNAME"/LiveOS
    # unmout all stuff inside CHROOT to build squashfs image
    umountAll "$CHROOTNAME"

    $SUDO mksquashfs "$CHROOTNAME" "$ISOROOTNAME"/LiveOS/squashfs.img -comp xz -no-progress -no-recovery -b 4096

    if [ ! -f  "$ISOROOTNAME"/LiveOS/squashfs.img ]; then
	echo "Failed to create squashfs. Exiting."
	error
    fi

}

# Usage: buildIso filename.iso rootdir
# Builds an ISO file from the files in rootdir
buildIso() {
	echo "Starting ISO build."

	if [ "$ABF" = "1" ]; then
	    ISOFILE="$OURDIR/$PRODUCT_ID.$EXTARCH.iso"
	else
	    ISOFILE="/var/tmp/$PRODUCT_ID.$EXTARCH.iso"
	fi

	if [ ! -x /usr/bin/xorriso ]; then
	    echo "xorriso does not exists. Exiting."
	    error
	fi

	echo "Building ISO with options ${XORRISO_OPTIONS}"

	$SUDO xorriso -as mkisofs -R -r -J -joliet-long -cache-inodes \
	    -graft-points -iso-level 3 -full-iso9660-filenames \
	    --modification-date=${ISO_DATE} \
	    -omit-version-number -disable-deep-relocation \
	    ${XORRISO_OPTIONS} \
	    -publisher "OpenMandriva Association" \
	    -preparer "OpenMandriva Association" \
	    -volid "$LABEL" -o "$ISOFILE" "$ISOROOTNAME"

	if [ ! -f "$ISOFILE" ]; then
	    echo "Failed build iso image. Exiting"
	    error
	fi

	echo "ISO build completed."
}

postBuild() {
    if [ ! -f $ISOFILE ]; then
	umountAll "$CHROOTNAME"
	error
    fi

    if [ "$ABF" = "1" ]; then
    	# We're running in ABF -- adjust to its directory structure
	# count checksums
	echo "Genrating ISO checksums."
	pushd $OURDIR
		md5sum  $PRODUCT_ID.$EXTARCH.iso > $PRODUCT_ID.$EXTARCH.iso.md5sum
		sha1sum $PRODUCT_ID.$EXTARCH.iso > $PRODUCT_ID.$EXTARCH.iso.sha1sum
	popd

	mkdir -p /home/vagrant/results /home/vagrant/archives
	mv $OURDIR/*.iso* /home/vagrant/results/
    fi

    # clean chroot
    umountAll "$CHROOTNAME"
}


# START ISO BUILD

showInfo
updateSystem
getPkgList
createChroot
createInitrd
setupBootloader
setupISOenv
createSquash
buildIso
postBuild

#END
