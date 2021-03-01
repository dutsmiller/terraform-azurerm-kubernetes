terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=2.48.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "=2.3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "=1.13.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "=1.3.2"
    }
  }
   required_version = "=0.14.7"
}

provider "azurerm" {
  features {}
}

provider "kubernetes" {
  host                   = module.kubernetes.host
  client_certificate     = base64decode(module.kubernetes.client_certificate)
  client_key             = base64decode(module.kubernetes.client_key)
  cluster_ca_certificate = base64decode(module.kubernetes.cluster_ca_certificate)
  load_config_file       = false
}

provider "helm" {
  kubernetes {
    host                   = module.kubernetes.host
    client_certificate     = base64decode(module.kubernetes.client_certificate)
    client_key             = base64decode(module.kubernetes.client_key)
    cluster_ca_certificate = base64decode(module.kubernetes.cluster_ca_certificate)
  }
}

data "http" "my_ip" {
  url = "http://ipv4.icanhazip.com"
}

data "azurerm_subscription" "current" {
}

resource "random_string" "random" {
  length  = 12
  upper   = false
  number  = false
  special = false
}

resource "random_password" "admin" {
  length      = 14
  special     = true
}

module "subscription" {
  source = "github.com/Azure-Terraform/terraform-azurerm-subscription-data.git?ref=v1.0.0"
  subscription_id = data.azurerm_subscription.current.subscription_id
}

module "naming" {
  source = "github.com/Azure-Terraform/example-naming-template.git?ref=v1.0.0"
}

module "metadata" {
  source = "github.com/Azure-Terraform/terraform-azurerm-metadata.git?ref=v1.1.0"

  naming_rules = module.naming.yaml

  market              = "us"
  project             = "https://github.com/Azure-Terraform/terraform-azurerm-kubernetes/tree/master/example/mixed-arch"
  location            = "eastus2"
  environment         = "sandbox"
  product_name        = random_string.random.result
  business_unit       = "infra"
  product_group       = "contoso"
  subscription_id     = module.subscription.output.subscription_id
  subscription_type   = "dev"
  resource_group_type = "app"
}

module "resource_group" {
  source = "github.com/Azure-Terraform/terraform-azurerm-resource-group.git?ref=v1.0.0"

  location = module.metadata.location
  names    = module.metadata.names
  tags     = module.metadata.tags
}

module "virtual_network" {
  source = "github.com/Azure-Terraform/terraform-azurerm-virtual-network.git?ref=v2.5.1"

  naming_rules = module.naming.yaml

  resource_group_name = module.resource_group.name
  location            = module.resource_group.location
  names               = module.metadata.names
  tags                = module.metadata.tags

  address_space = ["10.1.0.0/22"]

  subnets = {
    "iaas-private" = { cidrs = ["10.1.0.0/24"] }
    "iaas-public"  = { cidrs                   = ["10.1.1.0/24"]
                       allow_lb_inbound        = true    # Allow traffic from Azure Load Balancer to pods
                       allow_internet_outbound = true }  # Allow traffic to Internet for image download
  }
}

module "kubernetes" {
  source = "../../"

  kubernetes_version = "1.18.10"

  location                 = module.metadata.location
  names                    = module.metadata.names
  tags                     = module.metadata.tags
  resource_group_name      = module.resource_group.name

  identity_type = "UserAssigned"

  enable_windows_node_pools      = true
  windows_profile_admin_username = "testadmin"
  windows_profile_admin_password = random_password.admin.result

  network_plugin             = "azure"
  configure_network_role     = true
  configure_subnet_nsg_rules = true

  node_pools = {
    default = {
      name                               = "system"
      subnet_id                          = module.virtual_network.subnets["iaas-private"].id
      subnet_resource_group_name         = module.virtual_network.subnets["iaas-private"].resource_group_name
      subnet_network_security_group_name = module.virtual_network.subnets["iaas-private"].network_security_group_name
    }
    linux_web = {
      name                               = "linuxweb"
      enable_auto_scaling                = true
      min_count                          = 1
      max_count                          = 3
      subnet_id                          = module.virtual_network.subnets["iaas-public"].id
      subnet_resource_group_name         = module.virtual_network.subnets["iaas-public"].resource_group_name
      subnet_network_security_group_name = module.virtual_network.subnets["iaas-public"].network_security_group_name
    }
    windows_web = {
      name                               = "winweb"
      os_type                            = "Windows"
      vm_size                            = "Standard_D2_v3"
      enable_auto_scaling                = true
      min_count                          = 1
      max_count                          = 3
      subnet_id                          = module.virtual_network.subnets["iaas-public"].id
      subnet_resource_group_name         = module.virtual_network.subnets["iaas-public"].resource_group_name
      subnet_network_security_group_name = module.virtual_network.subnets["iaas-public"].network_security_group_name
    }
  }
}

resource "azurerm_network_security_rule" "ingress_public_allow_nginx" {
  name                        = "AllowNginx"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "Internet"
  destination_address_prefix  = data.kubernetes_service.nginx.load_balancer_ingress.0.ip
  resource_group_name         = module.virtual_network.subnets["iaas-public"].resource_group_name
  network_security_group_name = module.virtual_network.subnets["iaas-public"].network_security_group_name
}

resource "azurerm_network_security_rule" "ingress_public_allow_iis" {
  name                        = "AllowIIS"
  priority                    = 101
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "Internet"
  destination_address_prefix  = data.kubernetes_service.iis.load_balancer_ingress.0.ip
  resource_group_name         = module.virtual_network.subnets["iaas-public"].resource_group_name
  network_security_group_name = module.virtual_network.subnets["iaas-public"].network_security_group_name
}

resource "helm_release" "nginx" {
  depends_on = [azurerm_kubernetes_cluster_node_pool.linux_webservers]
  name       = "nginx"
  chart      = "./helm_chart"

  set {
    name  = "name"
    value = "nginx"
  }

  set {
    name  = "image"
    value = "nginx:latest"
  }

  set {
    name  = "nodeSelector"
    value = yamlencode({agentpool = "linuxweb"})
  }
}

resource "helm_release" "iis" {
  depends_on = [azurerm_kubernetes_cluster_node_pool.windows_webservers]
  name       = "iis"
  chart      = "./helm_chart"
  timeout    = 600

  set {
    name  = "name"
    value = "iis"
  }

  set {
    name  = "image"
    value = "microsoft/iis:latest"
  }

  set {
    name  = "nodeSelector"
    value = yamlencode({agentpool = "winweb"})
  }
}

data "kubernetes_service" "nginx" {
  depends_on = [helm_release.nginx] 
  metadata {
    name = "nginx"
  }
}

data "kubernetes_service" "iis" {
  depends_on = [helm_release.iis] 
  metadata {
    name = "iis"
  }
}

output "nginx_url" {
  value = "http://${data.kubernetes_service.nginx.load_balancer_ingress.0.ip}"
}

output "iis_url" {
  value = "http://${data.kubernetes_service.iis.load_balancer_ingress.0.ip}"
}

output "aks_login" {
  value = "az aks get-credentials --name ${module.kubernetes.name} --resource-group ${module.resource_group.name}"
}
