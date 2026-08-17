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

resource "aws_s3_bucket" "raw_events" {
  bucket = "threat-engine-raw-event" # replace with your EXACT bucket name
}

resource "aws_dynamodb_table" "threat_records" {
  name         = "threat-records"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }
}


resource "aws_sqs_queue" "threat_events_dlq" {
  name = "threat-events-dlq"
}

resource "aws_sqs_queue" "threat_events_queue" {
  name = "threat-event-queue"

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.threat_events_dlq.arn
    maxReceiveCount     = 10
  })
}


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


resource "aws_lambda_function" "threat_evaluator" {
  function_name = "threat-evaluator"
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.12"

  filename         = "lambda_function.zip"
  source_code_hash = filebase64sha256("lambda_function.zip")
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
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "raw_events" {
  bucket = aws_s3_bucket.raw_events.id

  versioning_configuration {
    status = "Enabled"
  }
}