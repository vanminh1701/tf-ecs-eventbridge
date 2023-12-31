provider "aws" {}

data "aws_availability_zones" "available" {}

# https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-optimized_AMI.html#ecs-optimized-ami-linux
data "aws_ssm_parameter" "ecs_optimized_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended"
}

locals {
  name = "ecs-alarm"

  vpc_cidr = var.vpc_cidr
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  capacities = {
    ondemand = "ex_1"
    fargate  = "ex_ecs"
  }

  service_objects = {
    kuard = {
      container_name   = "kuard"
      container_port   = 8080
      alb_target_group = "ex_ecs"
      image            = "gcr.io/kuar-demo/kuard-amd64:blue"
      desired_count    = 1
    }
    nginx = {
      container_name   = "nginx"
      container_port   = 80
      alb_target_group = "ex_1"
      image            = "nginxdemos/hello"
      desired_count    = 2
    }
  }

  services = {
    for each_service in local.service_objects : each_service.container_name => {
      # Enables ECS Exec
      enable_execute_command = true

      desired_count = each_service.desired_count

      # Container definition(s)
      container_definitions = {
        (each_service.container_name) = {
          cpu       = 512
          memory    = 1024
          essential = true
          image     = each_service.image

          port_mappings = [{
            name          = each_service.container_name
            containerPort = each_service.container_port
            hostPort      = each_service.container_port
            protocol      = "tcp"
          }]

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

      load_balancer = {
        service = {
          target_group_arn = module.alb.target_groups[each_service.alb_target_group].arn
          container_name   = each_service.container_name
          container_port   = each_service.container_port
        }
      }

      subnet_ids = module.vpc.private_subnets
      security_group_rules = {
        alb_ingress_ecs = {
          type                     = "ingress"
          from_port                = each_service.container_port
          to_port                  = each_service.container_port
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

  slack_input_transformer = {
    input_paths = {
      id = "$.id"
    }
    input_template = <<EOF
{
  "text" : "ECS Task State Change id <id>"
}
EOF
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

  autoscaling_capacity_providers = {
    # On-demand instances
    (local.capacities.ondemand) = {
      auto_scaling_group_arn         = module.autoscaling[local.capacities.ondemand].autoscaling_group_arn
      managed_termination_protection = "ENABLED"

      managed_scaling = {
        maximum_scaling_step_size = 2
        minimum_scaling_step_size = 1
        status                    = "ENABLED"
        target_capacity           = 100
      }

      default_capacity_provider_strategy = {
        weight = 100
      }
    }
  }

  services = local.services

  tags = local.tags
}

################################################################################
# Supporting Resources
################################################################################
module "autoscaling" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "~> 6.5"

  for_each = {
    # On-demand instances
    (local.capacities.ondemand) = {
      instance_type              = "t3.medium"
      use_mixed_instances_policy = false
      mixed_instances_policy     = {}
      user_data                  = <<-EOT
        #!/bin/bash

        cat <<'EOF' >> /etc/ecs/ecs.config
        ECS_CLUSTER=${local.name}
        ECS_LOGLEVEL=debug
        ECS_CONTAINER_INSTANCE_TAGS=${jsonencode(local.tags)}
        ECS_ENABLE_TASK_IAM_ROLE=true
        EOF
      EOT
    }
  }

  name = "${local.name}-${each.key}"

  image_id      = jsondecode(data.aws_ssm_parameter.ecs_optimized_ami.value)["image_id"]
  instance_type = each.value.instance_type

  security_groups                 = [module.autoscaling_sg.security_group_id]
  user_data                       = base64encode(each.value.user_data)
  ignore_desired_capacity_changes = true

  create_iam_instance_profile = true
  iam_role_name               = local.name
  iam_role_description        = "ECS role for ${local.name}"
  iam_role_policies = {
    AmazonEC2ContainerServiceforEC2Role = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
    AmazonSSMManagedInstanceCore        = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  vpc_zone_identifier = module.vpc.private_subnets
  health_check_type   = "EC2"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1

  # https://github.com/hashicorp/terraform-provider-aws/issues/12582
  autoscaling_group_tags = {
    AmazonECSManaged = true
  }

  # Required for  managed_termination_protection = "ENABLED"
  protect_from_scale_in = true

  # Spot instances
  use_mixed_instances_policy = each.value.use_mixed_instances_policy
  mixed_instances_policy     = each.value.mixed_instances_policy

  tags = local.tags
}

module "autoscaling_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = local.name
  description = "Autoscaling group security group"
  vpc_id      = module.vpc.vpc_id

  computed_ingress_with_source_security_group_id = [{
    rule                     = "http-80-tcp"
    source_security_group_id = module.alb.security_group_id
  }]
  number_of_computed_ingress_with_source_security_group_id = 1

  egress_rules = ["all-all"]

  tags = local.tags
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

      rules = {
        nginx = {
          priority = 1
          conditions = [{
            path_pattern = { values = ["/nginx"] }
          }]
          actions = [{
            type             = "forward"
            target_group_key = "ex_1"
          }]
        }

      }
    }
  }

  target_groups = {
    for each_service in local.service_objects : each_service.alb_target_group => {
      backend_protocol                  = "HTTP"
      backend_port                      = each_service.container_port
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
  source  = "terraform-aws-modules/eventbridge/aws"
  version = "~> 3.0"

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


