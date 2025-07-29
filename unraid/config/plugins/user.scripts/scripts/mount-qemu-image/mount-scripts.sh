#!/bin/bash

SCRIPT_PATH="/boot/config/plugins/user.scripts/scripts/mount-qemu-image/script"
if [[ ! -f "$SCRIPT_PATH" ]]; then
    echo "Error: Mount script not found at $SCRIPT_PATH"
    exit 1
fi
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)"
    exit 1
fi

mount_image() {
    local image_path="$1"
    local partition="$2"
    local image_name=$(basename "$image_path" | sed 's/\.[^.]*$//')
    
    echo "=== Mounting $image_name ($partition) ==="
    bash "$SCRIPT_PATH" mount --image "$image_path" --partition "$partition" --readonly --exit > "/tmp/mount_${image_name}.log" 2>&1 &
    local pid=$!
    echo "   Background process started (PID: $pid)"
    echo "   Log file: /tmp/mount_${image_name}.log"
    echo
}

echo "=== Starting QEMU Disk Mounting ==="
echo

# Clean up any existing mounts
echo "Cleaning up existing mounts..."
bash "$SCRIPT_PATH" unmount
rm -rf /mnt/images/*/
echo

# Mount specific partitions using their actual labels
mount_image "/mnt/user/backups/Timo/PC/Drives/blu-pc.img" "Win 11 Pro"
mount_image "/mnt/user/backups/Bettina/Laptop/drives/betty-laptop.img" "Windows"
mount_image "/mnt/user/backups/Timo/Server/HomeAssistant/HASS_USB.img" "hassos-data"

# Skip the broken disk since it has no partitions
echo "=== Skipping broken disk ==="
echo "Skipping /mnt/user/backups/Timo/Server/HomeAssistant/hass-sd_broken.img (no partitions)"
echo

echo "=== All mount operations started in background ==="
echo "Mounts will complete automatically and exit"
echo "To check mounted disks, run: $SCRIPT_PATH list"
echo "To unmount all disks later, run: $SCRIPT_PATH unmount"
echo "To view individual mount logs, check /tmp/mount_*.log files"
echo
echo "Background processes:"
jobs

echo
echo "=== Mount Status ==="
sleep 2
for log_file in /tmp/mount_*.log; do
    if [[ -f "$log_file" ]]; then
        local image_name=$(basename "$log_file" | sed 's/mount_\(.*\)\.log/\1/')
        echo "Checking $image_name..."
        if grep -q "Exiting immediately after successful mount" "$log_file"; then
            echo "  ✅ Successfully mounted"
        elif grep -q "ERROR" "$log_file"; then
            echo "  ❌ Failed to mount"
        else
            echo "  ⏳ Still processing..."
        fi
    fi
done