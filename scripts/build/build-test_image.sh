#!/bin/sh

SSL_CA_CERT_FILE=/usr/local/share/certs/ca-root-nss.crt

set -ex

if [ -z "${SVN_REVISION}" ]; then
	echo "No subversion revision specified"
	exit 1
fi

ARTIFACT_SUBDIR=${FBSD_BRANCH}/r${SVN_REVISION}/${TARGET}/${TARGET_ARCH}
OUTPUT_IMG_NAME=disk-test.img

sudo rm -fr work
mkdir -p work
cd work

DIST_PACKAGES="base kernel"
if [ "${WITH_DOC}" = 1 ]; then
	DIST_PACKAGES="${DIST_PACKAGES} doc"
fi
if [ "${WITH_TESTS}" = 1 ]; then
	DIST_PACKAGES="${DIST_PACKAGES} tests"
fi
if [ "${WITH_DEBUG}" = 1 ]; then
	DIST_PACKAGES="${DIST_PACKAGES} base-dbg kernel-dbg"
fi
if [ "${WITH_LIB32}" = 1 ]; then
	DIST_PACKAGES="${DIST_PACKAGES} lib32"
	if [ "${WITH_DEBUG}" = 1 ]; then
		DIST_PACKAGES="${DIST_PACKAGES} lib32-dbg"
	fi
fi
mkdir -p ufs
for f in ${DIST_PACKAGES}
do
	fetch https://artifact.ci.freebsd.org/snapshot/${ARTIFACT_SUBDIR}/${f}.txz
	sudo tar Jxf ${f}.txz -C ufs
done

sudo cp /etc/resolv.conf ufs/etc/
sudo chroot ufs env ASSUME_ALWAYS_YES=yes pkg update
# Install packages needed by tests:
# coreutils: bin/date
# gdb: local/kyua/utils/stacktrace_test
# kyua: everything
# ksh93: tests/sys/cddl/zfs/...
# nist-kat: sys/opencrypto/runtests
# nmap: sys/netinet/fibs_test:arpresolve_checks_interface_fib
# perl5: lots of stuff
# pkgconf: local/lutok/examples_test, local/atf/atf-c, local/atf/atf-c++
# python: sys/opencrypto
sudo chroot ufs pkg install -y coreutils gdb kyua ksh93 nist-kat nmap perl5 scapy python

cat <<EOF | sudo tee -a ufs/boot/loader.conf
net.fibs=3
EOF

cat <<EOF | sudo tee -a ufs/usr/local/etc/kyua/kyua.conf
test_suites.FreeBSD.fibs = '1 2'
test_suites.FreeBSD.allow_sysctl_side_effects = '1'
test_suites.FreeBSD.disks = '/dev/ada1 /dev/ada2 /dev/ada3 /dev/ada4 /dev/ada5'
test_suites.FreeBSD.cam_test_device = '/dev/ada1'
EOF

# disable zfs tests because them need more complex environment setup
if [ -f ufs/usr/tests/sys/cddl/Kyuafile ]; then
	sudo sed -i .bak -e 's,include("zfs/Kyuafile"),-- include("zfs/Kyuafile"),' ufs/usr/tests/sys/cddl/Kyuafile
fi

cat <<EOF | sudo tee ufs/etc/fstab
# Device        Mountpoint      FStype  Options Dump    Pass#
/dev/gpt/swapfs none            swap    sw      0       0
/dev/gpt/rootfs /               ufs     rw      1       1
fdesc           /dev/fd         fdescfs rw      0       0
EOF

# Load modules needed by tests
# blake2:		sys/opencrypto
# cryptodev:		sys/opencrypto
# mac_bsdextended:	sys/mac/bsdextended
# mac_portacl:		sys/mac/portacl
# mqueuefs:		sys/kern/mqueue_test
# pf:			sys/netpfil/pf
cat <<EOF | sudo tee -a ufs/etc/rc.conf
kld_list="blake2 cryptodev mac_bsdextended mac_portacl mqueuefs pf"
auditd_enable="YES"
background_fsck="NO"
sendmail_enable="NONE"
EOF

cat <<EOF | sudo tee ufs/etc/rc.local
#!/bin/sh -ex
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH
echo
echo "--------------------------------------------------------------"
echo "start kyua tests!"
echo "--------------------------------------------------------------"
cd /usr/tests
/usr/local/bin/kyua test
/usr/local/bin/kyua report --verbose --results-filter passed,skipped,xfail,broken,failed --output test-report.txt
/usr/local/bin/kyua report-junit --output=test-report.xml
shutdown -p now
EOF

cat <<EOF | sudo tee ufs/etc/sysctl.conf
kern.cryptodevallowsoft=1
net.add_addr_allfibs=0
vfs.aio.enable_unsafe=1
EOF

sudo rm -f ufs/etc/resolv.conf

sudo makefs -d 6144 -t ffs -f 200000 -s 8g -o version=2,bsize=32768,fsize=4096 -Z ufs.img ufs
mkimg -s gpt -f raw \
	-b ufs/boot/pmbr \
	-p freebsd-boot/bootfs:=ufs/boot/gptboot \
	-p freebsd-swap/swapfs::1G \
	-p freebsd-ufs/rootfs:=ufs.img \
	-o ${OUTPUT_IMG_NAME}
xz -0 ${OUTPUT_IMG_NAME}

cd ${WORKSPACE}
rm -fr artifact
mkdir -p artifact/${ARTIFACT_SUBDIR}
mv work/${OUTPUT_IMG_NAME}.xz artifact/${ARTIFACT_SUBDIR}

echo "SVN_REVISION=${SVN_REVISION}" > ${WORKSPACE}/trigger.property
