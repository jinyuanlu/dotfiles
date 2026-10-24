# shellcheck shell=bash disable=SC2034  # helios-engvm's create.sh reads these
#
# engvm-lab.sh — the Helios guest's sizing for helios-engvm (plan: "Host and
# guest"). Pushed with host/ on every up; the engvm stage of helios-lab-host
# installs it in the checkout as config/lab.sh. `create.sh lab` sources
# config/defaults.sh, then this, so the VM keeps its default name, helios.
# 3 vCPU and 8 GiB leave an m8i.xlarge host 1 vCPU and 8 GiB of its own.
#
# A change here applies only to a guest created after it: a verified guest is
# never recreated, and helios-lab status shows the mismatch instead. Keep the
# three lines in these forms: helios-lab-host lab_sizing refuses anything else.
VCPU=3
MEM=$(( 8 * 1024 * 1024 ))
SIZE=60G
