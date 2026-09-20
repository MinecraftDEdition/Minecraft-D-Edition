# Watertight merged block faces

The greedy mesher previously emitted large two-triangle rectangles. Short
neighboring edges could terminate partway along these edges (T-junctions),
including at chunk and vertical section boundaries. Camera-dependent raster
rounding can expose background pixels at these otherwise coincident edges.

Merged rectangles now use a center fan with perimeter vertices at every block
boundary. Axis-aligned integer steps produce exact matching edge coordinates.
Single-block faces retain their original triangulation and AO. Flat merged
faces retain their original lighting and repeating texture coordinates, with
no geometric expansion, texture bleeding workaround, or depth bias.

This increases a merged w-by-h rectangle from two triangles to 2*(w+h),
while avoiding 2*w*h triangles for large surfaces. Existing initial-neighborhood
mesh size regression still passes. Shared geometry serves DX12 and Vulkan,
including MoltenVK; no renderer-specific shader change is required.

Immediate block-face removal now processes triangles instead of assuming every
six vertices form a quad, preserving the block visibility hotfix.

Validation: all six face directions, outward winding, exact area and unit
boundary edges; renderer module regressions; closed stepped room spanning
chunks, viewed from 24 moving camera poses on both DX12 and Vulkan with a
contrasting background; existing fire depth and leaf-cutout rendering tests.
Mac runtime testing was not performed locally. Existing worlds need only reload
with the rebuilt executable to regenerate their cached meshes.
