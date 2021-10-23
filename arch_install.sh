#!/bin/bash

#------------------------------------------------------------------------------------------------
# Arch linux install script by Damir Kucic, 2021
# Use it freely but absolutely at your own risk. I wrote this for my own purpose.
# This script will install arch linux on BIOS/MBR or UEFI/GPT based systems. Firmware 
# type is autodetected. 
# In case of BIOS MBR is used as some BIOS'es are not playing along nicely with 
#  GPT so MBR is a safe bet for legacy systems.
# / will be installed on luks encrypted LVM volume.
# TODO: Add autodetection of the last available sector in function create_disk_partitions_uefi
#------------------------------------------------------------------------------------------------

# Disk on which to install the system
DISK_NAME='vda'
# Desired hostname
HOST_NAME='smesko-pc'
# User to create during install
USER_NAME='smesko'

function create_disk_partitions_mbr()
{
  local disk_drive="/dev/$DISK_NAME"
  local all_sectors=$(fdisk -l | grep "Disk $disk_drive" | cut -d " " -f 7)
  local usable_sectors=$(( $all_sectors - 1 ))
  # We are getting this calcuation based on the 1GB boot sector
  # as 1GB in bytes is 1073742000÷512 <- sector size + 2048 we  
  # get 2099200 so last sector is $usable_sectors - 2099200
  local last_sector=$(( $usable_sectors - 2099200 ))

  local hdd_layout="label: dos
  label-id: 0x5c0819ae
  device: /dev/$DISK_NAME
  unit: sectors
  sector-size: 512

  /dev/$DISK_NAME1 : start=        2048, size=     +1G, type=83
  /dev/$DISK_NAME2 : start=     2099200, size=     $last_sector, type=8e"

  echo "$hdd_layout" | sfdisk "$disk_drive"
}

function create_disk_partitions_uefi()
{
  disk_drive="/dev/$DISK_NAME"
 
  hdd_layout="label: gpt
  label-id: F01059EC-E16E-D14B-A984-D2030A81310A
  device: $disk_drive
  unit: sectors
  first-lba: 2048
  last-lba: 41943006
  sector-size: 512

  /dev/vda1 : start=        2048, size=     +1G, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=5720C2F3-FA11-D54E-BFB3-00C02BC404E5
  /dev/vda2 : start=     2099200, size=     +19G, type=E6D6D379-F507-44C2-A23C-238F2A3DF928, uuid=B8486D22-063C-7A4B-9977-30F79816AFDF"

  echo "$hdd_layout" | sfdisk "$disk_drive"
}

function create_filesystems()
{
  if [ ! -d /sys/firmware/efi ]; then
    mkfs.ext4 /dev/"${DISK_NAME}"1
  else   
    mkfs.fat -F32 /dev/"${DISK_NAME}"1
  fi
  
  cryptsetup -y luksFormat /dev/"${DISK_NAME}"2
  cryptsetup luksOpen /dev/"${DISK_NAME}"2 luks

  pvcreate /dev/mapper/luks
  vgcreate vg0 /dev/mapper/luks
  lvcreate --size 4G vg0 --name swap
  lvcreate -l +100%FREE vg0 --name root

  mkfs.ext4 /dev/mapper/vg0-root  
  mkswap /dev/mapper/vg0-swap
}

function prepare_chroot()
{
  mount /dev/mapper/vg0-root /mnt
  mkdir /mnt/boot
  mount /dev/"${DISK_NAME}1" /mnt/boot
  swapon /dev/mapper/vg0-swap

  pacstrap -i /mnt base base-devel linux linux-firmware openssh git neovim lvm2 pass keychain gnupg networkmanager dhclient grub 
  genfstab -pU /mnt >> /mnt/etc/fstab 
}

function set_environment()
{
  arch-chroot /mnt localectl set-keymap slovene
  arch-chroot /mnt ln -s /usr/share/zoneinfo/Europe/Ljubljana /etc/localtime
  arch-chroot /mnt sed -i '/en_US.UTF-8 UTF-8/s/^#//g' /etc/locale.gen
  arch-chroot /mnt locale-gen
   
  arch-chroot /mnt /bin/bash <<EOF
  export LANG=en_US.UTF-8
  echo "$HOST_NAME" > /etc/hostname
  echo LANG=en_US.UTF-8 > /etc/locale.conf
  printf "127.0.0.1  localhost\n::1  localhost\n127.0.1.1  $HOST_NAME.localdomain  $HOST_NAME\n" > /etc/hosts  
EOF

  arch-chroot /mnt hwclock --systohc --utc
}

function add_user()
{
  arch-chroot /mnt useradd -m -g users -G wheel "$USER_NAME"
  echo "Please enter password for user $USER_NAME"
  arch-chroot /mnt passwd "$USER_NAME"
  arch-chroot /mnt sed -i '/wheel ALL=(ALL) ALL/s/^#//g' /etc/sudoers
}

function generate_initrd()
{
  local orig_modules='MODULES=()'
  local new_modules='MODULES=(ext4)'
  local orig_hooks='HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)'
  local new_hooks='HOOKS=(base udev autodetect modconf block encrypt lvm2 filesystems keyboard fsck)'

  arch-chroot /mnt sed -i "s/$orig_modules/$new_modules/g" /etc/mkinitcpio.conf
  arch-chroot /mnt sed -i "s/$orig_hooks/$new_hooks/g" /etc/mkinitcpio.conf  
  
  arch-chroot /mnt mkinitcpio -p linux
}

function setup_grub()
{  
  if [ ! -d /sys/firmware/efi ]; then
   arch-chroot /mnt grub-install --target=i386-pc --recheck /dev/"$DISK_NAME"
  else
    arch-chroot /mnt pacman -S efibootmgr
    arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
  fi
  
  local grub_cmdline_linux_old="GRUB_CMDLINE_LINUX=\"\""
  local grub_cmdline_linux_new="GRUB_CMDLINE_LINUX=\"cryptdevice=\/dev\/${DISK_NAME}2:luks:allow-discards\""  
  arch-chroot /mnt sed -i "s/$grub_cmdline_linux_old/$grub_cmdline_linux_new/g" /etc/default/grub
  
  # Optional grub settings I prefer
  arch-chroot /mnt sed -i "s/GRUB_DEFAULT=0/GRUB_DEFAULT=saved/g" /etc/default/grub
  arch-chroot /mnt sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet\"/GRUB_CMDLINE_LINUX_DEFAULT=\"lsm=lockdown,yama,apparmor,bpf\"/g" /etc/default/grub
  arch-chroot /mnt sed -i "s/#GRUB_DISABLE_SUBMENU=y/GRUB_DISABLE_SUBMENU=y/g" /etc/default/grub
  arch-chroot /mnt sed -i "s/#GRUB_SAVEDEFAULT=true/GRUB_SAVEDEFAULT=true/g" /etc/default/grub
  
  arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg        
}

function create_post_boot_script()
{
  local setup_script="/home/$USER_NAME/run.sh"
  
  arch-chroot /mnt /bin/bash <<EOF 
  echo '#!/bin/bash' >> "$setup_script"
  echo 'localectl set-keymap slovene' >> "$setup_script"
  echo 'sudo dhclient' >> "$setup_script"
  echo 'sudo pacman -Syu && sudo pacman -S gdm apparmor bash-completion ntp bluez bluez-tools linux-lts ufw' >> "$setup_script" 
  echo 'sudo systemctl enable gdm.service' >> "$setup_script"
  echo 'sudo systemctl enable fstrim.timer' >> "$setup_script"
  echo 'sudo systemctl enable apparmor.service' >> "$setup_script"
  echo 'sudo systemctl enable ntpd.service' >> "$setup_script"
  echo 'sudo systemctl enable bluetooth.service' >> "$setup_script"
  echo 'sudo systemctl enable NetworkManager.service' >> "$setup_script"
  echo 'sudo ufw enable' >> "$setup_script"
  echo 'sudo ufw allow from 192.168.1.0/24 to any port 22 proto tcp' >> "$setup_script"
EOF
  
  arch-chroot /mnt chown "$USER_NAME" "$setup_script" && arch-chroot /mnt chmod +x "$setup_script"
}  

function cleanup_reboot()
{
  umount -R /mnt
  swapoff -a
  reboot
}

#Function calls

if [ ! -d /sys/firmware/efi ]; then
  create_disk_partitions_mbr
else
  create_disk_partitions_uefi  
fi

create_filesystems
prepare_chroot
set_environment
add_user
generate_initrd
setup_grub
create_post_boot_script
cleanup_reboot
