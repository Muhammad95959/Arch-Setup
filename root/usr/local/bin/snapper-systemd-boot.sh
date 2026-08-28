#!/bin/bash
set -e
ESP="/boot"
ROOT_UUID="86248124-9996-4f48-8c3f-ab4404f6f1f2"
ENTRIES_DIR="$ESP/loader/entries"
KERNEL="/vmlinuz-linux"
INITRD="/initramfs-linux.img"
CMDLINE="root=UUID=$ROOT_UUID rw rootflags=subvol="
# remove stale entries
for entry in "$ENTRIES_DIR"/snapper-*.conf; do
  [ -e "$entry" ] || continue
  id=$(basename "$entry" | sed -n "s/snapper-\([0-9]\+\)\.conf/\1/p")
  [ -n "$id" ] && [ ! -d "/.snapshots/$id/snapshot" ] && rm -f "$entry" && echo "Removed stale $entry"
done
# create/update bootable entries from snapper info
for snap in /.snapshots/*/snapshot; do
  [ -d "$snap" ] || continue
  id=$(echo "$snap" | cut -d/ -f3)
  [ "$id" = "0" ] && continue
  info="/.snapshots/$id/info.xml"
  [ -f "$info" ] || continue
  desc=$(grep -oP "(?<=<description>).*?(?=</description>)" "$info" 2>/dev/null || echo "snap $id")
  date=$(grep -oP "(?<=<date>).*?(?=</date>)" "$info" 2>/dev/null || echo "")
  type=$(grep -oP "(?<=<type>).*?(?=</type>)" "$info" 2>/dev/null || echo "single")
  subvol="@/.snapshots/$id/snapshot"
  cat > "$ENTRIES_DIR/snapper-$id.conf" <<EOF
title   Snapper $id ($type) $date - $desc
linux   $KERNEL
initrd  $INITRD
options $CMDLINE$subvol console=tty1
sort-key snapper
EOF
done
