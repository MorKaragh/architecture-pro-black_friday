#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Настройки
API_URL="${API_URL:-http://localhost:8080}"
ENDPOINT="${ENDPOINT:-/helloDoc/users}"
REDIS_CONTAINER="${REDIS_CONTAINER:-redis}"

echo -e "${BOLD}${CYAN}========================================${NC}"
echo -e "${BOLD}${CYAN}  Тест работы Redis кеширования${NC}"
echo -e "${BOLD}${CYAN}========================================${NC}"
echo ""

# Функция для форматирования времени
format_time() {
    local seconds=$1
    if awk "BEGIN {exit !($seconds > 1)}"; then
        printf "${RED}%.3f сек${NC}" "$seconds"
    elif awk "BEGIN {exit !($seconds > 0.1)}"; then
        printf "${YELLOW}%.3f сек${NC}" "$seconds"
    else
        printf "${GREEN}%.3f сек${NC}" "$seconds"
    fi
}

# Функция для вычисления времени выполнения
measure_time() {
    local start=$(date +%s.%N)
    "$@" > /dev/null 2>&1
    local end=$(date +%s.%N)
    awk "BEGIN {printf \"%.3f\", $end - $start}"
}

# Проверка доступности API
echo -e "${BLUE}[1/6]${NC} Проверка доступности API..."
if ! curl -s -f "${API_URL}/" > /dev/null 2>&1; then
    echo -e "${RED}✗ API недоступен по адресу ${API_URL}${NC}"
    exit 1
fi
echo -e "${GREEN}✓ API доступен${NC}"
echo ""

# Проверка статуса кеша в API
echo -e "${BLUE}[2/6]${NC} Проверка статуса кеша в API..."
CACHE_STATUS=$(curl -s "${API_URL}/" | python3 -c "import sys, json; data=json.load(sys.stdin); print('enabled' if data.get('cache_enabled') else 'disabled')" 2>/dev/null)
if [ "$CACHE_STATUS" = "enabled" ]; then
    echo -e "${GREEN}✓ Кеш включен в API${NC}"
else
    echo -e "${YELLOW}⚠ Кеш отключен в API${NC}"
fi
echo ""

# Проверка доступности Redis
echo -e "${BLUE}[3/6]${NC} Проверка доступности Redis..."
if ! docker exec "${REDIS_CONTAINER}" redis-cli ping > /dev/null 2>&1; then
    echo -e "${RED}✗ Redis недоступен (контейнер: ${REDIS_CONTAINER})${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Redis доступен${NC}"
echo ""

# Очистка кеша
echo -e "${BLUE}[4/6]${NC} Очистка кеша Redis..."
KEYS_BEFORE=$(docker exec "${REDIS_CONTAINER}" redis-cli DBSIZE 2>/dev/null | tail -1)
docker exec "${REDIS_CONTAINER}" redis-cli FLUSHDB > /dev/null 2>&1
KEYS_AFTER=$(docker exec "${REDIS_CONTAINER}" redis-cli DBSIZE 2>/dev/null | tail -1)
echo -e "${GREEN}✓ Кеш очищен (было ключей: ${KEYS_BEFORE}, стало: ${KEYS_AFTER})${NC}"
echo ""

# Первый запрос (без кеша)
echo -e "${BLUE}[5/6]${NC} Выполнение первого запроса (без кеша)..."
FIRST_REQUEST_TIME=$(measure_time curl -s "${API_URL}${ENDPOINT}")
echo -e "   Время выполнения: $(format_time $FIRST_REQUEST_TIME)"
echo ""

# Проверка ключей в Redis после первого запроса
KEYS_AFTER_FIRST=$(docker exec "${REDIS_CONTAINER}" redis-cli DBSIZE 2>/dev/null | tail -1)
if [ "$KEYS_AFTER_FIRST" -gt 0 ]; then
    echo -e "${GREEN}✓ Ключи кеша созданы в Redis (количество: ${KEYS_AFTER_FIRST})${NC}"
    CACHE_KEY=$(docker exec "${REDIS_CONTAINER}" redis-cli KEYS "*" 2>/dev/null | head -1)
    echo -e "   Ключ кеша: ${CYAN}${CACHE_KEY}${NC}"
else
    echo -e "${YELLOW}⚠ Ключи кеша не найдены в Redis${NC}"
fi
echo ""

# Второй запрос (с кешем)
echo -e "${BLUE}[6/6]${NC} Выполнение второго запроса (с кешем)..."
SECOND_REQUEST_TIME=$(measure_time curl -s "${API_URL}${ENDPOINT}")
echo -e "   Время выполнения: $(format_time $SECOND_REQUEST_TIME)"
echo ""

# Третий запрос для подтверждения
echo -e "${BLUE}[7/6]${NC} Выполнение третьего запроса (подтверждение кеша)..."
THIRD_REQUEST_TIME=$(measure_time curl -s "${API_URL}${ENDPOINT}")
echo -e "   Время выполнения: $(format_time $THIRD_REQUEST_TIME)"
echo ""

# Расчет ускорения и среднего времени
SPEEDUP=$(awk "BEGIN {printf \"%.2f\", $FIRST_REQUEST_TIME / $SECOND_REQUEST_TIME}")
AVG_CACHED_TIME=$(awk "BEGIN {printf \"%.3f\", ($SECOND_REQUEST_TIME + $THIRD_REQUEST_TIME) / 2}")

# Итоговый отчет
echo -e "${BOLD}${CYAN}========================================${NC}"
echo -e "${BOLD}${CYAN}  Результаты тестирования${NC}"
echo -e "${BOLD}${CYAN}========================================${NC}"
echo ""
echo -e "${BOLD}Время выполнения запросов:${NC}"
echo -e "  Первый запрос (без кеша):  $(format_time $FIRST_REQUEST_TIME)"
echo -e "  Второй запрос (с кешем):   $(format_time $SECOND_REQUEST_TIME)"
echo -e "  Третий запрос (с кешем):   $(format_time $THIRD_REQUEST_TIME)"
echo ""
echo -e "${BOLD}Среднее время с кешем:${NC} $(format_time $AVG_CACHED_TIME)"
echo ""

# Проверка эффективности кеша
if awk "BEGIN {exit !($SPEEDUP > 10)}"; then
    echo -e "${BOLD}Ускорение:${NC} ${GREEN}${SPEEDUP}x${NC} ${GREEN}✓ Отлично!${NC}"
elif awk "BEGIN {exit !($SPEEDUP > 5)}"; then
    echo -e "${BOLD}Ускорение:${NC} ${YELLOW}${SPEEDUP}x${NC} ${YELLOW}⚠ Хорошо${NC}"
elif awk "BEGIN {exit !($SPEEDUP > 2)}"; then
    echo -e "${BOLD}Ускорение:${NC} ${YELLOW}${SPEEDUP}x${NC} ${YELLOW}⚠ Приемлемо${NC}"
else
    echo -e "${BOLD}Ускорение:${NC} ${RED}${SPEEDUP}x${NC} ${RED}✗ Кеш работает неэффективно${NC}"
fi
echo ""

# Проверка наличия ключей в Redis
FINAL_KEYS=$(docker exec "${REDIS_CONTAINER}" redis-cli DBSIZE 2>/dev/null | tail -1)
if [ "$FINAL_KEYS" -gt 0 ]; then
    echo -e "${BOLD}Статус Redis:${NC} ${GREEN}✓ Кеш активен (ключей: ${FINAL_KEYS})${NC}"
else
    echo -e "${BOLD}Статус Redis:${NC} ${RED}✗ Кеш не активен${NC}"
fi
echo ""

# Итоговая оценка
if awk "BEGIN {exit !($SPEEDUP > 10)}" && [ "$FINAL_KEYS" -gt 0 ]; then
    echo -e "${BOLD}${GREEN}✓ Кеширование работает отлично!${NC}"
    exit 0
elif awk "BEGIN {exit !($SPEEDUP > 2)}" && [ "$FINAL_KEYS" -gt 0 ]; then
    echo -e "${BOLD}${YELLOW}⚠ Кеширование работает, но можно улучшить${NC}"
    exit 0
else
    echo -e "${BOLD}${RED}✗ Кеширование работает некорректно${NC}"
    exit 1
fi
