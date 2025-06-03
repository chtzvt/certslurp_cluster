provider "azurerm" {
  features {}
  subscription_id                 = local.subscription_id
  resource_provider_registrations = "none"
}

locals {
  subscription_id = var.subscription_id
  location        = var.location
  resource_group  = var.resource_group

  ssh_public_key = var.ssh_public_key

  db_user_name     = var.db_user_name
  db_user_password = var.db_user_password

  slurpload_db_password = var.slurpload_db_password
  slurpload_port        = var.slurpload_port

  my_home_ip = chomp(data.http.wanip.response_body)

  postgres_init_rendered = templatefile("${path.module}/init_scripts/postgres_init.sh.tpl", {
    mount_point           = "/mnt/postgres"
    data_device           = "/dev/disk/azure/scsi1/lun0" # azurerm_virtual_machine_data_disk_attachment.postgres.lun
    pg_version            = "16"
    pg_data_dir           = "/mnt/postgres/pgdata"
    admin_username        = "azureuser"
    slurpload_db_password = local.slurpload_db_password
    db_user_name          = local.db_user_name
    db_user_password      = local.db_user_password
  })

  slurpload_init_rendered = templatefile("${path.module}/init_scripts/slurpload_init.sh.tpl", {
    postgres_internal_ip  = azurerm_network_interface.postgres.private_ip_address
    slurpload_db_password = local.slurpload_db_password
    slurpload_port        = local.slurpload_port
  })
}

variable "subscription_id" {
  description = "Azure subscription id"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group" {
  description = "resource group name"
  type        = string
}

variable "ssh_public_key" {
  description = "your ssh public key"
  type        = string
}

variable "db_user_name" {
  description = "read/query db user name"
  type        = string
}

variable "db_user_password" {
  description = "read/query db user password"
  type        = string
}

variable "slurpload_db_password" {
  description = "slurpload db password (ingestion)"
  type        = string
}

variable "slurpload_port" {
  description = "slurpload http listen port"
  default     = "8080"
  type        = string
}

data "http" "wanip" {
  url = "http://whatismyip.akamai.com"
}

output "postgres_public_ip" {
  value = azurerm_public_ip.postgres.ip_address
}

output "slurpload_public_ip" {
  value = azurerm_public_ip.slurpload.ip_address
}

output "my_home_ip" {
  value = local.my_home_ip
}

output "acr_login_server" {
  value = azurerm_container_registry.certslurp.login_server
}

output "acr_username" {
  value = azurerm_container_registry.certslurp.admin_username
}

output "acr_password" {
  value     = azurerm_container_registry.certslurp.admin_password
  sensitive = true
}

resource "azurerm_resource_group" "main" {
  name     = local.resource_group
  location = local.location
}

resource "azurerm_container_registry" "certslurp" {
  name                = "certslurp${random_integer.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Standard"
  admin_enabled       = true
}

resource "random_integer" "suffix" {
  min = 1000
  max = 9999
}

resource "azurerm_virtual_network" "main" {
  name                = "certslurp-vnet"
  location            = local.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "aks" {
  name                 = "aks-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.0.0/22"]
}

resource "azurerm_subnet" "slurpload" {
  name                 = "slurpload-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.4.0/24"]
}

resource "azurerm_subnet" "postgres" {
  name                 = "postgres-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.5.0/24"]
}

# Multiple public IPs for NAT Gateway
resource "azurerm_public_ip" "nat" {
  count               = 12 # Up to 16 per NAT Gateway
  name                = "aks-nat-ip-${count.index}"
  location            = local.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_nat_gateway" "aks" {
  name                = "aks-nat"
  location            = local.location
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = "Standard"
}

resource "azurerm_nat_gateway_public_ip_association" "aks" {
  for_each = { for pip in azurerm_public_ip.nat : pip.name => pip }

  nat_gateway_id       = azurerm_nat_gateway.aks.id
  public_ip_address_id = each.value.id
}

resource "azurerm_network_security_group" "slurpload" {
  name                = "slurpload-nsg"
  location            = local.location
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "AllowHTTPFromAKS"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = azurerm_subnet.aks.address_prefixes[0]
    destination_port_range     = local.slurpload_port # or whatever port slurpload listens on
    destination_address_prefix = "*"
    source_port_range          = "*"
  }

  security_rule {
    name                       = "AllowSSHFromHome"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "${local.my_home_ip}/32"
    destination_port_range     = "22"
    destination_address_prefix = "*"
    source_port_range          = "*"
  }

  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_address_prefix      = "*"
    destination_port_range     = "*"
    destination_address_prefix = "*"
    source_port_range          = "*"
  }
}

resource "azurerm_network_security_group" "postgres" {
  name                = "postgres-nsg"
  location            = local.location
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "AllowPostgresFromSlurpload"
    priority                   = 210
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = azurerm_subnet.slurpload.address_prefixes[0]
    destination_port_range     = "5432"
    destination_address_prefix = "*"
    source_port_range          = "*"
  }

  security_rule {
    name                       = "AllowSSHFromHome"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "${local.my_home_ip}/32"
    destination_port_range     = "22"
    destination_address_prefix = "*"
    source_port_range          = "*"
  }

  security_rule {
    name                       = "AllowPostgresFromHome"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "${local.my_home_ip}/32"
    destination_port_range     = "5432"
    destination_address_prefix = "*"
    source_port_range          = "*"
  }

  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_address_prefix      = "*"
    destination_port_range     = "*"
    destination_address_prefix = "*"
    source_port_range          = "*"
  }
}

resource "azurerm_subnet_nat_gateway_association" "aks" {
  subnet_id      = azurerm_subnet.aks.id
  nat_gateway_id = azurerm_nat_gateway.aks.id
}

# AKS Cluster
resource "azurerm_kubernetes_cluster" "main" {
  name                = "certslurp-aks"
  location            = local.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = "certslurp"

  default_node_pool {
    name                        = "nodepool1"
    temporary_name_for_rotation = "certslurptmp"

    # Note: MUST have at least as many nodes as etd pods
    node_count     = 3
    max_pods       = 80
    vm_size        = "Standard_B16als_v2"
    vnet_subnet_id = azurerm_subnet.aks.id

    # For high node counts, disk IOPS are a severe bottleneck for etcd
    ultra_ssd_enabled = true
    zones             = [1]
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
    service_cidr   = "10.96.0.0/16"
    dns_service_ip = "10.96.0.10"
  }
}

# Slurpload VM
resource "azurerm_network_interface" "slurpload" {
  name                = "slurpload-nic"
  location            = local.location
  resource_group_name = azurerm_resource_group.main.name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.slurpload.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.slurpload.id
  }
}

resource "azurerm_network_interface_security_group_association" "slurpload" {
  network_interface_id      = azurerm_network_interface.slurpload.id
  network_security_group_id = azurerm_network_security_group.slurpload.id
}

resource "azurerm_public_ip" "slurpload" {
  name                = "slurpload-pip"
  location            = local.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_linux_virtual_machine" "slurpload" {
  name                  = "slurpload-vm"
  resource_group_name   = azurerm_resource_group.main.name
  location              = local.location
  size                  = "Standard_B8als_v2"
  admin_username        = "azureuser"
  network_interface_ids = [azurerm_network_interface.slurpload.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 512
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  admin_ssh_key {
    username   = "azureuser"
    public_key = local.ssh_public_key
  }

  custom_data = base64encode(local.slurpload_init_rendered)
}

# Postgres VM
resource "azurerm_network_interface" "postgres" {
  name                = "postgres-nic"
  location            = local.location
  resource_group_name = azurerm_resource_group.main.name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.postgres.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.postgres.id
  }
}

resource "azurerm_network_interface_security_group_association" "postgres" {
  network_interface_id      = azurerm_network_interface.postgres.id
  network_security_group_id = azurerm_network_security_group.postgres.id
}

resource "azurerm_public_ip" "postgres" {
  name                = "postgres-pip"
  location            = local.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# Current metrics from local test:
# 1911702 certs / 4512122 FDQNs -> 3GB base, 1.1GB WAL
# We'll have many billions in prod
resource "azurerm_managed_disk" "postgres_data" {
  create_option        = "Empty"
  name                 = "postgres-data-disk"
  location             = local.location
  resource_group_name  = azurerm_resource_group.main.name
  storage_account_type = "Premium_LRS"
  disk_size_gb         = 8192
}

resource "azurerm_linux_virtual_machine" "postgres" {
  name                  = "postgres-vm"
  resource_group_name   = azurerm_resource_group.main.name
  location              = local.location
  size                  = "Standard_E8as_v5"
  admin_username        = "azureuser"
  network_interface_ids = [azurerm_network_interface.postgres.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 64 # Typical OS disk, leave this as default or as needed (max 4095)
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  admin_ssh_key {
    username   = "azureuser"
    public_key = local.ssh_public_key
  }

  custom_data = base64encode(local.postgres_init_rendered)
}

resource "azurerm_virtual_machine_data_disk_attachment" "postgres" {
  managed_disk_id    = azurerm_managed_disk.postgres_data.id
  virtual_machine_id = azurerm_linux_virtual_machine.postgres.id
  lun                = "0"
  caching            = "None" # Only Disk CachingType 'None' is supported for disk with size greater than 4095 GB
}
