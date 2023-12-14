provider "aws" {}

data "aws_availability_zones" "available" {}

locals {
  name = "ecs-alarm"

  vpc_cidr = var.vpc_cidr
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  container_name = "kuard"
  container_port = 8080

  slack_input_transformer = {
    input_paths = {
      id = "$.id"
    }
    input_template = jsonencode({ "text" : "ECS Task State Change id <id>" })
  }

  tags = {
    Writer = "tvminh"
  }
}

################################################################################
# Cluster
################################################################################

module "ecs_cluster" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "~> 5.7.3"

  cluster_name = local.name

  # Capacity provider
  fargate_capacity_providers = {
    FARGATE = {
      default_capacity_provider_strategy = {
        weight = 100
      }
    }
  }

  services = {
    kuard = {
      # Enables ECS Exec
      enable_execute_command = true

      # Container definition(s)
      container_definitions = {

        (local.container_name) = {
          cpu       = 512
          memory    = 1024
          essential = true
          image     = "gcr.io/kuar-demo/kuard-amd64:blue"
          port_mappings = [
            {
              name          = local.container_name
              containerPort = local.container_port
              hostPort      = local.container_port
              protocol      = "tcp"
            }
          ]

          # Example image used requires access to write to root filesystem
          readonly_root_filesystem  = false
          enable_cloudwatch_logging = false

          health_check = {
            command  = ["CMD-SHELL", "curl -f http://localhost/ || exit 1"]
            retries  = 2
            timeout  = 5
            interval = 5
          }
        }
      }

      service_connect_configuration = {
        namespace = aws_service_discovery_http_namespace.this.arn
        service = {
          client_alias = {
            port     = local.container_port
            dns_name = local.container_name
          }
          port_name      = local.container_name
          discovery_name = local.container_name
        }
      }

      load_balancer = {
        service = {
          target_group_arn = module.alb.target_groups["ex_ecs"].arn
          container_name   = local.container_name
          container_port   = local.container_port
        }
      }

      subnet_ids = module.vpc.private_subnets
      security_group_rules = {
        alb_ingress_8080 = {
          type                     = "ingress"
          from_port                = local.container_port
          to_port                  = local.container_port
          protocol                 = "tcp"
          description              = "Service port"
          source_security_group_id = module.alb.security_group_id
        }
        egress_all = {
          type        = "egress"
          from_port   = 0
          to_port     = 0
          protocol    = "-1"
          cidr_blocks = ["0.0.0.0/0"]
        }
      }
    }
  }

  tags = local.tags
}

################################################################################
# Supporting Resources
################################################################################

resource "aws_service_discovery_http_namespace" "this" {
  name        = local.name
  description = "CloudMap namespace for ${local.name}"
  tags        = local.tags
}

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 9.0"

  name = local.name

  load_balancer_type = "application"

  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.public_subnets

  # For example only
  enable_deletion_protection = false

  # Security Group
  security_group_ingress_rules = {
    all_http = {
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }
  security_group_egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = module.vpc.vpc_cidr_block
    }
  }

  listeners = {
    ex_http = {
      port     = 80
      protocol = "HTTP"

      forward = {
        target_group_key = "ex_ecs"
      }
    }
  }

  target_groups = {
    ex_ecs = {
      backend_protocol                  = "HTTP"
      backend_port                      = local.container_port
      target_type                       = "ip"
      deregistration_delay              = 5
      load_balancing_cross_zone_enabled = true

      health_check = {
        enabled             = true
        healthy_threshold   = 5
        interval            = 30
        matcher             = "200"
        path                = "/"
        port                = "traffic-port"
        protocol            = "HTTP"
        timeout             = 5
        unhealthy_threshold = 2
      }

      # There's nothing to attach here in this definition. Instead,
      # ECS will attach the IPs of the tasks to this target group
      create_attachment = false
    }
  }

  tags = local.tags
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = local.tags
}

# ################################################################################
# EventBridge
# ################################################################################
module "eventbridge" {
  source = "terraform-aws-modules/eventbridge/aws"

  create_bus              = false
  create_connections      = true
  create_api_destinations = true

  attach_cloudwatch_policy      = true
  attach_api_destination_policy = true

  cloudwatch_target_arns = [
    aws_cloudwatch_log_group.this.arn
  ]

  connections = {
    slack = {
      authorization_type = "API_KEY"

      auth_parameters = {
        api_key = {
          key   = "x-slack"
          value = "unused"
        }
      }
    }
  }

  api_destinations = {
    slack = {
      description                      = "Slack noti"
      invocation_endpoint              = var.slack_webhook
      http_method                      = "POST"
      invocation_rate_limit_per_second = 100

    }
  }

  rules = {
    ecs = {
      event_pattern = jsonencode({
        "source" : ["aws.ecs"],
        "detail-type" : ["ECS Task State Change"],
        "detail" : {
          "lastStatus" : ["STOPPING"],
          "clusterArn" : [module.ecs_cluster.cluster_arn]
        }
      })
    }
  }

  targets = {
    ecs = [
      {
        name = "log-orders-to-cloudwatch"
        arn  = aws_cloudwatch_log_group.this.arn
      },
      {
        name              = "send-slack-notification"
        destination       = "slack"
        attach_role_arn   = true
        input_transformer = local.slack_input_transformer
      }
    ]
  }

  tags = local.tags
}

# ################################################################################
# Cloudwatch Log Group
# ################################################################################

resource "aws_cloudwatch_log_group" "this" {
  name = "/aws/events/ecs/${local.name}"

  tags = local.tags
}


