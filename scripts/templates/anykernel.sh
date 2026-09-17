### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

### AnyKernel setup
# global properties
properties() { '
kernel.string=OnePlus Kernel
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=
device.name2=
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
## boot files attributes
boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*;
set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
} # end attributes

# All supported OnePlus targets use A/B boot partitions.  A partition name is
# intentionally used instead of a device-specific /dev path so AnyKernel3 can
# resolve the selected slot through the device's by-name links.
BLOCK=boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# Import functions/variables and resolve the target boot slot.
. tools/ak3-core.sh;

# Preserve the existing ramdisk and replace only the kernel Image.
ui_print "Stage 1/3: dumping and unpacking boot image...";
dump_boot;
ui_print "Stage 2/3: boot image unpacked; replacing kernel...";
ui_print "Stage 3/3: repacking and flashing boot image...";
write_boot;
ui_print "Boot image flash completed.";
## end boot install
