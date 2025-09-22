#!/usr/bin/env python3
"""
Script de monitoramento OpenTelemetry para containers Linux
Coleta métricas do sistema e envia para o OpenTelemetry Collector
"""

import os
import time
import psutil
import logging
import platform
from opentelemetry import trace
from opentelemetry import metrics
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.semconv.resource import ResourceAttributes

# Configurar logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class SystemMonitor:
    def __init__(self):
        # Configurar resource attributes
        service_name = os.getenv('OTEL_SERVICE_NAME', 'unknown-service')
        service_version = os.getenv('OTEL_SERVICE_VERSION', '1.0.0')
        
        self.resource = Resource.create({
            ResourceAttributes.SERVICE_NAME: service_name,
            ResourceAttributes.SERVICE_VERSION: service_version,
            ResourceAttributes.HOST_NAME: platform.node(),
            ResourceAttributes.OS_NAME: platform.system(),
            ResourceAttributes.OS_VERSION: platform.release(),
            "container.name": os.getenv('HOSTNAME', 'unknown'),
            "deployment.environment": os.getenv('DEPLOYMENT_ENVIRONMENT', 'production')
        })
        
        # Configurar exporters
        otlp_endpoint = os.getenv('OTEL_EXPORTER_OTLP_ENDPOINT', 'http://otel-collector:4318')
        
        # Configurar trace provider
        trace.set_tracer_provider(TracerProvider(resource=self.resource))
        tracer = trace.get_tracer(__name__)
        
        span_exporter = OTLPSpanExporter(endpoint=f"{otlp_endpoint}/v1/traces")
        span_processor = BatchSpanProcessor(span_exporter)
        trace.get_tracer_provider().add_span_processor(span_processor)
        
        # Configurar metrics provider
        metric_exporter = OTLPMetricExporter(endpoint=f"{otlp_endpoint}/v1/metrics")
        metric_reader = PeriodicExportingMetricReader(
            exporter=metric_exporter,
            export_interval_millis=10000  # 10 segundos
        )
        
        metrics.set_meter_provider(MeterProvider(
            resource=self.resource,
            metric_readers=[metric_reader]
        ))
        
        # Criar meter e instrumentos de medição
        self.meter = metrics.get_meter(__name__)
        
        # Criar instrumentos de métricas
        self.cpu_usage_gauge = self.meter.create_gauge(
            name="system_cpu_usage_percent",
            description="Current CPU usage percentage",
            unit="%"
        )
        
        self.memory_usage_gauge = self.meter.create_gauge(
            name="system_memory_usage_bytes",
            description="Current memory usage in bytes",
            unit="bytes"
        )
        
        self.memory_usage_percent_gauge = self.meter.create_gauge(
            name="system_memory_usage_percent",
            description="Current memory usage percentage",
            unit="%"
        )
        
        self.disk_usage_gauge = self.meter.create_gauge(
            name="system_disk_usage_percent",
            description="Current disk usage percentage",
            unit="%"
        )
        
        self.network_bytes_sent_counter = self.meter.create_counter(
            name="system_network_bytes_sent_total",
            description="Total bytes sent over network",
            unit="bytes"
        )
        
        self.network_bytes_recv_counter = self.meter.create_counter(
            name="system_network_bytes_received_total",
            description="Total bytes received over network",
            unit="bytes"
        )
        
        self.process_count_gauge = self.meter.create_gauge(
            name="system_process_count",
            description="Number of running processes"
        )
        
        self.load_average_gauge = self.meter.create_gauge(
            name="system_load_average_1m",
            description="System load average over 1 minute"
        )
        
        # Armazenar valores anteriores para cálculos de delta
        self.previous_network = self.get_network_stats()
        
        logger.info(f"SystemMonitor initialized for service: {service_name}")
        logger.info(f"OTLP endpoint: {otlp_endpoint}")

    def get_network_stats(self):
        """Obter estatísticas de rede"""
        net_io = psutil.net_io_counters()
        return {
            'bytes_sent': net_io.bytes_sent,
            'bytes_recv': net_io.bytes_recv
        }

    def collect_metrics(self):
        """Coletar e enviar métricas do sistema"""
        try:
            # CPU Usage
            cpu_percent = psutil.cpu_percent(interval=1)
            self.cpu_usage_gauge.set(cpu_percent)
            
            # Memory Usage
            memory = psutil.virtual_memory()
            self.memory_usage_gauge.set(memory.used)
            self.memory_usage_percent_gauge.set(memory.percent)
            
            # Disk Usage (root filesystem)
            disk = psutil.disk_usage('/')
            disk_percent = (disk.used / disk.total) * 100
            self.disk_usage_gauge.set(disk_percent)
            
            # Network Stats
            current_network = self.get_network_stats()
            bytes_sent_delta = current_network['bytes_sent'] - self.previous_network['bytes_sent']
            bytes_recv_delta = current_network['bytes_recv'] - self.previous_network['bytes_recv']
            
            if bytes_sent_delta > 0:
                self.network_bytes_sent_counter.add(bytes_sent_delta)
            if bytes_recv_delta > 0:
                self.network_bytes_recv_counter.add(bytes_recv_delta)
                
            self.previous_network = current_network
            
            # Process Count
            process_count = len(psutil.pids())
            self.process_count_gauge.set(process_count)
            
            # Load Average (apenas em sistemas Unix)
            try:
                load_avg = os.getloadavg()[0]  # 1 minute load average
                self.load_average_gauge.set(load_avg)
            except (OSError, AttributeError):
                # Windows não suporta getloadavg
                pass
            
            logger.info(f"Metrics collected - CPU: {cpu_percent:.1f}%, Memory: {memory.percent:.1f}%, Disk: {disk_percent:.1f}%")
            
        except Exception as e:
            logger.error(f"Error collecting metrics: {e}")

    def create_trace_span(self):
        """Criar um span de exemplo para traces"""
        tracer = trace.get_tracer(__name__)
        
        with tracer.start_as_current_span("system_health_check") as span:
            span.set_attribute("service.name", os.getenv('OTEL_SERVICE_NAME', 'unknown-service'))
            span.set_attribute("host.name", platform.node())
            
            # Simular algum trabalho
            time.sleep(0.1)
            
            # Adicionar eventos ao span
            span.add_event("Health check completed", {
                "cpu_count": psutil.cpu_count(),
                "total_memory": psutil.virtual_memory().total
            })

    def run(self):
        """Executar loop principal de monitoramento"""
        logger.info("Starting system monitoring...")
        
        try:
            while True:
                # Coletar métricas
                self.collect_metrics()
                
                # Criar trace ocasionalmente (a cada 5 iterações)
                if time.time() % 50 < 10:  # aproximadamente a cada 50 segundos
                    self.create_trace_span()
                
                # Aguardar antes da próxima coleta
                time.sleep(10)  # 10 segundos
                
        except KeyboardInterrupt:
            logger.info("Monitoring stopped by user")
        except Exception as e:
            logger.error(f"Monitoring error: {e}")

def main():
    """Função principal"""
    monitor = SystemMonitor()
    monitor.run()

if __name__ == "__main__":
    main()