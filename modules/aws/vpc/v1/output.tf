output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnets" {
  value = [for subnet in aws_subnet.public : subnet.id]
}

output "private_subnets" {
  value = [for subnet in aws_subnet.private : subnet.id]
}

output "aws_internet_gateway" {
  value = aws_internet_gateway.main
}

output "aws_route_table_public" {
  description = "The ID of the public route table"
  value       = aws_route_table.public.id
}

output "aws_route_table_private" {
  description = "The ID of the private route table"
  value       = aws_route_table.private.id
}


output "nat_gateway_ipv4_address" {
  value = var.nat_gateway ? aws_eip.nat_gateway[0].public_ip : null
}
