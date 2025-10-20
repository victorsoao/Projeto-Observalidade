#!/bin/bash

# ===============================================
# CONFIGURAÇÃO DE ALERTA (AJUSTADO)
# ===============================================
# 1. Alerta Discord (Webhook REAL)
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/1422602417911894197/-WIVgGuvVJ3YnluYWjAufZnyJVxtOXgzxln1sJ_8g9hTFCIrqIsHIulkeoYkBFMfeFIv"

# 2. Alerta Email (Configuração REAL - Usado apenas se ativado)
RECIPIENT_EMAIL="EMAIL"

# ===============================================

echo "Starting Ubuntu monitoring services..."

# Variável de ambiente do Docker Compose (ubuntu-service)
SERVICE_NAME="${OTEL_SERVICE_NAME}"
HOSTNAME_VAL="$(hostname)"

# Função para enviar alerta para o Discord
discord_alert() {
    JSON_PAYLOAD=$(cat <<EOF
{
  "username": "Monitoramento Crítico Docker",
  "embeds": [
    {
      "title": "🔴 FALHA CRÍTICA - Contêiner Morreu! 🔴",
      "description": "O contêiner **${SERVICE_NAME}** parou de funcionar completamente. A auto-remediação FALHOU.",
      "color": 16711680,
      "fields": [
        {"name": "Container", "value": "${SERVICE_NAME}", "inline": true},
        {"name": "Status", "value": "Exited/Dead", "inline": true},
        {"name": "Ação", "value": "O loop de manutenção foi encerrado ou o Docker recebeu um sinal de parada.", "inline": false},
        {"name": "Hostname", "value": "${HOSTNAME_VAL}", "inline": false}
      ]
    }
  ]
}
EOF
)
    curl -H "Content-Type: application/json" -X POST -d "$JSON_PAYLOAD" "$DISCORD_WEBHOOK_URL"
}

# Função para enviar alerta por e-mail
send_email_alert() {
    SUBJECT="ALERTA CRÍTICO: Container ${SERVICE_NAME} PAROU"
    BODY="O container ${SERVICE_NAME} no host ${HOSTNAME_VAL} parou de funcionar e a auto-remediação falhou ou o Docker enviou um comando de parada."
    echo "$BODY" | mail -s "$SUBJECT" "$RECIPIENT_EMAIL"
}

# Função para cleanup em caso de sinal (SIGTERM, SIGINT) - AGORA COM ALERTA
cleanup() {
    echo "Stopping services and sending critical alert..."
    
    # Envia o alerta ANTES de matar os processos e sair
    discord_alert
    # send_email_alert # Descomente para enviar e-mail
    
    # Mata os processos em background
    kill $NODE_EXPORTER_PID $OTEL_MONITOR_PID 2>/dev/null
    
    # Sai do script
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
echo "ubuntu-service:healthy" > /tmp/service_status

# Manter script rodando
echo "Services started successfully. Container is ready."
echo "Ubuntu system info:"
echo "- OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'=' -f2 | tr -d '\"') " 
echo "- Kernel: $(uname -r)"
echo "- Architecture: $(uname -m)"
echo "- CPU cores: $(nproc)"
echo "- Total memory: $(free -h | awk '/^Mem:/ {print $2}')"

# Loop infinito para manter o container rodando
while true; do
    # [1] Verificar e reiniciar NODE EXPORTER
    if ! kill -0 $NODE_EXPORTER_PID 2>/dev/null; then
        echo "Node Exporter died, attempting restart..."
        /usr/local/bin/node_exporter \
            --web.listen-address=":9100" \
            --path.procfs=/proc \
            --path.sysfs=/sys \
            --collector.filesystem.mount-points-exclude="^/(dev|proc|sys|var/lib/docker/.+)($|/)" \
            --collector.textfile.directory=/var/lib/node_exporter/textfile_collector &
        NODE_EXPORTER_PID=$!
    fi
    
    # [2] Verificar e reiniciar OTEL MONITOR
    if ! kill -0 $OTEL_MONITOR_PID 2>/dev/null; then
        echo "OpenTelemetry monitor died, attempting restart..."
        python3 /usr/local/bin/otel_monitor.py &
        OTEL_MONITOR_PID=$!
    fi
    
    sleep 30
    
done

# REMOVIDO: O bloco de alerta final foi movido para a função cleanup()

# O script nunca deve chegar aqui, mas se chegar, ele envia o alerta e sai com erro.
# Para manter a lógica de falha no loop, garantimos que o alerta seja disparado.
discord_alert 
# send_email_alert 
exit 1