package require ::quartus::project

project_open DE10_Standard_golden_top
set_global_assignment -name QIP_FILE soc_system/synthesis/soc_system.qip
export_assignments
project_close
