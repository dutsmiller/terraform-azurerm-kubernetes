locals {
  cluster_name = "aks-${var.names.resource_group_type}-${var.names.product_name}-${var.names.environment}-${var.names.location}"

  aks_identity_id = (var.identity_type == "ServicePrincipal" ? data.azuread_service_principal.aks.0.id :
                     (var.identity_type == "UserAssigned" ? 
                      lookup(var.user_assigned_identity, "principal_id", azurerm_user_assigned_identity.aks.0.principal_id) :
                       azurerm_kubernetes_cluster.aks.identity.0.principal_id))
}

resource "azurerm_user_assigned_identity" "aks" {
  count = (var.identity_type == "UserAssigned" && var.user_assigned_identity != null ? 1 : 0)

  resource_group_name = var.resource_group_name
  location            = var.location
  name                = "uai-${local.cluster_name}"
}

resource "azurerm_role_assignment" "route_table_network_contributor" {
  for_each             = (var.identity_type == "UserAssigned" && var.configure_network_role ? var.custom_route_table_ids : {})

  scope                = each.value
  role_definition_name = "Network Contributor"
  principal_id         = local.aks_identity_id
}

module "subnet_config" {
  source = "./subnet_config"

  for_each = (var.aks_managed_vnet ? {} : var.node_pool_subnets)

  resource_group_name = var.resource_group_name 
  principal_id        = local.aks_identity_id
  subnet_info         = each.value

  configure_network_role  = var.configure_network_role
  configure_nsg_rules     = var.configure_subnet_nsg_rules
  nsg_rule_priority_start = var.subnet_nsg_rule_priority_start
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = local.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = "${var.names.product_name}-${var.names.environment}-${var.names.location}"
  tags                = var.tags

  kubernetes_version = var.kubernetes_version
  
  network_profile {
    network_plugin = var.network_plugin
  }

  default_node_pool {
    name                = var.default_node_pool_name
    vm_size             = var.default_node_pool_vm_size
    enable_auto_scaling = var.default_node_pool_enable_auto_scaling
    node_count          = (var.default_node_pool_enable_auto_scaling ? null : var.default_node_pool_node_count)
    min_count           = (var.default_node_pool_enable_auto_scaling ? var.default_node_pool_node_min_count : null)
    max_count           = (var.default_node_pool_enable_auto_scaling ? var.default_node_pool_node_max_count : null)
    availability_zones  = var.default_node_pool_availability_zones
    vnet_subnet_id      = (var.aks_managed_vnet ? null : var.node_pool_subnets[var.default_node_pool_subnet].id)
    tags                = var.tags
  }

  addon_profile {
    kube_dashboard {
      enabled = var.enable_kube_dashboard
    }
  }

  dynamic "windows_profile" {
    for_each = var.enable_windows_node_pools ? [1] : []
    content {
      admin_username = var.windows_profile_admin_username
      admin_password = var.windows_profile_admin_password
    }
  }

  dynamic "identity" {
    for_each = (var.identity_type == "ServicePrincipal" ? [] : [1])
    content {
      type                      = var.identity_type
      user_assigned_identity_id = lookup(var.user_assigned_identity, "id", null)
    }
  }

  dynamic "service_principal" {
    for_each = (var.identity_type == "ServicePrincipal" ? [1] : [])
    content {
      client_id     = var.service_principal_id
      client_secret = var.service_principal_secret
    }
  }
}
