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

  my_home_ip = chomp(data.http.wanip.response_body)

  clickhouse_admin_username         = var.clickhouse_admin_username
  clickhouse_admin_password         = var.clickhouse_admin_password
  clickhouse_readonly_user_name     = var.clickhouse_readonly_user_name
  clickhouse_readonly_user_password = var.clickhouse_readonly_user_password

  clickhouse_init_rendered = templatefile("${path.module}/init_scripts/clickhouse.sh.tpl", {
    mount_point            = "/mnt/clickhouse"
    data_device            = "/dev/disk/azure/scsi1/lun0" # azurerm_virtual_machine_data_disk_attachment.clickhouse.lun
    admin_username         = local.clickhouse_admin_username
    admin_password         = local.clickhouse_admin_password
    readonly_user_name     = local.clickhouse_readonly_user_name
    readonly_user_password = local.clickhouse_readonly_user_password
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

data "http" "wanip" {
  url = "http://whatismyip.akamai.com"
}

output "clickhouse_public_ip" {
  value = azurerm_public_ip.clickhouse.ip_address
}

output "my_home_ip" {
  value = local.my_home_ip
}

variable "clickhouse_admin_username" {
  description = "Clickhouse admin username"
  type        = string
}

variable "clickhouse_admin_password" {
  description = "Clickhouse admin password"
  type        = string
}

variable "clickhouse_readonly_user_name" {
  description = "Clickhouse read-only user name"
  type        = string
}

variable "clickhouse_readonly_user_password" {
  description = "Clickhouse read-only user password"
  type        = string
}



resource "azurerm_resource_group" "main" {
  name     = local.resource_group
  location = local.location
}

resource "azurerm_virtual_network" "main" {
  name                = "clickhouse-vnet"
  location            = local.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "clickhouse" {
  name                 = "clickhouse-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.5.0/24"]
  service_endpoints    = ["Microsoft.Storage"]
}

resource "azurerm_network_security_group" "clickhouse" {
  name                = "clickhouse-nsg"
  location            = local.location
  resource_group_name = azurerm_resource_group.main.name

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
    name                       = "AllowClickhouseFromHome"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "${local.my_home_ip}/32"
    destination_port_range     = "9000"
    destination_address_prefix = "*"
    source_port_range          = "*"
  }

  security_rule {
    name                       = "AllowClickhouseHttpFromHome"
    priority                   = 300
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "${local.my_home_ip}/32"
    destination_port_range     = "8123"
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

# Clickhouse VM
resource "azurerm_network_interface" "clickhouse" {
  name                = "clickhouse-nic"
  location            = local.location
  resource_group_name = azurerm_resource_group.main.name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.clickhouse.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.clickhouse.id
  }
}

resource "azurerm_network_interface_security_group_association" "clickhouse" {
  network_interface_id      = azurerm_network_interface.clickhouse.id
  network_security_group_id = azurerm_network_security_group.clickhouse.id
}

resource "azurerm_public_ip" "clickhouse" {
  name                = "clickhouse-pip"
  location            = local.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_linux_virtual_machine" "clickhouse" {
  name                  = "clickhouse-vm"
  resource_group_name   = azurerm_resource_group.main.name
  location              = local.location
  size                  = "Standard_E8bs_v5"
  admin_username        = "azureuser"
  network_interface_ids = [azurerm_network_interface.clickhouse.id]
  zone                  = 1

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 64
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

  custom_data = base64encode(local.clickhouse_init_rendered)
}

resource "azurerm_managed_disk" "clickhouse_data" {
  create_option        = "Empty"
  name                 = "clickhouse-data-disk"
  location             = local.location
  resource_group_name  = azurerm_resource_group.main.name
  zone                 = 1
  storage_account_type = "PremiumV2_LRS"
  disk_size_gb         = 4096
}

resource "azurerm_virtual_machine_data_disk_attachment" "clickhouse" {
  managed_disk_id    = azurerm_managed_disk.clickhouse_data.id
  virtual_machine_id = azurerm_linux_virtual_machine.clickhouse.id
  lun                = "0"
  caching            = "None" # Only Disk CachingType 'None' is supported for disk with size greater than 4095 GB
}
