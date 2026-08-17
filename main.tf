terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-south-1"
}

# ---------------------------------------------------------------------------
# KMS key used to encrypt S3, DynamoDB, and SQS below
# ---------------------------------------------------------------------------
resource "aws_kms_key" "threat_engine_key" {
  description             = "KMS key for threat detection pipeline encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "threat_engine_key_alias" {
  name          = "alias/threat-engine-key"
  target_key_id = aws_kms_key.threat_engine_key.key_id
}

# ---------------------------------------------------------------------------
# S3 - raw event storage
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "raw_events" {
  bucket = "threat-engine-raw-event" # replace with your EXACT bucket name
}

resource "aws_s3_bucket_public_access_block" "raw_events" {
  bucket = aws_s3_bucket.raw_events.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw_events" {
  bucket = aws_s3_bucket.raw_events.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.threat_engine_key.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "raw_events" {
  bucket = aws_s3_bucket.raw_events.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Separate bucket to receive access logs for raw_events (resolves
# aws-s3-enable-bucket-logging). Logging bucket does not log itself.
resource "aws_s3_bucket" "access_logs" {
  bucket = "threat-engine-access-logs" # must be globally unique; adjust if taken
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_logging" "raw_events" {
  bucket = aws_s3_bucket.raw_events.id

  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "raw-events-access-logs/"
}

# ---------------------------------------------------------------------------
# DynamoDB - processed threat records
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "threat_records" {
  name         = "threat-records"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.threat_engine_key.arn
  }

  point_in_time_recovery {
    enabled = true
  }
}

# ---------------------------------------------------------------------------
# SQS - main queue + dead letter queue
# ---------------------------------------------------------------------------
resource "aws_sqs_queue" "threat_events_dlq" {
  name              = "threat-events-dlq"
  kms_master_key_id = aws_kms_key.threat_engine_key.id
}

resource "aws_sqs_queue" "threat_events_queue" {
  name              = "threat-event-queue"
  kms_master_key_id = aws_kms_key.threat_engine_key.id

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.threat_events_dlq.arn
    maxReceiveCount     = 10
  })
}

# ---------------------------------------------------------------------------
# IAM role + policies for Lambda
# ---------------------------------------------------------------------------
resource "aws_iam_role" "lambda_role" {
  name = "threat-evaluator-role-hkp4orir"
  path = "/service-role/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "sqs_permission" {
  name = "sqs_permission"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = "arn:aws:sqs:ap-south-1:710809468235:threat-event-queue"
      }
    ]
  })
}

resource "aws_iam_role_policy" "dynamodb_write" {
  name = "threat-evaluator-dynamdb-write"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = "arn:aws:dynamodb:ap-south-1:710809468235:table/threat-records"
      }
    ]
  })
}

resource "aws_iam_role_policy" "s3_write" {
  name = "threat-evaluator-s3-write"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "arn:aws:s3:::threat-engine-raw-event/*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "xray_tracing" {
  name = "xray-tracing"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }
    ]
  })
}

# Grant the KMS key permission to be used by the Lambda role (needed since
# the key is customer-managed, not the AWS-managed default key)
resource "aws_iam_role_policy" "kms_usage" {
  name = "kms-usage"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.threat_engine_key.arn
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Lambda function
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "threat_evaluator" {
  function_name = "threat-evaluator"
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.12"

  filename         = "lambda_function.zip"
  source_code_hash = filebase64sha256("lambda_function.zip")

  tracing_config {
    mode = "Active"
  }
}
