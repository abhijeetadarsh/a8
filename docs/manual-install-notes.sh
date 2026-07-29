# step 1: connect to wifi using iwctl
# iwctl
# iwctl 
# 	station wlan0 get-networks
# 	startion wlan0 connect xyzssid
# 	exit


timedatectl
# ckdisk if partition required
lsblk

root_partition = /dev/nvme0n1p6  
boot_partition = /dev/nvme0n1p3
swap_partition = /dev/nvme0n1p5

mkfs.btrfs root_partition
mkswap swap_partition

mount root_partition /mnt
mount --mkdir boot_partition /mnt/boot
swapon swap_partition

pacstrap -K /mnt base linux linux-firmware

genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot -S /mnt

ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime

hwclock --systohc

uncomment en_US.UTF-8 inside /etc/locale.gen

locale-gen

/etc/locale.conf
LANG=en_US.UTF-8

NAME        MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
loop0         7:0    0 999.4M  1 loop /run/archiso/airootfs
sda           8:0    1 232.9G  0 disk 
├─sda1        8:1    1 232.8G  0 part 
│ └─ventoy  253:0    0   1.5G  1 dm   
└─sda2        8:2    1    32M  0 part 
nvme0n1     259:0    0 476.9G  0 disk 
├─nvme0n1p1 259:1    0    16M  0 part 
├─nvme0n1p2 259:2    0 190.5G  0 part 
├─nvme0n1p3 259:3    0   512M  0 part 
├─nvme0n1p4 259:4    0   200G  0 part /a8
├─nvme0n1p5 259:5    0   5.9G  0 part 
└─nvme0n1p6 259:6    0    80G  0 part 
