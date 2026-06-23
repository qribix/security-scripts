#!/bin/bash

# WiFi Pentest Automation Tool
# Run as root (sudo)

set -e

INTERFACE="wlan1"
MON_INTERFACE="${INTERFACE}mon"
CAPTURE_DIR="/home/kali/Desktop/wifi_captures"
COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_YELLOW='\033[1;33m'
COLOR_RESET='\033[0m'

# Create capture directory
mkdir -p "$CAPTURE_DIR"

# Check root privileges
if [[ $EUID -ne 0 ]]; then
    echo -e "${COLOR_RED}[!] Script must be run as root (sudo).${COLOR_RESET}"
    exit 1
fi

# Check if interface exists
if ! ip link show "$INTERFACE" &>/dev/null; then
    echo -e "${COLOR_RED}[!] Interface $INTERFACE not found.${COLOR_RESET}"
    exit 1
fi

# Check if monitor mode is running
is_monitor_up() {
    ip link show "$MON_INTERFACE" &>/dev/null
}

# Stop monitor mode (cleanup)
cleanup_monitor() {
    if is_monitor_up; then
        echo -e "${COLOR_YELLOW}[*] Stopping monitor mode...${COLOR_RESET}"
        airmon-ng stop "$MON_INTERFACE" &>/dev/null
        sleep 1
    fi
}

# Function for clean exit
exit_script() {
    cleanup_monitor
    echo -e "${COLOR_GREEN}[+] Exiting.${COLOR_RESET}"
    exit 0
}
trap exit_script INT TERM

# === MENU FUNCTIONS ===

# 1 Network scanning (overview)
scan_networks() {
    if ! is_monitor_up; then
        echo -e "${COLOR_RED}[!] Monitor mode is not running. Start it first (option 8).${COLOR_RESET}"
        read -p "Start now? (y/N): " START_NOW
        if [[ "$START_NOW" =~ ^[Yy]$ ]]; then
            start_monitor
        else
            return
        fi
    fi
    
    echo -e "${COLOR_GREEN}[+] Scanning networks. Press Ctrl+C to stop.${COLOR_RESET}"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    sudo airodump-ng "$MON_INTERFACE" --write "$CAPTURE_DIR/capture-$TIMESTAMP" --output-format csv &
    AIRODUMP_PID=$!
    
    wait $AIRODUMP_PID 2>/dev/null
    
    # Parse CSV and display nicely
    CSV_FILE="$CAPTURE_DIR/capture-$TIMESTAMP-01.csv"
    if [[ -f "$CSV_FILE" ]]; then
        echo ""
        echo -e "${COLOR_GREEN}[+] Found networks:${COLOR_RESET}"
        cat "$CSV_FILE" | grep -E "^[0-9A-Fa-f]{2}:" | awk -F ',' '{printf "%-18s CH:%-3s PWR:%-5s %s\n", $1, $4, $6, $14}'
    fi
}

# 2 Targeted listener (single network)
targeted_listen() {
    if ! is_monitor_up; then
        echo -e "${COLOR_RED}[!] Monitor mode is not running. Start it first (option 8).${COLOR_RESET}"
        return
    fi
    
    read -p "Channel (CH): " CHANNEL
    read -p "Target BSSID: " BSSID
    read -p "Capture filename (no extension): " FILENAME
    
    echo -e "${COLOR_GREEN}[+] Starting targeted capture. Press Ctrl+C to stop.${COLOR_RESET}"
    sudo airodump-ng -c "$CHANNEL" --bssid "$BSSID" -w "$CAPTURE_DIR/$FILENAME" "$MON_INTERFACE"
}

# 3 Deauthentication attack
deauth_attack() {
    if ! is_monitor_up; then
        echo -e "${COLOR_RED}[!] Monitor mode is not running. Start it first (option 8).${COLOR_RESET}"
        return
    fi
    
    read -p "Network BSSID (AP): " BSSID
    read -p "Client MAC (leave empty for broadcast): " CLIENT
    read -p "Number of packets (0 = infinite): " COUNT
    
    if [[ -z "$CLIENT" ]]; then
        echo -e "${COLOR_YELLOW}[*] Starting deauthentication of all clients...${COLOR_RESET}"
        sudo aireplay-ng -0 "$COUNT" -a "$BSSID" "$MON_INTERFACE"
    else
        echo -e "${COLOR_YELLOW}[*] Starting deauthentication of client $CLIENT...${COLOR_RESET}"
        sudo aireplay-ng -0 "$COUNT" -a "$BSSID" -c "$CLIENT" "$MON_INTERFACE"
    fi
}

# 4 Parse CSV and display networks
parse_csv() {
    echo -e "${COLOR_YELLOW}[*] Available CSV files:${COLOR_RESET}"
    ls -1 "$CAPTURE_DIR"/*.csv 2>/dev/null | head -10
    
    read -p "Enter CSV filename (full path or just name): " CSV_INPUT
    # If only name is entered - add path
    if [[ ! "$CSV_INPUT" =~ ^/ ]]; then
        CSV_INPUT="$CAPTURE_DIR/$CSV_INPUT"
    fi
    
    if [[ ! -f "$CSV_INPUT" ]]; then
        echo -e "${COLOR_RED}[!] File not found.${COLOR_RESET}"
        return
    fi
    
    echo -e "${COLOR_GREEN}[+] Results:${COLOR_RESET}"
    cat "$CSV_INPUT" | grep -E "^[0-9A-Fa-f]{2}:" | awk -F ',' '{printf "%-18s CH:%-3s Clients:%-5s %s\n", $1, $4, $6, $14}'
}

# 5 Check for handshake in capture file
check_handshake() {
    echo -e "${COLOR_YELLOW}[*] Available .cap files:${COLOR_RESET}"
    ls -1 "$CAPTURE_DIR"/*.cap 2>/dev/null | head -10
    
    read -p "Enter cap filename (full path or just name): " CAP_INPUT
    if [[ ! "$CAP_INPUT" =~ ^/ ]]; then
        CAP_INPUT="$CAPTURE_DIR/$CAP_INPUT"
    fi
    
    if [[ ! -f "$CAP_INPUT" ]]; then
        echo -e "${COLOR_RED}[!] File not found.${COLOR_RESET}"
        return
    fi
    
    echo -e "${COLOR_YELLOW}[*] Checking for handshake in $CAP_INPUT...${COLOR_RESET}"
    aircrack-ng "$CAP_INPUT" 2>&1 | grep -E "(handshake|WPA|No networks|0 handshake)"
}

# 6 Stop monitor mode
stop_monitor() {
    cleanup_monitor
    echo -e "${COLOR_GREEN}[+] Monitor mode stopped.${COLOR_RESET}"
}

# 7 Show interface status
show_status() {
    echo -e "${COLOR_GREEN}[+] Interface status:${COLOR_RESET}"
    iwconfig 2>/dev/null | grep -E "(wlan|mon|IEEE|Mode|Frequency)"
    echo ""
    echo -e "${COLOR_GREEN}[+] Capture files:${COLOR_RESET}"
    ls -lh "$CAPTURE_DIR"/*.cap 2>/dev/null | head -5 || echo "No capture files."
}

# 8 Start monitor mode
start_monitor() {
    if is_monitor_up; then
        echo -e "${COLOR_YELLOW}[*] Monitor mode is already running ($MON_INTERFACE).${COLOR_RESET}"
        return
    fi
    echo -e "${COLOR_YELLOW}[*] Starting monitor mode on $INTERFACE...${COLOR_RESET}"
    airmon-ng start "$INTERFACE" &>/dev/null
    sleep 2
    if is_monitor_up; then
        echo -e "${COLOR_GREEN}[+] Monitor mode started: $MON_INTERFACE${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}[!] Failed to start monitor mode.${COLOR_RESET}"
    fi
}

# === MAIN MENU ===
show_menu() {
    clear   
    echo -e "${COLOR_GREEN}╔══════════════════════════════════════════════╗${COLOR_RESET}"
    echo -e "${COLOR_GREEN}║                                              ║${COLOR_RESET}"
    echo -e "${COLOR_RED}
            ⣾⣿⣿⣿⣿⣷⢸⣿⣿⡜⢯⣷⡌⡻⣿⣿⣿⣆⢈⠻⠿⢿⣿⣿⣿⣿⣿⣿⣷⣦⣤⣀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡁⢳⣿⣿⣿⣿⣿⣿⡜⣿⣿⣧⢀⢻⣷⠰⠈⢿⣿⣿⣧⢣⠉⠑⠪⢙⠿⠿⠿⠿⠿⠿⠿⠋⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣱⡇⡞⣿⣿⣿⣿⣿⣿⡇⣿⣿⡏⡄⣧⠹⡇⠧⠈⢻⣿⣿⡇⢧⢢⠀⠀⠑⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢸⣿⣇⢃⢿⣿⣿⣿⣿⣿⣷⣿⣿⠇⢃⣡⣤⡹⠐⣿⣀⢻⣿⣿⢸⡎⠳⡄⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⣾⣿⣿⠘⡸⣿⣿⣿⣿⣿⣿⣿⡿⣰⣿⣿⢟⡷⠈⠋⠃⠎⢿⣿⡏⣿⠀⠘⢆⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⡐⢹⣿⣿⡐⢡⢹⣿⣿⣿⣿⡏⣿⢣⣿⣿⡑⠁⠔⠀⠉⠉⠢⡘⣿⡇⣿⡇⠀⡀⠡⡀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⡇⠘⣿⣿⣇⠇⢣⢻⣿⣿⣿⡇⢇⣾⣿⣿⡆⢸⣤⡀⠚⢂⠀⢡⢿⡇⣿⡇⠀⢿⠀⠀⠄⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⣿⠠⠹⣿⣿⡘⣆⢣⠻⣿⣿⢈⣾⣿⣿⣿⣶⣸⣏⢀⣬⣋⡼⣠⢸⢹⣿⡇⢠⣼⠙⡄⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⢹⡇⠁⠹⣿⣇⠹⡃⠃⠙⡇⠘⢿⣿⣿⣿⣿⣿⣏⣓⣉⣭⣴⣿⠘⢸⣿⠁⠘⠋⠀⠹⠄⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⢷⠀⠀⠈⢿⣇⠂⣷⠄⠐⠀⠘⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⢠⢸⡏⠀⢀⣠⣴⣾⣿⣶⣄⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⢆⠀⠀⠀⠙⠆⠈⠢⠲⠥⣰⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣷⡞⣸⠁⠀⢸⣿⣿⣿⣿⣿⣿⡆⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢶⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠟⠄⠃⠀⠀⠘⣿⣿⣿⣿⣿⣿⣿⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠙⢿⣿⣿⣿⣿⡏⠹⣿⣿⡿⠫⠊⠀⠀⠀⣶⠀⢻⣿⣿⣿⣿⡿⡇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠙⠛⠻⠿⠿⠿⢋⠀⠀⠀⠀⢀⣼⣿⡆⠈⣿⣿⣿⡟⣱⡷⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢁⣁⡀⠨⣛⠿⠶⠄⢀⣠⣾⣿⣿⣷⠀⢹⣿⡟⣴⠈⢃⣶⠔⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣾⣿⣿⡄⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⡄⠈⣿⣿⡿⠀⡀⣿⣷⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢙⠻⣿⣿⢀⠙⠻⠿⣿⣿⣿⣿⣿⣿⡇⠁⣿⠟⡀⠈⣧⢰⣿⠆⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠿⠴⠮⣥⠻⢧⣤⣄⣀⡉⢩⣭⣍⣃⣀⣩⠎⢀⣼⠉⣼⡯⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠑⠁⣛⠓⢒⣒⣢⡭⢁⡈⠿⠿⠟⠹⠛⠁⠀⠀⠀⠰⠃⠂⠀⠀⠀${COLOR_RESET}"
    echo -e "${COLOR_GREEN}║                                              ║${COLOR_RESET}"
    echo -e "${COLOR_GREEN}╠══════════════════════════════════════════════╣${COLOR_RESET}"
    echo -e "${COLOR_GREEN}║         WiFi Pentest Automation Tool         ║${COLOR_RESET}"
    echo -e "${COLOR_GREEN}║     Author: qribix | github.com/qribix       ║${COLOR_RESET}"
    echo -e "${COLOR_GREEN}║               Version: 1.0                   ║${COLOR_RESET}"
    echo -e "${COLOR_GREEN}╚══════════════════════════════════════════════╝${COLOR_RESET}"
    echo "1. Scan networks (overview)"
    echo "2. Targeted listener (single network)"
    echo "3. Deauthentication (disconnect clients)"
    echo "4. Parse CSV and display networks"
    echo "5. Check handshake (aircrack-ng)"
    echo "6. Stop monitor mode"
    echo "7. Show status"
    echo "8. Start monitor mode"
    echo "0. Exit"
    echo -e "${COLOR_GREEN}----------------------------------------${COLOR_RESET}"
    read -p "Select option: " CHOICE
    
    case $CHOICE in
        1) scan_networks ;;
        2) targeted_listen ;;
        3) deauth_attack ;;
        4) parse_csv ;;
        5) check_handshake ;;
        6) stop_monitor ;;
        7) show_status ;;
        8) start_monitor ;;
        0) exit_script ;;
        *) echo -e "${COLOR_RED}[!] Invalid option.${COLOR_RESET}"; sleep 1 ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
}

# Main loop
while true; do
    show_menu
done
