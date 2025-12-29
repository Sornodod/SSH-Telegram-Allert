#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        print_error "Этот скрипт должен запускаться с правами root"
        print_info "Используйте: sudo $0"
        exit 1
    fi
}

check_dependencies() {
    print_info "Проверка зависимостей..."
    
    if ! command -v python3 &> /dev/null; then
        print_error "Python3 не установлен"
        print_info "Установка Python3..."
        apt-get update
        apt-get install -y python3 python3-pip
    fi
    
    if ! command -v pip3 &> /dev/null; then
        print_info "Установка pip3..."
        apt-get install -y python3-pip
    fi
    
    if ! python3 -c "import requests" &> /dev/null; then
        print_info "Установка библиотеки requests..."
        pip3 install requests
    fi
    
    print_success "Все зависимости установлены"
}

get_telegram_data() {
    echo ""
    print_info "=== НАСТРОЙКА TELEGRAM ==="
    echo ""
    
    while true; do
        read -p "Введите ID Telegram чата: " TELEGRAM_CHAT_ID
        
        if [[ -z "$TELEGRAM_CHAT_ID" ]]; then
            print_error "ID чата не может быть пустым"
            continue
        fi
        
        if [[ ! "$TELEGRAM_CHAT_ID" =~ ^-?[0-9]+$ ]]; then
            print_error "ID чата должен содержать только цифры (может начинаться с минуса, если это супергруппа)"
            continue
        fi
        
        print_info "Вы ввели ID чата: $TELEGRAM_CHAT_ID"
        read -p "Это верно? (y/n): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            break
        fi
    done
    
    echo ""
    
    while true; do
        read -p "Введите токен Telegram бота: " TELEGRAM_BOT_TOKEN
        
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
}

create_monitor_script() {
    print_info "Создание скрипта мониторинга..."
    
    SCRIPT_PATH="/usr/local/bin/ssh-telegram-alert.py"
    
    cat > "$SCRIPT_PATH" << EOF
#!/usr/bin/env python3
import subprocess
import re
import requests
import datetime
import hashlib

TELEGRAM_BOT_TOKEN = "$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID = "$TELEGRAM_CHAT_ID"
TELEGRAM_API_URL = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"

processed_hashes = set()
MAX_PROCESSED_HASHES = 1000

def send_telegram_message(message):
    data = {
        "chat_id": TELEGRAM_CHAT_ID,
        "text": message,
        "parse_mode": "HTML"
    }
    
    try:
        response = requests.post(TELEGRAM_API_URL, data=data, timeout=10)
        response.raise_for_status()
        return True
    except Exception as e:
        print(f"Ошибка отправки в Telegram: {e}")
        return False

def get_message_hash(line):
    clean_line = re.sub(r'^\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\s+\S+\s+', '', line)
    return hashlib.md5(clean_line.encode()).hexdigest()

def parse_ssh_line(line):
    if "Accepted" in line and ("password" in line or "publickey" in line):
        ip_match = re.search(r'from\s+([0-9.:]+)', line)
        user_match = re.search(r'for\s+(\S+)', line)
        auth_method_match = re.search(r'Accepted\s+(\S+)\s+for', line)
        
        if ip_match and user_match:
            return {
                'type': 'success',
                'ip': ip_match.group(1),
                'user': user_match.group(1),
                'auth_method': auth_method_match.group(1) if auth_method_match else 'password'
            }
    
    elif "Invalid user" in line:
        ip_match = re.search(r'from\s+([0-9.:]+)', line)
        user_match = re.search(r'Invalid user\s+(\S+)', line)
        
        if ip_match and user_match:
            return {
                'type': 'failed_user',
                'ip': ip_match.group(1),
                'user': user_match.group(1)
            }
    
    elif "Failed password" in line and "Invalid user" not in line:
        ip_match = re.search(r'from\s+([0-9.:]+)', line)
        user_match = re.search(r'for\s+(\S+)', line)
        
        if ip_match and user_match:
            return {
                'type': 'failed_password',
                'ip': ip_match.group(1),
                'user': user_match.group(1)
            }
    
    return None

def monitor_ssh():
    print("Мониторинг SSH подключений запущен...")
    
    cmd = [
        "journalctl",
        "_COMM=sshd",
        "-f",
        "-n", "0",
        "--no-pager",
        "-o", "short"
    ]
    
    try:
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            universal_newlines=True
        )
        
        print("Ожидание SSH событий...")
        
        for raw_line in process.stdout:
            line = raw_line.strip()
            if not line:
                continue
            
            if '-- No entries --' in line or '-- Reboot --' in line:
                continue
            
            line_hash = get_message_hash(line)
            
            if line_hash in processed_hashes:
                continue
            
            processed_hashes.add(line_hash)
            
            if len(processed_hashes) > MAX_PROCESSED_HASHES:
                processed_hashes.remove(next(iter(processed_hashes)))
            
            event = parse_ssh_line(line)
            if not event:
                continue
            
            now = datetime.datetime.now()
            current_date = now.strftime('%Y-%m-%d')
            current_time = now.strftime('%H:%M:%S')
            
            if event['type'] == 'success':
                message = f"""<b>#SSH_Подключения</b>
✅ Успешное SSH подключение
👤 Пользователь: {event['user']}
🔐 Метод аутентификации: {event['auth_method']}
🌐 IP адрес: {event['ip']}
📅 Дата: {current_date}
🕒 Время: {current_time}"""
                
                print(f"✓ Успешное подключение: {event['user']}@{event['ip']}")
            
            elif event['type'] == 'failed_user':
                message = f"""<b>#SSH_Подключения</b>
❌ Неудачное SSH подключение
👤 Неверный пользователь: {event['user']}
🌐 IP адрес: {event['ip']}
📅 Дата: {current_date}
🕒 Время: {current_time}"""
                
                print(f"✗ Неверный пользователь: {event['user']}@{event['ip']}")
            
            elif event['type'] == 'failed_password':
                message = f"""<b>#SSH_Подключения</b>
❌ Неудачное SSH подключение
👤 Пользователь: {event['user']}
🌐 IP адрес: {event['ip']}
📅 Дата: {current_date}
🕒 Время: {current_time}"""
                
                print(f"✗ Неверный пароль: {event['user']}@{event['ip']}")
            
            else:
                continue
            
            send_telegram_message(message)
    
    except KeyboardInterrupt:
        print("\nОстановка мониторинга...")
    except Exception as e:
        print(f"Ошибка: {e}")

def main():
    print("SSH Alert Monitor")
    print("=" * 50)
    monitor_ssh()

if __name__ == "__main__":
    main()
EOF
    
    chmod +x "$SCRIPT_PATH"
    print_success "Скрипт создан: $SCRIPT_PATH"
}

create_systemd_service() {
    print_info "Создание systemd сервиса..."
    
    SERVICE_NAME="ssh-telegram-alert"
    SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME.service"
    
    cat > "$SERVICE_PATH" << EOF
[Unit]
Description=SSH Connection Telegram Alert Monitor
After=network.target
Requires=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /usr/local/bin/ssh-telegram-alert.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$SERVICE_NAME
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectHostname=true
ProtectClock=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    
    print_success "Сервис создан: $SERVICE_PATH"
    print_info "Наименование службы: $SERVICE_NAME"
}

enable_and_start_service() {
    print_info "Запуск сервиса..."
    
    SERVICE_NAME="ssh-telegram-alert"
    
    systemctl enable "$SERVICE_NAME"
    if [ $? -eq 0 ]; then
        print_success "Сервис добавлен в автозагрузку"
    else
        print_error "Ошибка при добавлении в автозагрузку"
    fi
    
    systemctl start "$SERVICE_NAME"
    if [ $? -eq 0 ]; then
        print_success "Сервис запущен"
    else
        print_error "Ошибка при запуске сервиса"
    fi
}

check_service_status() {
    print_info "Проверка статуса сервиса..."
    
    SERVICE_NAME="ssh-telegram-alert"
    
    echo ""
    systemctl status "$SERVICE_NAME" --no-pager
    
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        print_success "Сервис работает корректно"
    else
        print_error "Сервис не работает. Проверьте логи: journalctl -u $SERVICE_NAME"
    fi
}

show_instructions() {
    echo ""
    print_info "=== ИНСТРУКЦИЯ ПО ИСПОЛЬЗОВАНИЮ ==="
    echo ""
    echo "Управление службой:"
    echo "  Просмотр статуса: ${GREEN}sudo systemctl status ssh-telegram-alert${NC}"
    echo "  Просмотр логов:   ${GREEN}sudo journalctl -u ssh-telegram-alert -f${NC}"
    echo "  Перезапуск:       ${GREEN}sudo systemctl restart ssh-telegram-alert${NC}"
    echo "  Остановка:        ${GREEN}sudo systemctl stop ssh-telegram-alert${NC}"
    echo "  Запуск:           ${GREEN}sudo systemctl start ssh-telegram-alert${NC}"
    echo "  Отключение автозапуска: ${GREEN}sudo systemctl disable ssh-telegram-alert${NC}"
    echo ""
    echo "Расположение файлов:"
    echo "  Скрипт:           ${GREEN}/usr/local/bin/ssh-telegram-alert.py${NC}"
    echo "  Конфигурация:     ${GREEN}/etc/systemd/system/ssh-telegram-alert.service${NC}"
    echo ""
    print_info "Сервис будет автоматически перезапускаться при сбоях и стартовать при загрузке системы"
}

send_test_message() {
    print_info "Отправка тестового сообщения..."
    
    TEMP_TEST="/tmp/ssh_alert_test.py"
    
    cat > "$TEMP_TEST" << EOF
#!/usr/bin/env python3
import requests
import datetime

TELEGRAM_BOT_TOKEN = "$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID = "$TELEGRAM_CHAT_ID"
TELEGRAM_API_URL = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"

now = datetime.datetime.now()
current_date = now.strftime('%Y-%m-%d')
current_time = now.strftime('%H:%M:%S')

test_message = f"""<b>#SSH_Подключения</b>
🔧 Тестовое сообщение
📋 Система: SSH Alert Monitor
✅ Установка завершена успешно
📅 Дата: {current_date}
🕒 Время: {current_time}

Сервис мониторинга SSH подключений установлен и работает!"""

data = {
    "chat_id": TELEGRAM_CHAT_ID,
    "text": test_message,
    "parse_mode": "HTML"
}

try:
    response = requests.post(TELEGRAM_API_URL, data=data, timeout=10)
    response.raise_for_status()
    print("Тестовое сообщение отправлено успешно!")
except Exception as e:
    print(f"Ошибка отправки тестового сообщения: {e}")
EOF
    
    python3 "$TEMP_TEST"
    rm -f "$TEMP_TEST"
}

main() {
    echo ""
    print_info "=== УСТАНОВЩИК SSH TELEGRAM ALERT ==="
    echo ""
    
    check_root
    check_dependencies
    get_telegram_data
    create_monitor_script
    create_systemd_service
    enable_and_start_service
    sleep 2
    check_service_status
    
    echo ""
    read -p "Отправить тестовое сообщение в Telegram? (y/n): " send_test
    if [[ "$send_test" =~ ^[Yy]$ ]]; then
        send_test_message
    fi
    
    show_instructions
    
    echo ""
    print_success "Установка завершена!"
    print_info "Сервис 'ssh-telegram-alert' будет отслеживать все SSH подключения"
    echo ""
}

main
