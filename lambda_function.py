 
import json
import boto3
import uuid
from datetime import datetime, timezone

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table('threat-records')

s3 = boto3.client('s3')
BUCKET_NAME = 'threat-engine-raw-events-meetpatel'  # replace with your exact bucket name

def lambda_handler(event, context):
    for record in event['Records']:
        body = json.loads(record['body'])

        source_ip = body.get('source_ip', 'unknown')
        event_type = body.get('event_type', 'unknown')
        failed_attempts = body.get('failed_attempts', 0)

        if failed_attempts >= 5:
            severity = 'HIGH'
        elif failed_attempts >= 2:
            severity = 'MEDIUM'
        else:
            severity = 'LOW'

        event_id = str(uuid.uuid4())
        timestamp = datetime.now(timezone.utc).isoformat()

        item = {
            'event_id': event_id,
            'source_ip': source_ip,
            'event_type': event_type,
            'failed_attempts': failed_attempts,
            'severity': severity,
            'timestamp': timestamp
        }

        # 1. Archive the raw event to S3 first (before processing result)
        s3_key = f"raw-events/{timestamp[:10]}/{event_id}.json"
        s3.put_object(
            Bucket='threat-engine-raw-event',
            Key=s3_key,
            Body=json.dumps(body),
            ContentType='application/json'
        )

        # 2. Write the processed/evaluated record to DynamoDB
        table.put_item(Item=item)

        print(f"Archived to S3: {s3_key}, Processed: {item}")

    return {'statusCode': 200}