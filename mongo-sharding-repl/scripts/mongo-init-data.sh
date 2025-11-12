#!/bin/bash

###
# Инициализируем бд данными через mongos
###

# Этот скрипт должен запускаться из корневой директории проекта
# или с указанием правильного пути к compose.yaml
docker compose -f compose.yaml exec -T mongos mongosh <<EOF
use somedb
for(var i = 0; i < 1000; i++) db.helloDoc.insertOne({age:i, name:"ly"+i})
EOF

