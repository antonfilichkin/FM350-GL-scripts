#!/bin/sh

# --- Configuration ---
APN="internet"

LOG_FILE="/var/log/5g_connection.log"
RESPONSE_FILE="/tmp/responsive_com_port.txt"

# Fibocom FM350-GL Modem
FM350_GL_VENDOR_ID="0e8d"
FM350_GL_PRODUCT_ID="7127"

# Realtek NIC
REALTEK_VENDOR_ID="0bda"
REALTEK_PRODUCT_ID="8153"

# Modem connection options
BAUD_RATE="9600"
COMMAND_DELAY=1
COMMAND_TIMEOUT=1


# --- Utility functions ---
log_separator() {
    echo >> "$LOG_FILE"
}

log_message() {
    local MESSAGE="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$MESSAGE" | tee -a "$LOG_FILE" >/dev/null
}

check_internet() {
    log_message "Pinging 8.8.8.8 to check internet connectivity..."
    if ping -c 3 8.8.8.8 > /dev/null 2>&1; then
        log_message "Internet connectivity check passed."
        return 0
    else
        log_message "Internet connectivity check failed."
        return 1
    fi
}

check_dependencies() {
    local DEPS="lsusb stty timeout iptables ipcalc"
    for DEP in $DEPS; do
        if ! command -v "$DEP" >/dev/null 2>&1; then
            log_message "Installing $DEP..."
            apk add $( [ "$DEP" = "ipcalc" ] && echo "ipcalc" || echo "coreutils iptables usbutils" )
        fi
    done
}


# --- AT functions ---
configure_at_port() {
    local SERIAL_PORT="$1"
    local BAUD_RATE="$2"

    if [ ! -c "$SERIAL_PORT" ]; then
        log_message "ERROR: $SERIAL_PORT does not exist or is not a character device."
        return 1
    fi
    
    log_message "Configuring AT port $SERIAL_PORT - setting baud rate $BAUD_RATE"
    stty -F "$SERIAL_PORT" "$BAUD_RATE" raw -echo -echoe -echok
}

flush_at_port() {
    local SERIAL_PORT="$1"

    log_message "Flushing AT port '$SERIAL_PORT'"
    echo -e "\r\n" > "$SERIAL_PORT"
    sleep "$COMMAND_DELAY"
}

send_at_command() {
    local SERIAL_PORT="$1"
    local COMMAND="$2"
    local TIMEOUT="${3:-$COMMAND_TIMEOUT}"
    local TEMP_RESPONSE_FILE="$(mktemp)"

    log_message "Sending AT command to $SERIAL_PORT: $COMMAND"
    echo -e "$COMMAND" > "$SERIAL_PORT"

    timeout "$COMMAND_TIMEOUT" cat < "$SERIAL_PORT" > "$TEMP_RESPONSE_FILE" 2>/dev/null
    sleep "$COMMAND_DELAY"

    local RESPONSE=$(cat "$TEMP_RESPONSE_FILE" | tr -d '\r\n')

    rm "$TEMP_RESPONSE_FILE"

    log_message "Recieved response: $RESPONSE"
    echo $RESPONSE
}


# --- Setup functions ---
find_usb_dev_path_by_usb_id(){
    local VENDOR_ID="$1"
    local PRODUCT_ID="$2"
    local DEVICE_NAME="${3:-Unknown}"

    log_message "Searching for device $DEVICE_NAME ($VENDOR_ID:$PRODUCT_ID)..."

    local USB_DEV_PATH=""
    for DEV_PATH in /sys/bus/usb/devices/*/ /sys/bus/usb/devices/*/*/ /sys/bus/usb/devices/*/*/*/ ; do
        if [ -f "${DEV_PATH}idVendor" ] && [ -f "${DEV_PATH}idProduct" ]; then
            CURRENT_VENDOR=$(cat "${DEV_PATH}idVendor" 2>/dev/null)
            CURRENT_PRODUCT=$(cat "${DEV_PATH}idProduct" 2>/dev/null)
            if [ "$CURRENT_VENDOR" = "$VENDOR_ID" ] && [ "$CURRENT_PRODUCT" = "$PRODUCT_ID" ]; then
                USB_DEV_PATH="$DEV_PATH"
                break
            fi
        fi
    done
    local USB_DEV_PATH="${USB_DEV_PATH%/}"

    if [ -z "$USB_DEV_PATH" ]; then
        log_message "ERROR: $DEVICE_NAME ($VENDOR_ID:$PRODUCT_ID) /sys path not found. Is it plugged in?"
        return 1
    fi

    log_message "Found $DEVICE_NAME at /sys path: $USB_DEV_PATH"
    echo $USB_DEV_PATH
}


find_network_interface_by_dev_path() {
    local DEV_PATH="$1"
    local DEVICE_NAME="${2:-Unknown}"

    local INTERFACE_NAME=""
    local DEVICE_ID_PATH=$(basename "$DEV_PATH")

    for IFACE_PATH in /sys/class/net/*; do
        if [ -d "$IFACE_PATH" ]; then
            DEVICE_SYMLINK_TARGET=$(readlink -f "$IFACE_PATH/device" 2>/dev/null)
            if [ -n "$DEVICE_SYMLINK_TARGET" ] && echo "$DEVICE_SYMLINK_TARGET" | grep -q "/$DEVICE_ID_PATH" && echo "$DEVICE_SYMLINK_TARGET" | grep -q "usb"; then
                INTERFACE_NAME=$(basename "$IFACE_PATH")
                log_message "Matched $DEVICE_NAME with interface: $INTERFACE_NAME"
                break
            fi
        fi
    done

    if [ -z "$INTERFACE_NAME" ]; then
        log_message "ERROR: No network interface found for $DEVICE_NAME ($DEV_PATH)"
        return 1
    fi

    # Bring interface up
    ip link set "$INTERFACE_NAME" up
    log_message "Activated network interface: $INTERFACE_NAME"
    echo "$INTERFACE_NAME"
}

find_at_port_by_dev_path() {
    local DEV_PATH="$1"
    local DEVICE_NAME="${2:-Unknown}"
    
    for TTY in "$DEV_PATH"/*/ttyUSB*; do
        if [ -d "$TTY" ]; then
            PORT="/dev/$(basename "$TTY")"
            if [ -c "$PORT" ]; then
                log_message "Testing port $PORT..."
                configure_at_port "$PORT" "$BAUD_RATE" || continue
                flush_at_port "$PORT"
                RESPONSE=$(send_at_command "$PORT" "AT" 1 || continue) 
                if [ "$RESPONSE" == "OK" ]; then
                    log_message "AT port found for $DEVICE_NAME ($DEV_PATH): $PORT"
                    echo "$PORT"
                    return 0
                fi
            fi
        fi
    done
    
    log_message "ERROR: AT port not found for $DEVICE_NAME ($DEV_PATH)"
    return 1
}


# --- Networking ---
remove_firewall() {
    log_message "Flushing existing iptables and firewall rules..."
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    iptables -t mangle -F
    iptables -t mangle -X

    log_message "Resetting default policies..."
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT

    log_message "Disabling IP forwarding..."
    echo 0 > /proc/sys/net/ipv4/ip_forward

    log_message "Removing saved rules and disabling service..."
    rc-service iptables stop 2>/dev/null
    rc-update del iptables default 2>/dev/null
    rm -f /etc/iptables/rules-save
    log_message "Firewall rules removed and persistence disabled."
}

configure_firewall() {
    local WAN_IF="$1"
    local LAN_IF="$2"

    if [ -z "$WAN_IF" ] || [ -z "$LAN_IF" ]; then
        log_message "ERROR: WAN_IF or LAN_IF not specified."
        return 1
    fi

    log_message "Configuring iptables firewall and NAT rules for WAN: $WAN_IF, LAN: $LAN_IF..."

    remove_firewall

    log_message "Setting secure default policies..."
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT

    log_message "Allowing loopback traffic..."
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT

    log_message "Allowing established and related connections..."
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

    log_message "Allowing LAN to access internet (NAT)..."
    iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE
    iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -j ACCEPT

    log_message "Allowing SSH access from LAN..."
    iptables -A INPUT -i "$LAN_IF" -p tcp --dport 22 -j ACCEPT

    log_message "Allowing DHCP requests from LAN..."
    iptables -A INPUT -i "$LAN_IF" -p udp --dport 67:68 -j ACCEPT

    log_message "Allowing DNS queries from LAN..."
    iptables -A FORWARD -i "$LAN_IF" -p udp --dport 53 -j ACCEPT
    iptables -A FORWARD -i "$LAN_IF" -p tcp --dport 53 -j ACCEPT

    log_message "Enabling IP forwarding..."
    echo 1 > /proc/sys/net/ipv4/ip_forward

    log_message "Firewall configured successfully."
    return 0
}

persist_firewall() {
    log_message "Saving firewall rules to persist on boot..."
    rc-service iptables save
    rc-update add iptables default
    log_message "Firewall rules saved and set to persist on boot."
}


# --- 5G Connection ---
connect() {
    local SERIAL_PORT="$1"

    if [ -z "$SERIAL_PORT" ] || [ ! -c "$SERIAL_PORT" ]; then
        log_message "ERROR: Invalid or missing AT port."
        return 1
    fi

    log_message "Initiating 5G connection on $SERIAL_PORT..."
    configure_at_port "$SERIAL_PORT" "$BAUD_RATE" || return 1
    flush_at_port "$SERIAL_PORT"

    send_at_command "$SERIAL_PORT" "ATE=0" 1 "OK"
    send_at_command "$SERIAL_PORT" "AT+CMEE=2" 1 "OK"
    send_at_command "$SERIAL_PORT" "AT+CFUN=1" 1 "OK"
    send_at_command "$SERIAL_PORT" "AT+CGPIAF=1,0,0,0" 1 "OK"
    send_at_command "$SERIAL_PORT" "AT+CREG=0" 1 "OK"
    send_at_command "$SERIAL_PORT" "AT+CGREG=0" 1 "OK"
    send_at_command "$SERIAL_PORT" "AT+CEREG=0" 1 "OK"
    send_at_command "$SERIAL_PORT" "AT+CGATT=0" 1 "OK"
    send_at_command "$SERIAL_PORT" "AT+COPS=2" 1 "OK"
    send_at_command "$SERIAL_PORT" "AT+COPS=3,0" 1 "OK"
    send_at_command "$SERIAL_PORT" 'AT+CGDCONT=0,"IPV4V6"' 1 "OK"
    send_at_command "$SERIAL_PORT" 'AT+CGDCONT=1,"IPV4V6","'"$APN"'"' 1 "OK"
    send_at_command "$SERIAL_PORT" "AT+GTACT=10" 5 "OK"
    send_at_command "$SERIAL_PORT" "AT+COPS=0" 10 "OK"
    send_at_command "$SERIAL_PORT" "AT+CGATT=1" 10 "OK"
    send_at_command "$SERIAL_PORT" "AT+CGACT=1,1" 5 "OK"
    send_at_command "$SERIAL_PORT" "AT+GTATT?;+CSQ?" 3 "OK"
    send_at_command "$SERIAL_PORT" "AT+CGPADDR=1;+GTDNS=1" 2 "+CGPADDR"

    log_message "5G connection attempt completed."
    check_internet
}

get_modem_info() {
    local SERIAL_PORT="$1"

    if [ -z "$SERIAL_PORT" ] || [ ! -c "$SERIAL_PORT" ]; then
        log_message "ERROR: Invalid or missing AT port."
        return 1
    fi

    log_message "Retrieving modem information from $SERIAL_PORT..."
    configure_at_port "$SERIAL_PORT" "$BAUD_RATE" || return 1
    flush_at_port "$SERIAL_PORT"
    send_at_command "$SERIAL_PORT" "AT+CGMI?;+FMM?;+GTPKGVER?;+CFSN?;+CGSN?" 2 "+CGMI"
}


# --- Cleanup on exit ---
trap 'rm -f /tmp/tmp.* 2>/dev/null' EXIT


# --- Main ---
log_separator
if [ "$1" = "--auto" ]; then
    log_message "--- Executing script in auto mode ---"
else
    log_message "--- Executing script in menu mode ---"
fi
check_dependencies

FM350_GL_PATH=$(find_usb_dev_path_by_usb_id "$FM350_GL_VENDOR_ID" "$FM350_GL_PRODUCT_ID" "FM350-GL")
REALTEK_PATH=$(find_usb_dev_path_by_usb_id "$REALTEK_VENDOR_ID" "$REALTEK_PRODUCT_ID" "REALTEK")

WAN_IF=$(find_network_interface_by_dev_path "$FM350_GL_PATH" "FM350-GL")
LAN_IF=$(find_network_interface_by_dev_path "$REALTEK_PATH" "REALTEK")

AT_PORT=$(find_at_port_by_dev_path "$FM350_GL_PATH" "FM350-GL")

if [ -z "$WAN_IF" ] || [ -z "$LAN_IF" ] || [ -z "$AT_PORT" ]; then
    log_message "ERROR: Failed to initialize interfaces or AT port."
    exit 1
fi

# --- Autorun mode ---
if [ "$1" = "--auto" ]; then
    configure_firewall "$WAN_IF" "$LAN_IF" || exit 1
    connect "$AT_PORT" || exit 1
    exit 0
fi

# --- Menu mode ---
while true; do
    clear
    echo "Select firewall option:"
    echo "1. Configure firewall"
    echo "2. Persist firewall rules"
    echo "3. Remove firewall rules"
    echo ""
    echo "Select connection option:"
    echo "4. Connect to 5G"
    echo "5. Show modem info"
    echo ""
    echo "Utils"
    echo "L. Show script log"
    echo "C. Clear script log"
    echo ""
    echo "Q. Exit"
    echo -n "Enter your choice (1-5, Q): "
    read choice

    case "$choice" in
        1)
            configure_firewall "$WAN_IF" "$LAN_IF"
            ;;
        2)
            persist_firewall
            ;;
        3)
            remove_firewall
            ;;
        4)
            connect "$AT_PORT"
            ;;
        5)
            get_modem_info "$AT_PORT"
            ;;
        [Ll])
            clear
            cat "$LOG_FILE"
            read -p "Press any key to return to menu"
            ;;
        [Cc])
            echo > "$LOG_FILE"
            ;;
        [Qq])
            clear
            exit 0
            ;;
        *)
            log_message "Invalid choice. Please select 1-5 or Q."
            ;;
    esac
done
