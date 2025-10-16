#!/bin/bash

# Script to run Ubuntu VM with NVIDIA Tesla T4 GPU passthrough and VNC access
# Requirements: QEMU/KVM, VFIO drivers, VNC viewer

set -e

# Configuration
VM_NAME="ubuntu-vm"
DROPBOX_URL="https://triumph-influenced-secrets-show.trycloudflare.com/files/ubuntu.img.gz"  # Dropbox direct download link

# Storage locations
SDB1_MOUNT="/mnt/sdb1"                        # Mount point for sdb1 (for .gz and extracted image)
SDA1_MOUNT="/mnt/sda1"                        # Mount point for sda1 (for secondary VM disk)
DISK_IMAGE_GZ="${SDB1_MOUNT}/ubuntu.img.gz"  # Downloaded .gz file on sdb1
DISK_IMAGE="${SDB1_MOUNT}/ubuntu-disk.img"        # Extracted disk image on sdb1
SECONDARY_DISK="${SDA1_MOUNT}/vm-data.qcow2"      # Secondary 299GB disk on sda1
SECONDARY_DISK_SIZE="299G"                        # Size of secondary disk

MEMORY="28G"                                  # RAM allocation
CPUS="4"                                      # CPU cores
VNC_PORT="5900"                               # VNC port (5900 = display :0)
VNC_BIND="0.0.0.0"                            # Bind VNC to all interfaces (0.0.0.0 for public access)
VNC_PASSWORD="lt4c"                         # VNC password (optional)
SKIP_DOWNLOAD=false                           # Set to true to skip download if file exists

# GPU PCI address - Will be auto-detected
GPU_PCI_ADDRESS=""                            # Auto-detected from lspci
GPU_VENDOR="NVIDIA"                           # GPU vendor to search for (NVIDIA, AMD, Intel)

# VFIO device paths (will be auto-detected based on PCI address)
VFIO_GROUP=""
IOMMU_GROUP=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    print_error "Please run as root (use sudo)"
    exit 1
fi

# Install required packages if not installed
print_info "Checking and installing required packages..."

PACKAGES_TO_INSTALL=""

# Check pciutils (for lspci command)
if ! command -v lspci &> /dev/null; then
    print_info "lspci not found. Will install pciutils..."
    PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL pciutils"
fi

# Check QEMU/KVM
if ! command -v qemu-system-x86_64 &> /dev/null; then
    print_info "QEMU not found. Will install qemu-kvm and related packages..."
    PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL qemu-kvm qemu-system-x86 qemu-utils"
fi

# Check libvirt (optional but recommended)
if ! command -v virsh &> /dev/null; then
    print_info "libvirt not found. Will install libvirt-daemon-system..."
    PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL libvirt-daemon-system libvirt-clients"
fi

# Check bridge-utils for network bridging
if ! command -v brctl &> /dev/null; then
    print_info "bridge-utils not found. Will install..."
    PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL bridge-utils"
fi

# Check wget for downloading
if ! command -v wget &> /dev/null; then
    print_info "wget not found. Will install..."
    PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL wget"
fi

# Check if we need to install anything
if [ ! -z "$PACKAGES_TO_INSTALL" ]; then
    print_info "Installing packages:$PACKAGES_TO_INSTALL"
    apt update
    apt install -y $PACKAGES_TO_INSTALL
    
    if [ $? -eq 0 ]; then
        print_info "All required packages installed successfully"
    else
        print_error "Failed to install some packages"
        exit 1
    fi
else
    print_info "All required packages are already installed"
fi

# Verify QEMU installation
if ! command -v qemu-system-x86_64 &> /dev/null; then
    print_error "QEMU installation failed or not found"
    exit 1
fi

print_info "QEMU version: $(qemu-system-x86_64 --version | head -n1)"

# Auto-detect GPU PCI address
print_info "Auto-detecting $GPU_VENDOR GPU..."
GPU_LIST=$(lspci -nn | grep -i "$GPU_VENDOR" | grep -i "VGA\|3D\|Display")

if [ -z "$GPU_LIST" ]; then
    print_error "No $GPU_VENDOR GPU found. Available GPUs:"
    lspci | grep -i "VGA\|3D\|Display"
    exit 1
fi

# Count number of GPUs found
GPU_COUNT=$(echo "$GPU_LIST" | wc -l)

if [ $GPU_COUNT -eq 1 ]; then
    # Only one GPU found, use it
    GPU_PCI_ADDRESS=$(echo "$GPU_LIST" | awk '{print $1}' | sed 's/^/0000:/')
    GPU_NAME=$(echo "$GPU_LIST" | cut -d':' -f3- | sed 's/^[[:space:]]*//')
    print_info "Found GPU: $GPU_NAME"
    print_info "PCI Address: $GPU_PCI_ADDRESS"
else
    # Multiple GPUs found, let user choose
    print_info "Found $GPU_COUNT $GPU_VENDOR GPUs:"
    echo "$GPU_LIST" | nl -w2 -s'. '
    
    # Auto-select first GPU (or you can add interactive selection)
    GPU_PCI_ADDRESS=$(echo "$GPU_LIST" | head -n1 | awk '{print $1}' | sed 's/^/0000:/')
    GPU_NAME=$(echo "$GPU_LIST" | head -n1 | cut -d':' -f3- | sed 's/^[[:space:]]*//')
    print_info "Auto-selecting first GPU: $GPU_NAME"
    print_info "PCI Address: $GPU_PCI_ADDRESS"
fi

# Verify PCI address format
if [[ ! "$GPU_PCI_ADDRESS" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ ]]; then
    print_error "Invalid PCI address format: $GPU_PCI_ADDRESS"
    exit 1
fi

# Check if IOMMU is enabled
if ! grep -q "intel_iommu=on\|amd_iommu=on" /proc/cmdline; then
    print_warn "IOMMU may not be enabled in kernel parameters"
    print_warn "Add 'intel_iommu=on iommu=pt' (Intel) or 'amd_iommu=on iommu=pt' (AMD) to GRUB_CMDLINE_LINUX"
fi

# Check if VFIO modules are loaded
if ! lsmod | grep -q vfio_pci; then
    print_info "Loading VFIO modules..."
    modprobe vfio
    modprobe vfio_pci
    modprobe vfio_iommu_type1
fi

# Install and configure UFW firewall
if ! command -v ufw &> /dev/null; then
    print_info "UFW not found. Installing UFW..."
    apt update
    apt install -y ufw
    print_info "UFW installed successfully"
else
    print_info "UFW is already installed"
fi

# Configure UFW firewall rules
print_info "Configuring firewall rules..."

# Enable UFW if not enabled
if ! ufw status | grep -q "Status: active"; then
    print_info "Enabling UFW..."
    # Allow SSH first to prevent lockout
    ufw allow 22/tcp comment 'SSH'
    ufw --force enable
fi

# Allow VNC port
print_info "Opening VNC port $VNC_PORT..."
ufw allow $VNC_PORT/tcp comment 'VNC for VM'

# Allow VNC websocket (if using noVNC)
ufw allow 6080/tcp comment 'noVNC websocket'

# Allow common VM ports
ufw allow 3389/tcp comment 'RDP (if needed)'
ufw allow 5901:5910/tcp comment 'Additional VNC displays'

# Reload firewall
ufw reload

print_info "Firewall rules configured successfully"
print_info "Current firewall status:"
ufw status numbered | grep -E "VNC|RDP|5900|5901|6080" || echo "  VNC ports configured"

# Setup network bridge for public IP access
print_info "Setting up network bridge tap0..."
if ! ip link show tap0 &> /dev/null; then
    ip tuntap add dev tap0 mode tap
    ip link set tap0 up
    
    # Get default network interface
    DEFAULT_IF=$(ip route | grep default | awk '{print $5}' | head -n1)
    
    if [ ! -z "$DEFAULT_IF" ]; then
        # Create bridge if not exists
        if ! ip link show br0 &> /dev/null; then
            print_info "Creating bridge br0..."
            ip link add name br0 type bridge
            ip link set br0 up
            
            # Add default interface to bridge
            ip link set "$DEFAULT_IF" master br0
            
            # Move IP from default interface to bridge
            DEFAULT_IP=$(ip -4 addr show "$DEFAULT_IF" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
            if [ ! -z "$DEFAULT_IP" ]; then
                ip addr flush dev "$DEFAULT_IF"
                ip addr add "$DEFAULT_IP"/24 dev br0
                ip route add default via $(ip route | grep default | awk '{print $3}' | head -n1) dev br0
            fi
        fi
        
        # Add tap0 to bridge
        ip link set tap0 master br0
        print_info "tap0 added to bridge br0"
    else
        print_warn "Could not detect default interface. Manual bridge setup may be required."
    fi
else
    print_info "tap0 already exists"
fi

# Check and mount sdb1 if not mounted
if ! mountpoint -q "$SDB1_MOUNT"; then
    print_info "Mounting /dev/sdb1 to $SDB1_MOUNT..."
    mkdir -p "$SDB1_MOUNT"
    if ! mount /dev/sdb1 "$SDB1_MOUNT" 2>/dev/null; then
        print_error "Failed to mount /dev/sdb1. Check if device exists and has filesystem."
        print_error "Create filesystem with: mkfs.ext4 /dev/sdb1"
        exit 1
    fi
    print_info "/dev/sdb1 mounted successfully"
else
    print_info "/dev/sdb1 already mounted at $SDB1_MOUNT"
fi

# Check and mount sda1 if not mounted
if ! mountpoint -q "$SDA1_MOUNT"; then
    print_info "Mounting /dev/sda1 to $SDA1_MOUNT..."
    mkdir -p "$SDA1_MOUNT"
    if ! mount /dev/sda1 "$SDA1_MOUNT" 2>/dev/null; then
        print_error "Failed to mount /dev/sda1. Check if device exists and has filesystem."
        print_error "Create filesystem with: mkfs.ext4 /dev/sda1"
        exit 1
    fi
    print_info "/dev/sda1 mounted successfully"
else
    print_info "/dev/sda1 already mounted at $SDA1_MOUNT"
fi

# Download disk image from Dropbox if not exists
if [ ! -f "$DISK_IMAGE_GZ" ] || [ "$SKIP_DOWNLOAD" = false ]; then
    print_info "Downloading disk image from Dropbox..."
    print_info "URL: $DROPBOX_URL"
    
    # Download with progress bar (wget already checked above)
    wget -O "$DISK_IMAGE_GZ" "$DROPBOX_URL" --progress=bar:force 2>&1 | tee /dev/stderr
    
    if [ $? -eq 0 ]; then
        print_info "Download completed: $DISK_IMAGE_GZ"
    else
        print_error "Download failed. Check your Dropbox URL."
        print_error "Make sure the URL ends with ?dl=1 for direct download"
        exit 1
    fi
else
    print_info "Using existing .gz file: $DISK_IMAGE_GZ"
fi

# Extract disk image if it's compressed
if [ ! -f "$DISK_IMAGE" ]; then
    if [ -f "$DISK_IMAGE_GZ" ]; then
        print_info "Extracting disk image from $DISK_IMAGE_GZ..."
        print_info "This may take a few minutes..."
        
        # Get compressed file size
        GZ_SIZE=$(du -h "$DISK_IMAGE_GZ" | cut -f1)
        print_info "Compressed size: $GZ_SIZE"
        
        # Extract with progress (using pv if available, otherwise gunzip)
        if command -v pv &> /dev/null; then
            pv "$DISK_IMAGE_GZ" | gunzip > "$DISK_IMAGE"
        else
            gunzip -c "$DISK_IMAGE_GZ" > "$DISK_IMAGE"
        fi
        
        IMG_SIZE=$(du -h "$DISK_IMAGE" | cut -f1)
        print_info "Disk image extracted to $DISK_IMAGE (Size: $IMG_SIZE)"
    else
        print_error "Disk image not found: $DISK_IMAGE_GZ"
        exit 1
    fi
else
    print_info "Using existing disk image: $DISK_IMAGE"
fi

# Create secondary disk on sda1 if not exists
if [ ! -f "$SECONDARY_DISK" ]; then
    print_info "Creating secondary disk at $SECONDARY_DISK (Size: $SECONDARY_DISK_SIZE)..."
    
    if ! command -v qemu-img &> /dev/null; then
        print_error "qemu-img not found. Install with: apt install qemu-utils"
        exit 1
    fi
    
    qemu-img create -f qcow2 "$SECONDARY_DISK" "$SECONDARY_DISK_SIZE"
    
    if [ $? -eq 0 ]; then
        print_info "Secondary disk created successfully"
        DISK2_SIZE=$(du -h "$SECONDARY_DISK" | cut -f1)
        print_info "Disk file size: $DISK2_SIZE (will grow up to $SECONDARY_DISK_SIZE)"
    else
        print_error "Failed to create secondary disk"
        exit 1
    fi
else
    print_info "Using existing secondary disk: $SECONDARY_DISK"
    DISK2_SIZE=$(du -h "$SECONDARY_DISK" | cut -f1)
    print_info "Secondary disk size: $DISK2_SIZE"
fi

# Find IOMMU group for GPU
print_info "Detecting IOMMU group for GPU at $GPU_PCI_ADDRESS..."
IOMMU_GROUP=$(basename $(readlink /sys/bus/pci/devices/$GPU_PCI_ADDRESS/iommu_group) 2>/dev/null || echo "")

if [ -z "$IOMMU_GROUP" ]; then
    print_error "Could not find IOMMU group for $GPU_PCI_ADDRESS"
    print_error "Check GPU PCI address with: lspci | grep NVIDIA"
    exit 1
fi

print_info "GPU IOMMU group: $IOMMU_GROUP"

# Unbind GPU from host driver and bind to VFIO
print_info "Binding GPU to VFIO driver..."

# Get vendor and device ID
VENDOR_ID=$(cat /sys/bus/pci/devices/$GPU_PCI_ADDRESS/vendor)
DEVICE_ID=$(cat /sys/bus/pci/devices/$GPU_PCI_ADDRESS/device)

# Remove 0x prefix
VENDOR_ID=${VENDOR_ID#0x}
DEVICE_ID=${DEVICE_ID#0x}

print_info "GPU Vendor:Device = $VENDOR_ID:$DEVICE_ID"

# Unbind from current driver if bound
if [ -e "/sys/bus/pci/devices/$GPU_PCI_ADDRESS/driver" ]; then
    CURRENT_DRIVER=$(basename $(readlink /sys/bus/pci/devices/$GPU_PCI_ADDRESS/driver))
    print_info "Unbinding from current driver: $CURRENT_DRIVER"
    echo "$GPU_PCI_ADDRESS" > /sys/bus/pci/devices/$GPU_PCI_ADDRESS/driver/unbind
fi

# Bind to VFIO-PCI
echo "$VENDOR_ID $DEVICE_ID" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true
echo "$GPU_PCI_ADDRESS" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true

print_info "GPU bound to VFIO driver"

# Build QEMU command
print_info "Starting VM with VNC on port $VNC_PORT (display :$(($VNC_PORT - 5900)))..."

# Detect disk format
DISK_FORMAT="raw"
if file "$DISK_IMAGE" | grep -q "QCOW"; then
    DISK_FORMAT="qcow2"
    print_info "Detected QCOW2 disk format"
else
    print_info "Using RAW disk format"
fi

QEMU_CMD="qemu-system-x86_64 \
    -name $VM_NAME \
    -machine type=q35,accel=kvm \
    -cpu host,kvm=off,hv_vendor_id=null \
    -smp $CPUS \
    -m $MEMORY \
    -drive file=$DISK_IMAGE,format=$DISK_FORMAT,if=virtio,cache=writeback,id=disk0 \
    -drive file=$SECONDARY_DISK,format=qcow2,if=virtio,cache=writeback,id=disk1 \
    -device vfio-pci,host=$GPU_PCI_ADDRESS,multifunction=on \
    -vnc $VNC_BIND:$(($VNC_PORT - 5900)),password=on \
    -monitor stdio \
    -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
    -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56 \
    -usb \
    -device usb-tablet \
    -rtc base=localtime,clock=host \
    -boot order=c"

# Get public IP address
PUBLIC_IP=$(hostname -I | awk '{print $1}')
if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP="<server-ip>"
fi

# Set VNC password if specified
if [ ! -z "$VNC_PASSWORD" ]; then
    print_info "VNC password will be set to: $VNC_PASSWORD"
    print_info "Connect to VNC at: $PUBLIC_IP:$(($VNC_PORT - 5900)) or $PUBLIC_IP:$VNC_PORT"
fi

print_info "VM Configuration:"
print_info "  - Memory: $MEMORY"
print_info "  - CPUs: $CPUS"
print_info "  - GPU: $GPU_PCI_ADDRESS (Tesla T4)"
print_info "  - Primary Disk: $DISK_IMAGE ($DISK_FORMAT)"
print_info "  - Secondary Disk: $SECONDARY_DISK (qcow2, $SECONDARY_DISK_SIZE)"
print_info "  - VNC: $PUBLIC_IP:$(($VNC_PORT - 5900)) (port $VNC_PORT)"
print_info "  - Network: Bridged mode via tap0"
print_info ""
print_info "To set VNC password, type in QEMU monitor: change vnc password"
print_info "To connect VNC: vncviewer $PUBLIC_IP:$(($VNC_PORT - 5900))"
print_info ""
print_warn "IMPORTANT: Make sure firewall allows port $VNC_PORT"
print_warn "IMPORTANT: Network bridge tap0 must be configured"
print_info ""
print_info "Starting QEMU..."

# Run QEMU
eval $QEMU_CMD

# Cleanup on exit
print_info "VM stopped. Cleaning up..."

# Rebind GPU to host driver (optional)
# Uncomment if you want to automatically rebind GPU to nouveau/nvidia driver
# echo "$GPU_PCI_ADDRESS" > /sys/bus/pci/drivers/vfio-pci/unbind
# echo "$GPU_PCI_ADDRESS" > /sys/bus/pci/drivers/nvidia/bind

# Unmount drives (optional - comment out if you want to keep them mounted)
# print_info "Unmounting drives..."
# umount "$SDB1_MOUNT" 2>/dev/null || true
# umount "$SDA1_MOUNT" 2>/dev/null || true

print_info "Done."
