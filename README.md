# aws-websocket

Creates the AWS resources necessary to run a Serverless WebSocket infrastructure using API Gateway.

## Features

- Creates a WebSocket API Gateway and related Lambdas

## Usage

```hcl
provider "aws" {
  region = "us-east-1"
}

module "aws_websocket" {
  source  = "dvargas92495/websocket/aws"
  name    = "example"
}
```

## Inputs
- `name` - The AWS API Gateway name.
- `repo` - The name of the repo for the project. Defaulted to the name of the gateway, replacing `-` with `.`.
 
## Output

There are no exposed outputs
