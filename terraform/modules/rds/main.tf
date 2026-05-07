# RDS PostgreSQL Module

resource "random_password" "master_password" {
  length  = 32
  special = true
}

resource "aws_secretsmanager_secret" "rds_password" {
  name_prefix             = "${var.environment}-${var.identifier}-password-"
  description             = "Master password for ${var.identifier} RDS instance"
  recovery_window_in_days = 7

  tags = merge(
    var.tags,
    {
      Name        = "${var.environment}-${var.identifier}-password"
      Environment = var.environment
    }
  )
}

resource "aws_secretsmanager_secret_version" "rds_password" {
  secret_id     = aws_secretsmanager_secret.rds_password.id
  secret_string = random_password.master_password.result
}

resource "aws_db_subnet_group" "main" {
  name        = "${var.environment}-${var.identifier}-subnet-group"
  description = "Subnet group for ${var.identifier} RDS instance"
  subnet_ids  = var.subnet_ids

  tags = merge(
    var.tags,
    {
      Name        = "${var.environment}-${var.identifier}-subnet-group"
      Environment = var.environment
    }
  )
}

resource "aws_security_group" "rds" {
  name        = "${var.environment}-${var.identifier}-rds-sg"
  description = "Security group for ${var.identifier} RDS instance"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from allowed security groups"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = var.allowed_security_group_ids
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name        = "${var.environment}-${var.identifier}-rds-sg"
      Environment = var.environment
    }
  )
}

resource "aws_kms_key" "rds" {
  description             = "KMS key for ${var.identifier} RDS encryption"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  tags = merge(
    var.tags,
    {
      Name        = "${var.environment}-${var.identifier}-kms"
      Environment = var.environment
    }
  )
}

resource "aws_kms_alias" "rds" {
  name          = "alias/${var.environment}-${var.identifier}-rds"
  target_key_id = aws_kms_key.rds.key_id
}

resource "aws_db_parameter_group" "main" {
  name        = "${var.environment}-${var.identifier}-params"
  family      = "postgres15"
  description = "Custom parameter group for ${var.identifier}"

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name  = "log_duration"
    value = "1"
  }

  parameter {
    name  = "log_statement"
    value = "all"
  }

  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements"
  }

  tags = merge(
    var.tags,
    {
      Name        = "${var.environment}-${var.identifier}-params"
      Environment = var.environment
    }
  )
}

resource "aws_db_instance" "main" {
  identifier     = "${var.environment}-${var.identifier}"
  engine         = var.engine
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.rds.arn

  db_name  = var.database_name
  username = var.master_username
  password = random_password.master_password.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.main.name

  multi_az               = var.multi_az
  publicly_accessible    = false
  deletion_protection    = var.deletion_protection
  skip_final_snapshot    = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.environment}-${var.identifier}-final-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"

  backup_retention_period = var.backup_retention_period
  backup_window           = var.backup_window
  maintenance_window      = var.maintenance_window

  enabled_cloudwatch_logs_exports = var.enabled_cloudwatch_logs_exports

  performance_insights_enabled          = var.enable_performance_insights
  performance_insights_retention_period = var.enable_performance_insights ? var.performance_insights_retention : null
  performance_insights_kms_key_id       = var.enable_performance_insights ? aws_kms_key.rds.arn : null

  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  tags = merge(
    var.tags,
    {
      Name        = "${var.environment}-${var.identifier}"
      Environment = var.environment
    }
  )

  lifecycle {
    ignore_changes = [
      password,
      final_snapshot_identifier
    ]
  }
}

# Read Replicas (optional)
resource "aws_db_instance" "read_replica" {
  count = var.create_read_replica ? var.read_replica_count : 0

  identifier     = "${var.environment}-${var.identifier}-replica-${count.index + 1}"
  replicate_source_db = aws_db_instance.main.identifier

  instance_class = var.instance_class
  
  publicly_accessible = false
  skip_final_snapshot = true

  performance_insights_enabled          = var.enable_performance_insights
  performance_insights_retention_period = var.enable_performance_insights ? var.performance_insights_retention : null
  performance_insights_kms_key_id       = var.enable_performance_insights ? aws_kms_key.rds.arn : null

  auto_minor_version_upgrade = true

  tags = merge(
    var.tags,
    {
      Name        = "${var.environment}-${var.identifier}-replica-${count.index + 1}"
      Environment = var.environment
      Role        = "ReadReplica"
    }
  )
}

# CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "database_cpu" {
  alarm_name          = "${var.environment}-${var.identifier}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This metric monitors RDS CPU utilization"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.id
  }

  tags = merge(
    var.tags,
    {
      Name        = "${var.environment}-${var.identifier}-high-cpu-alarm"
      Environment = var.environment
    }
  )
}

resource "aws_cloudwatch_metric_alarm" "database_memory" {
  alarm_name          = "${var.environment}-${var.identifier}-low-memory"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "FreeableMemory"
  namespace           = "AWS/RDS"
  period              = "300"
  statistic           = "Average"
  threshold           = "1000000000" # 1GB in bytes
  alarm_description   = "This metric monitors RDS freeable memory"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.id
  }

  tags = merge(
    var.tags,
    {
      Name        = "${var.environment}-${var.identifier}-low-memory-alarm"
      Environment = var.environment
    }
  )
}

resource "aws_cloudwatch_metric_alarm" "database_storage" {
  alarm_name          = "${var.environment}-${var.identifier}-low-storage"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = "300"
  statistic           = "Average"
  threshold           = "10000000000" # 10GB in bytes
  alarm_description   = "This metric monitors RDS free storage space"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.id
  }

  tags = merge(
    var.tags,
    {
      Name        = "${var.environment}-${var.identifier}-low-storage-alarm"
      Environment = var.environment
    }
  )
}
