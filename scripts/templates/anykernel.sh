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
device.name6=
device.name7=
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
SLOT_SELECT=active;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=0;
NO_MAGISK_CHECK=1;
NO_VBMETA_PARTITION_PATCH=1;

# Import functions/variables and resolve the target boot slot.
. tools/ak3-core.sh;

# Never let a booted flasher or a stale /postinstall mount redirect this
# kernel-only package to the inactive slot.  Its init_boot/vendor_boot pair may
# belong to a different ROM build and cannot safely be mixed with this kernel.
case "$SLOT:$BLOCK" in
  _a:*boot_a|_b:*boot_b)
    ui_print "Target slot verified: $SLOT";
    ui_print "Target boot partition: $BLOCK";
    ;;
  *)
    abort "Active-slot boot target verification failed: slot=$SLOT block=$BLOCK";
    ;;
esac;

# Preserve the boot image layout and replace only the kernel Image.  Modern
# devices such as OnePlus 11 keep their first-stage ramdisk in init_boot, so
# boot itself legitimately has no ramdisk for dump_boot to unpack.
ui_print "Stage 1/3: dumping and splitting boot image...";
split_boot;
ui_print "Stage 2/3: boot image split; replacing kernel...";
ui_print "Stage 3/3: rebuilding and flashing boot image...";
flash_boot;
ui_print "Boot image flash completed.";
## end boot install
