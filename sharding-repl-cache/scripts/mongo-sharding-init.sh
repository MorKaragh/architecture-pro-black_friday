#!/bin/bash
set -e

echo "=== Starting MongoDB Sharding Initialization ==="

# Функция для ожидания готовности MongoDB (не только ping, но и выполнение команд)
wait_for_mongo_ready() {
    local host=$1
    local port=$2
    local counter=0
    local max_attempts=60
    
    echo "[INFO] Waiting for MongoDB to be fully ready at $host:$port..."
    
    while ! mongosh --host $host --port $port --eval "
    try {
        // Проверяем что можем выполнять команды, а не только ping
        const adminDb = db.getSiblingDB('admin');
        const result = adminDb.runCommand({serverStatus: 1});
        if (result.ok === 1) {
            quit(0);
        } else {
            quit(1);
        }
    } catch (e) {
        quit(1);
    }
    " --quiet > /dev/null 2>&1; do
        counter=$((counter + 1))
        if [ $counter -ge $max_attempts ]; then
            echo "[ERROR] MongoDB at $host:$port is not fully ready after $max_attempts attempts"
            exit 1
        fi
        echo "[DEBUG] Waiting for MongoDB at $host:$port to accept commands... ($counter/$max_attempts)"
        sleep 2
    done
    echo "[SUCCESS] MongoDB at $host:$port is fully ready"
}

# Функция для ожидания готовности replica set (есть primary)
wait_for_replica_set_ready() {
    local host=$1
    local port=$2
    local replset_name=$3
    local counter=0
    local max_attempts=50
    
    echo "[INFO] Waiting for replica set '$replset_name' to have primary at $host:$port..."
    
    while ! mongosh --host $host --port $port --eval "
    try {
        const status = rs.status();
        if (status.ok === 1) {
            const hasPrimary = status.members.some(m => m.state === 1);
            const healthyMembers = status.members.filter(m => m.health === 1).length;
            const totalMembers = status.members.length;
            
            if (hasPrimary && healthyMembers >= Math.floor(totalMembers/2) + 1) {
                console.log('Replica set ready: Primary elected and', healthyMembers, 'of', totalMembers, 'members healthy');
                quit(0);
            } else {
                console.log('Replica set not ready: Primary:', hasPrimary, 'Healthy members:', healthyMembers, '/', totalMembers);
                quit(1);
            }
        } else {
            console.log('Replica set status not ok');
            quit(1);
        }
    } catch (e) {
        console.log('Error checking replica set:', e.message);
        quit(1);
    }
    " --quiet > /dev/null 2>&1; do
        counter=$((counter + 1))
        if [ $counter -ge $max_attempts ]; then
            echo "[ERROR] Replica set '$replset_name' at $host:$port has no primary after $max_attempts attempts"
            exit 1
        fi
        echo "[DEBUG] Waiting for primary in '$replset_name' at $host:$port... ($counter/$max_attempts)"
        sleep 3
    done
    echo "[SUCCESS] Replica set '$replset_name' at $host:$port has primary and is ready"
}

# Функция для инициализации replica set с проверками
init_replica_set() {
    local host=$1
    local port=$2
    local config=$3
    local replset_name=$4
    
    echo "[INFO] Initializing replica set '$replset_name' at $host:$port..."
    
    mongosh --host $host --port $port --eval "
    try {
        // Проверяем, не инициализирован ли уже replica set
        const status = rs.status();
        console.log('Replica set already initialized with status:', status.ok);
        quit(0);
    } catch (e) {
        if (e.codeName === 'NotYetInitialized') {
            console.log('Initializing new replica set...');
            const result = rs.initiate($config);
            if (result.ok === 1) {
                console.log('Replica set initiation started successfully');
                quit(0);
            } else {
                console.log('Failed to initiate replica set:', result);
                quit(1);
            }
        } else {
            console.log('Unexpected error:', e.message);
            quit(1);
        }
    }
    " --quiet
    
    if [ $? -eq 0 ]; then
        echo "[SUCCESS] Replica set '$replset_name' initiation command sent successfully"
    else
        echo "[ERROR] Failed to initiate replica set '$replset_name'"
        exit 1
    fi
}

# Ожидаем готовности всех узлов (умное ожидание)
echo "=== Phase 1: Waiting for all MongoDB nodes to be fully ready ==="
wait_for_mongo_ready mongodb-config1 27019
wait_for_mongo_ready mongodb-config2 27019
wait_for_mongo_ready mongodb-config3 27019
wait_for_mongo_ready mongodb-shard1-node1 27018
wait_for_mongo_ready mongodb-shard1-node2 27018
wait_for_mongo_ready mongodb-shard1-node3 27018
wait_for_mongo_ready mongodb-shard2-node1 27018
wait_for_mongo_ready mongodb-shard2-node2 27018
wait_for_mongo_ready mongodb-shard2-node3 27018

# Инициализация Config Server Replica Set
echo "=== Phase 2: Initializing Config Server Replica Set ==="
init_replica_set mongodb-config1 27019 '{
  _id: "configReplSet",
  configsvr: true,
  members: [
    { _id: 0, host: "mongodb-config1:27019" },
    { _id: 1, host: "mongodb-config2:27019" },
    { _id: 2, host: "mongodb-config3:27019" }
  ]
}' "configReplSet"

# Ждем пока config replica set будет готов
wait_for_replica_set_ready mongodb-config1 27019 "configReplSet"

# Инициализация Shard 1 Replica Set
echo "=== Phase 3: Initializing Shard 1 Replica Set ==="
init_replica_set mongodb-shard1-node1 27018 '{
  _id: "shard1ReplSet",
  members: [
    { _id: 0, host: "mongodb-shard1-node1:27018" },
    { _id: 1, host: "mongodb-shard1-node2:27018" },
    { _id: 2, host: "mongodb-shard1-node3:27018" }
  ]
}' "shard1ReplSet"

# Ждем пока shard1 replica set будет готов
wait_for_replica_set_ready mongodb-shard1-node1 27018 "shard1ReplSet"

# Инициализация Shard 2 Replica Set
echo "=== Phase 4: Initializing Shard 2 Replica Set ==="
init_replica_set mongodb-shard2-node1 27018 '{
  _id: "shard2ReplSet",
  members: [
    { _id: 0, host: "mongodb-shard2-node1:27018" },
    { _id: 1, host: "mongodb-shard2-node2:27018" },
    { _id: 2, host: "mongodb-shard2-node3:27018" }
  ]
}' "shard2ReplSet"

# Ждем пока shard2 replica set будет готов
wait_for_replica_set_ready mongodb-shard2-node1 27018 "shard2ReplSet"

# Ждем пока mongos будет готов
echo "=== Phase 5: Waiting for mongos to be ready ==="
wait_for_mongo_ready mongos 27017

# Добавление шардов в кластер через mongos
echo "=== Phase 6: Adding shards to cluster via mongos ==="
mongosh --host mongos:27017 --eval "
console.log('Starting shard configuration...');

function addShardWithRetry(shardString, shardName) {
    let attempts = 0;
    const maxAttempts = 10;
    
    while (attempts < maxAttempts) {
        try {
            console.log('Attempting to add shard:', shardName, 'Attempt:', attempts + 1);
            const result = sh.addShard(shardString);
            
            if (result.ok === 1) {
                console.log('Successfully added shard:', shardName);
                return true;
            } else {
                console.log('Failed to add shard:', shardName, 'Result:', result);
            }
        } catch (e) {
            if (e.codeName === 'AlreadyInitialized' || e.message.includes('already exists')) {
                console.log('Shard already added:', shardName);
                return true;
            }
            console.log('Error adding shard:', shardName, 'Error:', e.message);
        }
        
        attempts++;
        if (attempts < maxAttempts) {
            console.log('Retrying in 5 seconds...');
            sleep(5000);
        }
    }
    
    console.log('Failed to add shard after', maxAttempts, 'attempts:', shardName);
    return false;
}

// Добавляем шарды с ретраями
const shard1Success = addShardWithRetry('shard1ReplSet/mongodb-shard1-node1:27018,mongodb-shard1-node2:27018,mongodb-shard1-node3:27018', 'shard1ReplSet');
const shard2Success = addShardWithRetry('shard2ReplSet/mongodb-shard2-node1:27018,mongodb-shard2-node2:27018,mongodb-shard2-node3:27018', 'shard2ReplSet');

if (shard1Success && shard2Success) {
    console.log('All shards added successfully!');
    console.log('Final sharding status:');
    sh.status();
} else {
    console.log('Failed to add some shards');
    console.log('Current sharding status:');
    sh.status();
    quit(1);
}
"

echo "=== Phase 7: Enabling sharding for database ==="

# Включение шардинга для базы
mongosh --host mongos:27017 --eval "
console.log('Enabling sharding for database somedb...');
sh.enableSharding('somedb');
console.log('Successfully enabled sharding for somedb');
"

# Создание коллекции и индекса
mongosh --host mongos:27017 --eval "
console.log('Creating collection and index...');
db = db.getSiblingDB('somedb');
db.createCollection('helloDoc');
db.helloDoc.createIndex({ '_id': 'hashed' });
console.log('Collection and index created');
"

# Шардирование коллекции
mongosh --host mongos:27017 --eval "
console.log('Sharding collection...');
sh.shardCollection('somedb.helloDoc', { '_id': 'hashed' });
console.log('Collection sharded successfully');
"

# Финальный статус
mongosh --host mongos:27017 --eval "
console.log('Final sharding configuration:');
sh.status();
console.log('=== SHARDING INITIALIZATION COMPLETED SUCCESSFULLY ===');
"

echo "[SUCCESS] MongoDB sharding cluster initialization completed!"
echo "[INFO] Cluster is ready for use"