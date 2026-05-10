# =============================================================================
# TFG Infraestructura Multi-Cloud - Despliegue AWS (Cloud Principal)
# =============================================================================
#
# Arquitectura:
#   - VPC 10.0.0.0/16 con 3 subredes en us-east-1
#   - Subred pública (10.0.1.0/24): Bastion host con Nginx reverse proxy
#   - Subred privada 1 (10.0.11.0/24): EC2 con Docker (app web PHP)
#   - Subred privada 2 (10.0.12.0/24): Solo existe porque RDS exige db_subnet_group
#     con mínimo 2 AZs. No se despliega nada aquí.
#   - NAT Gateway: permite a la EC2 privada salir a internet (descargar imágenes Docker)
#   - RDS MySQL 8.0: single-AZ, db.t3.micro, sin Multi-AZ para reducir costes
#
# Flujo de tráfico:
#   Usuario → HTTPS (443) → Bastion (Nginx) → HTTP (80) → EC2 Docker → RDS
#   Admin   → SSH (22) → Bastion → SSH → EC2 Docker / mysql → RDS
#
# Cuenta: AWS Academy Learner Lab (us-east-1, crédito limitado, sesiones 4h)
#
# Notas de producción (comentadas en cada recurso donde aplique):
#   - Multi-AZ en RDS: cambiar multi_az = true
#   - ALB en vez de Nginx reverse proxy para health checks L7 y escalado
#   - Certificado ACM o Let's Encrypt en vez de autofirmado
#   - EKS en vez de EC2+Docker para orquestación de contenedores
#   - Múltiples nodos en múltiples AZs para alta disponibilidad
# =============================================================================


# =============================================================================
# PROVIDER
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
      # Usamos ~> 5.0 según las instrucciones del proyecto.
      # El ejemplo de Diego usa ~> 6.0, pero 5.x es más estable
      # y compatible con AWS Academy.
    }
  }
}

provider "aws" {
  region = var.aws_region
}


# =============================================================================
# VARIABLES
# =============================================================================

variable "aws_region" {
  description = "Región de AWS. us-east-1 es la predeterminada de AWS Academy"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefijo para nombrar todos los recursos del proyecto"
  type        = string
  default     = "tfg-gym"
}

variable "db_name" {
  description = "Nombre de la base de datos MySQL que se creará en RDS"
  type        = string
  default     = "gym"
}

variable "db_username" {
  description = "Usuario administrador de la base de datos RDS"
  type        = string
  default     = "admin"
}

variable "db_password" {
  description = "Contraseña del usuario admin de RDS. Se define en terraform.tfvars (NO subir a GitHub)"
  type        = string
  sensitive   = true
}

variable "admin_ip" {
  description = "IP pública del administrador para restringir SSH al bastion (formato: X.X.X.X/32). Se puede obtener con 'curl ifconfig.me'"
  type        = string
  default     = "0.0.0.0/0"
  # NOTA DE SEGURIDAD: En producción se pondría la IP fija del admin.
  # 0.0.0.0/0 permite SSH desde cualquier IP, útil para desarrollo/demo
  # pero NO recomendable en entornos reales.
  # Para GitHub Actions, se podría usar los rangos de IP de GitHub
  # o un bastion gestionado como AWS Systems Manager Session Manager.
}

variable "key_name" {
  description = "Nombre del key pair en AWS. Se crea previamente con ssh-keygen y se sube la clave pública"
  type        = string
  default     = "tfg-gym-key"
}

variable "public_key_path" {
  description = "Ruta local a la clave pública SSH (.pub) para crear el key pair en AWS"
  type        = string
  default     = "./.ssh/tfg-gym-key.pub"
}


# =============================================================================
# DATA SOURCES
# =============================================================================

# Obtener las AZs disponibles en la región
data "aws_availability_zones" "available" {
  state = "available"
}

# AMI de Ubuntu 22.04 LTS (misma que usa Diego en su ejemplo)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical (propietario oficial de Ubuntu en AWS)

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}


# =============================================================================
# VPC
# =============================================================================

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true  # Necesario para que RDS tenga un endpoint DNS
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}


# =============================================================================
# INTERNET GATEWAY
# =============================================================================
# Permite que los recursos en la subred pública accedan a internet

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}


# =============================================================================
# SUBREDES
# =============================================================================

# --- Subred pública: Bastion host + NAT Gateway ---
# Aquí van los recursos que necesitan IP pública directa
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0] # us-east-1a
  map_public_ip_on_launch = true  # Las instancias aquí reciben IP pública automáticamente

  tags = {
    Name = "${var.project_name}-subnet-public"
  }
}

# --- Subred privada 1: EC2 con Docker ---
# Sin IP pública. Sale a internet por NAT Gateway.
resource "aws_subnet" "private_app" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = data.aws_availability_zones.available.names[0] # us-east-1a

  tags = {
    Name = "${var.project_name}-subnet-private-app"
  }
}

# --- Subred privada 2: Solo para cumplir requisito de RDS ---
# AWS exige que el db_subnet_group tenga subredes en al menos 2 AZs distintas.
# Esta subred está en us-east-1b pero NO se despliega nada en ella.
# La instancia RDS se crea en us-east-1a igualmente (single-AZ).
# PRODUCCIÓN: con multi_az = true, RDS usaría ambas subredes para la réplica standby.
resource "aws_subnet" "private_db_secondary" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.12.0/24"
  availability_zone = data.aws_availability_zones.available.names[1] # us-east-1b

  tags = {
    Name = "${var.project_name}-subnet-private-db-secondary"
  }
}


# =============================================================================
# ELASTIC IP + NAT GATEWAY
# =============================================================================
# El NAT Gateway permite que la EC2 en subred privada salga a internet
# (descargar imágenes Docker, actualizaciones apt) sin tener IP pública.
# El tráfico de entrada desde internet NO pasa por aquí.
# Coste: ~0.045 $/hora + transferencia. Imprescindible para EC2 en subred privada.
# PRODUCCIÓN: se podría usar un NAT Gateway por AZ para alta disponibilidad.

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-eip"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id  # El NAT Gateway va en la subred PÚBLICA

  tags = {
    Name = "${var.project_name}-nat-gw"
  }

  depends_on = [aws_internet_gateway.main]
}


# =============================================================================
# TABLAS DE RUTAS
# =============================================================================

# --- Tabla de rutas pública ---
# Todo el tráfico no local (0.0.0.0/0) sale por el Internet Gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-rt-public"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# --- Tabla de rutas privada ---
# Todo el tráfico no local (0.0.0.0/0) sale por el NAT Gateway
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-rt-private"
  }
}

resource "aws_route_table_association" "private_app" {
  subnet_id      = aws_subnet.private_app.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_db_secondary" {
  subnet_id      = aws_subnet.private_db_secondary.id
  route_table_id = aws_route_table.private.id
}


# =============================================================================
# KEY PAIR
# =============================================================================
# Se crea a partir de la clave pública generada con:
#   ssh-keygen -t rsa -b 4096 -f ~/.ssh/tfg-gym-key
# La clave privada (~/.ssh/tfg-gym-key) se usa para conectar por SSH.
# En GitHub Actions, la clave privada se almacena como secreto (SSH_PRIVATE_KEY).

resource "aws_key_pair" "main" {
  key_name   = var.key_name
  public_key = file(var.public_key_path)

  tags = {
    Name = "${var.project_name}-key"
  }
}


# =============================================================================
# SECURITY GROUPS
# =============================================================================

# --- SG del Bastion ---
# Permite:
#   - SSH (22) desde la IP del admin (o 0.0.0.0/0 para demo)
#   - HTTPS (443) desde cualquier IP (los usuarios acceden a la app por aquí)
#   - Salida total a internet
resource "aws_security_group" "bastion" {
  name        = "${var.project_name}-sg-bastion"
  description = "SG del bastion: SSH desde admin + HTTPS desde usuarios"
  vpc_id      = aws_vpc.main.id

  # SSH solo desde la IP del administrador
  ingress {
    description = "SSH desde IP del admin"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_ip]
  }

  # HTTPS desde cualquier IP (Nginx reverse proxy hacia la app)
  ingress {
    description = "HTTPS desde Internet (reverse proxy a la app)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Salida total (actualizaciones, apt, etc.)
  egress {
    description = "Salida total a Internet"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg-bastion"
  }
}

# --- SG de la EC2 con Docker ---
# Permite:
#   - HTTP (80) solo desde el bastion (Nginx le reenvía el tráfico)
#   - SSH (22) solo desde el bastion (administración)
#   - Salida total (descargar imágenes Docker por NAT Gateway)
resource "aws_security_group" "app" {
  name        = "${var.project_name}-sg-app"
  description = "SG de la EC2 Docker: HTTP y SSH solo desde bastion"
  vpc_id      = aws_vpc.main.id

  # HTTP solo desde el bastion (Nginx reverse proxy)
  ingress {
    description     = "HTTP desde bastion (Nginx reverse proxy)"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  # SSH solo desde el bastion (para administración y despliegue)
  ingress {
    description     = "SSH desde bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  # Salida total (NAT Gateway → Internet para descargar imágenes Docker)
  egress {
    description = "Salida total via NAT Gateway"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg-app"
  }
}

# --- SG de RDS ---
# Permite:
#   - MySQL (3306) solo desde la EC2 Docker y desde el bastion
#   - El bastion necesita acceso para ejecutar init.sql y para administración
# PRODUCCIÓN: restringir aún más, solo desde la app, y usar IAM DB Auth
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-sg-rds"
  description = "SG de RDS: MySQL solo desde app y bastion"
  vpc_id      = aws_vpc.main.id

  # MySQL desde la EC2 Docker (la app conecta a la BD)
  ingress {
    description     = "MySQL desde EC2 Docker"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  # MySQL desde el bastion (para ejecutar init.sql y administración)
  ingress {
    description     = "MySQL desde bastion (init SQL y admin)"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  # Salida (respuestas a las queries)
  egress {
    description = "Salida permitida"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg-rds"
  }
}


# =============================================================================
# BASTION HOST
# =============================================================================
# EC2 t3.micro en subred pública con IP elástica.
# Funciones:
#   1. Punto de acceso SSH (único recurso accesible desde internet por SSH)
#   2. Reverse proxy Nginx: recibe HTTPS (443) y reenvía a EC2 Docker (HTTP 80)
#   3. Punto de ejecución de init.sql contra RDS (mysql-client)
#
# El user_data instala:
#   - Nginx (reverse proxy HTTPS → HTTP a la app)
#   - mysql-client (para ejecutar SQL contra RDS)
#   - Certificado SSL autofirmado (para HTTPS sin dominio real)
# PRODUCCIÓN: usar Let's Encrypt o ACM + ALB para certificados válidos.

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro" # Capa gratuita / mínimo coste
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  key_name               = aws_key_pair.main.key_name

  user_data = <<-EOF
    #!/bin/bash
    set -e

    # --- Actualizar sistema ---
    apt-get update -y
    apt-get upgrade -y

    # --- Instalar Nginx y mysql-client ---
    apt-get install -y nginx mysql-client-8.0

    # --- Crear certificado SSL autofirmado ---
    # PRODUCCIÓN: usar Let's Encrypt (certbot) o AWS ACM con ALB
    mkdir -p /etc/nginx/ssl
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout /etc/nginx/ssl/selfsigned.key \
      -out /etc/nginx/ssl/selfsigned.crt \
      -subj "/C=ES/ST=Madrid/L=Madrid/O=TFG/CN=tfg-gym"

    # --- Configurar Nginx como reverse proxy ---
    # Recibe HTTPS (443) y reenvía a la EC2 Docker en subred privada (HTTP 80)
    # La IP privada de la EC2 Docker se actualizará después del despliegue
    # o se puede usar el DNS privado de AWS.
    cat > /etc/nginx/sites-available/default <<'NGINX'
    server {
        listen 443 ssl;
        server_name _;

        ssl_certificate     /etc/nginx/ssl/selfsigned.crt;
        ssl_certificate_key /etc/nginx/ssl/selfsigned.key;

        # Reenviar todo el tráfico a la EC2 Docker en subred privada
        # PLACEHOLDER_APP_IP se reemplaza con la IP privada real de la EC2 Docker
        location / {
            proxy_pass http://PLACEHOLDER_APP_IP:80;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }

    # Redirigir HTTP a HTTPS
    server {
        listen 80;
        server_name _;
        return 301 https://$host$request_uri;
    }
    NGINX

    # Nginx se reiniciará cuando se configure la IP real de la EC2 Docker
    # (se hace desde el workflow de GitHub Actions o manualmente)
    systemctl enable nginx

    echo "Bastion configurado correctamente" > /home/ubuntu/bastion-ready.txt
  EOF

  tags = {
    Name = "${var.project_name}-bastion"
  }
}

# IP elástica para el bastion (persiste aunque la instancia se reinicie)
resource "aws_eip" "bastion" {
  instance = aws_instance.bastion.id
  domain   = "vpc"

  tags = {
    Name = "${var.project_name}-bastion-eip"
  }

  depends_on = [aws_internet_gateway.main]
}


# =============================================================================
# EC2 CON DOCKER (App Web)
# =============================================================================
# EC2 t3.micro en subred privada (sin IP pública).
# Ejecuta un contenedor Docker con la app PHP (formulario CRUD del gimnasio).
# Sale a internet por NAT Gateway para descargar imágenes Docker.
# Solo accesible desde el bastion (SSH y HTTP).
#
# El user_data instala Docker y lo deja listo para recibir la imagen.
# El despliegue de la app (docker build + docker run) se hace desde
# GitHub Actions a través del bastion (SSH → EC2 Docker).
# PRODUCCIÓN: usar EKS (Kubernetes) para orquestación de contenedores.

resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private_app.id
  vpc_security_group_ids = [aws_security_group.app.id]
  key_name               = aws_key_pair.main.key_name

  user_data = <<-EOF
    #!/bin/bash
    set -e

    # --- Actualizar sistema ---
    apt-get update -y
    apt-get upgrade -y

    # --- Instalar Docker ---
    apt-get install -y docker.io
    systemctl start docker
    systemctl enable docker

    # Añadir usuario ubuntu al grupo docker (evita usar sudo para docker)
    usermod -aG docker ubuntu

    # --- Instalar mysql-client (útil para debug desde la EC2) ---
    apt-get install -y mysql-client-8.0

    echo "EC2 Docker lista" > /home/ubuntu/app-ready.txt
  EOF

  tags = {
    Name = "${var.project_name}-ec2-docker"
  }
}


# =============================================================================
# RDS MYSQL
# =============================================================================
# Instancia MySQL 8.0, single-AZ, db.t3.micro.
# En subred privada, solo accesible desde la EC2 Docker y el bastion.
# Sin Multi-AZ para reducir costes (cuenta estudiantil).
#
# El db_subnet_group requiere subredes en 2 AZs aunque solo usemos 1.
# PRODUCCIÓN: activar multi_az = true (una sola línea) para alta disponibilidad.

resource "aws_db_subnet_group" "main" {
  name = "${var.project_name}-db-subnet-group"
  subnet_ids = [
    aws_subnet.private_app.id,          # us-east-1a (donde se despliega RDS)
    aws_subnet.private_db_secondary.id  # us-east-1b (solo para cumplir requisito AWS)
  ]

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

resource "aws_db_instance" "mysql" {
  identifier = "${var.project_name}-rds"

  # Motor y versión
  engine         = "mysql"
  engine_version = "8.0"

  # Tamaño de instancia (mínimo para cuenta estudiantil)
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp2"

  # Credenciales y base de datos
  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  # Red y seguridad
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  availability_zone      = data.aws_availability_zones.available.names[0] # us-east-1a
  publicly_accessible    = false  # Solo accesible desde dentro de la VPC

  # Configuración de backups
  backup_retention_period = 7  # Mantener backups automáticos 7 días
  # PRODUCCIÓN: configurar backup_window y maintenance_window

  # Sin Multi-AZ (reduce coste a la mitad)
  multi_az = false
  # PRODUCCIÓN: multi_az = true para réplica standby automática

  # Cifrado en reposo
  storage_encrypted = true
  # PRODUCCIÓN: especificar kms_key_id para usar una clave KMS propia

  # Permitir destruir sin snapshot final (entorno de desarrollo)
  skip_final_snapshot = true
  deletion_protection = false
  # PRODUCCIÓN: skip_final_snapshot = false, deletion_protection = true

  tags = {
    Name = "${var.project_name}-rds"
  }
}


# =============================================================================
# OUTPUTS
# =============================================================================
# Estos valores se usan en:
#   - GitHub Actions (secretos y variables)
#   - Ansible (inventory)
#   - Configuración de Nginx (IP privada de la EC2 Docker)
#   - Conexión a RDS (endpoint)

output "bastion_public_ip" {
  description = "IP pública del bastion (para SSH y acceso web HTTPS)"
  value       = aws_eip.bastion.public_ip
}

output "bastion_public_dns" {
  description = "DNS público del bastion"
  value       = aws_instance.bastion.public_dns
}

output "app_private_ip" {
  description = "IP privada de la EC2 Docker (para configurar Nginx en el bastion)"
  value       = aws_instance.app.private_ip
}

output "rds_endpoint" {
  description = "Endpoint de conexión a RDS (host para mysql -h)"
  value       = aws_db_instance.mysql.address
}

output "rds_port" {
  description = "Puerto de RDS"
  value       = aws_db_instance.mysql.port
}

output "vpc_id" {
  description = "ID de la VPC creada"
  value       = aws_vpc.main.id
}

output "nat_gateway_ip" {
  description = "IP pública del NAT Gateway (la IP de salida de la EC2 Docker)"
  value       = aws_eip.nat.public_ip
}
