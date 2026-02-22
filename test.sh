#!/bin/bash

# =============================================================================
# Reranker Service - Test Script
# =============================================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "Testing Reranker Service..."
echo "========================================================================"

# Test 1: Health Check
echo -n "Test 1: Health Check... "
HEALTH=$(curl -sf http://localhost:8100/health)
if [ $? -eq 0 ]; then
    echo -e "${GREEN}PASS${NC}"
    echo "$HEALTH" | python3 -m json.tool
else
    echo -e "${RED}FAIL${NC}"
    exit 1
fi

echo ""

# Test 2: Rerank Endpoint
echo -n "Test 2: Rerank Endpoint... "
RERANK_RESPONSE=$(curl -sf -X POST http://localhost:8100/rerank \
    -H "Content-Type: application/json" \
    -d '{
        "query": "مالیات بر درآمد چیست؟",
        "documents": [
            {"text": "مالیات بر درآمد نوعی مالیات است که از درآمد افراد و شرکت‌ها اخذ می‌شود.", "score": 0.8},
            {"text": "قانون مالیات‌های مستقیم در ایران تعریف می‌کند.", "score": 0.7},
            {"text": "بیمه تامین اجتماعی برای کارگران است.", "score": 0.3}
        ],
        "top_k": 3
    }')

if [ $? -eq 0 ]; then
    echo -e "${GREEN}PASS${NC}"
    echo "$RERANK_RESPONSE" | python3 -m json.tool
else
    echo -e "${RED}FAIL${NC}"
    exit 1
fi

echo ""
echo "========================================================================"
echo -e "${GREEN}All tests passed!${NC}"
