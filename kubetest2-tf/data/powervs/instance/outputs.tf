output "addresses" {
  value = ibm_pi_instance.pvminstance.*.pi_network
}

output "ids" {
  value       = ibm_pi_instance.pvminstance[*].instance_id
  description = "PowerVS instance UUIDs"
}
