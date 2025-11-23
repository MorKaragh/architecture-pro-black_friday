#!/bin/bash

# Не используем set -e, чтобы скрипт продолжал работу даже при некоторых ошибках
# (например, если replica set уже инициализирован)

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

# Функция для проверки, что replica set стал PRIMARY
wait_for_primary() {
    local host=$1
    local port=$2
    local max_attempts=30
    local attempt=0
    
    echo "Waiting for replica set at $host:$port to become PRIMARY..."
    while [ $attempt -lt $max_attempts ]; do
        # Проверяем статус replica set
        status=$(mongosh --host $host:$port --eval "try { rs.status().myState } catch(e) { 0 }" --quiet 2>/dev/null || echo "0")
        if [ "$status" = "1" ]; then
            echo "Replica set at $host:$port is PRIMARY!"
            return 0
        fi
        attempt=$((attempt + 1))
        if [ -z "$status" ] || [ "$status" = "0" ]; then
            echo "Attempt $attempt/$max_attempts: Replica set not initialized yet, waiting..."
        else
            echo "Attempt $attempt/$max_attempts: Replica set not PRIMARY yet (state: $status), waiting..."
        fi
        sleep 2
    done
    
    echo "Replica set at $host:$port failed to become PRIMARY after $max_attempts attempts"
    return 1
}

echo "Waiting for MongoDB services to be ready..."
wait_for_mongo mongodb-config 27019
wait_for_mongo mongodb-shard1 27018
wait_for_mongo mongodb-shard2 27018
# Не ждем mongos здесь - он запустится после инициализации replica sets

# Инициализация Config Server Replica Set
echo "Initializing Config Server Replica Set..."
mongosh --host mongodb-config:27019 <<EOF
try {
  var status = rs.status()
  print("Config Server replica set already initialized")
} catch (e) {
  if (e.message.includes("no replset config")) {
    print("Initializing Config Server replica set...")
    rs.initiate({
      _id: "configReplSet",
      configsvr: true,
      members: [
        { _id: 0, host: "mongodb-config:27019" }
      ]
    })
    print("Config Server replica set initiated, waiting to become PRIMARY...")
  } else {
    throw e
  }
}
EOF

# Ждем, пока config server станет PRIMARY
if wait_for_primary mongodb-config 27019; then
    echo "Config Server is PRIMARY and ready!"
else
    echo "Warning: Config Server may not be PRIMARY yet, but continuing..."
fi

# Инициализация Shard 1 Replica Set
echo "Initializing Shard 1 Replica Set..."
mongosh --host mongodb-shard1:27018 <<EOF
try {
  var status = rs.status()
  print("Shard 1 replica set already initialized")
} catch (e) {
  if (e.message.includes("no replset config")) {
    print("Initializing Shard 1 replica set...")
    rs.initiate({
      _id: "shard1ReplSet",
      members: [
        { _id: 0, host: "mongodb-shard1:27018" }
      ]
    })
    print("Shard 1 replica set initiated, waiting to become PRIMARY...")
  } else {
    throw e
  }
}
EOF

# Ждем, пока shard 1 станет PRIMARY
if wait_for_primary mongodb-shard1 27018; then
    echo "Shard 1 is PRIMARY and ready!"
else
    echo "Warning: Shard 1 may not be PRIMARY yet, but continuing..."
fi

# Инициализация Shard 2 Replica Set
echo "Initializing Shard 2 Replica Set..."
mongosh --host mongodb-shard2:27018 <<EOF
try {
  var status = rs.status()
  print("Shard 2 replica set already initialized")
} catch (e) {
  if (e.message.includes("no replset config")) {
    print("Initializing Shard 2 replica set...")
    rs.initiate({
      _id: "shard2ReplSet",
      members: [
        { _id: 0, host: "mongodb-shard2:27018" }
      ]
    })
    print("Shard 2 replica set initiated, waiting to become PRIMARY...")
  } else {
    throw e
  }
}
EOF

# Ждем, пока shard 2 станет PRIMARY
if wait_for_primary mongodb-shard2 27018; then
    echo "Shard 2 is PRIMARY and ready!"
else
    echo "Warning: Shard 2 may not be PRIMARY yet, but continuing..."
fi

# Теперь ждем, пока mongos запустится и подключится к config server
echo "Waiting for mongos to start and connect to config server..."
wait_for_mongo mongos 27017

# Дополнительное ожидание, чтобы mongos успел подключиться к config server
echo "Waiting for mongos to fully initialize connection to config server..."
max_attempts=30
attempt=0
while [ $attempt -lt $max_attempts ]; do
    if mongosh --host mongos:27017 --eval "sh.status()" --quiet > /dev/null 2>&1; then
        echo "Mongos is ready and connected to config server!"
        break
    fi
    attempt=$((attempt + 1))
    echo "Attempt $attempt/$max_attempts: Mongos not fully ready yet, waiting..."
    sleep 2
done

if [ $attempt -eq $max_attempts ]; then
    echo "Warning: Mongos may not be fully ready, but continuing..."
fi

# Добавление шардов в кластер через mongos
echo "Adding shards to cluster via mongos..."
mongosh --host mongos:27017 <<EOF
// Проверяем, что mongos работает
try {
  sh.status()
} catch (e) {
  print("Error connecting to mongos: " + e.message)
  throw e
}

// Добавляем шарды
try {
  sh.addShard("shard1ReplSet/mongodb-shard1:27018")
  print("Shard 1 added successfully")
} catch (e) {
  if (e.message.includes("already exists") || e.message.includes("already been added")) {
    print("Shard 1 already added")
  } else {
    print("Error adding shard 1: " + e.message)
    throw e
  }
}

try {
  sh.addShard("shard2ReplSet/mongodb-shard2:27018")
  print("Shard 2 added successfully")
} catch (e) {
  if (e.message.includes("already exists") || e.message.includes("already been added")) {
    print("Shard 2 already added")
  } else {
    print("Error adding shard 2: " + e.message)
    throw e
  }
}

// Включаем шардирование для базы данных
try {
  sh.enableSharding("somedb")
  print("Sharding enabled for database 'somedb'")
} catch (e) {
  if (e.message.includes("already enabled")) {
    print("Sharding already enabled for database 'somedb'")
  } else {
    print("Error enabling sharding: " + e.message)
    throw e
  }
}

// Создаем индекс для шардирования коллекции по полю _id (hashed sharding)
// Это равномерно распределит данные между шардами
try {
  sh.shardCollection("somedb.helloDoc", { "_id": "hashed" })
  print("Collection 'helloDoc' sharded successfully")
} catch (e) {
  if (e.message.includes("already sharded")) {
    print("Collection 'helloDoc' already sharded")
  } else {
    print("Error sharding collection: " + e.message)
    throw e
  }
}

print("Sharding configuration completed!")
EOF

echo "Sharding initialization completed successfully!"

