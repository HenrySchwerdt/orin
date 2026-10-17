# The runtime source list for shell scripts (ADR-0052 Addendum A section 4): `. tools/runtime_files.sh` from the repository root.
# The data is tools/runtime-sources.txt; this file only reads it.
#   rt_inc [world]    the -I flags            rt_src [world]   the C files a program is linked with
#   rt_llvm [world]   the extra file of the LLVM backend (the out-of-line shim)
# world: core (default, the live runtime) or legacy (the frozen snapshot bootstrap/seed/runtime/).
_rt_list() { awk -F' *= *' -v k="$1" '$1 == k { print $2 }' tools/runtime-sources.txt; }
rt_inc() { for _d in $(_rt_list "${1:-core}.include"); do printf -- '-I %s ' "$_d"; done; }
rt_src() { _rt_list "${1:-core}.sources"; }
rt_llvm() { _rt_list "${1:-core}.llvm"; }
