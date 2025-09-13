# Configurações básicas do Spark
SPARK_HOME=/opt/spark
SPARK_CONF_DIR=/opt/spark/conf

# Configuração do mestre Spark
#SPARK_MASTER_HOST=spark-iceberg
SPARK_MASTER_HOST=spark-master
SPARK_MASTER_PORT=7077

# Configurações para integração com MinIO (opcional, já definidas no script)
export AWS_ACCESS_KEY_ID=${S3_ACCESS_KEY}
export AWS_SECRET_ACCESS_KEY=${S3_SECRET_KEY}
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1

# Configuração do Hadoop (ajuste conforme necessário)
HADOOP_CONF_DIR=/opt/spark/conf

# Opcional: Configurações de logging e desempenho
SPARK_WORKER_MEMORY=2g
SPARK_WORKER_CORES=2
SPARK_LOG_DIR=/opt/spark/logs