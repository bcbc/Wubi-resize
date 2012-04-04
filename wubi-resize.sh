#!/bin/bash
# Increase the size of the WUBI virtual disk (root.disk)
# 
# This script creates a new virtual disk (new.disk) and copies
# the current loop mounted install to it. This can be used to 
# increase the size of the virtual disk, or also to combine
# multiple virtual disks into a single root.disk (e.g. home.disk, usr.disk)
#
# This script does not work on host partitions that are FAT32 as files
# on these are limited to maximum 4GB. It arbitrarily is set to a minimum
# of 5GB for the new disk and a maximum of 32GB. There must be enough 
# space on the host partition so that at least 5% of the total disk size
# is left remaining as free space. 
#
# After running the script, you will need to boot into the host operating
# system and rename the root.disk to OLDroot.disk and the new.disk to root.disk
# (leaving the extension as .disk is quicker as windows doesn't have to figure
# out the type). Once you have tested the new root.disk, you can remove the old
# disk.
# 
# Credits:
# The actual work (the meat and bones) of the resize - is largely based 
# on work done by others including:
#    
#    LVPM - Copyright (C) by Geza Kovacs <geza0kovacs@gmail.com> 
#    Lupin - Copyright (C) 2007 Agostino Russo <agostino.russo@gmail.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2, or (at your option) any
# later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307 USA
##########################################################################

# options
verbose=false    # don't provide output of dd, mkfs or rsync commands
ignore_max=false # limit max size of virtual disk by default
debug=false      # internal use only
size=            # size of new virtual disk 
resume=false     # resume failed copy or synch backup

# literals
version=1.5b
maxsize=32 # max size of new virtual disk unless --max-override supplied
target=/tmp/wubi-resize # mountpoint to be used for new virtual disk
# flags
size_entered=false  #did the user enter the new size?

# work variables
ddcount=0
host_mountpoint= 
GRUB_DEVICE_BOOT=
loop_file=
mtpt=
newdisk=
hostdev=
installsize=
work1=
work2=
free_space=
total_size=
buffer=
input=
retcode=
rsync_opts=

usage () 
{
    cat <<EOF
Usage: sudo bash $0 [options] | [size in GB]
       e.g. sudo bash $0 --help (print this message)
       e.g. sudo bash $0 10 (resize to 10GB)
       e.g. sudo bash $0 --version (print version number)

Increase the wubi virtual disk size  
  -h, --help              print this message and exit
  --version               print the version information and exit
  -v, --verbose           print verbose output
  --max-override          ignore maximum size constraint of 32GB
  --resume                resume previous failure due to copy errors

Note: you have to complete the resize by booting into windows and
renaming the root.disk to OLDroot.disk and new.disk to root.disk
before rebooting. Only delete the old root.disk once you are sure
the resize worked. 

This script will merge separate virtual disks into a single root.disk
(and adjust the /etc/fstab accordingly). 
Host partitions that are FAT32 are not supported.

If the script exits due to rsync copy failures, for example, a corrupt
file, it is possible to correct the problem and then resume the script
without recreating the new virtual disk and recopying everything.
Rerun the script with the --resume option. In this case the size parameter
is ignored, but the script will offer to resize the new disk if too small.
EOF
}

# Check the arguments.
for option in "$@"; do
    case "$option" in
    -h | --help)
    usage
    exit 0 ;;
    --version)
    echo "$0: Version $version"
    exit 0 ;;
    -v | --verbose)
    echo "$0: Verbose option selected"
    verbose=true
    ;;
    --max-override)
    ignore_max=true
    ;;
    --resume)
    resume=true
    ;;
#undocumented debug option
    -d | --debug)
    set -x
    debug=true
    ;;
    -*)
    echo "$0: Unrecognized option '$option'. (--help for usage instructions)"
    exit 1
    ;;
# Get the new size in GB
# Any additional parameters are errors
    *[^0-9]*)
        echo "$0: Invalid size in GB: '$option'. An integer is required."
        exit 1
        ;;
    *)
    if test "x$size" != x; then
          echo "$0: Too many parameters"
          exit 1
    else
          size="${option}"
          size_entered=true
    fi
    ;;
    esac
done

### Present Y/N questions and check response 
### (a valid response is required)
### Parameter: the question requiring an answer
### Returns: 0 = Yes, 1 = No
test_YN ()
{
    while true; do
      echo "$0: " "$@"
      read input
      case "$input" in
        "y" | "Y" )
          return 0 ;;
        "n" | "N" )
          return 1 ;;
        * )
          echo "$0: Invalid response ('$input')"
      esac
    done
}

sanity_checks ()
{
# Check it's a standard wubi loopmounted install 
# The size must be valid and between 5GB and the default maximum size 
# unless the --max-override option is supplied.
# There must be sufficient space on /host for the new disk
# including a remaining space buffer of 5% of total disk size

    if [ "$(whoami)" != root ]; then
        echo "$0: Admin rights are required to run this program." 
        exit 1
    fi

# identify boot device - looking for /dev/loop , and then identify the loop file (root.disk)
    GRUB_DEVICE_BOOT="`grub-probe --target=device /boot`"
    case ${GRUB_DEVICE_BOOT} in
      /dev/loop/*|/dev/loop[0-9])
        loop_file=`losetup ${GRUB_DEVICE_BOOT} | sed -e "s/^[^(]*(\([^)]\+\)).*/\1/"`
      ;;
    esac

    # Confirm loop file is a physical file 
    if [ "x${loop_file}" = x ] || [ ! -f "${loop_file}" ]; then
        echo "$0: Unsupported - this is not a loopmounted install"
        exit 1
    fi

    #keep it to the known scenarios
    if [ "$loop_file" != "/host/ubuntu/disks/root.disk" ]; then
        echo "$0: Unsupported install - irregular root.disk"
        exit 1
    fi

    mtpt="${loop_file%/*}"
    while [ -n "$mtpt" ]; do
        while read DEV MTPT FSTYPE OPTS REST; do
            if [ "$MTPT" = "$mtpt" ]; then
                loop_file=${loop_file#$MTPT}
                host_mountpoint=$MTPT
                break
            fi
        done < /proc/mounts
        mtpt="${mtpt%/*}"
        [ -z "$host_mountpoint" ] || break
    done

    #keep it to the known scenarios
    if [ "$host_mountpoint" != "/host" ]; then
        echo "$0: Unsupported install - not mounted under /host"
        exit 1
    fi

    newdisk=/host/ubuntu/disks/new.disk
    if [ -f "$newdisk" ]; then
      if [ "$resume" == "true" ]; then
        new_size=$(du -b /host/ubuntu/disks/new.disk 2> /dev/null | cut -f 1)
        new_size=`echo "$new_size / 1000000000" | bc`  #assumes made by this program, otherwise will underreport
        echo "$0: resuming previous attempt - size is "$new_size" GB"
        size=$new_size # edit size check with actual size, not inputted size
      else
        echo "$0: $newdisk already exists. Either remove"
        echo "$0: manually or rerun with --resume option"
        exit 1
      fi
    elif [ "$resume" == "true" ]; then
        echo "$0: --resume option invalid and will be ignored"
        resume=false
    fi
    # check host partition is not FAT32 - this is limited to 4GB file sizes
    hostdev=$(mount | grep /host | tail -n 1 | awk '{print $1}')
    hosttype=`blkid -o value -s TYPE "$hostdev"`
    if [ "$hosttype" = "fat32" ]  || [ "$hosttype" = "FAT32" ]; then
        echo "$0: Host partition is type FAT32 - this is not supported"
        exit 1
    fi

    if [ "$resume" == "false" ]; then
      if [ "$size_entered" != "true" ]; then
          echo "$0: Please enter the size of the new root.disk."
          echo "$0: Use \"--help\" for usage instructions"
          exit 1
      fi
      if [ $size -lt 5 ]; then
          echo "$0: The new disk must be at least 5GB."
          exit 1
      fi
      if [ "$ignore_max" = "false" ]; then
        if [ $size -gt $maxsize ]; then
            echo "$0: The new disk cannot exceed $maxsize GB unless the"
            echo "$0: --max-override option is used (not recommended)."
            exit 1
        fi
      fi
    fi

    # Make sure the new size is bigger than the existing install size
    installsize=0
    installsize=$(df | awk '$6=="/" || $6=="/home" || $6=="/usr" {sum += $3} END {print sum}')
    if [ $? != 0 ]; then
        echo "$0: Unexpected failure calculating available size"
        exit 1
    fi
    if [ $installsize -eq 0 ]; then
        echo "$0: Error determining size of current wubi install. Aborting"
        umount $target || true
        exit 1
    fi
    # convert to GB - round up
    # Add a 500MB buffer - probably because of the filesystem reserved space
    # it won't boot properly if it's borderline
    work1=`echo "( $installsize + 512000) / 1024000" | bc`
    work2=`echo "$work1 * 1024000" | bc`
    if [ "$installsize" -gt "$work2" ]; then
        installsize=`echo "$work1 + 1" | bc`
    else
        installsize=$work1
    fi
    if [ "$installsize" -ge "$size" ]; then
        echo "$0: The new size ("$size" GB) isn't sufficient to hold your"
        echo "$0: existing install ("$installsize" GB) plus a freespace buffer"
        if [ "$resume" == "true" ]; then
          size=`echo "$installsize + 1" | bc`
          test_YN "Resize existing new disk size to: $size GB? (Y/N)"
          if [ "$?" -eq 1 ]; then # user pressed N
            echo "$0: Cancelling resize"
            exit 1
          else
            # Force fsck and correct without prompt 
            # Ignore exit codes:
            #    0 - no problem
            #    1 - errors corrected.
            fsck -fp "$newdisk" > /dev/null # just let errors show
            if [ "$?" -gt 1 ]; then
              echo "$0: Cancelling resize - fsck failed"
              exit 1
            fi
            resize2fs "$newdisk" "$size"G > /dev/null # this is actually gibibytes
            if [ "$?" -ne 0 ]; then
              echo "$0: Resize of $newdisk to $sizeG failed"
              exit 1
            fi
            new_size=$(du -b /host/ubuntu/disks/new.disk 2> /dev/null | cut -f 1)
            new_size=`echo "$new_size / 1000000000" | bc`  #assumes made by this program, otherwise will underreport
            echo "$0: "$newdisk" resized to "$new_size" GB"
          fi
        else
          exit 1
        fi
    fi
    
   # Determine free space on /host, also the size of /host partition
   # There must be enough space to create the new virtual disk as 
   # well as leave sufficient buffer (set at 5% of total disk size).
    if [ "$resume" == "false" ]; then
      free_space=$(df /host|tail -n 1|awk '{print $4}')
      if [ $? != 0 ]; then
          echo "$0: unexpected failure calculating available size"
          exit 1
      fi
      # convert to GB (round down)
      free_space=`echo "$free_space / 1024000" | bc`

      # total size of partition
      total_size=$(df /host|tail -n 1|awk '{print $2}')
      if [ $? != 0 ]; then
          echo "$0: unexpected failure calculating available size"
          exit 1
      fi
      # convert to GB
      total_size=`echo "$total_size / 1024000" | bc`
      # calculate 5% buffer
      buffer=`echo "$total_size * 5 / 100" | bc`
      requiredspace=`echo "$buffer + $size" | bc`
      if [ "$free_space" -lt "$requiredspace" ] && [ "$resume" == "false" ]; then
          echo "$0: Insufficient space - only $free_space GB available"
          echo "$0: $size GB plus a remaining buffer of $buffer GB (5%) is required."
          exit 1
      fi
    fi

}
# warn about return code 24 from rsync but don't quit
rc_24_warn ()
{
    echo "$0: Ignoring return code 24 from rsync copy..."
}

#resize
# 1. use dd to create a new empty file
# 2. format the file as ext4 file system
# 3. loop mount the file
# 4. copy everything from current disk to new disk
resize ()
{
  if [ "$resume" == "true" ]; then
      test_YN "Resume previous resize attempt? (Y/N)"
  else
      test_YN "A new virtual disk of $size GB will be created. Continue? (Y/N)"
  fi
  # User pressed N
  if [ "$?" -eq "1" ]; then
      echo "$0: Request aborted"
      exit 0
  fi

#  echo "$0: `date`"
  if [ "$resume" == "false" ]; then
    echo "$0: Creating new virtual disk (new.disk)..."

  # The dd command uses a block size of 1MB (1024KB)
  # Multiply new size by 1000 for the count= parameter
    ddcount=`expr "$size" "*" 1000`
    if [ "$verbose" != "true" ]; then
      exec 3>&1 #save stdout to file descriptor 3
      exec > /dev/null
    fi
    dd if=/dev/zero of="$newdisk" bs=1MB count="$ddcount"
    retcode="$?"
    if [ "$verbose" != "true" ]; then
      exec 1>&3 3>&- # restore stdout and remove fd3
    else
      echo ""
      echo  "$0: Verbose mode: press Enter to continue"
      read input
    fi
    if [ "$retcode" != 0 ]; then
       echo "$0: Creating the new.disk failed or was canceled"
       echo "$0: Operation aborted"
       rm "$newdisk" 
       exit 1
    fi
  fi
   
 # echo "$0: `date`"
  if [ "$resume" == "false" ]; then
    echo "$0: Formatting new virtual disk as ext4."
    if [ "$verbose" != "true" ]; then
      exec 3>&1 #save stdout to file descriptor 3
      exec > /dev/null
    fi
    mkfs.ext4 -F "$newdisk"
    retcode="$?"
    if [ "$verbose" != "true" ]; then
      exec 1>&3 3>&- # restore stdout and remove fd3
    else
      echo ""
      echo  "$0: Verbose mode: press Enter to continue"
      read input
    fi
    if [ "$retcode" != 0 ]; then
       echo "$0: Formatting the new.disk failed or was canceled"
       echo "$0: Operation aborted"
       rm "$newdisk" > /dev/null 2>&1
       exit 1
    fi
  fi

# copy files
  mkdir -p $target
  umount $target > /dev/null 2>&1
#  mount -o loop,sync "$newdisk" $target (sync takes much longer and only really helps in case of hard shutdown in which case
# this wouldn't work anyway.)
  mount -o loop "$newdisk" $target
#  echo "$0: `date`"
  echo "$0: Copying files - this will take some time." 
  echo "$0: Please be patient..."  
  if [ "$verbose" = "true" ]; then
     rsync_opts="-av"
  else
     rsync_opts="-a"
  fi
  echo "$0: Copying from root (/)"
  warn_24_rc=false
  rsync "$rsync_opts" --delete --one-file-system --exclude=/boot --exclude=/usr --exclude=/home --exclude=/tmp/* --exclude=/proc/* --exclude=/sys/* --exclude=/var/lib/lightdm/.gvfs / "$target"
  rc="$?"
  if [ "$rc" == 24 ]; then
    warn_24_rc=true
    rc=0
  fi
  if [ "$rc" == 0 ]; then
    echo "$0: Copying from /boot"
    rsync "$rsync_opts" --delete --one-file-system /boot "$target"
    rc="$?"
  fi
  if [ "$rc" == 24 ]; then
    warn_24_rc=true
    rc=0
  fi
  if [ "$rc" == 0 ]; then
    echo "$0: Copying from /usr"
    rsync "$rsync_opts" --delete --one-file-system /usr "$target"
    rc="$?"
  fi
  if [ "$rc" == 24 ]; then
    warn_24_rc=true
    rc=0
  fi
  if [ "$rc" == 0 ]; then
    echo "$0: Copying from /home"
    rsync "$rsync_opts" --delete --one-file-system --exclude=/home/*/.cache/gvfs --exclude=/home/*/.gvfs /home "$target"
    rc="$?"
  fi
  if [ "$rc" == 24 ]; then
    warn_24_rc=true
    rc=0
  fi
  if [ "$rc" != 0 ]; then
     echo "$0: Copying files failed or was canceled. Return code: "$rc""
     echo "$0: Correct errors and rerun with --resume option"
     echo "$0: Please wait - cleaning up..."
     umount $target > /dev/null 2>&1 
     sleep 3
     rmdir $target
     #rm "$newdisk" > /dev/null 2>&1  don't delete anymore
     echo "$0: Operation aborted"
     exit 1
  fi 
# Already noted any 24 return code from separate rsync calls. If any other non-zero
# return code was issued, it will have dropped down to the block above and exited.
# Otherwise issue warning and continue
  if [ "$warn_24_rc" == "true" ]; then
    rc_24_warn
  fi
#  echo "$0: `date`"
  echo "$0: Copying files completed"

# remove reference to home.disk or usr.disk in fstab (it's been combined into new.disk)
  sed -i 's:/.*home[\.]disk .*::' $target/etc/fstab
  sed -i 's:/.*usr[\.]disk .*::' $target/etc/fstab
# force ureadahead to refresh
  rm $target/var/lib/ureadahead/pack
  umount $target
  sleep 3
  rmdir $target

  echo "$0: Operation completed successfully. Please boot into"
  echo "$0: Windows and rename the existing root.disk to"
  echo "$0: OLDroot.disk and new.disk to root.disk. Keep the"
  echo "$0: old disk until you confirm everything is working!"
}

#Main processing
#echo "$0: `date`"
sanity_checks
resize
#echo "$0: `date`"
exit 0
