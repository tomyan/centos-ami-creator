package CentOSAMI::Creator;

use strict;
use warnings;

use IPC::Run3;
use Data::Dumper;
use MIME::Base64;

sub new {
    my ($class, %options) = @_;
    bless { _options => \%options }, $class;
}

sub create {
    my ($this) = @_;
    $this->output("starting");
    $this->create_image;
}

sub mount_image {
    my ($this) = @_;
    $this->run("mounting image", [ "sudo", "mount", "-o", "loop", $this->image_name, $this->mount_point ]);
}

sub create_file_structure {
    my ($this) = @_;

    for my $dir (qw( /proc /etc /dev /sys /var/cache /var/log /var/lock /var/lib/rpm )) {
        $this->run("creating $dir folder", [ "sudo", "mkdir", "-p", $this->mount_point . $dir ]);
    }

    $this->write_file($this->mount_point . "/etc/fstab", "/dev/xvde1 / ext4 defaults,noatime,nodiratime 1 1\n");
}

sub install_base_os {
    my ($this) = @_;

    my $yum_conf_file = $this->{_options}->{target_dir} . "/yum.conf";

    $this->write_file($yum_conf_file, $this->yum_config);

    $this->run("creating yum cache folder", [ "mkdir", "-p", $this->{_options}->{target_dir} . "/yumcache" ]);

    $this->run("linking yum cache folder",
        [ "ln", "-s", $this->{_options}->{target_dir} . "/yumcache", $this->mount_point . "/var/cache/yumtmp" ]
    );

    $this->run("yum installing",
        [ "yum", "shell", "-y", "-c", $yum_conf_file, "--releasever=" . $this->{_options}->{release},
            "--installroot=" . $this->mount_point ],
        "groupinstall Base\n" .
        "install openssh-server yum-plugin-fastestmirror.noarch e2fsprogs dhclient\n" .
        "ts run\n"
    );

    $this->run("unlinking yum cache folder", [ "rm", $this->mount_point . "/var/cache/yumtmp" ]);
}

sub allow_passwordless_root_login {
    my ($this) = @_;

    $this->write_file($this->mount_point . "/etc/ssh/sshd_config",
        "UseDNS no\n" .
        "PermitRootLogin without-password\n"
    );
}

sub create_devices_for_chroot {
    my ($this) = @_;

    $this->run("making $_ device", [ "MAKEDEV", "-d", $this->mount_point . "/dev", "-x", $_ ]) for qw( console null zero );

    $this->run("mounting bound filesystem $_", [ "mount", "-o", "bind", $_, $this->mount_point . $_ ]) for qw( /dev /dev/pts /dev/shm /proc /sys );
}

sub configure_networking {
    my ($this) = @_;

    $this->write_file($this->mount_point . "/etc/sysconfig/network",
        "NETWORKING=yes\n" .
        "HOSTNAME=localhost.localdomain\n"
    );

    $this->write_file($this->mount_point . "/etc/sysconfig/network-scripts/ifcfg-eth0",
        "ONBOOT=yes\n" .
        "DEVICE=eth0\n" .
        "BOOTPROTO=dhcp\n" .
        "NM_CONTROLLED=yes\n"
    );
}

sub configure_grub {
    my ($this) = @_;

    $this->write_file($this->mount_point . "/boot/grub/grub.conf",
        "default=0\n" .
        "timeout=0\n" .
        "title CentOS$this->{_options}->{release}\n" .
        "root (hd0)\n" .
        "kernel /boot/vmlinuz ro root=/dev/xvde1 rd_NO_PLYMOUTH selinux=0 console=hvc0" .
            " loglvl=all sync_console console_to_ring earlyprintk=xen nomodeset\n" .
        "initrd /boot/initramfs\n"
    );

    $this->run("linking grub.conf", [ "ln", "-s", "/boot/grub/grub.conf", $this->mount_point . "/boot/grub/menu.lst" ]);
     
    my $mount_point = $this->mount_point;

    my ($vmlinuz) = `ls $mount_point/boot/vmlinuz-*` =~ /\/boot\/(vmlinuz-\S+)$/s
        or die "could not extract vmlinuz";

    my ($initramfs) = `ls $mount_point/boot/initramfs-*.img` =~ /\/boot\/(initramfs-\S+)$/s
        or die "could not extract initramfs";
     
    $this->run("updating vmlinuz in grub.conf",
        [ "perl", "-i", "-pe", "s/vmlinuz/$vmlinuz/", $this->mount_point . "/boot/grub/grub.conf" ]
    );
 
    $this->run("updating initramfs in grub.conf",
        [ "perl", "-i", "-pe", "s/initramfs/$initramfs/", $this->mount_point . "/boot/grub/grub.conf" ]
    );
}

sub add_root_ssh_key_script {
    my ($this) = @_;

    $this->write_file($this->mount_point . "/etc/init.d/getssh", $this->root_ssh_key_script);

    $this->run("making ssh key script executable", [ "chmod", "+x", $this->mount_point . "/etc/init.d/getssh" ]);
    $this->run("enabling ssh key script at startup", [ "chroot", $this->mount_point, "chkconfig", "--level", "34", "getssh", "on" ]);
    
}

sub clean_up {
    my ($this) = @_;

    $this->run("cleaning bash history", [ "rm", "-f", $this->mount_point . "/root/.bash_history" ]);
    $this->run("cleaning yum cache", [ "rm", "-rf", $this->mount_point . "/var/cache/yum" ]);
    $this->run("cleaning yum lib repos", [ "rm", "-rf", $this->mount_point . "/var/lib/yum/repos" ]);
    $this->run("cleaning yum lib rpmdb-indexes", [ "rm", "-rf", $this->mount_point . "/var/lib/yum/rpmdb-indexes" ]);
    $this->run("cleaning yum lib", [ "rm", "-rf", $this->mount_point . "/var/lib/yum/transaction-all" ]);
    $this->run("cleaning yum lib", [ "rm", "-rf", $this->mount_point . "/var/lib/yum/transaction-done" ]);
}

sub unmount_image {
    my ($this) = @_;
    
    $this->run("unmounting image", [ "sudo", "umount", $this->mount_point ]);
}

sub create_priv {
    my ($this) = @_;

    $this->mount_image;
    $this->create_file_structure;
    $this->install_base_os;
    $this->allow_passwordless_root_login;
    $this->create_devices_for_chroot;
    $this->configure_networking;
    $this->configure_grub;
    $this->add_root_ssh_key_script;
    $this->unmount_image;
}

sub output {
    my ($this, $output) = @_;
    print "[centos-ami-creator] $output\n" unless $this->{_options}->{quiet};
}

sub run {
    my ($this, $desc, $command, $input) = @_;
    $this->output("$desc...");
    my ($err);
    run3 $command, \$input, undef, \$err or die "error $desc: $!";
    if ($?) {
        die "error $desc: $err";
    }
    $this->output("done $desc.");
}

sub write_file {
    my ($this, $file, $contents) = @_;
    open my $fh, '>', $file or die $!;
    print $fh $contents;
    close $fh or die $!;
}

sub create_image {
    my ($this) = @_;
    $this->run("creating target dir",  [ "mkdir", "-p", $this->{_options}->{target_dir} ]);
    $this->run("removing old image",   [ "rm", "-f", $this->image_name ]);
    $this->run("creating image",       [ "dd", "if=/dev/zero", "of=" . $this->image_name, "bs=1M", "count=" . (1024 * $this->{_options}->{size}) ]);
    $this->run("formatting image",     [ "mkfs.ext4", "-F", "-j", $this->image_name ]);
    $this->run("creating mount point", [ "sudo", "mkdir", "-p", $this->mount_point ]);

    my $dumper = Data::Dumper->new([]);
    $dumper->Terse(1);
    $dumper->Values([$this->{_options}]);

    $this->run("initialising image",   [ "sudo", "$this->{_options}->{bin_dir}/centos-ami-priv", encode_base64($dumper->Dump) ]);
}

sub image_name {
    my ($this) = @_;
    return "$this->{_options}->{target_dir}/CentOS-$this->{_options}->{release}-$this->{_options}->{arch}.img";
}

sub mount_point {
    my ($this) = @_;
    return "$this->{_options}->{target_dir}/mnt";
}

sub yum_config {
    my ($this) = @_;

    return <<CONFIG;
[main]
cachedir=/var/cache/yumtmp
keepcache=1

[base]
name=CentOS-$this->{_options}->{release} - Base
mirrorlist=http://mirrorlist.centos.org/?release=$this->{_options}->{release}&arch=$this->{_options}->{arch}&repo=os
#baseurl=http://mirror.centos.org/centos/$this->{_options}->{release}/os/$this->{_options}->{arch}/
gpgcheck=1
gpgkey=http://mirror.centos.org/centos/RPM-GPG-KEY-CentOS-$this->{_options}->{release}
 
[updates]
name=CentOS-$this->{_options}->{release} - Updates
mirrorlist=http://mirrorlist.centos.org/?release=$this->{_options}->{release}&arch=$this->{_options}->{arch}&repo=updates
#baseurl=http://mirror.centos.org/centos/$this->{_options}->{release}/updates/$this->{_options}->{arch}/
gpgcheck=1
gpgkey=http://mirror.centos.org/centos/RPM-GPG-KEY-CentOS-$this->{_options}->{release}
 
[extras]
name=CentOS-$this->{_options}->{release} - Extras
mirrorlist=http://mirrorlist.centos.org/?release=$this->{_options}->{release}&arch=$this->{_options}->{arch}&repo=extras
#baseurl=http://mirror.centos.org/centos/$this->{_options}->{release}/extras/$this->{_options}->{arch}/
gpgcheck=1
gpgkey=http://mirror.centos.org/centos/RPM-GPG-KEY-$this->{_options}->{release}
 
[centosplus]
name=CentOS-$this->{_options}->{release} - Plus
mirrorlist=http://mirrorlist.centos.org/?release=$this->{_options}->{release}&arch=$this->{_options}->{arch}&repo=centosplus
#baseurl=http://mirror.centos.org/centos/$this->{_options}->{release}/centosplus/$this->{_options}->{arch}/
gpgcheck=1
enabled=0
gpgkey=http://mirror.centos.org/centos/RPM-GPG-KEY-$this->{_options}->{release}
 
[contrib]
name=CentOS-$this->{_options}->{release} - Contrib
mirrorlist=http://mirrorlist.centos.org/?release=$this->{_options}->{release}&arch=$this->{_options}->{arch}&repo=contrib
#baseurl=http://mirror.centos.org/centos/$this->{_options}->{release}/contrib/$this->{_options}->{arch}/
gpgcheck=1
enabled=0
gpgkey=http://mirror.centos.org/centos/RPM-GPG-KEY-$this->{_options}->{release}

CONFIG

}

sub root_ssh_key_script {
    return <<'SCRIPT';
#!/bin/bash
# chkconfig: 2345 95 20
# description: getssh
# processname: getssh
#
export PATH=:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin
# Source function library.
. /etc/rc.d/init.d/functions
 
# Source networking configuration.
[ -r /etc/sysconfig/network ] && . /etc/sysconfig/network
 
# Check that networking is up.
[ "${NETWORKING}" = "no" ] && exit 1
 
start() {
  if [ ! -d /root/.ssh ] ; then
          mkdir -p /root/.ssh
          chmod 700 /root/.ssh
  fi
  # Fetch public key using HTTP
/usr/bin/curl -f http://169.254.169.254/latest/meta-data/public-keys/0/openssh-key > /tmp/my-key
  if [ $? -eq 0 ] ; then
          cat /tmp/my-key >> /root/.ssh/authorized_keys
          chmod 600 /root/.ssh/authorized_keys
          rm /tmp/my-key
  fi
  # or fetch public key using the file in the ephemeral store:
  if [ -e /mnt/openssh_id.pub ] ; then
          cat /mnt/openssh_id.pub >> /root/.ssh/authorized_keys
          chmod 600 /root/.ssh/authorized_keys
  fi
}
 
stop() {
  echo "Nothing to do here"
}
 
restart() {
  stop
  start
}
 
# See how we were called.
case "$1" in
  start)
    start
    ;;
  stop)
    stop
    ;;
  restart)
    restart
    ;;
  *)
    echo $"Usage: $0 {start|stop}"
    exit 1
esac
 
exit $?
###END OF SCRIPT
SCRIPT

}

1;

