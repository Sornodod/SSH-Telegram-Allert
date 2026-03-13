#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функции для вывода
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Функции для работы с установкой
SCRIPT_PATH="/usr/local/bin/ssh-telegram-alert.py"
SERVICE_NAME="ssh-telegram-alert"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME.service"
CONFIG_PATH="/etc/ssh-telegram-alert.conf"

# Переменные для портов
ALT_PORTS=""  # Список портов по умолчанию (пусто - не мониторим)

# Проверка наличия установки
check_existing_installation() {
    local existing=0
    
    if [ -f "$SCRIPT_PATH" ]; then
        existing=1
        print_warning "Найден существующий скрипт: $SCRIPT_PATH"
    fi
    
    if [ -f "$SERVICE_PATH" ]; then
        existing=1
        print_warning "Найден существующий сервис: $SERVICE_NAME"
    fi
    
    if [ -f "$CONFIG_PATH" ]; then
        existing=1
        print_warning "Найден существующий конфиг: $CONFIG_PATH"
    fi
    
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        existing=1
        print_warning "Найден запущенный сервис: $SERVICE_NAME"
    fi
    
    return $existing
}

# Остановка и удаление существующей установки
remove_existing_installation() {
    print_info "Остановка и удаление существующей установки..."
    
    # Останавливаем сервис если он запущен
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        print_info "Остановка сервиса $SERVICE_NAME..."
        systemctl stop "$SERVICE_NAME"
    fi
    
    # Отключаем автозапуск
    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        print_info "Отключение автозапуска $SERVICE_NAME..."
        systemctl disable "$SERVICE_NAME"
    fi
    
    # Удаляем файл сервиса
    if [ -f "$SERVICE_PATH" ]; then
        print_info "Удаление файла сервиса..."
        rm -f "$SERVICE_PATH"
    fi
    
    # Удаляем скрипт
    if [ -f "$SCRIPT_PATH" ]; then
        print_info "Удаление скрипта..."
        rm -f "$SCRIPT_PATH"
    fi
    
    # Удаляем конфиг
    if [ -f "$CONFIG_PATH" ]; then
        print_info "Удаление конфигурационного файла..."
        rm -f "$CONFIG_PATH"
    fi
    
    # Перезагружаем systemd
    systemctl daemon-reload
    
    print_success "Существующая установка удалена"
}

# Проверка прав root
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        print_error "Этот скрипт должен запускаться с правами root"
        print_info "Используйте: sudo $0"
        exit 1
    fi
}

# Проверка наличия зависимостей
check_dependencies() {
    print_info "Проверка зависимостей..."
    
    # Проверяем Python3
    if ! command -v python3 &> /dev/null; then
        print_error "Python3 не установлен"
        print_info "Установка Python3..."
        apt-get update
        apt-get install -y python3 python3-pip
    fi
    
    # Проверяем pip3
    if ! command -v pip3 &> /dev/null; then
        print_info "Установка pip3..."
        apt-get install -y python3-pip
    fi
    
    # Проверяем requests
    if ! python3 -c "import requests" &> /dev/null; then
        print_info "Установка библиотеки requests..."
        pip3 install requests
    fi
    
    # Проверяем tcpdump для мониторинга портов
    if ! command -v tcpdump &> /dev/null; then
        print_info "Установка tcpdump..."
        apt-get update
        apt-get install -y tcpdump
        if [ $? -eq 0 ]; then
            print_success "tcpdump установлен"
        else
            print_error "Не удалось установить tcpdump. Мониторинг альтернативных портов будет недоступен"
        fi
    fi
    
    # Проверяем journalctl (для systemd)
    if ! command -v journalctl &> /dev/null; then
        print_warning "journalctl не найден. Убедитесь, что используется systemd"
    fi
    
    print_success "Все зависимости проверены"
}

# Функция валидации порта
validate_port() {
    local port=$1
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

# Функция валидации диапазона портов
validate_port_range() {
    local range=$1
    if [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local start=${BASH_REMATCH[1]}
        local end=${BASH_REMATCH[2]}
        if validate_port "$start" && validate_port "$end" && [ "$start" -lt "$end" ]; then
            return 0
        fi
    fi
    return 1
}

# Функция парсинга строки с портами
parse_ports() {
    local input=$1
    local ports=()
    
    # Разделяем по запятой
    IFS=',' read -ra items <<< "$input"
    
    for item in "${items[@]}"; do
        # Убираем пробелы
        item=$(echo "$item" | xargs)
        
        if [[ -z "$item" ]]; then
            continue
        fi
        
        # Проверяем, является ли элемент диапазоном
        if [[ "$item" == *-* ]]; then
            if validate_port_range "$item"; then
                local start=${item%-*}
                local end=${item#*-}
                for ((p=start; p<=end; p++)); do
                    ports+=("$p")
                done
            else
                return 1
            fi
        else
            if validate_port "$item"; then
                ports+=("$item")
            else
                return 1
            fi
        fi
    done
    
    # Убираем дубликаты и сортируем
    if [ ${#ports[@]} -gt 0 ]; then
        ports=($(printf "%s\n" "${ports[@]}" | sort -nu))
        ALT_PORTS=$(printf "%s," "${ports[@]}")
        ALT_PORTS=${ALT_PORTS%,}
    else
        ALT_PORTS=""
    fi
    
    return 0
}

# Настройка альтернативных портов
configure_alt_ports() {
    echo ""
    print_info "=== НАСТРОЙКА АЛЬТЕРНАТИВНЫХ ПОРТОВ ==="
    echo ""
    
    if [ -z "$ALT_PORTS" ]; then
        print_info "По умолчанию альтернативные порты не отслеживаются"
    else
        print_info "Текущие отслеживаемые порты: $ALT_PORTS"
    fi
    
    echo ""
    echo "Введите порты для мониторинга (через запятую, можно диапазоны)"
    echo "Например: 8022,8080,2222 или 8022,8080-8090"
    echo "Оставьте пустым, чтобы не мониторить альтернативные порты"
    echo ""
    
    while true; do
        read -p "Порты: " input_ports
        
        if [ -z "$input_ports" ]; then
            ALT_PORTS=""
            print_info "Мониторинг альтернативных портов отключен"
            break
        fi
        
        if parse_ports "$input_ports"; then
            if [ -n "$ALT_PORTS" ]; then
                print_success "Установлены порты для мониторинга: $ALT_PORTS"
                break
            else
                print_error "Не указано ни одного корректного порта"
            fi
        else
            print_error "Некорректный формат портов. Используйте числа от 1 до 65535, разделенные запятыми"
            echo "Примеры: 8022,8080,2222 или 8022,8080-8090"
        fi
    done
}

# Настройка антиспама
configure_antispam() {
    echo ""
    print_info "=== НАСТРОЙКА АНТИСПАМА ==="
    echo ""
    print_info "Антиспам защищает от повторных уведомлений с одного IP в течение заданного времени"
    
    while true; do
        echo ""
        echo "Выберите режим антиспама:"
        echo "  ${GREEN}1${NC}) Включить антиспам (рекомендуется) - 60 секунд"
        echo "  ${YELLOW}2${NC}) Включить антиспам с пользовательским интервалом"
        echo "  ${RED}3${NC}) Отключить антиспам (много уведомлений!)"
        echo ""
        read -p "Ваш выбор (1-3): " antispam_choice
        
        case $antispam_choice in
            1)
                ANTISPAM_ENABLED="true"
                ANTISPAM_TIMEOUT="60"
                print_success "Антиспам включен (интервал: 60 секунд)"
                break
                ;;
            2)
                while true; do
                    read -p "Введите интервал антиспама в секундах (10-3600): " custom_timeout
                    if [[ "$custom_timeout" =~ ^[0-9]+$ ]] && [ "$custom_timeout" -ge 10 ] && [ "$custom_timeout" -le 3600 ]; then
                        ANTISPAM_ENABLED="true"
                        ANTISPAM_TIMEOUT="$custom_timeout"
                        print_success "Антиспам включен (интервал: $custom_timeout секунд)"
                        break 2
                    else
                        print_error "Введите число от 10 до 3600"
                    fi
                done
                ;;
            3)
                ANTISPAM_ENABLED="false"
                ANTISPAM_TIMEOUT="0"
                print_warning "Антиспам ОТКЛЮЧЕН! Вы будете получать уведомления о КАЖДОЙ попытке подключения"
                print_warning "Это может привести к большому количеству сообщений при брутфорс атаках"
                
                read -p "Вы уверены, что хотите отключить антиспам? (y/n): " confirm
                if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                    continue
                fi
                break
                ;;
            *)
                print_error "Неверный выбор. Выберите 1, 2 или 3"
                ;;
        esac
    done
}

# Запрос данных у пользователя
get_telegram_data() {
    echo ""
    print_info "=== НАСТРОЙКА TELEGRAM ==="
    echo ""
    
    # Пытаемся прочитать существующие настройки
    local old_token=""
    local old_chat_id=""
    local old_antispam=""
    local old_timeout=""
    local old_ports=""
    
    if [ -f "$CONFIG_PATH" ]; then
        source "$CONFIG_PATH" 2>/dev/null
        old_token="$TELEGRAM_BOT_TOKEN"
        old_chat_id="$TELEGRAM_CHAT_ID"
        old_antispam="$ANTISPAM_ENABLED"
        old_timeout="$ANTISPAM_TIMEOUT"
        old_ports="$ALT_PORTS"
    fi
    
    # Настройка альтернативных портов
    if [ -n "$old_ports" ]; then
        echo "Текущие отслеживаемые порты: $old_ports"
        read -p "Изменить список портов? (y/n): " change_ports
        if [[ "$change_ports" =~ ^[Yy]$ ]]; then
            configure_alt_ports
        else
            ALT_PORTS="$old_ports"
            if [ -n "$ALT_PORTS" ]; then
                print_info "Оставлены порты: $ALT_PORTS"
            else
                print_info "Мониторинг альтернативных портов отключен"
            fi
        fi
    else
        configure_alt_ports
    fi
    
    echo ""
    
    # Запрашиваем ID чата
    while true; do
        if [ -n "$old_chat_id" ]; then
            read -p "Введите ID Telegram чата [текущий: $old_chat_id]: " input_chat_id
            TELEGRAM_CHAT_ID="${input_chat_id:-$old_chat_id}"
        else
            read -p "Введите ID Telegram чата: " TELEGRAM_CHAT_ID
        fi
        
        if [[ -z "$TELEGRAM_CHAT_ID" ]]; then
            print_error "ID чата не может быть пустым"
            continue
        fi
        
        if [[ ! "$TELEGRAM_CHAT_ID" =~ ^-?[0-9]+$ ]]; then
            print_error "ID чата должен содержать только цифры (может начинаться с минуса)"
            continue
        fi
        
        print_info "Вы ввели ID чата: $TELEGRAM_CHAT_ID"
        read -p "Это верно? (y/n): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            break
        fi
    done
    
    echo ""
    
    # Запрашиваем токен бота
    while true; do
        if [ -n "$old_token" ]; then
            masked_token="${old_token:0:10}...${old_token: -5}"
            read -p "Введите токен Telegram бота [текущий: $masked_token]: " input_token
            TELEGRAM_BOT_TOKEN="${input_token:-$old_token}"
        else
            read -p "Введите токен Telegram бота: " TELEGRAM_BOT_TOKEN
        fi
        
        if [[ -z "$TELEGRAM_BOT_TOKEN" ]]; then
            print_error "Токен бота не может быть пустым"
            continue
        fi
        
        if [[ ! "$TELEGRAM_BOT_TOKEN" =~ ^[0-9]+:[a-zA-Z0-9_-]+$ ]]; then
            print_error "Токен должен быть в формате: 1234567890:ABCdefGHIjklMNoPQRsTUVwxyz"
            continue
        fi
        
        print_info "Вы ввели токен: ${TELEGRAM_BOT_TOKEN:0:10}..."
        read -p "Это верно? (y/n): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            break
        fi
    done
    
    # Настройка антиспама
    if [ -n "$old_antispam" ] && [ -n "$old_timeout" ]; then
        echo ""
        print_info "Текущие настройки антиспама:"
        if [ "$old_antispam" = "true" ]; then
            print_info "Антиспам: ВКЛЮЧЕН (интервал: $old_timeout сек)"
        else
            print_info "Антиспам: ОТКЛЮЧЕН"
        fi
        read -p "Изменить настройки антиспама? (y/n): " change_antispam
        if [[ "$change_antispam" =~ ^[Yy]$ ]]; then
            configure_antispam
        else
            ANTISPAM_ENABLED="$old_antispam"
            ANTISPAM_TIMEOUT="$old_timeout"
        fi
    else
        configure_antispam
    fi
}

# Создание конфигурационного файла
create_config_file() {
    print_info "Создание конфигурационного файла..."
    
    cat > "$CONFIG_PATH" << EOF
# Конфигурация SSH Telegram Alert
# Автоматически сгенерировано установщиком $(date)

# Telegram настройки
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"

# Настройки альтернативных портов (через запятую)
ALT_PORTS="$ALT_PORTS"

# Настройки антиспама
ANTISPAM_ENABLED=$ANTISPAM_ENABLED
ANTISPAM_TIMEOUT=$ANTISPAM_TIMEOUT
EOF
    
    chmod 600 "$CONFIG_PATH"
    print_success "Конфигурационный файл создан: $CONFIG_PATH"
}

# Создание скрипта мониторинга
create_monitor_script() {
    print_info "Создание скрипта мониторинга..."
    
    cat > "$SCRIPT_PATH" << 'EOF'
#!/usr/bin/env python3
import subprocess
import re
import requests
import datetime
import socket
import threading
import time
import os
import sys
import json

# Загружаем конфигурацию
CONFIG_PATH = "/etc/ssh-telegram-alert.conf"

def load_config():
    """Загружает конфигурацию из файла"""
    config = {}
    try:
        with open(CONFIG_PATH, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    if '=' in line:
                        key, value = line.split('=', 1)
                        key = key.strip()
                        value = value.strip().strip('"')
                        config[key] = value
    except Exception as e:
        print(f"Ошибка загрузки конфигурации: {e}")
        sys.exit(1)
    
    return config

# Загружаем конфигурацию
config = load_config()

# ==== Настройка Telegram ====
TELEGRAM_BOT_TOKEN = config.get('TELEGRAM_BOT_TOKEN', '')
TELEGRAM_CHAT_ID = config.get('TELEGRAM_CHAT_ID', '')
TELEGRAM_API_URL = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"

# ==== Настройки альтернативных портов ====
ALT_PORTS_STR = config.get('ALT_PORTS', '')
if ALT_PORTS_STR:
    ALT_PORTS = [p.strip() for p in ALT_PORTS_STR.split(',') if p.strip()]
else:
    ALT_PORTS = []

# ==== Настройки антиспама ====
ANTISPAM_ENABLED = config.get('ANTISPAM_ENABLED', 'true').lower() == 'true'
ANTISPAM_TIMEOUT = int(config.get('ANTISPAM_TIMEOUT', '60'))

# ==== Информация о сервере ====
SERVER_HOSTNAME = socket.gethostname()
try:
    SERVER_FQDN = socket.getfqdn()
except:
    SERVER_FQDN = SERVER_HOSTNAME
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(("8.8.8.8", 80))
    SERVER_IP = s.getsockname()[0]
    s.close()
except:
    try:
        SERVER_IP = socket.gethostbyname(socket.gethostname())
    except:
        SERVER_IP = "Не удалось определить IP"

# Кэш для антиспама
sent_ips = {}

# Кэш для геоданных
geo_cache = {}

# ==== Функция получения геоданных ====
def get_ip_geo_info(ip):
    """Получает информацию о местоположении IP через ip-api.com"""
    if ip in geo_cache:
        return geo_cache[ip]
    
    try:
        # Используем ip-api.com (бесплатно, до 45 запросов в минуту)
        url = f'http://ip-api.com/json/{ip}?fields=status,country,countryCode,regionName,city,isp,org,lat,lon'
        headers = {'User-Agent': 'Mozilla/5.0 (compatible; SSH-Monitor/2.0)'}
        
        response = requests.get(url, headers=headers, timeout=5)
        
        if response.status_code == 200:
            data = response.json()
            if data.get('status') == 'success':
                geo_info = {
                    'country': data.get('country', 'Неизвестно'),
                    'countryCode': data.get('countryCode', ''),
                    'region': data.get('regionName', 'Неизвестно'),
                    'city': data.get('city', 'Неизвестно'),
                    'isp': data.get('isp', 'Неизвестно'),
                    'org': data.get('org', 'Неизвестно'),
                    'lat': data.get('lat', ''),
                    'lon': data.get('lon', '')
                }
                geo_cache[ip] = geo_info
                return geo_info
    except Exception as e:
        print(f"Ошибка получения геоданных для {ip}: {e}")
    
    # Возвращаем заглушку в случае ошибки
    geo_info = {
        'country': 'Неизвестно',
        'countryCode': '',
        'region': 'Неизвестно',
        'city': 'Неизвестно',
        'isp': 'Неизвестно',
        'org': 'Неизвестно',
        'lat': '',
        'lon': ''
    }
    geo_cache[ip] = geo_info
    return geo_info

# ==== Функция отправки в Telegram ====
def send_telegram_message(message):
    data = {"chat_id": TELEGRAM_CHAT_ID, "text": message, "parse_mode": "HTML"}
    try:
        requests.post(TELEGRAM_API_URL, data=data, timeout=10)
    except Exception as e:
        print(f"Ошибка отправки в Telegram: {e}")

# ==== Проверка антиспама ====
def can_send_for_ip(ip):
    """Проверяем, можно ли отправить сообщение для данного IP"""
    if not ANTISPAM_ENABLED:
        return True
    
    current_time = time.time()
    
    if ip in sent_ips:
        if current_time - sent_ips[ip] < ANTISPAM_TIMEOUT:
            return False
    
    sent_ips[ip] = current_time
    return True

# ==== Форматирование сообщений с геоданными ====
def format_ip_geo_info(geo_info):
    """Форматирует геоинформацию для вставки в сообщение"""
    lines = []
    if geo_info['country'] != 'Неизвестно':
        flag = ""
        if geo_info['countryCode']:
            flag = f" {geo_info['countryCode']}"
        lines.append(f"   🌍 Страна: {geo_info['country']}{flag}")
    if geo_info['region'] != 'Неизвестно' and geo_info['region'] != geo_info['city']:
        lines.append(f"   📍 Регион: {geo_info['region']}")
    if geo_info['city'] != 'Неизвестно':
        lines.append(f"   🏙️ Город: {geo_info['city']}")
    if geo_info['isp'] != 'Неизвестно':
        lines.append(f"   📡 Провайдер: {geo_info['isp']}")
    if geo_info['org'] != 'Неизвестно' and geo_info['org'] != geo_info['isp']:
        lines.append(f"   🏢 Организация: {geo_info['org']}")
    if geo_info['lat'] and geo_info['lon']:
        lines.append(f"   🗺️ Координаты: {geo_info['lat']}, {geo_info['lon']}")
    
    if lines:
        return "\n" + "\n".join(lines)
    return ""

def format_success(user, method, client_ip, port):
    now = datetime.datetime.now()
    geo_info = get_ip_geo_info(client_ip)
    geo_text = format_ip_geo_info(geo_info)
    
    return f"""#SSH_Подключения ✅
🖥️ Сервер: {SERVER_HOSTNAME}
🌐 Сервер IP: {SERVER_IP}
📌 FQDN: {SERVER_FQDN}

Успешное SSH подключение
👤 Пользователь: {user}
🔐 Метод: {method}
🌍 Клиент IP: {client_ip}{geo_text}
🔌 Порт: {port}
📅 Дата: {now.strftime('%Y-%m-%d')}
🕒 Время: {now.strftime('%H:%M:%S')}"""

def format_failed(client_ip, port, username="неизвестно", method="неизвестно", is_alternative=False):
    now = datetime.datetime.now()
    geo_info = get_ip_geo_info(client_ip)
    geo_text = format_ip_geo_info(geo_info)
    
    if is_alternative:
        username = f"попытка подключения к порту {port}"
        method = "TCP-соединение"
    
    return f"""#SSH_Атака ❌
🖥️ Сервер: {SERVER_HOSTNAME}
🌐 Сервер IP: {SERVER_IP}
📌 FQDN: {SERVER_FQDN}

Неудачная попытка подключения
🌍 Клиент IP: {client_ip}{geo_text}
👤 Попытка входа: {username}
🔐 Метод: {method}
🔌 Порт: {port}
📅 Дата: {now.strftime('%Y-%m-%d')}
🕒 Время: {now.strftime('%H:%M:%S')}"""

# ==== Мониторинг sshd логов ====
def monitor_sshd():
    # Пробуем разные команды для journalctl
    commands = [
        ["journalctl", "_COMM=sshd", "-f", "-n", "0", "--no-pager", "-o", "cat"],
        ["journalctl", "-u", "ssh", "-f", "-n", "0", "--no-pager", "-o", "cat"],
        ["journalctl", "-u", "sshd", "-f", "-n", "0", "--no-pager", "-o", "cat"],
        ["tail", "-f", "/var/log/auth.log"]  # Для Ubuntu/Debian
    ]
    
    process = None
    for cmd in commands:
        try:
            print(f"Пробуем команду: {' '.join(cmd)}")
            process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
            # Проверяем, работает ли команда
            time.sleep(1)
            if process.poll() is None:  # Процесс все еще работает
                print(f"Команда успешно запущена: {' '.join(cmd)}")
                break
        except:
            continue
    
    if not process:
        print("Не удалось запустить мониторинг SSH логов")
        return

    for line in process.stdout:
        line = line.strip()
        if not line:
            continue

        # Успешное подключение
        if "Accepted" in line:
            ip_match = re.search(r'from\s+([0-9.:]+)', line)
            user_match = re.search(r'for\s+(\S+)', line)
            method_match = re.search(r'Accepted\s+(\S+)\s+for', line)
            port_match = re.search(r'port\s+(\d+)', line)
            if ip_match and user_match:
                # Проверяем антиспам
                if can_send_for_ip(ip_match.group(1)):
                    message = format_success(user_match.group(1),
                                             method_match.group(1) if method_match else "password",
                                             ip_match.group(1),
                                             port_match.group(1) if port_match else "unknown")
                    send_telegram_message(message)
                    print(f"✅ Успешное подключение: {user_match.group(1)}@{ip_match.group(1)}")

        # Неудачные подключения
        elif "Failed password" in line or "Invalid user" in line:
            ip_match = re.search(r'from\s+([0-9.:]+)', line)
            port_match = re.search(r'port\s+(\d+)', line)
            
            # Извлекаем имя пользователя
            user_match = None
            method = "password"  # По умолчанию
            
            # Проверяем разные форматы
            patterns = [
                r'Invalid user\s+(\S+)',
                r'invalid user\s+(\S+)',
                r'for invalid user\s+(\S+)',
                r'for\s+(\S+)\s+from',
                r'Failed password for\s+(\S+)'
            ]
            
            for pattern in patterns:
                match = re.search(pattern, line, re.IGNORECASE)
                if match:
                    user_match = match
                    break
            
            # Определяем метод аутентификации для неудачных попыток
            if "Failed password" in line:
                if "invalid user" in line.lower():
                    method = "password (несуществующий пользователь)"
                else:
                    method = "password (неверный пароль)"
            elif "Invalid user" in line:
                method = "попытка входа с несуществующим пользователем"
            
            if ip_match:
                username = user_match.group(1) if user_match else "неизвестно"
                client_port = port_match.group(1) if port_match else "unknown"
                
                # Проверяем антиспам
                if can_send_for_ip(ip_match.group(1)):
                    message = format_failed(ip_match.group(1), 
                                            client_port,
                                            username,
                                            method,
                                            False)
                    send_telegram_message(message)
                    print(f"❌ Атака: {username}@{ip_match.group(1)} (метод: {method})")

# ==== Мониторинг TCP-пакетов на альтернативных портах ====
def monitor_port_tcpdump(port):
    """Мониторит указанный порт на предмет входящих соединений"""
    # Проверяем наличие tcpdump
    try:
        subprocess.run(["which", "tcpdump"], check=True, capture_output=True)
    except subprocess.CalledProcessError:
        print(f"❌ tcpdump не установлен. Мониторинг порта {port} отключен")
        return
    
    # Словарь для отслеживания времени последнего SYN с IP
    # { "1.2.3.4": последнее_время }
    last_syn_time = {}
    SYN_TIMEOUT = 3  # секунд - если пауза больше, считаем новой атакой
    
    cmd = ["tcpdump", "-ni", "any", "port", str(port), "-l"]
    
    try:
        process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
    except Exception as e:
        print(f"❌ Ошибка запуска tcpdump для порта {port}: {e}")
        return
    
    print(f"📡 Мониторинг порта {port} запущен")
    
    for line in process.stdout:
        line = line.strip()
        if not line:
            continue
        
        # Отслеживаем только новые подключения (SYN пакеты)
        if "Flags [S]" in line:
            match = re.search(r'IP\s+([0-9.]+)\.(\d+)\s+>', line)
            if match:
                client_ip = match.group(1)
                client_port = match.group(2)
                current_time = time.time()
                
                # Проверяем, был ли недавно SYN с этого IP
                should_notify = False
                
                if client_ip not in last_syn_time:
                    # Первый SYN с этого IP
                    should_notify = True
                else:
                    # Проверяем, сколько прошло времени с последнего SYN
                    time_diff = current_time - last_syn_time[client_ip]
                    if time_diff > SYN_TIMEOUT:
                        # Прошло больше таймаута - это новая атака
                        should_notify = True
                    else:
                        # Меньше таймаута - это часть той же атаки, игнорируем
                        pass
                
                # Обновляем время последнего SYN
                last_syn_time[client_ip] = current_time
                
                # Отправляем уведомление если нужно
                if should_notify and can_send_for_ip(client_ip):
                    print(f"⚠️ Атака на порт {port} с {client_ip}:{client_port}")
                    message = format_failed(client_ip, 
                                           str(port),
                                           f"атака на порт {port}",
                                           "TCP-сканирование",
                                           True)
                    send_telegram_message(message)

def monitor_alternative_ports():
    """Запускает мониторинг для всех альтернативных портов"""
    if not ALT_PORTS:
        print("📡 Мониторинг альтернативных портов отключен")
        return
    
    threads = []
    for port in ALT_PORTS:
        thread = threading.Thread(target=monitor_port_tcpdump, args=(port,))
        thread.daemon = True
        thread.start()
        threads.append(thread)
    
    # Ожидаем завершения всех потоков (никогда не произойдет)
    for thread in threads:
        thread.join()

# ==== Главная функция ====
def main():
    antispam_status = f"ВКЛЮЧЕН ({ANTISPAM_TIMEOUT} сек)" if ANTISPAM_ENABLED else "ОТКЛЮЧЕН"
    
    print("=" * 60)
    print("SSH Alert Monitor v2.0 (с геолокацией)")
    print("=" * 60)
    print(f"Сервер: {SERVER_HOSTNAME}")
    print(f"IP: {SERVER_IP}")
    print(f"FQDN: {SERVER_FQDN}")
    print(f"Telegram Chat ID: {TELEGRAM_CHAT_ID}")
    if ALT_PORTS:
        print(f"Альтернативные порты: {', '.join(ALT_PORTS)}")
    else:
        print("Альтернативные порты: не отслеживаются")
    print(f"Антиспам: {antispam_status}")
    print("=" * 60)
    
    # Отправляем приветственное сообщение
    ports_info = f"🔌 Альт. порты: {', '.join(ALT_PORTS)}" if ALT_PORTS else "🔌 Альт. порты: не отслеживаются"
    
    welcome_message = f"""#SSH_Мониторинг 🚀
🖥️ Сервер: {SERVER_HOSTNAME}
🌐 Сервер IP: {SERVER_IP}
📌 FQDN: {SERVER_FQDN}
{ports_info}
🛡️ Антиспам: {antispam_status}

Мониторинг SSH подключений запущен
📅 Дата: {datetime.datetime.now().strftime('%Y-%m-%d')}
🕒 Время: {datetime.datetime.now().strftime('%H:%M:%S')}

Ожидание событий..."""
    
    send_telegram_message(welcome_message)
    
    # Запускаем потоки
    t1 = threading.Thread(target=monitor_sshd)
    t2 = threading.Thread(target=monitor_alternative_ports)
    t1.daemon = True
    t2.daemon = True
    t1.start()
    t2.start()
    
    if ALT_PORTS:
        print(f"\n📡 Мониторинг SSH и портов {', '.join(ALT_PORTS)}... (нажмите Ctrl+C для остановки)\n")
    else:
        print(f"\n📡 Мониторинг SSH (альтернативные порты отключены)... (нажмите Ctrl+C для остановки)\n")
    
    try:
        t1.join()
        t2.join()
    except KeyboardInterrupt:
        print("\n⏹️ Остановка мониторинга...")
        stop_message = f"""#SSH_Мониторинг ⏹️
🖥️ Сервер: {SERVER_HOSTNAME}
🌐 Сервер IP: {SERVER_IP}
📌 FQDN: {SERVER_FQDN}

Мониторинг SSH подключений остановлен
📅 Дата: {datetime.datetime.now().strftime('%Y-%m-%d')}
🕒 Время: {datetime.datetime.now().strftime('%H:%M:%S')}"""
        send_telegram_message(stop_message)

if __name__ == "__main__":
    main()
EOF

    chmod +x "$SCRIPT_PATH"
    print_success "Скрипт создан: $SCRIPT_PATH"
}

# Создание systemd сервиса
create_systemd_service() {
    print_info "Создание systemd сервиса..."
    
    cat > "$SERVICE_PATH" << EOF
[Unit]
Description=SSH Connection Telegram Alert Monitor v2.0 (с геолокацией)
After=network.target auditd.service systemd-user-sessions.service time-sync.target
Requires=network.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/bin/python3 /usr/local/bin/ssh-telegram-alert.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$SERVICE_NAME

# Безопасность
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/tmp
PrivateTmp=yes
PrivateDevices=yes
ProtectHostname=yes
ProtectClock=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictRealtime=yes
RestrictNamespaces=yes

[Install]
WantedBy=multi-user.target
EOF
    
    # Перезагружаем демон systemd
    systemctl daemon-reload
    
    print_success "Сервис создан: $SERVICE_PATH"
    print_info "Наименование службы: $SERVICE_NAME"
}

# Включение и запуск сервиса
enable_and_start_service() {
    print_info "Запуск сервиса..."
    
    # Включаем автозапуск
    systemctl enable "$SERVICE_NAME"
    if [ $? -eq 0 ]; then
        print_success "Сервис добавлен в автозагрузку"
    else
        print_error "Ошибка при добавлении в автозагрузку"
    fi
    
    # Запускаем сервис
    systemctl start "$SERVICE_NAME"
    if [ $? -eq 0 ]; then
        print_success "Сервис запущен"
    else
        print_error "Ошибка при запуске сервиса"
    fi
}

# Проверка работы сервиса
check_service_status() {
    print_info "Проверка статуса сервиса..."
    
    echo ""
    systemctl status "$SERVICE_NAME" --no-pager -l
    
    # Проверяем, активен ли сервис
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        print_success "Сервис работает корректно"
    else
        print_error "Сервис не работает. Проверьте логи: journalctl -u $SERVICE_NAME -f"
    fi
}

# Показ инструкций
show_instructions() {
    echo ""
    print_info "=== ИНСТРУКЦИЯ ПО ИСПОЛЬЗОВАНИЮ ==="
    echo ""
    echo "📋 Управление службой:"
    echo "  ┌─────────────────────────────────────────────┐"
    echo "  │ ${GREEN}sudo systemctl status $SERVICE_NAME${NC}     │  # Просмотр статуса"
    echo "  │ ${GREEN}sudo journalctl -u $SERVICE_NAME -f${NC}     │  # Просмотр логов"
    echo "  │ ${GREEN}sudo systemctl restart $SERVICE_NAME${NC}    │  # Перезапуск"
    echo "  │ ${GREEN}sudo systemctl stop $SERVICE_NAME${NC}       │  # Остановка"
    echo "  │ ${GREEN}sudo systemctl start $SERVICE_NAME${NC}      │  # Запуск"
    echo "  │ ${GREEN}sudo systemctl disable $SERVICE_NAME${NC}    │  # Отключить автозапуск"
    echo "  └─────────────────────────────────────────────┘"
    echo ""
    echo "📁 Расположение файлов:"
    echo "  ├─ Скрипт: ${GREEN}$SCRIPT_PATH${NC}"
    echo "  ├─ Конфиг: ${GREEN}$CONFIG_PATH${NC}"
    echo "  └─ Сервис: ${GREEN}$SERVICE_PATH${NC}"
    echo ""
    echo "⚙️ Изменение настроек:"
    echo "  ┌─────────────────────────────────────────────┐"
    echo "  │ ${GREEN}sudo nano $CONFIG_PATH${NC}                     │  # Редактировать конфиг"
    echo "  │ ${GREEN}sudo systemctl restart $SERVICE_NAME${NC}       │  # Применить изменения"
    echo "  └─────────────────────────────────────────────┘"
    echo ""
    echo "🔌 Отслеживаемые порты:"
    echo "  ├─ Стандартный SSH: 22"
    if [ -n "$ALT_PORTS" ]; then
        echo "  └─ Альтернативные: ${GREEN}$ALT_PORTS${NC}"
    else
        echo "  └─ Альтернативные: ${YELLOW}не отслеживаются${NC}"
    fi
    echo ""
    
    if [ "$ANTISPAM_ENABLED" = "true" ]; then
        echo "🛡️ Антиспам: ${GREEN}ВКЛЮЧЕН${NC} (интервал: $ANTISPAM_TIMEOUT сек)"
    else
        echo "🛡️ Антиспам: ${RED}ОТКЛЮЧЕН${NC} (вы будете получать много сообщений!)"
    fi
    echo ""
    print_info "Для проверки работы сделайте неудачную попытку SSH подключения"
}

# Тестовое сообщение в Telegram
send_test_message() {
    print_info "Отправка тестового сообщения..."
    
    # Определяем статус антиспама для тестового сообщения
    if [ "$ANTISPAM_ENABLED" = "true" ]; then
        ANTISPAM_TEXT="ВКЛЮЧЕН ($ANTISPAM_TIMEOUT сек)"
    else
        ANTISPAM_TEXT="ОТКЛЮЧЕН"
    fi
    
    # Формируем информацию о портах
    if [ -n "$ALT_PORTS" ]; then
        PORTS_TEXT="$ALT_PORTS"
    else
        PORTS_TEXT="не отслеживаются"
    fi
    
    # Создаем временный скрипт для отправки теста
    TEMP_TEST="/tmp/ssh_alert_test.py"
    
    cat > "$TEMP_TEST" << EOF
#!/usr/bin/env python3
import requests
import datetime
import socket

TELEGRAM_BOT_TOKEN = "$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID = "$TELEGRAM_CHAT_ID"
ALT_PORTS = "$ALT_PORTS"
TELEGRAM_API_URL = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"

# Информация о сервере
hostname = socket.gethostname()
try:
    fqdn = socket.getfqdn()
except:
    fqdn = hostname

# Получаем IP
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(("8.8.8.8", 80))
    server_ip = s.getsockname()[0]
    s.close()
except:
    try:
        server_ip = socket.gethostbyname(socket.gethostname())
    except:
        server_ip = "Не удалось определить"

antispam_status = "$ANTISPAM_TEXT"
ports_text = "$PORTS_TEXT"

now = datetime.datetime.now()
current_date = now.strftime('%Y-%m-%d')
current_time = now.strftime('%H:%M:%S')

test_message = f"""#SSH_Тест ✅
🖥️ Сервер: {hostname}
🌐 Сервер IP: {server_ip}
📌 FQDN: {fqdn}
🔌 Альт. порты: {ports_text}
🛡️ Антиспам: {antispam_status}

Тестовое сообщение
Установка завершена успешно
⚙️ Версия: 2.0 (с геолокацией, множественные порты)

📅 Дата: {current_date}
🕒 Время: {current_time}"""

data = {
    "chat_id": TELEGRAM_CHAT_ID,
    "text": test_message,
    "parse_mode": "HTML"
}

try:
    response = requests.post(TELEGRAM_API_URL, data=data, timeout=10)
    response.raise_for_status()
    print("✅ Тестовое сообщение отправлено успешно!")
    print(f"📊 Сервер: {hostname} ({fqdn}) - {server_ip}")
    print(f"📨 Chat ID: {TELEGRAM_CHAT_ID}")
    print(f"🔌 Альт. порты: {ports_text}")
    print(f"🛡️ Антиспам: {antispam_status}")
except Exception as e:
    print(f"❌ Ошибка отправки тестового сообщения: {e}")
EOF
    
    python3 "$TEMP_TEST"
    rm -f "$TEMP_TEST"
}

# Основная функция
main() {
    echo ""
    print_info "=== УСТАНОВЩИК SSH TELEGRAM ALERT v2.0 (с геолокацией, множественные порты) ==="
    echo ""
    
    # Проверка прав
    check_root
    
    # Проверка существующей установки
    if check_existing_installation; then
        echo ""
        print_warning "Обнаружена существующая установка!"
        echo ""
        echo "Выберите действие:"
        echo "  ${GREEN}1${NC}) Переустановить (удалить старую версию и установить заново)"
        echo "  ${YELLOW}2${NC}) Обновить конфигурацию (сохранить скрипт, обновить настройки)"
        echo "  ${RED}3${NC}) Удалить существующую установку"
        echo "  ${BLUE}4${NC}) Выйти"
        echo ""
        read -p "Ваш выбор (1-4): " action
        
        case $action in
            1)
                print_info "Выбрана переустановка"
                remove_existing_installation
                ;;
            2)
                print_info "Выбрано обновление конфигурации"
                # Сохраняем старый скрипт как бэкап
                if [ -f "$SCRIPT_PATH" ]; then
                    cp "$SCRIPT_PATH" "${SCRIPT_PATH}.backup"
                    print_info "Создан бэкап: ${SCRIPT_PATH}.backup"
                fi
                ;;
            3)
                print_info "Выбрано удаление"
                remove_existing_installation
                print_success "Установка удалена"
                exit 0
                ;;
            4)
                print_info "Выход"
                exit 0
                ;;
            *)
                print_error "Неверный выбор"
                exit 1
                ;;
        esac
    fi
    
    # Проверка зависимостей
    check_dependencies
    
    # Получение данных (включая настройки портов и антиспама)
    get_telegram_data
    
    # Создание конфигурационного файла
    create_config_file
    
    # Создание скрипта
    create_monitor_script
    
    # Создание сервиса
    create_systemd_service
    
    # Запуск сервиса
    enable_and_start_service
    
    # Небольшая пауза для инициализации
    sleep 3
    
    # Проверка статуса
    check_service_status
    
    # Отправка тестового сообщения
    echo ""
    read -p "Отправить тестовое сообщение в Telegram? (y/n): " send_test
    if [[ "$send_test" =~ ^[Yy]$ ]]; then
        send_test_message
    fi
    
    # Показ инструкций
    show_instructions
    
    echo ""
    print_success "Установка завершена!"
    
    if [ -n "$ALT_PORTS" ]; then
        print_info "Сервис '$SERVICE_NAME' будет отслеживать все SSH подключения и порты: $ALT_PORTS"
    else
        print_info "Сервис '$SERVICE_NAME' будет отслеживать только стандартный SSH порт 22"
    fi
    echo ""
}

# Запуск основной функции
main
