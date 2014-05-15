Wubi Resize
==============

wubi-resize.sh :- 
-----------

This is a bash script that resizes the Wubi virtual disk (root.disk). It is not really a resize - a new root.disk (new.disk) is created and the old one is copied onto it. The benefit of this is that it can be run while the Wubi install is booted, and also, the original root.disk is not modified (backup is created). The downside is you cannot "add a couple of GBs" to the existing disk e.g. if you have a 7GB root.disk, and you want to make it 10GB you need 10GB of free space (plus leave enough for Windows to operate).

<strong>NOTE:</strong> it's a good idea to defragment and run chkdsk on Windows before doing the resize. An excessively fragmented virtual disk may have problems booting.

Usage
-----

       sudo bash wubi-resize.sh [options] | [size in GB]
       e.g. sudo bash wubi-resize.sh --help (print this message)
       e.g. sudo bash wubi-resize.sh 10 (resize to 10GB)
       e.g. sudo bash wubi-resize.sh --version (print version number)
       
####Increase the wubi virtual disk size####

|Options|Utility|
|`-h, --help`       |print this message and exit|
|--version          |print the version information and exit|
|-v, --verbose      |print verbose output|
|--max-override     |ignore maximum size constraint of 32GB|
|--resume           |resume previous failure due to copy errors|

<strong>Note:</strong> you have to complete the resize by booting into windows and
renaming the root.disk to OLDroot.disk and new.disk to root.disk
before rebooting. Only delete the OLDroot.disk once you are sure
the resize worked. 

This script will merge separate virtual disks into a single root.disk
(and adjust the /etc/fstab accordingly).

the --resume-option
---------

If the script exits due to rsync copy failures, for example, a corrupt 
file, it is possible to correct the problem and then resume the script
without recreating the new virtual disk and recopying everything.
Rerun the script with the `--resume option`. In this case the size parameter
is ignored, but the script will offer to resize the new disk if too small.

Known Limitations
-----

This script will not permit a resize on a FAT32 host partition (individual files are limited to a maximum size of 4GB). The script limits the minimum resize to 5GB (arbitrary limit), and a maximum resize of 32GB (can be overridden, but not recommended). The size must be greater than the Used Space on the current install (it can be smaller than the current root.disk).
