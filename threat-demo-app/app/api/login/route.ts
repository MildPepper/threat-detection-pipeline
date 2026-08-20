import { NextRequest, NextResponse } from "next/server";
import { SQSClient, SendMessageCommand } from "@aws-sdk/client-sqs";

const sqsClient = new SQSClient({
  region: process.env.AWS_REGION,
  credentials: {
    accessKeyId: process.env.AWS_ACCESS_KEY_ID!,
    secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY!,
  },
});

export async function POST(request: NextRequest) {
  const body = await request.json();
  const { email, success } = body;

  const forwardedFor = request.headers.get("x-forwarded-for");
  const sourceIp = forwardedFor ? forwardedFor.split(",")[0] : "unknown";

  const failedAttempts = success ? 0 : 1;

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

    return NextResponse.json({ ok: true });
  } catch (error) {
    console.error("Failed to send to SQS:", error);
    return NextResponse.json({ ok: false, error: "Failed to log event" }, { status: 500 });
  }
}