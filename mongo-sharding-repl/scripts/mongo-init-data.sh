#!/bin/bash

###
# Инициализируем бд данными через mongos
###

# Функция для проверки готовности MongoDB
wait_for_mongo() {
    local host=$1
    local port=$2
    local max_attempts=30
    local attempt=0
    
    echo "Waiting for MongoDB at $host:$port to be ready..."
    while [ $attempt -lt $max_attempts ]; do
        if mongosh --host $host:$port --eval "db.adminCommand('ping')" --quiet > /dev/null 2>&1; then
            echo "MongoDB at $host:$port is ready!"
            return 0
        fi
        attempt=$((attempt + 1))
        echo "Attempt $attempt/$max_attempts: MongoDB not ready yet, waiting..."
        sleep 2
    done
    
    echo "MongoDB at $host:$port failed to become ready"
    return 1
}

# Ждем готовности mongos
if ! wait_for_mongo "mongos" "27017"; then
    echo "Failed to connect to mongos, exiting..."
    exit 1
fi

# Функция для проверки, что шарды добавлены в кластер
wait_for_shards() {
    local max_attempts=60
    local attempt=0
    
    echo "Waiting for shards to be added to cluster..."
    while [ $attempt -lt $max_attempts ]; do
        # Проверяем количество шардов
        shard_count=$(mongosh --host mongos:27017 --eval "db.adminCommand('listShards').shards.length" --quiet 2>/dev/null || echo "0")
        
        if [ "$shard_count" -ge "2" ]; then
            echo "Shards are ready! Found $shard_count shards."
            # Даем еще немного времени на завершение инициализации шардирования
            echo "Waiting a bit more for sharding initialization to complete..."
            sleep 5
            return 0
        fi
        attempt=$((attempt + 1))
        echo "Attempt $attempt/$max_attempts: Shards not ready yet (found $shard_count), waiting..."
        sleep 2
    done
    
    echo "Failed to wait for shards to be added"
    return 1
}

# Ждем, пока шарды будут добавлены
if ! wait_for_shards; then
    echo "Failed to wait for shards, exiting..."
    exit 1
fi

echo "Initializing database with test data..."

# Вставляем данные через mongos
mongosh --host mongos:27017 <<'MONGO_SCRIPT'
use somedb

// Проверяем, есть ли уже данные в коллекции
var existingCount = db.helloDoc.countDocuments();
if (existingCount > 0) {
    print("Collection already contains " + existingCount + " documents. Clearing it first...");
    db.helloDoc.deleteMany({});
    print("Collection cleared.");
}

// Вставляем данные
print("Inserting 1000 documents...");
for(var i = 0; i < 1000; i++) {
    db.helloDoc.insertOne({age:i, name:"ly"+i});
}
print("Inserted 1000 documents into helloDoc collection");
print("Total documents in collection: " + db.helloDoc.countDocuments());
MONGO_SCRIPT

if [ $? -eq 0 ]; then
    echo "Database initialization completed successfully!"
else
    echo "Database initialization failed!"
    exit 1
fi
