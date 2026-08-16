# Terraform example

A self-contained module using only the `local` and `random` providers, so it
runs anywhere with no cloud credentials and no cost.

```bash
cd examples/terraform
devbox terraform check      # fmt · validate · tflint · security · policy · docs
terraform init
terraform plan              # SAFE — read-only
```

There is deliberately no `apply` step documented here. `terraform apply` is
`APPROVAL_REQUIRED` in `ai/policies/policy.yaml`, and no command, alias or task
in this repository runs it for you.

## What this demonstrates

- `required_version` and `~>`-pinned providers
- typed variables with descriptions and `validation` blocks
- `sensitive = true` where it belongs
- described outputs
- `for_each` rather than `count`
- a nested module with a clean interface

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5 |
| <a name="requirement_local"></a> [local](#requirement\_local) | ~> 2.5 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.6 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_local"></a> [local](#provider\_local) | 2.9.0 |
| <a name="provider_random"></a> [random](#provider\_random) | 3.9.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_network"></a> [network](#module\_network) | ./modules/example-network | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [local_file.environment](https://registry.terraform.io/providers/hashicorp/local/latest/docs/resources/file) | resource |
| [random_id.suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_common_labels"></a> [common\_labels](#input\_common\_labels) | Labels applied to every resource. Consistent labelling is what makes cost and ownership attributable later. | `map(string)` | <pre>{<br/>  "example": "devbox",<br/>  "managed_by": "terraform"<br/>}</pre> | no |
| <a name="input_environments"></a> [environments](#input\_environments) | Environments to generate, keyed by environment name. | <pre>map(object({<br/>    region     = string<br/>    replicas   = number<br/>    cidr_block = string<br/>  }))</pre> | <pre>{<br/>  "dev": {<br/>    "cidr_block": "10.10.0.0/16",<br/>    "region": "us-east-1",<br/>    "replicas": 1<br/>  },<br/>  "prod": {<br/>    "cidr_block": "10.20.0.0/16",<br/>    "region": "us-east-1",<br/>    "replicas": 3<br/>  }<br/>}</pre> | no |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Project name used as a prefix for every generated resource. | `string` | `"devbox-example"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_generated_files"></a> [generated\_files](#output\_generated\_files) | Paths of the generated environment files, keyed by environment. |
| <a name="output_instance_suffixes"></a> [instance\_suffixes](#output\_instance\_suffixes) | Per-environment random suffixes. Marked sensitive to demonstrate the practice. |
| <a name="output_network_ids"></a> [network\_ids](#output\_network\_ids) | Network identifiers produced by the example-network module. |
| <a name="output_subnet_cidrs"></a> [subnet\_cidrs](#output\_subnet\_cidrs) | Subnet CIDR blocks per environment. |
<!-- END_TF_DOCS -->
