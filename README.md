# Workspace Unimed: Data Lakehouse com Apache Iceberg

## Visão Geral

Este workspace implementa um **data lakehouse** moderno utilizando **Apache Iceberg** para gerenciamento de tabelas analíticas, integrado com **MinIO** (storage S3-compatível), **PostgreSQL** (banco operacional), **Spark** (processamento ETL), **Hive Metastore** (catálogo de metadados), **Trino** (query engine) e **Grafana** (observabilidade). O foco é em um pipeline de dados para dados de clientes e vendas da Unimed, com camadas **Bronze**, **Silver** e **Gold**.

O ambiente é orquestrado via **Docker Compose**, permitindo setup local rápido. A arquitetura segue o padrão **Medallion** (ingestão → refinamento → consumo).

### Arquitetura de Alto Nível

- **Fontes de Dados**: PostgreSQL (dados operacionais).
- **Ingestion**: Upload de CSVs para MinIO (bucket `ingestion`).
- **Camadas Iceberg** (armazenadas em `s3a://datalake/iceberg` no MinIO):
  - **Bronze**: Dados raw/particionados por data de criação.
  - **Silver**: Dados limpos/dedupicados, particionados por data.
  - **Gold**: Tabelas dimensionais/fat (dim_clientes, fato_vendas), particionadas por ano/mês.
- **Query**: Trino para consultas SQL federadas.
- **Processamento**: Spark + Jupyter Notebooks.
- **Observabilidade**: Grafana com Promtail para logs.
- **Orquestração**: Airflow (futuro, via DAGs).

![Arquitetura](https://via.placeholder.com/800x400?text=Data+Lakehouse+Architecture)  
*(Diagrama conceitual: PostgreSQL → Ingestion → Bronze → Silver → Gold → Trino/Grafana)*

## Pré-requisitos

- Docker & Docker Compose v2+.
- Python 3.10+ com `pip install faker psycopg2 tqdm python-dotenv boto3 pyspark`.
- Hardware: Mínimo 8GB RAM (para Spark Master/Worker).
- Variáveis de ambiente (`.env` em cada pasta):
  ```
  S3_ACCESS_KEY=minioadmin
  S3_SECRET_KEY=minioadmin
  S3_ENDPOINT=http://localhost:9000
  MINIO_DOMAIN=localhost
  HIVE_METASTORE_JDBC_URL=jdbc:postgresql://postgres:5432/hive
  HIVE_METASTORE_WAREHOUSE_DIR=s3a://datalake/warehouse
  AWS_ACCESS_KEY_ID=minioadmin
  AWS_SECRET_ACCESS_KEY=minioadmin
  AWS_REGION=us-east-1
  AWS_DEFAULT_REGION=us-east-1
  ```
  Ajuste conforme necessário.

## Setup e Inicialização

### 1. Subir PostgreSQL
Navegue para `postgres/` e execute:

```bash
docker compose up -d
```

**docker-compose.yml** (resumido):
```yaml
version: "3.9"
services:
  postgres:
    image: postgres:14
    container_name: postgres
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres  # Altere para produção
    ports:
      - "5434:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - iceber-net

volumes:
  postgres_data:

networks:
  iceber-net:
    driver: bridge
```

- Acesse: `psql -h localhost -p 5434 -U postgres`.
- Execute `init-database.sh` para criar DB `postgres` e tabelas (se aplicável).

### 2. Subir MinIO
Navegue para `minio/` e execute:

```bash
docker compose up -d
```

**docker-compose.yml** (resumido):
```yaml
version: "3.9"
services:
  minio:
    container_name: minio
    hostname: minio
    image: minio/minio
    ports:
      - '9000:9000'  # API
      - '9001:9001'  # Console
    volumes:
      - ./data:/data
    environment:
      MINIO_ROOT_USER: ${S3_ACCESS_KEY}
      MINIO_ROOT_PASSWORD: ${S3_SECRET_KEY}
      MINIO_DOMAIN: ${MINIO_DOMAIN}
    command: server /data --console-address ":9001"
    networks:
      - iceber-net

  minio-job:
    image: minio/mc
    container_name: minio-job
    depends_on: [minio]
    entrypoint: /bin/bash -c "sleep 5; mc config host add myminio http://minio:9000 $S3_ACCESS_KEY $S3_SECRET_KEY; mc mb myminio/datalake;"
    networks:
      - iceber-net

networks:
  iceber-net:
    external: true
```

- Acesse Console: http://localhost:9001 (user: `minioadmin`, pass: `minioadmin`).
- Buckets criados: `datalake`, `ingestion`.

### 3. Subir Processing (Spark + Hive + Trino)
Navegue para `processing/` e execute:

```bash
docker compose up -d --build
```

**docker-compose.yml** (resumido, corrigido para YAML válido):
```yaml
version: "3.9"
services:
  hive-metastore:
    container_name: hive-metastore
    hostname: hive-metastore
    build: {context: ./hive-metastore, dockerfile: Dockerfile}
    image: dataincode/openlakehouse:hive-metastore-3.1.2
    ports: ["9083:9083"]
    environment:
      HIVE_METASTORE_DRIVER: org.postgresql.Driver
      HIVE_METASTORE_JDBC_URL: ${HIVE_METASTORE_JDBC_URL}
      HIVE_METASTORE_USER: hive
      HIVE_METASTORE_PASSWORD: hive
      HIVE_METASTORE_WAREHOUSE_DIR: ${HIVE_METASTORE_WAREHOUSE_DIR}
      S3_ENDPOINT: ${S3_ENDPOINT}
      S3_ACCESS_KEY: ${S3_ACCESS_KEY}
      S3_SECRET_KEY: ${S3_SECRET_KEY}
      S3_PATH_STYLE_ACCESS: "true"
    networks: [iceber-net]
    depends_on: [postgres]  # Adicione se necessário

  spark-master:
    build: {context: ./spark, dockerfile: Dockerfile-spark3.5}
    image: dataincode/openlakehouse:spark-3.5-master
    container_name: spark-master
    hostname: spark-master
    ports:
      - "4040:4040"  # Spark UI
      - "7077:7077"  # Master
      - "8082:8080"  # Master Web
      - "8900:8888"  # Jupyter
    entrypoint: /bin/bash -c "/opt/spark/sbin/start-master.sh && jupyter lab --notebook-dir=/opt/notebook --ip='*' --NotebookApp.token='' --NotebookApp.password='' --port=8888 --no-browser --allow-root"
    environment:
      SPARK_MODE: master
      SPARK_MASTER_MEMORY: 4g
      AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY: ${S3_SECRET_KEY}
      AWS_REGION: ${AWS_REGION}
      AWS_DEFAULT_REGION: ${AWS_DEFAULT_REGION}
      S3_ENDPOINT: ${S3_ENDPOINT}
      S3_PATH_STYLE_ACCESS: "true"
    volumes:
      - ./notebook:/opt/notebook
      - ./spark/spark-defaults-iceberg.conf:/opt/spark/conf/spark-defaults.conf
      - ./spark/spark-env.sh:/opt/spark/conf/spark-env.sh
    networks: [iceber-net]
    depends_on: [hive-metastore]

  spark-worker:
    build: {context: ./spark, dockerfile: Dockerfile-spark3.5}
    image: dataincode/openlakehouse:spark-3.5-worker
    container_name: spark-worker
    hostname: spark-worker
    entrypoint: /bin/bash -c "/opt/spark/bin/spark-class org.apache.spark.deploy.worker.Worker spark://spark-master:7077"
    environment:
      SPARK_MODE: worker
      SPARK_WORKER_MEMORY: 2g
      SPARK_WORKER_CORES: 2
      # ... (mesmas envs do master)
    volumes:  # ... (mesmos volumes)
    networks: [iceber-net]
    depends_on: [spark-master, hive-metastore]

  trino:
    container_name: trino
    hostname: trino
    image: trinodb/trino:425
    ports: ["8889:8080"]
    volumes:
      - ./trino/etc-coordinator:/etc/trino
      - ./trino/catalog:/etc/trino/catalog
    depends_on: [hive-metastore]
    networks: [iceber-net]

  trino-worker:  # Opcional, para escalabilidade
    container_name: trino-worker
    hostname: trino-worker
    image: trinodb/trino:425
    volumes:  # ... (sem ports)
    depends_on: [trino]
    networks: [iceber-net]

networks:
  iceber-net:
    external: true
```

- **Hive Metastore**: Porta 9083, usa PostgreSQL backend.
- **Spark**: Master em http://localhost:8082, Jupyter em http://localhost:8900.
- **Trino**: Web UI em http://localhost:8889. Catálogos: `hive` e `iceberg` (configs em `./trino/catalog/`).

### 4. Subir Grafana (Opcional, para Observabilidade)
Navegue para `grafana/` e execute:

```bash
docker compose up -d
```

- Config: `./config/promtail.yaml` para coleta de logs.
- Acesse: http://localhost:3000 (default user/pass: admin/admin).
- Dashboards: Monitore logs de `/logs/` (coletados via Promtail).

### 5. Verificação
- Rede: `docker network inspect workspaceUnimed_iceber-net`.
- Logs: `docker compose logs -f` em cada pasta.
- Parar tudo: `docker compose down -v` em cada pasta.

## Pipeline de Dados

O pipeline usa Jupyter Notebooks em `processing/notebook/` para ETL. Execute sequencialmente no Jupyter (http://localhost:8900).

### 1. Geração de Dados Fakes (dlake-FAKE.ipynb)
Cria dados em PostgreSQL para testes (1 registro por padrão; ajuste `total_registros` para 100k+).

- **Tabela `clientes`**:
  ```python
  from faker import Faker
  import psycopg2
  from tqdm import tqdm
  import random

  fake = Faker('pt_BR')
  conn = psycopg2.connect(dbname="postgres", user="postgres", password="postgres", host="localhost", port="5434")
  cursor = conn.cursor()

  total_registros = 1  # Ajuste para produção
  batch_size = 1
  status_opcoes = ['ativo', 'inativo', 'pendente']

  def gerar_dados_fake(inicio, qtd):
      return [(fake.name(), f"{fake.name().lower().replace(' ', '.')}.{i}@exemplo.com", fake.date_between(start_date='-2y', end_date='today'), random.choice(status_opcoes)) for i in range(inicio, inicio + qtd)]

  for inicio in tqdm(range(0, total_registros, batch_size)):
      dados = gerar_dados_fake(inicio, batch_size)
      args_str = ','.join(cursor.mogrify("(%s,%s,%s,%s)", x).decode("utf-8") for x in dados)
      cursor.execute(f"INSERT INTO clientes (nome, email, data_cadastro, status) VALUES {args_str}")
      conn.commit()

  cursor.close()
  conn.close()
  ```

- **Tabela `vendas`** (depende de `clientes`):
  ```python
  # ... (conexão similar)
  total_vendas = 1
  produtos = [{'nome': 'Notebook', 'preco': 3500.00, 'categoria': 'eletronicos'}, ...]  # 10 produtos
  status_venda = ['concluida', 'cancelada', 'devolvida', 'pendente']

  cursor.execute("CREATE TABLE IF NOT EXISTS vendas (id SERIAL PRIMARY KEY, cliente_id INTEGER REFERENCES clientes(id), produto VARCHAR(100), categoria VARCHAR(50), quantidade INTEGER, preco_unitario DECIMAL(10,2), total DECIMAL(10,2), data_venda TIMESTAMP, status VARCHAR(20), data_processamento TIMESTAMP DEFAULT CURRENT_TIMESTAMP)")

  def gerar_vendas_fake(qtd_vendas):
      cursor.execute("SELECT id FROM clientes")
      ids_clientes = [row[0] for row in cursor.fetchall()]
      return [(random.choice(ids_clientes), p['nome'], p['categoria'], random.randint(1,3), p['preco'] * (1 - random.uniform(0,0.2)), ... ) for _ in range(qtd_vendas) for p in [random.choice(produtos)]]

  # Inserção em lotes similar ao clientes
  ```

- Saída: Tabelas `clientes` e `vendas` no PostgreSQL.

### 2. ETL no PostgreSQL (dlake-ETL.ipynb)
Exporta dados para CSVs em `./notebook/data/` (não fornecido no prompt, mas inferido como extração via pandas ou COPY). Use para gerar `clientes.csv` e `vendas_part1.csv`.

### 3. Upload para Ingestion (dlake-UPLOAD.ipynb)
Envia CSVs para MinIO bucket `ingestion`, organizados por pasta (ex: `vendas/vendas_part1.csv`).

```python
import boto3, os, logging, re
from botocore.client import Config
from dotenv import load_dotenv
from datetime import datetime

load_dotenv()
s3 = boto3.client("s3", endpoint_url=os.getenv("S3_ENDPOINT"), aws_access_key_id=os.getenv("S3_ACCESS_KEY"), aws_secret_access_key=os.getenv("S3_SECRET_KEY"), config=Config(signature_version="s3v4"), region_name="us-east-1")

def setup_logger():  # Configura logger para console + arquivo em /opt/notebook/logs/
    # ... (código fornecido)

logger = setup_logger()
MINIO_BUCKET = "ingestion"
DATA_FOLDER = "/opt/notebook/data"

# Cria bucket se não existir
if MINIO_BUCKET not in [b['Name'] for b in s3.list_buckets()['Buckets']]:
    s3.create_bucket(Bucket=MINIO_BUCKET)

csv_files = [f for f in os.listdir(DATA_FOLDER) if f.endswith(".csv")]
for filename in csv_files:
    folder_prefix = re.sub(r'^(.+)_part\d+$', r'\1/', filename.replace('.csv', '')) or f"{filename.replace('.csv', '/')}/"
    s3_key = folder_prefix + filename
    with open(os.path.join(DATA_FOLDER, filename), "rb") as f:
        s3.upload_fileobj(f, MINIO_BUCKET, s3_key)
    os.remove(os.path.join(DATA_FOLDER, filename))
    logger.info(f"Upload concluído: {s3_key}")
```

### 4. Camada Bronze (dlake-BRONZE.ipynb)
Lê CSVs do `ingestion`, cria tabelas Iceberg em `local.bronze.{tabela}` (ex: `bronze.clientes`), adiciona `created_at`, deduplica por `id`, particiona por `days(created_at)`. Usa MERGE para upserts. Otimiza (compactação, expire snapshots, remove orphans).

```python
# ... (imports, logger, S3 client)
from pyspark.sql import SparkSession
from pyspark.sql.functions import current_timestamp

def create_spark_session():
    # Configs otimizadas para Iceberg + MinIO (JARs, fs.s3a.*, adaptive query)
    spark = SparkSession.builder \
        .appName("IcebergOptimizedPipeline") \
        .config("spark.sql.extensions", "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions") \
        .config("spark.sql.catalog.local", "org.apache.iceberg.spark.SparkCatalog") \
        .config("spark.sql.catalog.local.type", "hadoop") \
        .config("spark.sql.catalog.local.warehouse", "s3a://datalake/iceberg") \
        # ... (S3 configs, adaptive.enabled=true, shuffle.partitions=4)
        .getOrCreate()
    spark.sparkContext.setLogLevel("ERROR")
    return spark

def list_csv_files_recursive(bucket, prefix=""):  # Recursivo com paginador
    # ...

def optimize_iceberg_table(spark, table_path):  # CALL system.rewrite_data_files, expire_snapshots, etc.
    # ...

def main():
    spark = create_spark_session()
    csv_files = list_csv_files_recursive("ingestion")
    prefix_groups = defaultdict(list)  # Agrupa por pasta (tabela)
    for file in csv_files:
        prefix_groups[file.split('/')[-2] or 'root'].append(file)
    
    for prefix, files in prefix_groups.items():
        table_path = f"local.bronze.{prefix}"
        df = spark.read.option("header", "true").csv([f"s3a://ingestion/{f}" for f in files])
        df = df.withColumn("created_at", current_timestamp()).dropDuplicates(["id"]).filter("id IS NOT NULL")
        
        # Cria tabela com TBLPROPERTIES (parquet+zstd, target-file-size=64MB)
        spark.sql(f"CREATE TABLE IF NOT EXISTS {table_path} (...) USING iceberg PARTITIONED BY (days(created_at)) TBLPROPERTIES (...)")
        
        df.createOrReplaceTempView("temp_df")
        spark.sql(f"MERGE INTO {table_path} ...")  # Upsert por id
        
        optimize_iceberg_table(spark, table_path)
        # Deleta CSVs processados
    spark.stop()

main()
```

- Particionamento: Por dia de criação.
- Otimizações: Zstd, 64MB files, retain 3 snapshots.

### 5. Camada Silver (dlake-SILVER.ipynb)
Refina Bronze: Filtra dados do dia atual, deduplica, MERGE/append/overwrite por partições. Particiona por `days(created_at)`. Usa Snappy, 128MB files.

```python
# ... (similar a Bronze: logger, spark_session, optimize)

bronze_tables = spark.sql("SHOW TABLES IN local.bronze").select("tableName").collect()
for table in bronze_tables:
    silver_source_df = spark.table(f"local.bronze.{table}").filter(f"date(created_at) = '{datetime.now().strftime('%Y-%m-%d')}'").dropDuplicates(["id"]).filter("id IS NOT NULL")
    
    if silver_source_df.count() == 0: continue
    
    # Cria tabela silver se não existir
    spark.sql(f"CREATE TABLE IF NOT EXISTS local.silver.{table} (...) USING iceberg PARTITIONED BY (days(created_at)) TBLPROPERTIES (snappy, 128MB)")
    
    # Split: insert novos (left_anti), update existentes (overwritePartitions)
    silver_insert_df = silver_source_df.join(spark.table(f"local.silver.{table}").select("id").distinct(), "id", "left_anti")
    silver_insert_df.writeTo(f"local.silver.{table}").append()
    
    silver_update_df = silver_source_df.join(..., "inner")
    silver_update_df.writeTo(f"local.silver.{table}").overwritePartitions()
    
    optimize_iceberg_table(spark, f"local.silver.{table}")
```

### 6. Camada Gold (dlake-GOLD.ipynb)
Agregações para BI: `dim_clientes` (flag ativo, ano/mês cadastro), `fato_vendas` (casts, ano/mês venda). Particiona por ano/mês. Append simples.

```python
# ... (similar: logger, spark_session, optimize)

def process_clientes(spark):
    clientes_df = spark.table("local.silver.clientes")
    clientes_gold = clientes_df.select(
        col("id").alias("cliente_id"), col("nome").alias("nome_cliente"), col("email"), col("data_cadastro"),
        when(col("status") == "ativo", 1).otherwise(0).alias("ativo"),
        year(col("data_cadastro")).alias("ano_cadastro"),
        month(col("data_cadastro")).alias("mes_cadastro"),
        col("created_at")
    )
    spark.sql("""
        CREATE TABLE IF NOT EXISTS local.gold.dim_clientes (
            cliente_id string, nome_cliente string, email string, data_cadastro string, ativo int,
            ano_cadastro int, mes_cadastro int, created_at timestamp
        ) USING iceberg PARTITIONED BY (ano_cadastro, mes_cadastro) TBLPROPERTIES (snappy)
    """)
    clientes_gold.writeTo("local.gold.dim_clientes").append()
    optimize_iceberg_table(spark, "local.gold.dim_clientes")

def process_vendas(spark):
    # Similar: select com casts, year/month(data_venda)
    # Cria fato_vendas, append, optimize

def main():
    spark = create_spark_session()
    process_clientes(spark)
    process_vendas(spark)
    spark.stop()
```

- **dim_clientes**: Dimensão com flags e partições temporais.
- **fato_vendas**: Fato com métricas de vendas.

### 7. Agregações Gold (dlake-GOLD-AGGR.ipynb)
Não fornecido, mas exemplo: Queries Spark para views agregadas (ex: vendas por cliente/mês).

```python
# Exemplo: spark.sql("SELECT cliente_id, SUM(total) as total_vendas FROM local.gold.fato_vendas GROUP BY cliente_id")
# Salve como view ou tabela agregada em Gold.
```

### 8. Estudo/Queries (dlake-STUDY.ipynb)
Queries de exemplo via Spark ou Trino (via JDBC no notebook).

- Exemplo Trino: `SELECT * FROM iceberg.local.gold.dim_clientes LIMIT 10;`
- Integre com `tables.yml` para schema docs.

## Consultas e Análise

- **Trino CLI**: `docker exec -it trino trino --server localhost:8080 --catalog iceberg --schema local`.
- Exemplo: 
  ```sql
  SELECT c.nome_cliente, SUM(v.total) as total_gasto, COUNT(v.id) as num_vendas
  FROM gold.dim_clientes c
  JOIN gold.fato_vendas v ON c.cliente_id = v.cliente_id
  WHERE v.ano_venda = 2025
  GROUP BY c.cliente_id, c.nome_cliente
  ORDER BY total_gasto DESC;
  ```

## Observabilidade e Manutenção

- **Grafana**: Dashboards para métricas Spark (via port 4040), logs via Promtail.
- **Airflow** (futuro): DAGs em `airflow/dags/` para orquestrar notebooks (ex: daily ETL).
- **Otimização Iceberg**: Rode `optimize_iceberg_table` periodicamente.
- **Backup**: Volumes persistentes (`postgres_data`, `minio/data`, `grafana-data`).
- **Escala**: Adicione workers Spark/Trino; use Kubernetes para prod.

## Troubleshooting

| Problema | Causa Provável | Solução |
|----------|----------------|---------|
| Conexão S3 falha | Endpoint errado | Verifique `.env` S3_ENDPOINT=http://host.docker.internal:9000 (em host) |
| Spark OOM | Memória baixa | Aumente SPARK_MASTER_MEMORY=8g |
| Hive Metastore erro | JDBC URL | Confirme HIVE_METASTORE_JDBC_URL=jdbc:postgresql://postgres:5432/hive |
| Trino não vê tabelas | Catálogo config | Edite `./trino/catalog/iceberg.properties` com connector=iceberg, hive.metastore.uri=thrift://hive-metastore:9083 |
| Logs não coletados | Promtail | Verifique `./grafana/config/promtail.yaml` paths |

## Próximos Passos

- Integre Airflow para automação.
- Adicione mais fontes (ex: Kafka para streaming).
- Monitore com Prometheus + Grafana.
- Teste com dados reais (aumente `total_registros=100000`).

Para contribuições: Fork, PR com testes. Contato: [seu-email].

*Última atualização: Setembro 2025*


workspaceUnimed/
├── airflow/                          # Orquestração
│   ├── docker-compose.yml
│   ├── dags/                         # DAGs do Airflow
│   ├── logs/                         # Logs do Airflow
│   ├── plugins/                      # Plugins customizados
│   ├── scripts/                      # Scripts auxiliares
│   ├── .env                          # Variáveis do Airflow
│   └── postgres-data/                # Volume persistente do Postgres do Airflow
│
├── postgres/ 
│   ├── data/
│   └── docker.compose.yml
│   └── init-database.sh
├── minio/                            # Storage
│   ├── docker-compose.yml
│   ├── data/                         # Dados do MinIO (buckets)
│   └── .env
│
├── processing/                       # Processamento e Query (Spark + Hive + Trino)
│   ├── docker-compose.yml
│   ├── hive-metastore/
│   │   └── Dockerfile                 # Dockerfile do Hive Metastore
│   ├── notebook/
|   |   ├── data/
|   |   ├── logs/
|   |   ├── .env
|   |   ├── dlake-FAKE.ipynb
|   |   ├── dlake-ETL.ipynb
|   |   ├── dlake-BRONZE.ipynb
|   |   ├── dlake-UPLOAD.ipynb
|   |   ├── dlake-SILVER.ipynb
|   |   ├── dlake-GOLD.ipynb
|   |   ├── dlake-GOLD-AGGR.ipynb
|   |   ├── dlake-STUDY.ipynb
|   |   ├── tables.yml
│   ├── spark/
│   │   ├── jupyter/
│   │   │   ├── jupyter_server_config.py
│   │   │   ├── requirements.txt
│   │   │   ├── themes.jupyterlab-settings
│   │   ├── Dockerfile-spark3.5
│   │   ├── spark-defaults-iceberg.conf
│   │   ├── spark-env.sh
│   ├── trino/
│   │   ├── etc-coordinator/          # Config do Trino Coordinator
│   │   │   ├── config.properties
│   │   │   └── jvm.config
│   │   ├── etc-worker/               # Config do Trino Worker
│   │   │   ├── config.properties
│   │   │   └── jvm.config
│   │   └── catalog/                  # Catálogos do Trino
│   │       ├── hive.properties
│   │       └── iceberg.properties
│   └── .env
├── grafana/                          # Observabilidade
│   ├── docker-compose.yml
│   ├── config/
│   │   └── promtail.yaml             # Config do Promtail
│   ├── grafana-data/                 # Volume persistente do Grafana
│   ├── logs/                         # Logs que o Promtail coleta
│   └── .env
│
└── README.md                         # Documentação do setup
│
└── docker-compose.yml

🚀 Fluxo resumido

MinIO → Data Lake (camada de storage em S3).
Hive Metastore → Catálogo de tabelas (metadados).
Spark → ETL, ML, processamento distribuído.
Trino → Consultas SQL interativas no Data Lake.
Airflow → Orquestração de pipelines (submete jobs Spark, queries Trino, movimenta dados).
Grafana + Loki + Promtail → Observabilidade (dashboards, logs centralizados).