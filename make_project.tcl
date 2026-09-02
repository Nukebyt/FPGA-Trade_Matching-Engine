# Materializes the real .qsf from platform_setup.tcl's setup_project proc
# (the golden_top starter ships assignments as a sourceable Tcl script,
# not a .qsf directly - this is the one-time step that turns it into an
# actual openable Quartus project).
package require ::quartus::project

set proj_name "DE10_Standard_golden_top"

if {[project_exists $proj_name]} {
    project_open $proj_name
} else {
    project_new $proj_name
}

source platform_setup.tcl
setup_project

export_assignments
project_close
