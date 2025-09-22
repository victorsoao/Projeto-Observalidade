#!/bin/bash

echo "Starting Debian monitoring services..."

# Função para cleanup em caso de sinal
cleanup() {
    echo "Stopping services..."
    kill $NODE_EXPORTER_PID $OTEL_MONITOR_PID 2>/dev/null
    exit 0
}

# Capturar sinais para cleanup
trap cleanup SIGTERM SIGINT

# Iniciar Node Exporter em background
echo "Starting Node Exporter..."
/usr/local/bin/node_exporter \
    --web.listen-address=":9100" \
    --path.procfs=/proc \
    --path.sysfs=/sys \
    --collector.filesystem.mount-points-exclude="^/(dev|proc|sys|var/lib/docker/.+)($|/)" \
    --collector.textfile.directory=/var/lib/node_exporter/textfile_collector &

NODE_EXPORTER_PID=$!
echo "Node Exporter started with PID: $NODE_EXPORTER_PID"

# Aguardar um pouco para o Node Exporter inicializar
sleep 5

# Iniciar monitor OpenTelemetry em background
echo "Starting OpenTelemetry monitor..."
python3 /usr/local/bin/otel_monitor.py &
OTEL_MONITOR_PID=$!
echo "OpenTelemetry monitor started with PID: $OTEL_MONITOR_PID"

# Criar arquivo de status
echo "debian-service:healthy" > /tmp/service_status

# Manter script rodando
echo "Services started successfully. Container is ready."
echo "Debian system info:"
echo "- OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'=' -f2 | tr -d '\"')"
echo "- Kernel: $(uname -r)"
echo "- Architecture: $(uname -m)"
echo "- CPU cores: $(nproc)"
echo "- Total memory: $(free -h | awk '/^Mem:/ {print $2}')"

# Loop infinito para manter o container rodando
while true; do
    # Verificar se os processos ainda estão rodando
    if ! kill -0 $NODE_EXPORTER_PID 2>/dev/null; then
        echo "Node Exporter died, restarting..."
        /usr/local/bin/node_exporter \
            --web.listen-address=":9100" \
            --path.procfs=/proc \
            --path.sysfs=/sys \
            --collector.filesystem.mount-points-exclude="^/(dev|proc|sys|var/lib/docker/.+)($|/)" \
            --collector.textfile.directory=/var/lib/node_exporter/textfile_collector &
        NODE_EXPORTER_PID=$!
    fi
    
    if ! kill -0 $OTEL_MONITOR_PID 2>/dev/null; then
        echo "OpenTelemetry monitor died, restarting..."
        python3 /usr/local/bin/otel_monitor.py &
        OTEL_MONITOR_PID=$!
    fi
    
    sleep 30
done