### Terraform template for ECS service
 Create an AWS ECS cluster with a service and task definition for a sample application. Configure CloudWatch alarms to send alerts when the ECS service's tasks are not in a healthy state.

 This project create:
- A simple ECS cluster with 1 service `kuard`
- Apply `EventBridge` service to monitor unhealthy service. If an service is unhealthy, it will send the log to CloudWatch Log group `/aws/events/ecs/$SERVICE_NAME` and send a notification to Slack chat