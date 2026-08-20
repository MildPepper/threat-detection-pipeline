import { NextRequest, NextResponse } from "next/server";
import { SQSClient, SendMessageCommand } from "@aws-sdk/client-sqs";
import {
  DynamoDBClient,
} from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient,
  GetCommand,
  UpdateCommand,
} from "@aws-sdk/lib-dynamodb";

const awsCredentials = {
  accessKeyId: process.env.AWS_ACCESS_KEY_ID!,
  secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY!,
};

const sqsClient = new SQSClient({
  region: process.env.AWS_REGION,
  credentials: awsCredentials,
});

const ddbClient = new DynamoDBClient({
  region: process.env.AWS_REGION,
  credentials: awsCredentials,
});
const ddb = DynamoDBDocumentClient.from(ddbClient);

export async function POST(request: NextRequest) {
  const body = await request.json();
  const { email, success } = body;

  const forwardedFor = request.headers.get("x-forwarded-for");
  const sourceIp = forwardedFor ? forwardedFor.split(",")[0] : "unknown";

  let failedAttempts = 0;

  if (success) {
    // Reset counter on successful login
    await ddb.send(
      new UpdateCommand({
        TableName: "login-attempts",
        Key: { source_ip: sourceIp },
        UpdateExpression: "SET fail_count = :zero",
        ExpressionAttributeValues: { ":zero": 0 },
      })
    );
    failedAttempts = 0;
  } else {
    // Read current count, increment it
    const existing = await ddb.send(
      new GetCommand({
        TableName: "login-attempts",
        Key: { source_ip: sourceIp },
      })
    );

    const currentCount = existing.Item?.fail_count ?? 0;
    failedAttempts = currentCount + 1;

    const expiresAt = Math.floor(Date.now() / 1000) + 15 * 60; // 15 min TTL

    await ddb.send(
      new UpdateCommand({
        TableName: "login-attempts",
        Key: { source_ip: sourceIp },
        UpdateExpression: "SET fail_count = :count, expires_at = :exp",
        ExpressionAttributeValues: {
          ":count": failedAttempts,
          ":exp": expiresAt,
        },
      })
    );
  }

  const message = {
    source_ip: sourceIp,
    event_type: "login_attempt",
    failed_attempts: failedAttempts,
    email_attempted: email,
  };

  try {
    await sqsClient.send(
      new SendMessageCommand({
        QueueUrl: process.env.SQS_QUEUE_URL,
        MessageBody: JSON.stringify(message),
      })
    );
    return NextResponse.json({ ok: true, failedAttempts });
  } catch (error) {
    console.error("Failed to send to SQS:", error);
    return NextResponse.json({ ok: false, error: "Failed to log event" }, { status: 500 });
  }
}